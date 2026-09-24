package durrent

import "core:fmt"
import endian "core:encoding/endian"
import "core:crypto/hash"
import "core:net"
import "core:sync"
import "core:time"

DHT_Network_Options :: struct {
	Timeout:     time.Duration,
	Max_Queries: u32,
}

DHT_Default_Network_Options :: proc() -> DHT_Network_Options {
	return DHT_Network_Options{Timeout = 3 * time.Second, Max_Queries = 32}
}

// DHT_Default_Bootstrap_Nodes returns well-known public DHT router seeds.
// Their IDs are synthetic until a response supplies the real remote ID; the
// endpoint is what matters for the initial query.
DHT_Default_Bootstrap_Nodes :: proc() -> [dynamic]DHT_Node {
	seeds: [dynamic]DHT_Node
	endpoints: [3]DHT_Endpoint
	endpoints[0].IP[0] = 87
	endpoints[0].IP[1] = 98
	endpoints[0].IP[2] = 162
	endpoints[0].IP[3] = 88
	endpoints[0].Port = 6881
	endpoints[1].IP[0] = 82
	endpoints[1].IP[1] = 221
	endpoints[1].IP[2] = 103
	endpoints[1].IP[3] = 244
	endpoints[1].Port = 6881
	endpoints[2].IP[0] = 67
	endpoints[2].IP[1] = 215
	endpoints[2].IP[2] = 246
	endpoints[2].IP[3] = 10
	endpoints[2].Port = 6881
	for endpoint, index in endpoints {
		append(&seeds, DHT_Node{
			ID = DHT_Node_ID_Generate(u64(0xD71000 + index + 1)),
			Endpoint = endpoint,
		})
	}
	return seeds
}

DHT_Client_Load_Routing :: proc(client: ^DHT_Client, path: string) -> DHT_Error {
	if client == nil || len(path) == 0 {
		return .Invalid_DHT
	}
	return DHT_Routing_Load(&client.Routing, path)
}

DHT_Client_Save_Routing :: proc(client: ^DHT_Client, path: string) -> DHT_Error {
	if client == nil || len(path) == 0 {
		return .Invalid_DHT
	}
	return DHT_Routing_Save(&client.Routing, path)
}

DHT_Lookup_Target :: struct {
	Node:  DHT_Node,
	Token: []byte,
}

DHT_Lookup_Result :: struct {
	Peers:  [dynamic]DHT_Endpoint,
	Targets: [dynamic]DHT_Lookup_Target,
}

Destroy_DHT_Lookup_Result :: proc(result: ^DHT_Lookup_Result) {
	if result == nil {
		return
	}
	for &target in result.Targets {
		delete(target.Token)
	}
	delete(result.Targets)
	delete(result.Peers)
	result^ = DHT_Lookup_Result{}
}

DHT_Client_Outbound_Packet :: struct {
	// Data ownership transfers to the caller of DHT_Client_Dequeue_Outbound.
	Data:        []byte,
	Endpoint:    DHT_Endpoint,
	Transaction: [2]byte,
}

DHT_Client :: struct {
	Mutex:       sync.Mutex,
	Exchange_Cond: sync.Cond,
	Socket:      net.UDP_Socket,
	Socket6:     net.UDP_Socket,
	Has_Socket6: bool,
	Owns_Sockets: bool,
	Node_ID:     DHT_Node_ID,
	Routing:     DHT_Routing_Table,
	Token_Secret: [20]byte,
	Previous_Secret: [20]byte,
	Secret_Time: time.Time,
	Transaction: u16,
	Open:         bool,

	// Exactly one exchange is active at a time. In external-socket mode the
	// dispatcher owns socket I/O and these fields bridge its datagrams back to
	// the synchronous lookup worker.
	External_Sockets: bool,
	Exchange_Active:  bool,
	Pending_Endpoint: DHT_Endpoint,
	Pending_Transaction: [2]byte,
	Pending_Response: DHT_Message,
	Pending_Error:    DHT_Error,
	Pending_Ready:    bool,
	Outbound:         [dynamic]DHT_Client_Outbound_Packet,
}

DHT_Client_Init :: proc(
	client: ^DHT_Client,
	torrent: ^Torrent,
	node_id: DHT_Node_ID,
	port: u16,
	options := DHT_Network_Options{Timeout = 3 * time.Second, Max_Queries = 32},
) -> DHT_Error {
	if client == nil {
		return .Invalid_DHT
	}
	if torrent != nil && !Torrent_Allows_DHT(torrent) {
		return .Private_Torrent
	}
	DHT_Client_Destroy(client)
	socket4, socket4_error := net.make_bound_udp_socket(net.IP4_Any, int(port))
	socket6, socket6_error := net.make_bound_udp_socket(net.IP6_Any, int(port))
	socket4_ready := socket4_error == nil
	socket6_ready := socket6_error == nil
	if !socket4_ready && !socket6_ready {
		return .Socket
	}
	timeout := options.Timeout if options.Timeout > 0 else DHT_Default_Network_Options().Timeout
	if socket4_ready && dht_configure_socket(socket4, timeout) != .None {
		net.close(socket4)
		socket4_ready = false
	}
	if socket6_ready && dht_configure_socket(socket6, timeout) != .None {
		net.close(socket6)
		socket6_ready = false
	}
	if !socket4_ready && !socket6_ready {
		return .Socket
	}
	if DHT_Routing_Init(&client.Routing, node_id) != .None {
		if socket4_ready {
			net.close(socket4)
		}
		if socket6_ready {
			net.close(socket6)
		}
		return .Out_Of_Memory
	}
	sync.mutex_lock(&client.Mutex)
	client.Socket = socket4
	client.Socket6 = socket6
	client.Has_Socket6 = socket6_ready
	client.Owns_Sockets = true
	client.Node_ID = node_id
	client.Token_Secret = node_id
	client.Secret_Time = time.now()
	client.Transaction = 1
	client.Open = true
	sync.mutex_unlock(&client.Mutex)
	return .None
}

// DHT_Client_Init_External initializes a client whose UDP sockets are owned
// and polled by the caller. The caller must relay packets through the public
// dequeue, send-error, and datagram handler APIs below.
DHT_Client_Init_External :: proc(
	client: ^DHT_Client,
	torrent: ^Torrent,
	node_id: DHT_Node_ID,
	socket4: net.UDP_Socket,
	socket6: net.UDP_Socket,
	has_socket6: bool,
) -> DHT_Error {
	if client == nil {
		return .Invalid_DHT
	}
	if torrent != nil && !Torrent_Allows_DHT(torrent) {
		return .Private_Torrent
	}
	DHT_Client_Destroy(client)
	if DHT_Routing_Init(&client.Routing, node_id) != .None {
		return .Out_Of_Memory
	}
	sync.mutex_lock(&client.Mutex)
	client.Socket = socket4
	client.Socket6 = socket6
	client.Has_Socket6 = has_socket6
	client.Owns_Sockets = false
	client.External_Sockets = true
	client.Node_ID = node_id
	client.Token_Secret = node_id
	client.Secret_Time = time.now()
	client.Transaction = 1
	client.Open = true
	sync.mutex_unlock(&client.Mutex)
	return .None
}

DHT_Client_Destroy :: proc(client: ^DHT_Client) {
	if client == nil {
		return
	}
	sync.mutex_lock(&client.Mutex)
	close_sockets := client.Open && client.Owns_Sockets
	socket4 := client.Socket
	socket6 := client.Socket6
	has_socket6 := client.Has_Socket6
	client.Open = false
	client.Owns_Sockets = false
	client.External_Sockets = false
	if client.Exchange_Active {
		dht_client_remove_pending_outbound_locked(client)
		Destroy_DHT_Message(&client.Pending_Response)
		client.Pending_Error = .Invalid_DHT
		client.Pending_Ready = true
		sync.cond_broadcast(&client.Exchange_Cond)
	}
	sync.mutex_unlock(&client.Mutex)
	if close_sockets {
		net.close(socket4)
		if has_socket6 {
			net.close(socket6)
		}
	}
	DHT_Routing_Destroy(&client.Routing)
}

DHT_Client_Get_Peers :: proc(
	client: ^DHT_Client,
	info_hash: Torrent_Hash,
	bootstrap: []DHT_Node,
	options := DHT_Network_Options{Timeout = 3 * time.Second, Max_Queries = 32},
) -> (DHT_Lookup_Result, DHT_Error) {
	result: DHT_Lookup_Result
	if client == nil {
		return result, .Invalid_DHT
	}
	sync.mutex_lock(&client.Mutex)
	open := client.Open
	node_id := client.Node_ID
	sync.mutex_unlock(&client.Mutex)
	if !open {
		return result, .Invalid_DHT
	}
	queue: [dynamic]DHT_Node
	visited: [dynamic]DHT_Node_ID
	closest := DHT_Routing_Closest(&client.Routing, DHT_Node_ID(info_hash), 16)
	defer delete(closest)
	for node in closest {
		if node.Endpoint.Port == 0 {
			continue
		}
		if dht_client_seen_endpoint(queue[:], node.Endpoint) {
			continue
		}
		append(&queue, node)
	}
	cached := DHT_Default_Bootstrap_Nodes()
	defer delete(cached)
	for node in bootstrap {
		if node.Endpoint.Port == 0 || dht_client_seen_endpoint(queue[:], node.Endpoint) {
			continue
		}
		append(&queue, node)
	}
	for node in cached {
		if node.Endpoint.Port == 0 || dht_client_seen_endpoint(queue[:], node.Endpoint) {
			continue
		}
		append(&queue, node)
	}
	for node in queue {
		_ = DHT_Routing_Add_Node(&client.Routing, node)
	}
	fmt.printf("[DURRENT-DHT] Lookup seeds=%d explicit=%d cached=%d\n", len(queue), len(bootstrap), len(closest))
	max_queries := options.Max_Queries if options.Max_Queries > 0 else u32(1)
	queries: u32
	for len(queue) > 0 && queries < max_queries {
		node := queue[0]
		copy(queue[:], queue[1:])
		resize(&queue, len(queue)-1)
		if dht_client_seen_id(visited, node.ID) {
			continue
		}
		append(&visited, node.ID)
		queries += 1
		fmt.printf(
			"[DURRENT-DHT] Query %d/%d endpoint=%d.%d.%d.%d:%d\n",
			queries,
			max_queries,
			node.Endpoint.IP[0],
			node.Endpoint.IP[1],
			node.Endpoint.IP[2],
			node.Endpoint.IP[3],
			node.Endpoint.Port,
		)
		transaction := dht_client_next_transaction(client)
		packet := DHT_Encode_Get_Peers(transaction[:], node_id, info_hash)
		message, query_error := dht_client_exchange_locked(client, node.Endpoint, packet, transaction[:], options)
		delete(packet)
		if query_error != .None {
			fmt.printf("[DURRENT-DHT] Query failed error=%v\n", query_error)
			continue
		}
		fmt.printf("[DURRENT-DHT] Response peers=%d nodes=%d token=%v\n", len(message.Peers), len(message.Nodes), len(message.Token) > 0)
		if message.Kind == .Response {
			zero_id: DHT_Node_ID
			if message.Sender != zero_id {
				_ = DHT_Routing_Add_Node(&client.Routing, DHT_Node{
					ID = message.Sender,
					Endpoint = node.Endpoint,
				})
			}
			if len(message.Peers) > 0 {
				append(&result.Peers, ..message.Peers[:])
			}
			if len(message.Token) > 0 {
				token, token_ok := torrent_clone(message.Token)
				if !token_ok {
					Destroy_DHT_Message(&message)
					delete(queue)
					delete(visited)
					Destroy_DHT_Lookup_Result(&result)
					return result, .Out_Of_Memory
				}
				append(&result.Targets, DHT_Lookup_Target{Node = node, Token = token})
			}
			for discovered in message.Nodes {
				if !dht_client_seen_id(visited, discovered.ID) && !dht_client_seen_node(queue[:], discovered.ID) {
					append(&queue, discovered)
					_ = DHT_Routing_Add_Node(&client.Routing, discovered)
				}
			}
		}
		Destroy_DHT_Message(&message)
	}
	delete(queue)
	delete(visited)
	return result, .None
}

DHT_Client_Announce_Peer :: proc(
	client: ^DHT_Client,
	info_hash: Torrent_Hash,
	port: u16,
	targets: []DHT_Lookup_Target,
	options := DHT_Network_Options{Timeout = 3 * time.Second, Max_Queries = 32},
) -> (u32, DHT_Error) {
	if client == nil {
		return 0, .Invalid_DHT
	}
	sync.mutex_lock(&client.Mutex)
	open := client.Open
	node_id := client.Node_ID
	sync.mutex_unlock(&client.Mutex)
	if !open {
		return 0, .Invalid_DHT
	}
	sent: u32
	for index := 0; index < len(targets) && u32(index) < options.Max_Queries; index += 1 {
		if len(targets[index].Token) == 0 {
			continue
		}
		transaction := dht_client_next_transaction(client)
		packet := DHT_Encode_Announce_Peer(transaction[:], node_id, info_hash, targets[index].Token, port)
		message, query_error := dht_client_exchange_locked(client, targets[index].Node.Endpoint, packet, transaction[:], options)
		delete(packet)
		if query_error == .None {
			sent += 1
		}
		Destroy_DHT_Message(&message)
	}
	return sent, .None
}

DHT_Node_ID_Generate :: proc(seed: u64) -> DHT_Node_ID {
	data: [8]byte
	endian.put_u64(data[:], .Big, seed)
	result: DHT_Node_ID
	hash.hash_bytes_to_buffer(hash.Algorithm.Insecure_SHA1, data[:], result[:])
	return result
}

DHT_Token_Make :: proc(secret: [20]byte, endpoint: DHT_Endpoint) -> [20]byte {
	data: [38]byte
	secret_value := secret
	ip := endpoint.IP
	copy(data[:20], secret_value[:])
	copy(data[20:36], ip[:])
	endian.put_u16(data[36:38], .Big, endpoint.Port)
	result: [20]byte
	hash.hash_bytes_to_buffer(hash.Algorithm.Insecure_SHA1, data[:], result[:])
	return result
}

DHT_Token_Validate :: proc(
	secret: [20]byte,
	previous_secret: [20]byte,
	endpoint: DHT_Endpoint,
	token: []byte,
) -> bool {
	if len(token) != 20 {
		return false
	}
	current := DHT_Token_Make(secret, endpoint)
	previous := DHT_Token_Make(previous_secret, endpoint)
	return dht_constant_time_equal(token, current[:]) || dht_constant_time_equal(token, previous[:])
}

// DHT_Client_Dequeue_Outbound transfers ownership of the packet data to the
// caller. It is used only by clients initialized with DHT_Client_Init_External.
DHT_Client_Dequeue_Outbound :: proc(client: ^DHT_Client) -> (DHT_Client_Outbound_Packet, bool) {
	if client == nil {
		return DHT_Client_Outbound_Packet{}, false
	}
	sync.mutex_lock(&client.Mutex)
	defer sync.mutex_unlock(&client.Mutex)
	if !client.Open || !client.External_Sockets || len(client.Outbound) == 0 {
		return DHT_Client_Outbound_Packet{}, false
	}
	packet := client.Outbound[0]
	copy(client.Outbound[:], client.Outbound[1:])
	resize(&client.Outbound, len(client.Outbound)-1)
	return packet, true
}

// DHT_Client_Mark_Send_Error wakes the matching external exchange after its
// dequeued packet could not be sent. The caller retains ownership of packet.Data.
DHT_Client_Mark_Send_Error :: proc(client: ^DHT_Client, packet: DHT_Client_Outbound_Packet) -> bool {
	if client == nil {
		return false
	}
	sync.mutex_lock(&client.Mutex)
	defer sync.mutex_unlock(&client.Mutex)
	if !client.Open || !client.External_Sockets || !client.Exchange_Active ||
	   client.Pending_Ready || !dht_client_same_endpoint(client.Pending_Endpoint, packet.Endpoint) ||
	   client.Pending_Transaction != packet.Transaction {
		return false
	}
	client.Pending_Error = .Send
	client.Pending_Ready = true
	sync.cond_signal(&client.Exchange_Cond)
	return true
}

// DHT_Client_Handle_Datagram parses a dispatcher-received datagram. A message
// is consumed only when both its sender endpoint and transaction match the
// current exchange; on success its allocation ownership moves to the client.
DHT_Client_Handle_Datagram :: proc(client: ^DHT_Client, data: []byte, source: DHT_Endpoint) -> bool {
	if client == nil {
		return false
	}
	message, parse_error := DHT_Parse_Message(data)
	if parse_error != .None {
		return false
	}
	sync.mutex_lock(&client.Mutex)
	if !client.Open || !client.External_Sockets || !client.Exchange_Active ||
	   client.Pending_Ready || !dht_client_same_endpoint(client.Pending_Endpoint, source) ||
	   !dht_client_transaction_matches(client.Pending_Transaction, message.Transaction) {
		sync.mutex_unlock(&client.Mutex)
		Destroy_DHT_Message(&message)
		return false
	}
	client.Pending_Response = message
	message = DHT_Message{}
	client.Pending_Error = .None
	client.Pending_Ready = true
	sync.cond_signal(&client.Exchange_Cond)
	sync.mutex_unlock(&client.Mutex)
	return true
}

// DHT_Client_Handle is a concise alias for DHT_Client_Handle_Datagram.
DHT_Client_Handle :: proc(client: ^DHT_Client, data: []byte, source: DHT_Endpoint) -> bool {
	return DHT_Client_Handle_Datagram(client, data, source)
}

// DHT_Client_Cancel_Pending_Exchange cancels the outstanding external request.
// Its synchronous caller receives DHT_Error.Timeout, the closest existing DHT
// error for a request that deliberately received no response.
DHT_Client_Cancel_Pending_Exchange :: proc(client: ^DHT_Client) -> bool {
	if client == nil {
		return false
	}
	sync.mutex_lock(&client.Mutex)
	defer sync.mutex_unlock(&client.Mutex)
	if !client.Open || !client.External_Sockets || !client.Exchange_Active || client.Pending_Ready {
		return false
	}
	dht_client_remove_pending_outbound_locked(client)
	client.Pending_Error = .Timeout
	client.Pending_Ready = true
	sync.cond_signal(&client.Exchange_Cond)
	return true
}

dht_client_exchange_locked :: proc(
	client: ^DHT_Client,
	endpoint: DHT_Endpoint,
	packet: []byte,
	transaction: []byte,
	options: DHT_Network_Options,
) -> (DHT_Message, DHT_Error) {
	if client == nil || len(transaction) != 2 {
		return DHT_Message{}, .Invalid_DHT
	}
	timeout := options.Timeout if options.Timeout > 0 else DHT_Default_Network_Options().Timeout
	deadline := time.time_add(time.now(), timeout)

	sync.mutex_lock(&client.Mutex)
	for client.Open && client.Exchange_Active {
		remaining := time.diff(time.now(), deadline)
		if remaining <= 0 || !sync.cond_wait_with_timeout(&client.Exchange_Cond, &client.Mutex, remaining) {
			sync.mutex_unlock(&client.Mutex)
			return DHT_Message{}, .Timeout
		}
	}
	if !client.Open {
		sync.mutex_unlock(&client.Mutex)
		return DHT_Message{}, .Invalid_DHT
	}
	if endpoint.IPv6 && !client.Has_Socket6 {
		sync.mutex_unlock(&client.Mutex)
		return DHT_Message{}, .Resolve
	}

	client.Exchange_Active = true
	if client.External_Sockets {
		outbound_data, clone_ok := torrent_clone(packet)
		if !clone_ok {
			client.Exchange_Active = false
			sync.cond_broadcast(&client.Exchange_Cond)
			sync.mutex_unlock(&client.Mutex)
			return DHT_Message{}, .Out_Of_Memory
		}
		outbound := DHT_Client_Outbound_Packet{Data = outbound_data, Endpoint = endpoint}
		copy(outbound.Transaction[:], transaction)
		client.Pending_Endpoint = endpoint
		client.Pending_Transaction = outbound.Transaction
		client.Pending_Response = DHT_Message{}
		client.Pending_Error = .None
		client.Pending_Ready = false
		append(&client.Outbound, outbound)
		sync.cond_signal(&client.Exchange_Cond)

		for !client.Pending_Ready {
			remaining := time.diff(time.now(), deadline)
			if remaining <= 0 || !sync.cond_wait_with_timeout(&client.Exchange_Cond, &client.Mutex, remaining) {
				if !client.Pending_Ready {
					dht_client_remove_pending_outbound_locked(client)
					client.Pending_Error = .Timeout
					client.Pending_Ready = true
				}
			}
		}
		message := client.Pending_Response
		client.Pending_Response = DHT_Message{}
		exchange_error := client.Pending_Error
		dht_client_remove_pending_outbound_locked(client)
		client.Pending_Endpoint = DHT_Endpoint{}
		client.Pending_Transaction = [2]byte{}
		client.Pending_Error = .None
		client.Pending_Ready = false
		client.Exchange_Active = false
		sync.cond_broadcast(&client.Exchange_Cond)
		sync.mutex_unlock(&client.Mutex)
		return message, exchange_error
	}

	socket: net.UDP_Socket
	net_endpoint: net.Endpoint
	if endpoint.IPv6 {
		ip6: net.IP6_Address
		for index := 0; index < 8; index += 1 {
			ip6[index] = u16be(u16(endpoint.IP[index*2])<<8 | u16(endpoint.IP[index*2+1]))
		}
		socket = client.Socket6
		net_endpoint = net.Endpoint{address = ip6, port = int(endpoint.Port)}
	} else {
		ip4 := net.IP4_Address{endpoint.IP[0], endpoint.IP[1], endpoint.IP[2], endpoint.IP[3]}
		socket = client.Socket
		net_endpoint = net.Endpoint{address = ip4, port = int(endpoint.Port)}
	}
	sync.mutex_unlock(&client.Mutex)
	defer dht_client_finish_direct_exchange(client)

	if _, send_error := net.send_udp(socket, packet, net_endpoint); send_error != .None {
		fmt.printf("[DURRENT-DHT] UDP send failed endpoint=%v error=%v\\n", net_endpoint, send_error)
		return DHT_Message{}, .Send
	}
	_ = net.set_option(socket, .Receive_Timeout, timeout)
	buffer, buffer_error := make([]byte, 64*1024, context.allocator)
	if buffer_error != nil {
		return DHT_Message{}, .Out_Of_Memory
	}
	count, _, receive_error := net.recv_udp(socket, buffer)
	if receive_error == .Timeout || receive_error == .Would_Block {
		delete(buffer)
		fmt.printf("[DURRENT-DHT] UDP receive timeout endpoint=%v\n", net_endpoint)
		return DHT_Message{}, .Timeout
	}
	if receive_error != .None {
		delete(buffer)
		fmt.printf("[DURRENT-DHT] UDP receive failed endpoint=%v error=%v\\n", net_endpoint, receive_error)
		return DHT_Message{}, .Receive
	}
	message, parse_error := DHT_Parse_Message(buffer[:count])
	delete(buffer)
	if parse_error != .None {
		fmt.printf("[DURRENT-DHT] KRPC parse failed bytes=%d error=%v\n", count, parse_error)
		return DHT_Message{}, parse_error
	}
	if !bytes_equal(message.Transaction, transaction) {
		Destroy_DHT_Message(&message)
		fmt.println("[DURRENT-DHT] KRPC transaction mismatch")
		return DHT_Message{}, .Transaction_Mismatch
	}
	return message, .None
}

dht_client_finish_direct_exchange :: proc(client: ^DHT_Client) {
	sync.mutex_lock(&client.Mutex)
	client.Exchange_Active = false
	sync.cond_broadcast(&client.Exchange_Cond)
	sync.mutex_unlock(&client.Mutex)
}

dht_client_remove_pending_outbound_locked :: proc(client: ^DHT_Client) {
	index := 0
	for index < len(client.Outbound) {
		outbound := client.Outbound[index]
		if dht_client_same_endpoint(outbound.Endpoint, client.Pending_Endpoint) &&
		   outbound.Transaction == client.Pending_Transaction {
			delete(outbound.Data)
			copy(client.Outbound[index:], client.Outbound[index+1:])
			resize(&client.Outbound, len(client.Outbound)-1)
			continue
		}
		index += 1
	}
}

dht_client_same_endpoint :: proc(left: DHT_Endpoint, right: DHT_Endpoint) -> bool {
	return left.IP == right.IP && left.Port == right.Port && left.IPv6 == right.IPv6
}

dht_client_transaction_matches :: proc(transaction: [2]byte, received: []byte) -> bool {
	value := transaction
	return len(received) == len(value) && bytes_equal(value[:], received)
}

dht_client_next_transaction :: proc(client: ^DHT_Client) -> [2]byte {
	sync.mutex_lock(&client.Mutex)
	client.Transaction += 1
	result: [2]byte
	endian.put_u16(result[:], .Big, client.Transaction)
	sync.mutex_unlock(&client.Mutex)
	return result
}

dht_client_seen_id :: proc(ids: [dynamic]DHT_Node_ID, id: DHT_Node_ID) -> bool {
	for existing in ids {
		if existing == id {
			return true
		}
	}
	return false
}

dht_client_seen_endpoint :: proc(queue: []DHT_Node, endpoint: DHT_Endpoint) -> bool {
	for node in queue {
		if node.Endpoint.IP == endpoint.IP &&
		   node.Endpoint.Port == endpoint.Port &&
		   node.Endpoint.IPv6 == endpoint.IPv6 {
			return true
		}
	}
	return false
}


dht_client_seen_node :: proc(queue: []DHT_Node, id: DHT_Node_ID) -> bool {
	for node in queue {
		if node.ID == id {
			return true
		}
	}
	return false
}

dht_constant_time_equal :: proc(left: []byte, right: []byte) -> bool {
	if len(left) != len(right) {
		return false
	}
	difference: byte
	for index := 0; index < len(left); index += 1 {
		difference |= left[index] ~ right[index]
	}
	return difference == 0
}
