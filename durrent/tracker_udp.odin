package durrent

import endian "core:encoding/endian"
import "core:net"
import "core:sync"
import "core:time"

UDP_Tracker_Connection_ID :: u64(0x41727101980)
UDP_Tracker_Connection_Lifetime :: time.Duration(60 * time.Second)

UDP_Tracker_Options :: struct {
	Timeout:          time.Duration,
	Retries:          u32,
	Max_Packet_Bytes: int,
}

UDP_Tracker_Default_Options :: proc() -> UDP_Tracker_Options {
	return UDP_Tracker_Options{Timeout = 5 * time.Second, Retries = 3, Max_Packet_Bytes = 64 * 1024}
}

UDP_Tracker_Error :: enum {
	None,
	Invalid_Client,
	Invalid_URL,
	Resolve,
	Socket,
	Send,
	Receive,
	Timeout,
	Invalid_Response,
	Invalid_Peer,
	Transaction_Mismatch,
	Tracker_Failure,
	Out_Of_Memory,
}

UDP_Tracker_Client :: struct {
	Mutex:             sync.Mutex,
	Socket:            net.UDP_Socket,
	Endpoint:          net.Endpoint,
	IPv6:              bool,
	Connection_ID:     u64,
	Connection_Expires: time.Time,
	Open:              bool,
}

UDP_Tracker_Client_Init :: proc(
	client: ^UDP_Tracker_Client,
	url: string,
	options := UDP_Tracker_Options{Timeout = 5 * time.Second, Retries = 3, Max_Packet_Bytes = 64 * 1024},
) -> UDP_Tracker_Error {
	if client == nil {
		return .Invalid_Client
	}
	UDP_Tracker_Client_Destroy(client)
	authority, authority_ok := udp_tracker_authority(url)
	if !authority_ok {
		return .Invalid_URL
	}
	ep4, ep6, resolve_error := net.resolve(authority)
	if resolve_error != nil && ep4.port == 0 && ep6.port == 0 {
		return .Resolve
	}
	endpoint: net.Endpoint
	family: net.Address_Family
	if ep4.port > 0 {
		endpoint = ep4
		family = .IP4
	} else if ep6.port > 0 {
		endpoint = ep6
		family = .IP6
	} else {
		return .Resolve
	}
	socket, socket_error := net.make_unbound_udp_socket(family)
	if socket_error != nil {
		return .Socket
	}
	timeout := options.Timeout if options.Timeout > 0 else UDP_Tracker_Default_Options().Timeout
	if net.set_option(socket, .Receive_Timeout, timeout) != nil || net.set_option(socket, .Send_Timeout, timeout) != nil {
		net.close(socket)
		return .Socket
	}
	sync.mutex_lock(&client.Mutex)
	client.Socket = socket
	client.Endpoint = endpoint
	client.IPv6 = family == .IP6
	client.Connection_ID = 0
	client.Connection_Expires = time.Time{}
	client.Open = true
	sync.mutex_unlock(&client.Mutex)
	return .None
}

UDP_Tracker_Client_Destroy :: proc(client: ^UDP_Tracker_Client) {
	if client == nil {
		return
	}
	sync.mutex_lock(&client.Mutex)
	if client.Open {
		net.close(client.Socket)
	}
	client^ = UDP_Tracker_Client{}
	sync.mutex_unlock(&client.Mutex)
}

UDP_Tracker_Client_Announce :: proc(
	client: ^UDP_Tracker_Client,
	request: Tracker_Announce_Request,
	options := UDP_Tracker_Options{Timeout = 5 * time.Second, Retries = 3, Max_Packet_Bytes = 64 * 1024},
) -> (Tracker_Announce_Response, UDP_Tracker_Error) {
	if client == nil {
		return Tracker_Announce_Response{}, .Invalid_Client
	}
	sync.mutex_lock(&client.Mutex)
	defer sync.mutex_unlock(&client.Mutex)
	if !client.Open {
		return Tracker_Announce_Response{}, .Invalid_Client
	}
	if client.Connection_ID == 0 || time.diff(client.Connection_Expires, time.now()) >= 0 {
		connect_error := udp_tracker_connect_locked(client, options)
		if connect_error != .None {
			return Tracker_Announce_Response{}, connect_error
		}
	}
	response, announce_error := udp_tracker_announce_locked(client, request, options)
	if announce_error == .Tracker_Failure {
		client.Connection_ID = 0
	}
	return response, announce_error
}

UDP_Tracker_Announce :: proc(
	url: string,
	request: Tracker_Announce_Request,
	options := UDP_Tracker_Options{Timeout = 5 * time.Second, Retries = 3, Max_Packet_Bytes = 64 * 1024},
) -> (Tracker_Announce_Response, UDP_Tracker_Error) {
	client: UDP_Tracker_Client
	init_error := UDP_Tracker_Client_Init(&client, url, options)
	if init_error != .None {
		return Tracker_Announce_Response{}, init_error
	}
	defer UDP_Tracker_Client_Destroy(&client)
	return UDP_Tracker_Client_Announce(&client, request, options)
}

UDP_Tracker_Encode_Connect_Request :: proc(transaction: u32) -> [16]byte {
	packet: [16]byte
	endian.put_u64(packet[0:8], .Big, UDP_Tracker_Connection_ID)
	endian.put_u32(packet[8:12], .Big, 0)
	endian.put_u32(packet[12:16], .Big, transaction)
	return packet
}

UDP_Tracker_Parse_Connect_Response :: proc(data: []byte, transaction: u32) -> (u64, UDP_Tracker_Error) {
	if len(data) < 16 {
		return 0, .Invalid_Response
	}
	action, action_ok := endian.get_u32(data[0:4], .Big)
	response_transaction, transaction_ok := endian.get_u32(data[4:8], .Big)
	if !action_ok || !transaction_ok || response_transaction != transaction {
		return 0, .Transaction_Mismatch
	}
	if action == 3 {
		return 0, .Tracker_Failure
	}
	if action != 0 {
		return 0, .Invalid_Response
	}
	connection, connection_ok := endian.get_u64(data[8:16], .Big)
	if !connection_ok || connection == 0 {
		return 0, .Invalid_Response
	}
	return connection, .None
}

UDP_Tracker_Encode_Announce_Request :: proc(
	connection: u64,
	transaction: u32,
	key: u32,
	request: Tracker_Announce_Request,
) -> [98]byte {
	packet: [98]byte
	endian.put_u64(packet[0:8], .Big, connection)
	endian.put_u32(packet[8:12], .Big, 1)
	endian.put_u32(packet[12:16], .Big, transaction)
	info_hash := request.Info_Hash
	peer_id := request.Peer_ID
	copy(packet[16:36], info_hash[:])
	copy(packet[36:56], peer_id[:])
	endian.put_u64(packet[56:64], .Big, request.Downloaded)
	endian.put_u64(packet[64:72], .Big, request.Left)
	endian.put_u64(packet[72:80], .Big, request.Uploaded)
	endian.put_u32(packet[80:84], .Big, udp_tracker_event(request.Event))
	endian.put_u32(packet[84:88], .Big, 0)
	endian.put_u32(packet[88:92], .Big, key)
	endian.put_u32(packet[92:96], .Big, 0xffffffff)
	endian.put_u16(packet[96:98], .Big, request.Port)
	return packet
}

UDP_Tracker_Parse_Announce_Response :: proc(
	data: []byte,
	transaction: u32,
	ipv6 := false,
) -> (Tracker_Announce_Response, UDP_Tracker_Error) {
	if len(data) < 20 {
		return Tracker_Announce_Response{}, .Invalid_Response
	}
	action, action_ok := endian.get_u32(data[0:4], .Big)
	response_transaction, transaction_ok := endian.get_u32(data[4:8], .Big)
	if !action_ok || !transaction_ok || response_transaction != transaction {
		return Tracker_Announce_Response{}, .Transaction_Mismatch
	}
	if action == 3 {
		return Tracker_Announce_Response{}, .Tracker_Failure
	}
	if action != 1 {
		return Tracker_Announce_Response{}, .Invalid_Response
	}
	interval, interval_ok := endian.get_u32(data[8:12], .Big)
	incomplete, incomplete_ok := endian.get_u32(data[12:16], .Big)
	complete, complete_ok := endian.get_u32(data[16:20], .Big)
	if !interval_ok || !incomplete_ok || !complete_ok {
		return Tracker_Announce_Response{}, .Invalid_Response
	}
	result := Tracker_Announce_Response{
		Interval = u64(interval),
		Incomplete = u64(incomplete),
		Complete = u64(complete),
		Has_Incomplete = true,
		Has_Complete = true,
	}
	tail := data[20:]
	if ipv6 {
		if len(tail)%18 != 0 {
			return Tracker_Announce_Response{}, .Invalid_Peer
		}
		for position := 0; position < len(tail); position += 18 {
			peer: Tracker_Peer_IPv6
			copy(peer.IP[:], tail[position:position+16])
			peer.Port = u16(tail[position+16]) << 8 | u16(tail[position+17])
			append(&result.Peers6, peer)
		}
	} else {
		if len(tail)%6 != 0 {
			return Tracker_Announce_Response{}, .Invalid_Peer
		}
		for position := 0; position < len(tail); position += 6 {
			append(&result.Peers, Tracker_Peer{
				IP = [4]byte{tail[position], tail[position+1], tail[position+2], tail[position+3]},
				Port = u16(tail[position+4]) << 8 | u16(tail[position+5]),
			})
		}
	}
	return result, .None
}

udp_tracker_connect_locked :: proc(client: ^UDP_Tracker_Client, options: UDP_Tracker_Options) -> UDP_Tracker_Error {
	attempts := options.Retries if options.Retries > 0 else u32(1)
	last_error := UDP_Tracker_Error.Timeout
	for attempt: u32 = 0; attempt < attempts; attempt += 1 {
		transaction := udp_tracker_transaction(attempt)
		packet := UDP_Tracker_Encode_Connect_Request(transaction)
		if _, send_error := net.send_udp(client.Socket, packet[:], client.Endpoint); send_error != .None {
			last_error = .Send
			udp_tracker_backoff(attempt)
			continue
		}
		buffer, buffer_error := make([]byte, udp_tracker_packet_limit(options), context.allocator)
		if buffer_error != nil {
			return .Out_Of_Memory
		}
		count, _, receive_error := net.recv_udp(client.Socket, buffer)
		if receive_error == .Timeout || receive_error == .Would_Block {
			last_error = .Timeout
		} else if receive_error != .None {
			last_error = .Receive
		} else {
			connection, parse_error := UDP_Tracker_Parse_Connect_Response(buffer[:count], transaction)
			if parse_error == .None {
				client.Connection_ID = connection
				client.Connection_Expires = time.time_add(time.now(), UDP_Tracker_Connection_Lifetime)
				delete(buffer)
				return .None
			}
			last_error = parse_error
		}
		delete(buffer)
		udp_tracker_backoff(attempt)
	}
	return last_error
}

udp_tracker_announce_locked :: proc(
	client: ^UDP_Tracker_Client,
	request: Tracker_Announce_Request,
	options: UDP_Tracker_Options,
) -> (Tracker_Announce_Response, UDP_Tracker_Error) {
	attempts := options.Retries if options.Retries > 0 else u32(1)
	last_error := UDP_Tracker_Error.Timeout
	for attempt: u32 = 0; attempt < attempts; attempt += 1 {
		transaction := udp_tracker_transaction(attempt + 17)
		packet := UDP_Tracker_Encode_Announce_Request(client.Connection_ID, transaction, transaction ~ u32(0xa5a5a5a5), request)
		if _, send_error := net.send_udp(client.Socket, packet[:], client.Endpoint); send_error != .None {
			last_error = .Send
			udp_tracker_backoff(attempt)
			continue
		}
		buffer, buffer_error := make([]byte, udp_tracker_packet_limit(options), context.allocator)
		if buffer_error != nil {
			return Tracker_Announce_Response{}, .Out_Of_Memory
		}
		count, _, receive_error := net.recv_udp(client.Socket, buffer)
		if receive_error == .Timeout || receive_error == .Would_Block {
			last_error = .Timeout
		} else if receive_error != .None {
			last_error = .Receive
		} else {
			response, parse_error := UDP_Tracker_Parse_Announce_Response(buffer[:count], transaction, client.IPv6)
			delete(buffer)
			if parse_error == .None {
				return response, .None
			}
			last_error = parse_error
			udp_tracker_backoff(attempt)
			continue
		}
		delete(buffer)
		udp_tracker_backoff(attempt)
	}
	return Tracker_Announce_Response{}, last_error
}

udp_tracker_transaction :: proc(attempt: u32) -> u32 {
	return u32(time.to_unix_nanoseconds(time.now())) ~ (attempt * 0x9e3779b9)
}

udp_tracker_event :: proc(event: Tracker_Event) -> u32 {
	switch event {
	case .Completed: return 1
	case .Started: return 2
	case .Stopped: return 3
	case .None: return 0
	}
	return 0
}

tracker_url_is_udp :: proc(url: string) -> bool {
	return len(url) >= 6 && url[:6] == "udp://"
}

udp_tracker_authority :: proc(url: string) -> (string, bool) {
	if len(url) < 7 || url[:6] != "udp://" {
		return "", false
	}
	start := 6
	end := start
	for end < len(url) && url[end] != '/' && url[end] != '?' {
		end += 1
	}
	authority := url[start:end]
	if len(authority) < 3 {
		return "", false
	}
	if authority[0] == '[' {
		close := -1
		for i := 1; i < len(authority); i += 1 {
			if authority[i] == ']' {
				close = i
				break
			}
		}
		return authority, close > 0 && close+2 < len(authority) && authority[close+1] == ':'
	}
	colon := -1
	for i := 0; i < len(authority); i += 1 {
		if authority[i] == ':' {
			colon = i
		}
	}
	return authority, colon > 0 && colon+1 < len(authority)
}

udp_tracker_packet_limit :: proc(options: UDP_Tracker_Options) -> int {
	return options.Max_Packet_Bytes if options.Max_Packet_Bytes >= 20 else UDP_Tracker_Default_Options().Max_Packet_Bytes
}

udp_tracker_backoff :: proc(attempt: u32) {
	if attempt > 0 {
		time.sleep(time.Duration(attempt) * 50 * time.Millisecond)
	}
}
