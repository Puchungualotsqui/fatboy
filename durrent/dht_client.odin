package durrent

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

DHT_Client :: struct {
	Mutex:       sync.Mutex,
	Socket:      net.UDP_Socket,
	Node_ID:     DHT_Node_ID,
	Routing:     DHT_Routing_Table,
	Token_Secret: [20]byte,
	Previous_Secret: [20]byte,
	Secret_Time: time.Time,
	Transaction: u16,
	Open:         bool,
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
	socket, socket_error := net.make_bound_udp_socket(net.IP4_Any, int(port))
	if socket_error != nil {
		return .Socket
	}
	timeout := options.Timeout if options.Timeout > 0 else DHT_Default_Network_Options().Timeout
	if net.set_option(socket, .Receive_Timeout, timeout) != nil || net.set_option(socket, .Send_Timeout, timeout) != nil {
		net.close(socket)
		return .Socket
	}
	if DHT_Routing_Init(&client.Routing, node_id) != .None {
		net.close(socket)
		return .Out_Of_Memory
	}
	client.Socket = socket
	client.Node_ID = node_id
	client.Token_Secret = node_id
	client.Secret_Time = time.now()
	client.Transaction = 1
	client.Open = true
	return .None
}

DHT_Client_Destroy :: proc(client: ^DHT_Client) {
	if client == nil {
		return
	}
	sync.mutex_lock(&client.Mutex)
	if client.Open {
		net.close(client.Socket)
	}
	client.Open = false
	sync.mutex_unlock(&client.Mutex)
	DHT_Routing_Destroy(&client.Routing)
	client^ = DHT_Client{}
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
	defer sync.mutex_unlock(&client.Mutex)
	if !client.Open {
		return result, .Invalid_DHT
	}
	queue: [dynamic]DHT_Node
	visited: [dynamic]DHT_Node_ID
	for node in bootstrap {
		if node.Endpoint.Port == 0 || dht_client_seen_node(queue, node.ID) {
			continue
		}
		append(&queue, node)
		_ = DHT_Routing_Add_Node(&client.Routing, node)
	}
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
		transaction := dht_client_next_transaction(client)
		packet := DHT_Encode_Get_Peers(transaction[:], client.Node_ID, info_hash)
		message, query_error := dht_client_exchange_locked(client, node.Endpoint, packet, transaction[:], options)
		delete(packet)
		if query_error != .None {
			continue
		}
		if message.Kind == .Response {
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
				if !dht_client_seen_id(visited, discovered.ID) && !dht_client_seen_node(queue, discovered.ID) {
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
	defer sync.mutex_unlock(&client.Mutex)
	if !client.Open {
		return 0, .Invalid_DHT
	}
	sent: u32
	for index := 0; index < len(targets) && u32(index) < options.Max_Queries; index += 1 {
		if len(targets[index].Token) == 0 {
			continue
		}
		transaction := dht_client_next_transaction(client)
		packet := DHT_Encode_Announce_Peer(transaction[:], client.Node_ID, info_hash, targets[index].Token, port)
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

dht_client_exchange_locked :: proc(
	client: ^DHT_Client,
	endpoint: DHT_Endpoint,
	packet: []byte,
	transaction: []byte,
	options: DHT_Network_Options,
) -> (DHT_Message, DHT_Error) {
	if endpoint.IPv6 {
		return DHT_Message{}, .Resolve
	}
	address := net.IP4_Address{endpoint.IP[0], endpoint.IP[1], endpoint.IP[2], endpoint.IP[3]}
	net_endpoint := net.Endpoint{address = address, port = int(endpoint.Port)}
	if _, send_error := net.send_udp(client.Socket, packet, net_endpoint); send_error != .None {
		return DHT_Message{}, .Send
	}
	timeout := options.Timeout if options.Timeout > 0 else DHT_Default_Network_Options().Timeout
	_ = net.set_option(client.Socket, .Receive_Timeout, timeout)
	buffer, buffer_error := make([]byte, 64*1024, context.allocator)
	if buffer_error != nil {
		return DHT_Message{}, .Out_Of_Memory
	}
	count, _, receive_error := net.recv_udp(client.Socket, buffer)
	if receive_error == .Timeout || receive_error == .Would_Block {
		delete(buffer)
		return DHT_Message{}, .Timeout
	}
	if receive_error != .None {
		delete(buffer)
		return DHT_Message{}, .Receive
	}
	message, parse_error := DHT_Parse_Message(buffer[:count])
	delete(buffer)
	if parse_error != .None {
		return DHT_Message{}, parse_error
	}
	if !bytes_equal(message.Transaction, transaction) {
		Destroy_DHT_Message(&message)
		return DHT_Message{}, .Transaction_Mismatch
	}
	return message, .None
}

dht_client_next_transaction :: proc(client: ^DHT_Client) -> [2]byte {
	client.Transaction += 1
	result: [2]byte
	endian.put_u16(result[:], .Big, client.Transaction)
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

dht_client_seen_node :: proc(nodes: [dynamic]DHT_Node, id: DHT_Node_ID) -> bool {
	for node in nodes {
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
