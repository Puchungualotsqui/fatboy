package orar

// This is a self-contained RFC 1951 raw Deflate decoder.  The bit reader is
// deliberately bounded by the supplied slice; no input byte is ever read
// speculatively past that slice.
deflate_bit_reader :: struct {
	data:      []byte,
	offset:    int,
	bits:      u64,
	available: int,
	position:  u64,
}

deflate_huffman :: struct {
	counts:      [16]u16,
	first_code:  [16]u32,
	offset:      [16]int,
	symbols:     [288]u16,
	symbol_count: int,
}

deflate_output :: struct {
	data:          []byte,
	length:        int,
	expected_size: u64,
	window:        [32768]byte,
	window_offset: int,
	max_output:    u64,
}

// RFC 1951 length and distance bases.  The table indexes are the Deflate
// symbols 257..285 and 0..29 respectively.
deflate_length_base: [29]int = {
	3, 4, 5, 6, 7, 8, 9, 10,
	11, 13, 15, 17, 19, 23, 27, 31,
	35, 43, 51, 59, 67, 83, 99, 115,
	131, 163, 195, 227, 258,
}

deflate_length_extra: [29]int = {
	0, 0, 0, 0, 0, 0, 0, 0,
	1, 1, 1, 1, 2, 2, 2, 2,
	3, 3, 3, 3, 4, 4, 4, 4,
	5, 5, 5, 5, 0,
}

deflate_distance_base: [30]int = {
	1, 2, 3, 4, 5, 7, 9, 13,
	17, 25, 33, 49, 65, 97, 129, 193,
	257, 385, 513, 769, 1025, 1537, 2049, 3073,
	4097, 6145, 8193, 12289, 16385, 24577,
}

deflate_distance_extra: [30]int = {
	0, 0, 0, 0, 1, 1, 2, 2,
	3, 3, 4, 4, 5, 5, 6, 6,
	7, 7, 8, 8, 9, 9, 10, 10,
	11, 11, 12, 12, 13, 13,
}

deflate_code_length_order: [19]int = {
	16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
}

// read_bits consumes count least-significant-bit-first bits.  At most the
// requested number of bytes is fetched, and the logical position is separate
// from offset because the small u64 buffer may contain a few already-fetched
// bits.
deflate_read_bits :: proc(reader: ^deflate_bit_reader, count: int) -> (u64, bool) {
	if count < 0 || count > 32 {
		return 0, false
	}
	for reader.available < count {
		if reader.offset >= len(reader.data) {
			return 0, false
		}
		reader.bits |= u64(reader.data[reader.offset]) << u64(reader.available)
		reader.offset += 1
		reader.available += 8
	}
	if count == 0 {
		return 0, true
	}
	mask := (u64(1) << u64(count)) - 1
	result := reader.bits & mask
	reader.bits >>= u64(count)
	reader.available -= count
	reader.position += u64(count)
	return result, true
}

deflate_read_required :: proc(reader: ^deflate_bit_reader, count: int) -> (u64, Error) {
	value, ok := deflate_read_bits(reader, count)
	if !ok {
		return 0, .Truncated
	}
	return value, .None
}

deflate_align_reader :: proc(reader: ^deflate_bit_reader) -> bool {
	discard := reader.available & 7
	_, ok := deflate_read_bits(reader, discard)
	return ok
}

// Deflate code values are canonical MSB-first values, while the bit stream is
// transmitted LSB-first.  Reverse a code after it has been accumulated from
// the stream.
deflate_reverse_bits :: proc(value: u32, count: int) -> u32 {
	result: u32 = 0
	for index := 0; index < count; index += 1 {
		result = (result << 1) | ((value >> u32(index)) & 1)
	}
	return result
}

// Build a canonical Huffman decoder.  Incomplete trees are retained (they are
// legal for some Deflate trees); oversubscribed trees are rejected.  A lookup
// failure while decoding an incomplete tree is still an invalid stream.
deflate_build_huffman :: proc(lengths: []u8, symbol_count: int) -> (deflate_huffman, bool) {
	tree: deflate_huffman
	if symbol_count < 0 || symbol_count > len(tree.symbols) || len(lengths) < symbol_count {
		return tree, false
	}

	for symbol := 0; symbol < symbol_count; symbol += 1 {
		length := int(lengths[symbol])
		if length > 15 {
			return tree, false
		}
		if length != 0 {
			tree.counts[length] += 1
			tree.symbol_count += 1
		}
	}

	// The Kraft sum must not exceed one.  A non-zero remainder is allowed;
	// the decoder will reject bit patterns which fall into that remainder.
	left := 1
	for length := 1; length <= 15; length += 1 {
		left = (left << 1) - int(tree.counts[length])
		if left < 0 {
			return tree, false
		}
	}

	code: u32 = 0
	for length := 1; length <= 15; length += 1 {
		code = (code + u32(tree.counts[length-1])) << 1
		tree.first_code[length] = code
	}

	offset := 0
	for length := 0; length <= 15; length += 1 {
		tree.offset[length] = offset
		offset += int(tree.counts[length])
	}

	next := tree.offset
	for symbol := 0; symbol < symbol_count; symbol += 1 {
		length := int(lengths[symbol])
		if length != 0 {
			tree.symbols[next[length]] = u16(symbol)
			next[length] += 1
		}
	}
	return tree, true
}

deflate_decode_symbol :: proc(reader: ^deflate_bit_reader, tree: ^deflate_huffman) -> (int, Error) {
	code: u32 = 0
	for length := 1; length <= 15; length += 1 {
		bit, ok := deflate_read_bits(reader, 1)
		if !ok {
			return -1, .Truncated
		}
		code |= u32(bit) << u32(length - 1)
		canonical := deflate_reverse_bits(code, length)
		first := tree.first_code[length]
		count := u32(tree.counts[length])
		if count != 0 && canonical >= first && canonical-first < count {
			index := tree.offset[length] + int(canonical-first)
			return int(tree.symbols[index]), .None
		}
	}
	return -1, .Invalid_Archive
}

deflate_output_grow :: proc(output: ^deflate_output) -> Error {
	current := len(output.data)
	next := 32768
	if current != 0 {
		// Keep the multiplication inside the signed int range used by slices.
		if u64(current) > 0x3fffffffffffffff {
			return .Limit_Exceeded
		}
		next = current * 2
	}
	if output.expected_size != 0 && output.expected_size < u64(next) {
		if output.expected_size > 0x7fffffffffffffff {
			return .Limit_Exceeded
		}
		next = int(output.expected_size)
	}
	if output.max_output != 0 && u64(next) > output.max_output {
		if output.max_output > u64(0x7fffffffffffffff) {
			return .Limit_Exceeded
		}
		next = int(output.max_output)
	}
	if next <= current {
		return .Limit_Exceeded
	}

	data, alloc_error := make([]byte, next, context.allocator)
	if alloc_error != nil {
		return .Out_Of_Memory
	}
	if output.length != 0 {
		copy(data[:output.length], output.data[:output.length])
	}
	delete(output.data)
	output.data = data
	return .None
}

deflate_output_write :: proc(output: ^deflate_output, value: byte) -> Error {
	if output.expected_size != 0 && u64(output.length) >= output.expected_size {
		return .Invalid_Archive
	}
	if output.max_output != 0 && u64(output.length) >= output.max_output {
		return .Limit_Exceeded
	}
	if output.length >= len(output.data) {
		if err := deflate_output_grow(output); err != .None {
			return err
		}
	}

	output.data[output.length] = value
	output.length += 1
	output.window[output.window_offset] = value
	output.window_offset = (output.window_offset + 1) & 0x7fff
	return .None
}

deflate_output_copy :: proc(output: ^deflate_output, distance, length: int) -> Error {
	if distance < 1 || distance > 32768 || u64(distance) > u64(output.length) {
		return .Invalid_Archive
	}
	source := (output.window_offset + 32768 - distance) & 0x7fff
	for index := 0; index < length; index += 1 {
		value := output.window[source]
		if err := deflate_output_write(output, value); err != .None {
			return err
		}
		source = (source + 1) & 0x7fff
	}
	return .None
}

deflate_make_fixed_trees :: proc() -> (deflate_huffman, deflate_huffman, bool) {
	literal_lengths: [288]u8
	for symbol := 0; symbol <= 143; symbol += 1 {
		literal_lengths[symbol] = 8
	}
	for symbol := 144; symbol <= 255; symbol += 1 {
		literal_lengths[symbol] = 9
	}
	for symbol := 256; symbol <= 279; symbol += 1 {
		literal_lengths[symbol] = 7
	}
	for symbol := 280; symbol <= 287; symbol += 1 {
		literal_lengths[symbol] = 8
	}

	distance_lengths: [32]u8
	for symbol := 0; symbol < len(distance_lengths); symbol += 1 {
		distance_lengths[symbol] = 5
	}

	literal_tree, literal_ok := deflate_build_huffman(literal_lengths[:], len(literal_lengths))
	distance_tree, distance_ok := deflate_build_huffman(distance_lengths[:], len(distance_lengths))
	return literal_tree, distance_tree, literal_ok && distance_ok
}

deflate_read_dynamic_trees :: proc(reader: ^deflate_bit_reader) -> (deflate_huffman, deflate_huffman, Error) {
	empty_literal: deflate_huffman
	empty_distance: deflate_huffman

	value, err := deflate_read_required(reader, 5)
	if err != .None {
		return empty_literal, empty_distance, err
	}
	hlit := int(value) + 257
	value, err = deflate_read_required(reader, 5)
	if err != .None {
		return empty_literal, empty_distance, err
	}
	hdist := int(value) + 1
	value, err = deflate_read_required(reader, 4)
	if err != .None {
		return empty_literal, empty_distance, err
	}
	hclen := int(value) + 4

	code_length_lengths: [19]u8
	for index := 0; index < hclen; index += 1 {
		value, err = deflate_read_required(reader, 3)
		if err != .None {
			return empty_literal, empty_distance, err
		}
		code_length_lengths[deflate_code_length_order[index]] = u8(value)
	}

	code_length_tree, tree_ok := deflate_build_huffman(code_length_lengths[:], len(code_length_lengths))
	if !tree_ok || code_length_tree.symbol_count == 0 {
		return empty_literal, empty_distance, .Invalid_Archive
	}

	lengths: [320]u8
	total := hlit + hdist
	index := 0
	for index < total {
		symbol, symbol_err := deflate_decode_symbol(reader, &code_length_tree)
		if symbol_err != .None {
			return empty_literal, empty_distance, symbol_err
		}
		switch {
		case symbol <= 15:
			lengths[index] = u8(symbol)
			index += 1
		case symbol == 16:
			if index == 0 {
				return empty_literal, empty_distance, .Invalid_Archive
			}
			value, err = deflate_read_required(reader, 2)
			if err != .None {
				return empty_literal, empty_distance, err
			}
			repeat := int(value) + 3
			if repeat > total-index {
				return empty_literal, empty_distance, .Invalid_Archive
			}
			previous := lengths[index-1]
			for count := 0; count < repeat; count += 1 {
				lengths[index] = previous
				index += 1
			}
		case symbol == 17:
			value, err = deflate_read_required(reader, 3)
			if err != .None {
				return empty_literal, empty_distance, err
			}
			repeat := int(value) + 3
			if repeat > total-index {
				return empty_literal, empty_distance, .Invalid_Archive
			}
			for count := 0; count < repeat; count += 1 {
				lengths[index] = 0
				index += 1
			}
		case symbol == 18:
			value, err = deflate_read_required(reader, 7)
			if err != .None {
				return empty_literal, empty_distance, err
			}
			repeat := int(value) + 11
			if repeat > total-index {
				return empty_literal, empty_distance, .Invalid_Archive
			}
			for count := 0; count < repeat; count += 1 {
				lengths[index] = 0
				index += 1
			}
		case:
			return empty_literal, empty_distance, .Invalid_Archive
		}
	}

	literal_tree, literal_ok := deflate_build_huffman(lengths[:hlit], hlit)
	if !literal_ok || lengths[256] == 0 {
		return empty_literal, empty_distance, .Invalid_Archive
	}
	distance_tree, distance_ok := deflate_build_huffman(lengths[hlit:total], hdist)
	if !distance_ok {
		return empty_literal, empty_distance, .Invalid_Archive
	}
	return literal_tree, distance_tree, .None
}

deflate_decode_stored_block :: proc(reader: ^deflate_bit_reader, output: ^deflate_output) -> Error {
	if !deflate_align_reader(reader) {
		return .Truncated
	}
	length_value, err := deflate_read_required(reader, 16)
	if err != .None {
		return err
	}
	inverse_value: u64
	inverse_value, err = deflate_read_required(reader, 16)
	if err != .None {
		return err
	}
	length := u16(length_value)
	inverse := u16(inverse_value)
	if (length ~ u16(0xffff)) != inverse {
		return .Invalid_Archive
	}

	for index := 0; index < int(length); index += 1 {
		value, err := deflate_read_required(reader, 8)
		if err != .None {
			return err
		}
		if err := deflate_output_write(output, byte(value)); err != .None {
			return err
		}
	}
	return .None
}

deflate_decode_huffman_block :: proc(
	reader: ^deflate_bit_reader,
	output: ^deflate_output,
	literal_tree: ^deflate_huffman,
	distance_tree: ^deflate_huffman,
) -> Error {
	for {
		symbol, err := deflate_decode_symbol(reader, literal_tree)
		if err != .None {
			return err
		}
		if symbol < 256 {
			if err := deflate_output_write(output, byte(symbol)); err != .None {
				return err
			}
			continue
		}
		if symbol == 256 {
			return .None
		}
		if symbol < 257 || symbol > 285 {
			return .Invalid_Archive
		}

		length_index := symbol - 257
		length := deflate_length_base[length_index]
		extra_count := deflate_length_extra[length_index]
		if extra_count != 0 {
			value, extra_err := deflate_read_required(reader, extra_count)
			if extra_err != .None {
				return extra_err
			}
			length += int(value)
		}

		distance_symbol, distance_err := deflate_decode_symbol(reader, distance_tree)
		if distance_err != .None {
			return distance_err
		}
		if distance_symbol < 0 || distance_symbol >= len(deflate_distance_base) {
			return .Invalid_Archive
		}
		distance := deflate_distance_base[distance_symbol]
		distance_extra_count := deflate_distance_extra[distance_symbol]
		if distance_extra_count != 0 {
			value, extra_err := deflate_read_required(reader, distance_extra_count)
			if extra_err != .None {
				return extra_err
			}
			distance += int(value)
		}
		if err := deflate_output_copy(output, distance, length); err != .None {
			return err
		}
	}
}

deflate_reader_has_only_padding :: proc(reader: ^deflate_bit_reader) -> bool {
	total_bits := u64(len(reader.data)) * 8
	if reader.position > total_bits {
		return false
	}
	remaining := total_bits - reader.position
	if remaining > 7 {
		return false
	}
	for position := reader.position; position < total_bits; position += 1 {
		byte_index := int(position / 8)
		bit_index := int(position & 7)
		if (reader.data[byte_index] & (byte(1) << u32(bit_index))) != 0 {
			return false
		}
	}
	return true
}

deflate_decode_stream :: proc(reader: ^deflate_bit_reader, output: ^deflate_output, require_padding: bool) -> Error {
	fixed_literal_tree, fixed_distance_tree, fixed_ok := deflate_make_fixed_trees()
	if !fixed_ok {
		return .Invalid_Archive
	}

	final_block := false
	for !final_block {
		value, err := deflate_read_required(reader, 1)
		if err != .None {
			return err
		}
		final_block = value != 0
		value, err = deflate_read_required(reader, 2)
		if err != .None {
			return err
		}
		block_type := int(value)

		switch block_type {
		case 0:
			err = deflate_decode_stored_block(reader, output)
		case 1:
			err = deflate_decode_huffman_block(reader, output, &fixed_literal_tree, &fixed_distance_tree)
		case 2:
			literal_tree, distance_tree, tree_err := deflate_read_dynamic_trees(reader)
			if tree_err != .None {
				return tree_err
			}
			err = deflate_decode_huffman_block(reader, output, &literal_tree, &distance_tree)
		case:
			return .Invalid_Archive
		}
		if err != .None {
			return err
		}
	}

	if require_padding && !deflate_reader_has_only_padding(reader) {
		return .Invalid_Archive
	}
	return .None
}

// inflate_raw decodes one complete raw Deflate stream.  A non-zero
// expected_size is both a bound and an exact-size check; zero means that the
// caller does not know the output size in advance.
//
// The returned slice owns its allocation and should be released with delete by
// the caller, just like other allocated byte slices in this package.
inflate_raw :: proc(data: []byte, expected_size: u64) -> ([]byte, Error) {
	if expected_size > 0x7fffffffffffffff {
		return nil, .Limit_Exceeded
	}

	reader := deflate_bit_reader{data = data}
	output := deflate_output{expected_size = expected_size}
	err := deflate_decode_stream(&reader, &output, true)
	if err != .None {
		delete(output.data)
		return nil, err
	}
	if expected_size != 0 && u64(output.length) != expected_size {
		delete(output.data)
		return nil, .Invalid_Archive
	}

	result := output.data[:output.length]
	output.data = nil
	return result, .None
}
