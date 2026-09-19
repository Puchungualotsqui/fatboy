package durrent

import "core:time"

// Protocol helpers are split out to keep KRPC parsing compact.
dht_append_bytes :: proc(output: ^[dynamic]byte, data: []byte) {
	if output == nil {
		return
	}
	dht_append_unsigned(output, u32(len(data)))
	append(output, ':')
	append(output, ..data)
}

dht_append_unsigned :: proc(output: ^[dynamic]byte, value: u32) {
	buffer: [10]byte
	position := len(buffer)
	current := value
	if current == 0 {
		append(output, '0')
		return
	}
	for current > 0 {
		position -= 1
		buffer[position] = byte(current%10) + '0'
		current /= 10
	}
	append(output, ..buffer[position:])
}

dht_parse_query :: proc(message: ^DHT_Message, root: ^Bencode_Value) -> DHT_Error {
	query_value, query_ok := Bencode_As_String(Bencode_Dictionary_Get(root, "q"))
	args := Bencode_Dictionary_Get(root, "a")
	if !query_ok || args == nil || args.Kind != .Dictionary {
		return .Invalid_Message
	}
	id_value, id_ok := Bencode_As_String(Bencode_Dictionary_Get(args, "id"))
	if !id_ok || len(id_value) != 20 {
		return .Invalid_Node
	}
	copy(message.Sender[:], id_value)
	get_peers_name := "get_peers"
	announce_name := "announce_peer"
	switch {
	case bytes_equal(query_value, transmute([]byte)get_peers_name):
		message.Query = .Get_Peers
	case bytes_equal(query_value, transmute([]byte)announce_name):
		message.Query = .Announce_Peer
	case:
		message.Query = .None
	}
	info_hash, info_hash_ok := Bencode_As_String(Bencode_Dictionary_Get(args, "info_hash"))
	if !info_hash_ok || len(info_hash) != 20 {
		return .Invalid_Message
	}
	copy(message.Info_Hash[:], info_hash)
	message.Has_Info_Hash = true
	if message.Query == .Announce_Peer {
		token, token_ok := Bencode_As_String(Bencode_Dictionary_Get(args, "token"))
		if !token_ok || len(token) == 0 {
			return .Invalid_Token
		}
		message.Token, token_ok = torrent_clone(token)
		if !token_ok {
			return .Out_Of_Memory
		}
		port, port_ok := dht_non_negative_integer(Bencode_Dictionary_Get(args, "port"))
		if port_ok && port <= 65535 {
			message.Port = u16(port)
		}
		implied, implied_ok := dht_non_negative_integer(Bencode_Dictionary_Get(args, "implied_port"))
		message.Implied_Port = implied_ok && implied != 0
	}
	return .None
}

dht_parse_response :: proc(message: ^DHT_Message, root: ^Bencode_Value) -> DHT_Error {
	result := Bencode_Dictionary_Get(root, "r")
	if result == nil || result.Kind != .Dictionary {
		return .Invalid_Message
	}
	id, id_ok := Bencode_As_String(Bencode_Dictionary_Get(result, "id"))
	if !id_ok || len(id) != 20 {
		return .Invalid_Node
	}
	copy(message.Sender[:], id)
	if info := Bencode_Dictionary_Get(result, "token"); info != nil {
		token, token_ok := Bencode_As_String(info)
		if !token_ok {
			return .Invalid_Message
		}
		message.Token, token_ok = torrent_clone(token)
		if !token_ok {
			return .Out_Of_Memory
		}
	}
	if nodes := Bencode_Dictionary_Get(result, "nodes"); nodes != nil {
		if nodes.Kind != .String || len(nodes.String)%26 != 0 {
			return .Invalid_Node
		}
		if dht_append_nodes(message, nodes.String, false) != .None {
			return .Out_Of_Memory
		}
	}
	if nodes6 := Bencode_Dictionary_Get(result, "nodes6"); nodes6 != nil {
		if nodes6.Kind != .String || len(nodes6.String)%38 != 0 {
			return .Invalid_Node
		}
		if dht_append_nodes(message, nodes6.String, true) != .None {
			return .Out_Of_Memory
		}
	}
	if values := Bencode_Dictionary_Get(result, "values"); values != nil {
		if values.Kind != .List {
			return .Invalid_Node
		}
		for value in values.List {
			if value.Kind != .String || (len(value.String) != 6 && len(value.String) != 18) {
				return .Invalid_Node
			}
			peer: DHT_Endpoint
			peer.IPv6 = len(value.String) == 18
			copy(peer.IP[:], value.String[:len(value.String)-2])
			peer.Port = u16(value.String[len(value.String)-2]) << 8 | u16(value.String[len(value.String)-1])
			append(&message.Peers, peer)
		}
	}
	return .None
}

dht_parse_error :: proc(message: ^DHT_Message, root: ^Bencode_Value) -> DHT_Error {
	errors := Bencode_Dictionary_Get(root, "e")
	if errors == nil || errors.Kind != .List || len(errors.List) < 2 {
		return .Invalid_Message
	}
	code, code_ok := Bencode_As_Integer(&errors.List[0])
	text, text_ok := Bencode_As_String(&errors.List[1])
	if !code_ok || !text_ok {
		return .Invalid_Message
	}
	message.Error_Code = code
	copy, copy_ok := torrent_clone(text)
	message.Error_Message = copy
	return .None if copy_ok else .Out_Of_Memory
}

dht_append_nodes :: proc(message: ^DHT_Message, data: []byte, ipv6: bool) -> DHT_Error {
	record_size := 26 if !ipv6 else 38
	for position := 0; position < len(data); position += record_size {
		node: DHT_Node
		copy(node.ID[:], data[position:position+20])
		node.Endpoint.IPv6 = ipv6
		ip_size := 16 if ipv6 else 4
		copy(node.Endpoint.IP[:], data[position+20:position+20+ip_size])
		port_position := position + 20 + ip_size
		node.Endpoint.Port = u16(data[port_position]) << 8 | u16(data[port_position+1])
		node.Last_Seen = time.now()
		append(&message.Nodes, node)
	}
	return .None
}

dht_non_negative_integer :: proc(value: ^Bencode_Value) -> (u64, bool) {
	if value == nil || value.Kind != .Integer || value.Integer < 0 {
		return 0, false
	}
	return u64(value.Integer), true
}

dht_bucket_index :: proc(local_id, remote_id: DHT_Node_ID) -> int {
	for byte_index := 0; byte_index < 20; byte_index += 1 {
		xor := local_id[byte_index] ~ remote_id[byte_index]
		if xor == 0 {
			continue
		}
		for bit := 7; bit >= 0; bit -= 1 {
			if xor&(byte(1)<<byte(bit)) != 0 {
				return 159 - byte_index*8 - (7-bit)
			}
		}
	}
	return -1
}

dht_id_less :: proc(left, right, target: DHT_Node_ID) -> bool {
	for index := 0; index < 20; index += 1 {
		left_distance := left[index] ~ target[index]
		right_distance := right[index] ~ target[index]
		if left_distance == right_distance {
			continue
		}
		return left_distance < right_distance
	}
	return false
}
