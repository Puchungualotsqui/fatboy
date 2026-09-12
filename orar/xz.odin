package orar

// XZ support is intentionally self-contained.  It implements the XZ stream
// framing and the LZMA2 filter used by normal tar.xz files; it does not call an
// operating-system decompressor.

XZ_MAGIC_SIZE :: 6
XZ_MAX_DICTIONARY :: 256 * 1024 * 1024
XZ_MAX_OUTPUT :: 512 * 1024 * 1024
XZ_RC_TOP :: u32(1 << 24)
XZ_RC_TOTAL_BITS :: 11
XZ_RC_TOTAL :: u32(1 << XZ_RC_TOTAL_BITS)
XZ_LZMA_MOVE_BITS :: 5

xz_block_info :: struct {
	unpadded_size:     u64,
	uncompressed_size: u64,
}

xz_lzma_decoder :: struct {
	probs:          []u16,
	lc:             int,
	lp:             int,
	pb:             int,
	dictionary:     []byte,
	dictionary_pos: int,
	dictionary_used: int,
	processed_pos:  u64,
	state:          int,
	reps:           [4]u32,
	range:          u32,
	code:           u32,
	pending_length: int,
	pending_distance: u32,
	input:          []byte,
	input_pos:      int,
	input_end:      int,
}

// The probability layout is the layout used by the public-domain 7-Zip LZMA
// decoder.  Keeping the offsets explicit makes the hot decoder compact while
// still allowing the literal tree to be sized from lc + lp.
XZ_LZMA_SPEC_POS :: 0
XZ_LZMA_REP0_LONG :: 128
XZ_LZMA_REP_LEN :: 384
XZ_LZMA_LEN :: 896
XZ_LZMA_IS_MATCH :: 1408
XZ_LZMA_ALIGN :: 1664
XZ_LZMA_IS_REP :: 1680
XZ_LZMA_IS_REP_G0 :: 1692
XZ_LZMA_IS_REP_G1 :: 1704
XZ_LZMA_IS_REP_G2 :: 1716
XZ_LZMA_POS_SLOT :: 1728
XZ_LZMA_LITERAL :: 1984
XZ_LZMA_BASE_PROBS :: 1984

XZ_LZMA_LEN_PROBS :: 272
XZ_LZMA_NUM_POS_STATES :: 16
XZ_LZMA_NUM_STATES :: 12
XZ_LZMA_NUM_FULL_DISTANCES :: 128
XZ_LZMA_END_POS_MODEL_INDEX :: 14

xz_read_vli :: proc(data: []byte, position: ^int) -> (u64, bool) {
	value: u64 = 0
	shift: u32 = 0
	for count := 0; count < 9; count += 1 {
		if position^ < 0 || position^ >= len(data) {
			return 0, false
		}
		value_byte := data[position^]
		position^ += 1
		if shift >= 64 || (u64(value_byte&0x7f) << shift) >> shift != u64(value_byte&0x7f) {
			return 0, false
		}
		value |= u64(value_byte&0x7f) << shift
		if value_byte&0x80 == 0 {
			return value, true
		}
		shift += 7
	}
	return 0, false
}

xz_check_size :: proc(check_type: byte) -> (int, bool) {
	switch check_type {
	case 0:
		return 0, true
	case 1:
		return 4, true
	case 4:
		return 8, true
	}
	return 0, false
}

xz_crc64 :: proc(data: []byte) -> u64 {
	crc: u64 = 0xffff_ffff_ffff_ffff
	for value in data {
		crc ~= u64(value)
		for bit := 0; bit < 8; bit += 1 {
			mask := u64(0) - (crc & 1)
			crc = (crc >> 1) ~ (u64(0xc96c5795d7870f42) & mask)
		}
	}
	return crc ~ u64(0xffff_ffff_ffff_ffff)
}

xz_align4 :: proc(value: int) -> int {
	return ((value + 3) / 4) * 4
}

xz_lzma_make_probs :: proc(decoder: ^xz_lzma_decoder, lc, lp, pb: int) -> Error {
	if lc < 0 || lc > 8 || lp < 0 || lp > 4 || pb < 0 || pb > 4 || lc+lp > 4 {
		return .Unsupported_Feature
	}
	count := XZ_LZMA_BASE_PROBS + (0x300 << u32(lc+lp))
	probs, alloc_error := make([]u16, count, context.allocator)
	if alloc_error != nil {
		return .Out_Of_Memory
	}
	delete(decoder.probs)
	decoder.probs = probs
	for index := 0; index < len(decoder.probs); index += 1 {
		decoder.probs[index] = u16(XZ_RC_TOTAL >> 1)
	}
	decoder.lc = lc
	decoder.lp = lp
	decoder.pb = pb
	return .None
}

xz_lzma_dictionary_size :: proc(property: byte) -> (int, Error) {
	if property&0xc0 != 0 || property > 40 {
		return 0, .Unsupported_Feature
	}
	if property == 40 {
		return 0, .Limit_Exceeded
	}
	mantissa := u64(2 | (property & 1))
	size: u64 = mantissa << u32(int(property)/2+11)
	if size > u64(XZ_MAX_DICTIONARY) || size > u64(0x7fffffffffffffff) {
		return 0, .Limit_Exceeded
	}
	return int(size), .None
}

xz_lzma_init :: proc(property: byte) -> (xz_lzma_decoder, Error) {
	decoder: xz_lzma_decoder
	dictionary_size, err := xz_lzma_dictionary_size(property)
	if err != .None {
		return decoder, err
	}
	dictionary, alloc_error := make([]byte, dictionary_size, context.allocator)
	if alloc_error != nil {
		return decoder, .Out_Of_Memory
	}
	decoder.dictionary = dictionary
	decoder.dictionary_pos = 0
	decoder.dictionary_used = 0
	decoder.processed_pos = 0
	decoder.state = 0
	decoder.reps = [4]u32{1, 1, 1, 1}
	return decoder, .None
}

xz_lzma_destroy :: proc(decoder: ^xz_lzma_decoder) {
	delete(decoder.probs)
	delete(decoder.dictionary)
	decoder^ = xz_lzma_decoder{}
}

xz_lzma_reset_dictionary :: proc(decoder: ^xz_lzma_decoder) {
	decoder.dictionary_pos = 0
	decoder.dictionary_used = 0
	decoder.processed_pos = 0
	decoder.pending_length = 0
	decoder.pending_distance = 0
}

xz_lzma_reset_state :: proc(decoder: ^xz_lzma_decoder) {
	decoder.state = 0
	decoder.reps = [4]u32{1, 1, 1, 1}
	decoder.pending_length = 0
	decoder.pending_distance = 0
}

xz_lzma_set_props :: proc(decoder: ^xz_lzma_decoder, property: byte) -> Error {
	lc := int(property % 9)
	remaining := int(property / 9)
	pb := remaining / 5
	lp := remaining % 5
	return xz_lzma_make_probs(decoder, lc, lp, pb)
}

xz_lzma_read_byte :: proc(decoder: ^xz_lzma_decoder) -> (byte, bool) {
	if decoder.input_pos >= decoder.input_end {
		return 0, false
	}
	value := decoder.input[decoder.input_pos]
	decoder.input_pos += 1
	return value, true
}

xz_lzma_normalize :: proc(decoder: ^xz_lzma_decoder) -> bool {
	if decoder.range >= XZ_RC_TOP {
		return true
	}
	value, ok := xz_lzma_read_byte(decoder)
	if !ok {
		return false
	}
	decoder.range <<= 8
	decoder.code = (decoder.code << 8) | u32(value)
	return true
}

xz_lzma_decode_bit :: proc(decoder: ^xz_lzma_decoder, probability: ^u16) -> (int, bool) {
	if !xz_lzma_normalize(decoder) {
		return 0, false
	}
	probability_value := u32(probability^)
	bound := (decoder.range >> XZ_RC_TOTAL_BITS) * probability_value
	if decoder.code < bound {
		decoder.range = bound
		probability^ = probability^ + u16((XZ_RC_TOTAL-u32(probability^)) >> XZ_LZMA_MOVE_BITS)
		return 0, true
	}
	decoder.range -= bound
	decoder.code -= bound
	probability^ = probability^ - u16(u32(probability^) >> XZ_LZMA_MOVE_BITS)
	return 1, true
}

xz_lzma_decode_tree :: proc(decoder: ^xz_lzma_decoder, base, bits: int) -> (int, bool) {
	symbol := 1
	for count := 0; count < bits; count += 1 {
		bit, ok := xz_lzma_decode_bit(decoder, &decoder.probs[base+symbol])
		if !ok {
			return 0, false
		}
		symbol = (symbol << 1) | bit

	}
	return symbol - (1 << u32(bits)), true
}

xz_lzma_decode_reverse_tree :: proc(decoder: ^xz_lzma_decoder, model_base, start_index, bits: int) -> (int, bool) {
	index := start_index
	mask := 1
	value := 0
	for count := 0; count < bits; count += 1 {
		bit, ok := xz_lzma_decode_bit(decoder, &decoder.probs[model_base+index])
		if !ok {
			return 0, false
		}
		if bit == 0 {
			index += mask
		} else {
			mask <<= 1
			index += mask
			value |= 1 << u32(count)
			continue
		}
		mask <<= 1
	}
	return value, true
}

xz_lzma_decode_direct :: proc(decoder: ^xz_lzma_decoder, bits: int) -> (u32, bool) {
	value: u32 = 0
	for count := 0; count < bits; count += 1 {
		if !xz_lzma_normalize(decoder) {
			return 0, false
		}
		decoder.range >>= 1
		bit: u32 = 0
		if decoder.code >= decoder.range {
			decoder.code -= decoder.range
			bit = 1
		}
		value = (value << 1) | bit
	}
	return value, true
}

xz_lzma_decode_align :: proc(decoder: ^xz_lzma_decoder) -> (u32, bool) {
	value: u32 = 0
	index := 1
	mask := 1
	for count := 0; count < 4; count += 1 {
		bit, ok := xz_lzma_decode_bit(decoder, &decoder.probs[XZ_LZMA_ALIGN+index])
		if !ok {
			return 0, false
		}
		if bit == 0 {
			index += mask
		} else {
			mask <<= 1
			index += mask
			value |= 1 << u32(count)
			continue
		}
		mask <<= 1
	}
	return value, true
}

xz_lzma_decode_length :: proc(decoder: ^xz_lzma_decoder, base, pos_state: int) -> (int, bool) {

	choice, ok := xz_lzma_decode_bit(decoder, &decoder.probs[base])
	if !ok {
		return 0, false
	}

	if choice == 0 {
		value, tree_ok := xz_lzma_decode_tree(decoder, base+pos_state, 3)

		return value, tree_ok
	}
	choice2, choice_ok := xz_lzma_decode_bit(decoder, &decoder.probs[base+8])
	if !choice_ok {
		return 0, false
	}
	if choice2 == 0 {
		value, tree_ok := xz_lzma_decode_tree(decoder, base+128+pos_state, 3)
		value += 8

		return value, tree_ok
	}
	value, tree_ok := xz_lzma_decode_tree(decoder, base+256, 8)
	value += 16

	return value, tree_ok
}

xz_lzma_dictionary_byte :: proc(decoder: ^xz_lzma_decoder, distance: u32) -> (byte, bool) {
	if distance == 0 || u64(distance) > u64(decoder.dictionary_used) || len(decoder.dictionary) == 0 {
		return 0, false
	}
	index := decoder.dictionary_pos - int(distance)
	if index < 0 {
		index += len(decoder.dictionary)
	}
	return decoder.dictionary[index], true
}

xz_lzma_write_byte :: proc(decoder: ^xz_lzma_decoder, output: []byte, output_pos: ^int, value: byte) -> bool {
	if output_pos^ >= len(output) || len(decoder.dictionary) == 0 {
		return false
	}
	output[output_pos^] = value
	output_pos^ += 1
	decoder.dictionary[decoder.dictionary_pos] = value
	decoder.dictionary_pos += 1
	if decoder.dictionary_pos == len(decoder.dictionary) {
		decoder.dictionary_pos = 0
	}
	if decoder.dictionary_used < len(decoder.dictionary) {
		decoder.dictionary_used += 1
	}
	decoder.processed_pos += 1
	return true
}

xz_lzma_copy_pending :: proc(decoder: ^xz_lzma_decoder, output: []byte, output_pos: ^int) -> bool {
	for decoder.pending_length > 0 && output_pos^ < len(output) {
		value, ok := xz_lzma_dictionary_byte(decoder, decoder.pending_distance)
		if !ok || !xz_lzma_write_byte(decoder, output, output_pos, value) {
			return false
		}
		decoder.pending_length -= 1
	}
	return true
}

xz_lzma_decode_distance :: proc(decoder: ^xz_lzma_decoder, length: int) -> (u32, bool) {
	length_state := length
	if length_state > 3 {
		length_state = 3
	}
	pos_slot, ok := xz_lzma_decode_tree(decoder, XZ_LZMA_POS_SLOT+length_state*64, 6)
	if !ok {
		return 0, false
	}
	if pos_slot < 4 {
		return u32(pos_slot + 1), true
	}
	direct_bits := (pos_slot >> 1) - 1
	base: u32 = u32(2 | (pos_slot & 1))
	if pos_slot < XZ_LZMA_END_POS_MODEL_INDEX {
		special_base := base << u32(direct_bits)
		value, reverse_ok := xz_lzma_decode_reverse_tree(decoder, XZ_LZMA_SPEC_POS, int(special_base)+1, direct_bits)
		if !reverse_ok {
			return 0, false
		}
		result := special_base + u32(value) + 1

		return result, true
	}
	direct_bits -= 4
	value, direct_ok := xz_lzma_decode_direct(decoder, direct_bits)
	if !direct_ok {
		return 0, false
	}
	align, align_ok := xz_lzma_decode_align(decoder)
	if !align_ok {
		return 0, false
	}
	result := ((base << u32(direct_bits) | value) << 4 | align) + 1

	return result, true
}

xz_lzma_decode_chunk :: proc(
	decoder: ^xz_lzma_decoder,
	compressed: []byte,
	output: []byte,
) -> Error {
	decoder.input = compressed
	decoder.input_pos = 0
	decoder.input_end = len(compressed)
	decoder.range = 0xffff_ffff
	decoder.code = 0
	for count := 0; count < 5; count += 1 {
		value, ok := xz_lzma_read_byte(decoder)
		if !ok || (count == 0 && value != 0) {
			return .Invalid_Archive
		}
		decoder.code = (decoder.code << 8) | u32(value)
	}

	output_pos := 0
	if !xz_lzma_copy_pending(decoder, output, &output_pos) {
		return .Invalid_Archive
	}
	for output_pos < len(output) {
		pos_state := int(decoder.processed_pos & u64((1 << u32(decoder.pb))-1))

		match_bit, ok := xz_lzma_decode_bit(decoder, &decoder.probs[XZ_LZMA_IS_MATCH+pos_state*16+decoder.state])

		if !ok {
			return .Truncated
		}
		if match_bit == 0 {
			literal_state := int(((decoder.processed_pos & u64((1 << u32(decoder.lp))-1)) << u32(decoder.lc)) | u64(xz_lzma_previous_byte(decoder) >> byte(8-decoder.lc)))
			base := XZ_LZMA_LITERAL + literal_state*0x300
			symbol := 1
			if decoder.state >= 7 {
				match_byte_value, valid := xz_lzma_dictionary_byte(decoder, decoder.reps[0])
				if !valid {

					return .Invalid_Archive
				}
				match_byte := int(match_byte_value)
				offs := 0x100
				for symbol < 0x100 {
					match_byte <<= 1
					bit_mask := offs
					offs &= int(match_byte)
					probability_index := base + offs + bit_mask + symbol
					bit, valid := xz_lzma_decode_bit(decoder, &decoder.probs[probability_index])
					if !valid {
						return .Truncated
					}
					symbol = (symbol << 1) | bit
					if bit == 0 {
						offs ~= bit_mask
					}
				}
			} else {
				for symbol < 0x100 {
					bit, valid := xz_lzma_decode_bit(decoder, &decoder.probs[base+symbol])
					if !valid {
						return .Truncated
					}
					symbol = (symbol << 1) | bit
				}
			}
			if decoder.state < 4 {
				decoder.state = 0
			} else if decoder.state < 10 {
				decoder.state -= 3
			} else {
				decoder.state -= 6
			}
			if !xz_lzma_write_byte(decoder, output, &output_pos, byte(symbol-0x100)) {
				return .Invalid_Archive
			}
			continue
		}


		is_rep, valid := xz_lzma_decode_bit(decoder, &decoder.probs[XZ_LZMA_IS_REP+decoder.state])

		if !valid {
			return .Truncated
		}
		length: int
		if is_rep != 0 {
			is_g0, valid := xz_lzma_decode_bit(decoder, &decoder.probs[XZ_LZMA_IS_REP_G0+decoder.state])
			if !valid {
				return .Truncated
			}
			if is_g0 == 0 {
				long, valid := xz_lzma_decode_bit(decoder, &decoder.probs[XZ_LZMA_REP0_LONG+pos_state*16+decoder.state])

				if !valid {
					return .Truncated
				}
				if long == 0 {
					value, valid := xz_lzma_dictionary_byte(decoder, decoder.reps[0])
					if !valid || !xz_lzma_write_byte(decoder, output, &output_pos, value) {

						return .Invalid_Archive
					}
					if decoder.state < 7 {
						decoder.state = 9
					} else {
						decoder.state = 11
					}
					continue
				}
			} else {
				is_g1, valid := xz_lzma_decode_bit(decoder, &decoder.probs[XZ_LZMA_IS_REP_G1+decoder.state])
				if !valid {
					return .Truncated
				}
				if is_g1 == 0 {
					distance := decoder.reps[1]
					decoder.reps[1] = decoder.reps[0]
					decoder.reps[0] = distance
				} else {
					is_g2, valid := xz_lzma_decode_bit(decoder, &decoder.probs[XZ_LZMA_IS_REP_G2+decoder.state])
					if !valid {
						return .Truncated
					}
					if is_g2 == 0 {
						distance := decoder.reps[2]
						decoder.reps[2] = decoder.reps[1]
						decoder.reps[1] = decoder.reps[0]
						decoder.reps[0] = distance
					} else {
						distance := decoder.reps[3]
						decoder.reps[3] = decoder.reps[2]
						decoder.reps[2] = decoder.reps[1]
						decoder.reps[1] = decoder.reps[0]
						decoder.reps[0] = distance
					}
				}
			}
			if decoder.state < 7 {
				decoder.state = 8
			} else {
				decoder.state = 11
			}
			length, valid = xz_lzma_decode_length(decoder, XZ_LZMA_REP_LEN, pos_state*16)
			if !valid {
				return .Truncated
			}

			xz_lzma_set_pending(decoder, length+2)
		} else {
			if decoder.state < 7 {
				decoder.state = 7
			} else {
				decoder.state = 10
			}
			length, valid = xz_lzma_decode_length(decoder, XZ_LZMA_LEN, pos_state*16)
			if !valid {
				return .Truncated
			}

			distance, valid := xz_lzma_decode_distance(decoder, length)
			if !valid || distance == 0 {
				return .Truncated
			}
			decoder.reps[3] = decoder.reps[2]
			decoder.reps[2] = decoder.reps[1]
			decoder.reps[1] = decoder.reps[0]
			decoder.reps[0] = distance
			xz_lzma_set_pending(decoder, length+2)
		}
		if !xz_lzma_copy_pending(decoder, output, &output_pos) {

			return .Invalid_Archive
		}
	}
	return .None
}

xz_lzma_set_pending :: proc(decoder: ^xz_lzma_decoder, length: int) {
	decoder.pending_length = length
	decoder.pending_distance = decoder.reps[0]
}

xz_lzma_previous_byte :: proc(decoder: ^xz_lzma_decoder) -> byte {
	if decoder.processed_pos == 0 || decoder.dictionary_used == 0 {
		return 0
	}
	index := decoder.dictionary_pos - 1
	if index < 0 {
		index += len(decoder.dictionary)
	}
	return decoder.dictionary[index]
}

xz_decode_lzma2 :: proc(data: []byte, dictionary_property: byte, expected_size: int) -> ([]byte, Error) {
	decoder, err := xz_lzma_init(dictionary_property)
	if err != .None {
		return nil, err
	}
	defer xz_lzma_destroy(&decoder)
	output, alloc_error := make([]byte, expected_size, context.allocator)
	if alloc_error != nil {
		return nil, .Out_Of_Memory
	}
	position := 0
	output_position := 0
	need_level := byte(0xe0)
	finished := false
	for position < len(data) {
		control := data[position]
		position += 1
		if control == 0 {
			finished = true
			break
		}
		if control == 1 || control == 2 {
			if control == 1 {
				if need_level == 0 {
					delete(output)
					return nil, .Invalid_Archive
				}
				xz_lzma_reset_dictionary(&decoder)
				need_level = 0xc0
			} else if need_level == 0xe0 {
				delete(output)
				return nil, .Invalid_Archive
			}
			unpacked, ok := read_u16be(data, position)
			if !ok {
				delete(output)
				return nil, .Truncated
			}
			position += 2
			chunk_size := int(unpacked) + 1
			if chunk_size > len(data)-position || chunk_size > len(output)-output_position {
				delete(output)
				return nil, .Truncated
			}
			if !xz_lzma_copy_pending(&decoder, output, &output_position) {
				delete(output)
				return nil, .Invalid_Archive
			}
			for index := 0; index < chunk_size; index += 1 {
				if !xz_lzma_write_byte(&decoder, output, &output_position, data[position+index]) {
					delete(output)
					return nil, .Invalid_Archive
				}
			}
			position += chunk_size
			continue
		}
		if control < 0x80 {
			delete(output)
			return nil, .Invalid_Archive
		}
		unpacked := int(u32(control&0x1f) << 16)
		unpacked_value, ok := read_u16be(data, position)
		if !ok {
			delete(output)
			return nil, .Truncated
		}
		position += 2
		unpacked += int(unpacked_value) + 1
		packed_value, packed_ok := read_u16be(data, position)
		if !packed_ok {
			delete(output)
			return nil, .Truncated
		}
		position += 2
		packed_size := int(packed_value) + 1
		if packed_size > len(data)-position || unpacked > len(output)-output_position {
			delete(output)
			return nil, .Truncated
		}
		if control >= 0xc0 {
			if position >= len(data) {
				delete(output)
				return nil, .Truncated
			}
			property := data[position]
			position += 1
			if err := xz_lzma_set_props(&decoder, property); err != .None {
				delete(output)
				return nil, err
			}
			need_level = 0
		} else if need_level != 0 {
			delete(output)
			return nil, .Invalid_Archive
		}
		if control >= 0xe0 {
			xz_lzma_reset_dictionary(&decoder)
			xz_lzma_reset_state(&decoder)
		} else if control >= 0xa0 {
			xz_lzma_reset_state(&decoder)
		}
		chunk := data[position:position+packed_size]
		if err := xz_lzma_decode_chunk(&decoder, chunk, output[output_position:output_position+unpacked]); err != .None {
			delete(output)
			return nil, err
		}
		position += packed_size
		output_position += unpacked
	}
	if !finished || output_position != len(output) || decoder.pending_length != 0 {
		delete(output)
		return nil, .Invalid_Archive
	}
	for position < len(data) {
		if data[position] != 0 {
			delete(output)
			return nil, .Invalid_Archive
		}
		position += 1
	}
	return output, .None
}

xz_check_value_valid :: proc(data: []byte, offset, check_type: int, expected: []byte) -> bool {
	if check_type == 0 {
		return true
	}
	if check_type == 4 {
		value, ok := read_u64le(data, offset)
		return ok && value == xz_crc64(expected)
	}
	value, ok := read_u32le(data, offset)
	return ok && value == crc32(0, expected)
}

xz_decode_stream :: proc(data: []byte) -> ([]byte, Error) {
	if len(data) < 12 || data[0] != 0xfd || data[1] != 0x37 || data[2] != 0x7a || data[3] != 0x58 || data[4] != 0x5a || data[5] != 0x00 {
		return nil, .Unsupported_Format
	}
	if data[6] != 0 || data[7]&0xf0 != 0 {
		return nil, .Invalid_Archive
	}
	check_size, check_ok := xz_check_size(data[7]&0x0f)
	if !check_ok {
		return nil, .Unsupported_Feature
	}
	stream_flags := data[6:8]
	stream_crc, stream_crc_ok := read_u32le(data, 8)
	if !stream_crc_ok || stream_crc != crc32(0, stream_flags) {
		return nil, .Checksum_Mismatch
	}

	position := 12
	blocks: [dynamic]xz_block_info
	output: [dynamic]byte
	defer delete(blocks)
	defer delete(output)
	for position < len(data) && data[position] != 0 {
		header_start := position
		header_size := (int(data[position])+1)*4
		if header_size < 8 || header_start+header_size > len(data) {
			return nil, .Truncated
		}
		header_end := header_start + header_size
		crc_position := header_end - 4
		flags := data[header_start+1]
		if flags&0x3c != 0 || flags&0x03 != 0 {
			return nil, .Invalid_Archive
		}
		if flags&0xc0 != 0xc0 {
			return nil, .Unsupported_Feature
		}
		filter_count := int(flags&0x03) + 1
		if filter_count != 1 {
			return nil, .Unsupported_Feature
		}
		cursor := header_start + 2
		compressed_size, compressed_ok := xz_read_vli(data[:crc_position], &cursor)
		uncompressed_size, uncompressed_ok := xz_read_vli(data[:crc_position], &cursor)
		if !compressed_ok || !uncompressed_ok || compressed_size > u64(0x7fffffffffffffff) || uncompressed_size > u64(0x7fffffffffffffff) {
			return nil, .Invalid_Archive
		}
		filter_id, filter_ok := xz_read_vli(data[:crc_position], &cursor)
		property_size, property_ok := xz_read_vli(data[:crc_position], &cursor)
		if !filter_ok || !property_ok || filter_id != 0x21 || property_size != 1 || cursor >= crc_position {
			return nil, .Unsupported_Feature
		}
		dictionary_property := data[cursor]
		cursor += 1
		_, dictionary_err := xz_lzma_dictionary_size(dictionary_property)
		if dictionary_err != .None {
			return nil, dictionary_err
		}
		for cursor < crc_position {
			if data[cursor] != 0 {
				return nil, .Invalid_Archive
			}
			cursor += 1
		}
		stored_header_crc, ok := read_u32le(data, crc_position)
		if !ok || stored_header_crc != crc32(0, data[header_start:crc_position]) {
			return nil, .Checksum_Mismatch
		}
		if compressed_size > u64(len(data)-header_end) || compressed_size > u64(0x7fffffffffffffff) {
			return nil, .Truncated
		}
		compressed_start := header_end
		compressed_end := compressed_start + int(compressed_size)
		padded_end := xz_align4(compressed_end)
		if padded_end > len(data) || padded_end+check_size > len(data) {
			return nil, .Truncated
		}
		for pad := compressed_end; pad < padded_end; pad += 1 {
			if data[pad] != 0 {
				return nil, .Invalid_Archive
			}
		}
		if uncompressed_size > u64(XZ_MAX_OUTPUT) || uncompressed_size > u64(0x7fffffffffffffff) {
			return nil, .Limit_Exceeded
		}
		block_output, err := xz_decode_lzma2(data[compressed_start:compressed_end], dictionary_property, int(uncompressed_size))
		if err != .None {

			return nil, err
		}

		if !xz_check_value_valid(data, padded_end, int(data[7]&0x0f), block_output) {
			delete(block_output)
			return nil, .Checksum_Mismatch
		}
		if u64(len(output))+uncompressed_size > u64(XZ_MAX_OUTPUT) {
			delete(block_output)
			return nil, .Limit_Exceeded
		}
		append(&output, ..block_output)
		delete(block_output)
		append(&blocks, xz_block_info{
			unpadded_size = u64(header_size) + compressed_size + u64(check_size),
			uncompressed_size = uncompressed_size,
		})
		position = padded_end + check_size
	}
	if len(blocks) == 0 || position >= len(data) || data[position] != 0 {
		return nil, .Invalid_Archive
	}
	index_start := position
	position += 1
	record_count, record_ok := xz_read_vli(data, &position)
	if !record_ok || record_count != u64(len(blocks)) {
		return nil, .Invalid_Archive
	}
	for index := 0; index < len(blocks); index += 1 {
		unpadded, unpadded_ok := xz_read_vli(data, &position)
		uncompressed, uncompressed_ok := xz_read_vli(data, &position)
		if !unpadded_ok || !uncompressed_ok || unpadded != blocks[index].unpadded_size || uncompressed != blocks[index].uncompressed_size {
			return nil, .Invalid_Archive
		}
	}
	index_crc_position := xz_align4(position)
	if index_crc_position+4+12 > len(data) {
		return nil, .Truncated
	}
	for pad := position; pad < index_crc_position; pad += 1 {
		if data[pad] != 0 {
			return nil, .Invalid_Archive
		}
	}
	stored_index_crc, index_crc_ok := read_u32le(data, index_crc_position)

	if !index_crc_ok || stored_index_crc != crc32(0, data[index_start:index_crc_position]) {
		return nil, .Checksum_Mismatch
	}
	footer_start := index_crc_position + 4
	footer_crc, footer_crc_ok := read_u32le(data, footer_start)

	if !footer_crc_ok || footer_crc != crc32(0, data[footer_start+4:footer_start+10]) || data[footer_start+10] != 0x59 || data[footer_start+11] != 0x5a {
		return nil, .Checksum_Mismatch
	}
	backward_size, backward_ok := read_u32le(data, footer_start+4)
	if !backward_ok || u64(backward_size+1)*4 != u64(footer_start-index_start) {
		return nil, .Invalid_Archive
	}
	if data[footer_start+8] != data[6] || data[footer_start+9] != data[7] {
		return nil, .Invalid_Archive
	}
	for trailing := footer_start + 12; trailing < len(data); trailing += 1 {
		if data[trailing] != 0 {
			return nil, .Invalid_Archive
		}
	}
	result, alloc_error := make([]byte, len(output), context.allocator)
	if alloc_error != nil {
		return nil, .Out_Of_Memory
	}
	copy(result, output[:])

	return result, .None
}

decode_xz :: proc(data: []byte) -> ([]byte, Error) {
	return xz_decode_stream(data)
}
