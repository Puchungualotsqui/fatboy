package durrent

// Magnet URI parsing is kept independent from networking. A parsed Magnet_Link
// owns its display name and tracker URLs; the info hash is fixed-size data.

Magnet_Link :: struct {
	Info_Hash: [20]byte,
	Has_Name:  bool,
	Name:     []byte,
	Trackers: [dynamic][]byte,
}

Magnet_Error :: enum {
	None,
	Invalid_Magnet,
	Invalid_Info_Hash,
	Invalid_Percent_Escape,
}

Parse_Magnet :: proc(uri: string) -> (Magnet_Link, Magnet_Error) {
	return Parse_Magnet_Bytes(transmute([]byte)uri)
}

Parse_Magnet_Bytes :: proc(uri: []byte) -> (Magnet_Link, Magnet_Error) {
	prefix := []byte{'m', 'a', 'g', 'n', 'e', 't', ':', '?'}
	if len(uri) < len(prefix) || !magnet_equal_ignore_case(uri[:len(prefix)], prefix) {
		return Magnet_Link{}, .Invalid_Magnet
	}

	result: Magnet_Link
	info_hash_found := false
	position := len(prefix)
	for position <= len(uri) {
		end := position
		for end < len(uri) && uri[end] != '&' {
			end += 1
		}

		parameter := uri[position:end]
		equals := -1
		for i := 0; i < len(parameter); i += 1 {
			if parameter[i] == '=' {
				equals = i
				break
			}
		}
		if equals >= 0 {
			key := parameter[:equals]
			encoded_value := parameter[equals+1:]
			value, decode_error := magnet_percent_decode(encoded_value)
			if decode_error != .None {
				Destroy_Magnet_Link(&result)
				return Magnet_Link{}, decode_error
			}

			switch {
			case magnet_equal_ignore_case(key, []byte{'x', 't'}):
				xt_prefix := []byte{'u', 'r', 'n', ':', 'b', 't', 'i', 'h', ':'}
				if len(value) <= len(xt_prefix) || !magnet_equal_ignore_case(value[:len(xt_prefix)], xt_prefix) {
					delete(value)
					Destroy_Magnet_Link(&result)
					return Magnet_Link{}, .Invalid_Info_Hash
				}
				hash, hash_error := magnet_parse_info_hash(value[len(xt_prefix):])
				delete(value)
				if hash_error != .None {
					Destroy_Magnet_Link(&result)
					return Magnet_Link{}, hash_error
				}
				result.Info_Hash = hash
				info_hash_found = true
			case magnet_equal_ignore_case(key, []byte{'d', 'n'}):
				delete(result.Name)
				result.Name = value
				result.Has_Name = true
			case magnet_equal_ignore_case(key, []byte{'t', 'r'}):
				append(&result.Trackers, value)
			case:
				delete(value)
			}
		}

		if end == len(uri) {
			break
		}
		position = end + 1
	}

	if !info_hash_found {
		Destroy_Magnet_Link(&result)
		return Magnet_Link{}, .Invalid_Info_Hash
	}
	return result, .None
}

Destroy_Magnet_Link :: proc(magnet: ^Magnet_Link) {
	if magnet == nil {
		return
	}
	delete(magnet.Name)
	for tracker in magnet.Trackers {
		delete(tracker)
	}
	delete(magnet.Trackers)
	magnet^ = Magnet_Link{}
}

magnet_percent_decode :: proc(input: []byte) -> ([]byte, Magnet_Error) {
	output: [dynamic]byte
	position := 0
	for position < len(input) {
		c := input[position]
		switch {
		case c == '%':
			if position+2 >= len(input) {
				delete(output)
				return nil, .Invalid_Percent_Escape
			}
			hi, hi_ok := magnet_hex_value(input[position+1])
			lo, lo_ok := magnet_hex_value(input[position+2])
			if !hi_ok || !lo_ok {
				delete(output)
				return nil, .Invalid_Percent_Escape
			}
			append(&output, (hi << 4) | lo)
			position += 3
		case c == '+':
			append(&output, ' ')
			position += 1
		case:
			append(&output, c)
			position += 1
		}
	}
	return output[:], .None
}

magnet_parse_info_hash :: proc(value: []byte) -> ([20]byte, Magnet_Error) {
	if len(value) == 40 {
		result: [20]byte
		for i := 0; i < 20; i += 1 {
			hi, hi_ok := magnet_hex_value(value[i*2])
			lo, lo_ok := magnet_hex_value(value[i*2+1])
			if !hi_ok || !lo_ok {
				return [20]byte{}, .Invalid_Info_Hash
			}
			result[i] = (hi << 4) | lo
		}
		return result, .None
	}

	// A BTIH may also be represented by 32 unpadded RFC 4648 Base32
	// characters (32 * 5 = 160 bits).
	if len(value) != 32 {
		return [20]byte{}, .Invalid_Info_Hash
	}
	result: [20]byte
	accumulator: u32 = 0
	bits := 0
	output_position := 0
	for c in value {
		digit, ok := magnet_base32_value(c)
		if !ok {
			return [20]byte{}, .Invalid_Info_Hash
		}
		accumulator = (accumulator << 5) | u32(digit)
		bits += 5
		if bits >= 8 {
			bits -= 8
			result[output_position] = byte((accumulator >> u32(bits)) & 0xff)
			output_position += 1
		}
		if bits == 0 {
			accumulator = 0
		} else {
			accumulator &= (u32(1) << u32(bits)) - 1
		}
	}
	if output_position != 20 || bits != 0 {
		return [20]byte{}, .Invalid_Info_Hash
	}
	return result, .None
}

magnet_hex_value :: proc(c: byte) -> (byte, bool) {
	switch c {
	case '0' ..= '9':
		return c - '0', true
	case 'a' ..= 'f':
		return c - 'a' + 10, true
	case 'A' ..= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}

magnet_base32_value :: proc(c: byte) -> (byte, bool) {
	switch c {
	case 'A' ..= 'Z':
		return c - 'A', true
	case 'a' ..= 'z':
		return c - 'a', true
	case '2' ..= '7':
		return c - '2' + 26, true
	}
	return 0, false
}

magnet_equal_ignore_case :: proc(a, b: []byte) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i := 0; i < len(a); i += 1 {
		left := a[i]
		right := b[i]
		if left >= 'A' && left <= 'Z' {
			left += 'a' - 'A'
		}
		if right >= 'A' && right <= 'Z' {
			right += 'a' - 'A'
		}
		if left != right {
			return false
		}
	}
	return true
}
