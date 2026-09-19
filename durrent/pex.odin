package durrent

import "core:fmt"

PEX_Peer :: struct {
	IP:    [16]byte,
	Port:  u16,
	IPv6:  bool,
}

PEX_Message :: struct {
	Added:   [dynamic]PEX_Peer,
	Dropped: [dynamic]PEX_Peer,
}

PEX_Error :: enum {
	None,
	Invalid_Message,
	Invalid_Extension,
	Out_Of_Memory,
}

Destroy_PEX_Message :: proc(message: ^PEX_Message) {
	if message == nil {
		return
	}
	delete(message.Added)
	delete(message.Dropped)
	message^ = PEX_Message{}
}

PEX_Encode_Extension_Handshake :: proc() -> []byte {
	payload: [dynamic]byte
	append(&payload, "d1:md6:ut_pexi2eee")
	return payload[:]
}

PEX_Parse_Extension_Handshake :: proc(data: []byte) -> (byte, PEX_Error) {
	root, decode_error := Bencode_Decode_Default(data)
	if decode_error != .None {
		return 0, .Invalid_Extension
	}
	defer Destroy_Bencode_Value(&root)
	mapping := Bencode_Dictionary_Get(&root, "m")
	value, value_ok := Bencode_As_Integer(Bencode_Dictionary_Get(mapping, "ut_pex"))
	if !value_ok || value <= 0 || value > 255 {
		return 0, .Invalid_Extension
	}
	return byte(value), .None
}

PEX_Parse_Message :: proc(data: []byte) -> (PEX_Message, PEX_Error) {
	root, decode_error := Bencode_Decode_Default(data)
	if decode_error != .None || root.Kind != .Dictionary {
		return PEX_Message{}, .Invalid_Message
	}
	defer Destroy_Bencode_Value(&root)
	result: PEX_Message
	if value := Bencode_Dictionary_Get(&root, "added"); value != nil {
		if pex_parse_compact(value, false, &result.Added) != .None {
			Destroy_PEX_Message(&result)
			return PEX_Message{}, .Invalid_Message
		}
	}
	if value := Bencode_Dictionary_Get(&root, "added6"); value != nil {
		if pex_parse_compact(value, true, &result.Added) != .None {
			Destroy_PEX_Message(&result)
			return PEX_Message{}, .Invalid_Message
		}
	}
	if value := Bencode_Dictionary_Get(&root, "dropped"); value != nil {
		if pex_parse_compact(value, false, &result.Dropped) != .None {
			Destroy_PEX_Message(&result)
			return PEX_Message{}, .Invalid_Message
		}
	}
	if value := Bencode_Dictionary_Get(&root, "dropped6"); value != nil {
		if pex_parse_compact(value, true, &result.Dropped) != .None {
			Destroy_PEX_Message(&result)
			return PEX_Message{}, .Invalid_Message
		}
	}
	return result, .None
}

PEX_Encode_Message :: proc(added, dropped: []PEX_Peer) -> []byte {
	output: [dynamic]byte
	append(&output, 'd')
	pex_append_compact(&output, "added", added, false)
	pex_append_compact(&output, "added6", added, true)
	pex_append_compact(&output, "dropped", dropped, false)
	pex_append_compact(&output, "dropped6", dropped, true)
	append(&output, 'e')
	return output[:]
}

pex_parse_compact :: proc(value: ^Bencode_Value, ipv6: bool, destination: ^[dynamic]PEX_Peer) -> PEX_Error {
	if value == nil || value.Kind != .String || destination == nil {
		return .Invalid_Message
	}
	record_size := 6 if !ipv6 else 18
	if len(value.String)%record_size != 0 {
		return .Invalid_Message
	}
	for position := 0; position < len(value.String); position += record_size {
		peer: PEX_Peer
		peer.IPv6 = ipv6
		ip_size := 16 if ipv6 else 4
		copy(peer.IP[:], value.String[position:position+ip_size])
		port_position := position + ip_size
		peer.Port = u16(value.String[port_position]) << 8 | u16(value.String[port_position+1])
		append(destination, peer)
	}
	return .None
}

pex_append_compact :: proc(output: ^[dynamic]byte, key: string, peers: []PEX_Peer, ipv6: bool) {
	count := 0
	for peer in peers {
		if peer.IPv6 == ipv6 {
			count += 1
		}
	}
	if count == 0 {
		return
	}
	pex_append_unsigned(output, u32(len(key)))
	append(output, ':')
	append(output, key)
	payload: [dynamic]byte
	for peer in peers {
		if peer.IPv6 != ipv6 {
			continue
		}
		ip_size := 16 if ipv6 else 4
		ip := peer.IP
		append(&payload, ..ip[:ip_size])
		append(&payload, byte(peer.Port>>8), byte(peer.Port))
	}
	pex_append_unsigned(output, u32(len(payload)))
	append(output, ':')
	append(output, ..payload[:])
	delete(payload)
}

pex_append_unsigned :: proc(output: ^[dynamic]byte, value: u32) {
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

PEX_Peer_Address :: proc(peer: PEX_Peer) -> string {
	if !peer.IPv6 {
		return fmt.aprintf("%d.%d.%d.%d:%d", peer.IP[0], peer.IP[1], peer.IP[2], peer.IP[3], peer.Port)
	}
	return fmt.aprintf("[%x:%x:%x:%x:%x:%x:%x:%x]:%d",
		u16(peer.IP[0])<<8|u16(peer.IP[1]),
		u16(peer.IP[2])<<8|u16(peer.IP[3]),
		u16(peer.IP[4])<<8|u16(peer.IP[5]),
		u16(peer.IP[6])<<8|u16(peer.IP[7]),
		u16(peer.IP[8])<<8|u16(peer.IP[9]),
		u16(peer.IP[10])<<8|u16(peer.IP[11]),
		u16(peer.IP[12])<<8|u16(peer.IP[13]),
		u16(peer.IP[14])<<8|u16(peer.IP[15]),
		peer.Port)
}
