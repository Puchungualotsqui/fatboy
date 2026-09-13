package orar

// GZIP support is a pure-Odin wrapper around the package's bounded raw
// DEFLATE decoder.  The wrapper validates the GZIP member framing and trailer;
// it does not invoke a system compression library.

// Keep this above the largest supported game archive expansion while still
// bounding gzip bombs and accidental unbounded allocations.
GZIP_MAX_OUTPUT :: u64(2) * 1024 * 1024 * 1024

GZIP_FLAG_HEADER_CRC :: byte(0x02)
GZIP_FLAG_EXTRA :: byte(0x04)
GZIP_FLAG_NAME :: byte(0x08)
GZIP_FLAG_COMMENT :: byte(0x10)

inflate_raw_with_consumed :: proc(data: []byte, expected_size, max_output: u64) -> ([]byte, int, Error) {
	if expected_size > 0x7fffffffffffffff || max_output > 0x7fffffffffffffff {
		return nil, 0, .Limit_Exceeded
	}
	if max_output != 0 && expected_size != 0 && expected_size > max_output {
		return nil, 0, .Limit_Exceeded
	}

	reader := deflate_bit_reader{data = data}
	output := deflate_output{
		expected_size = expected_size,
		max_output = max_output,
	}
	if err := deflate_decode_stream(&reader, &output, false); err != .None {
		delete(output.data)
		return nil, 0, err
	}
	if expected_size != 0 && u64(output.length) != expected_size {
		delete(output.data)
		return nil, 0, .Invalid_Archive
	}
	consumed := int((reader.position + 7) / 8)
	if consumed < 0 || consumed > len(data) {
		delete(output.data)
		return nil, 0, .Invalid_Archive
	}
	result := output.data[:output.length]
	output.data = nil
	return result, consumed, .None
}

gzip_skip_zero_terminated :: proc(data: []byte, position: ^int, limit: int) -> bool {
	for position^ < limit {
		value := data[position^]
		position^ += 1
		if value == 0 {
			return true
		}
	}
	return false
}

decode_gzip :: proc(data: []byte) -> ([]byte, Error) {
	if len(data) < 18 || data[0] != 0x1f || data[1] != 0x8b {
		return nil, .Unsupported_Format
	}
	if data[2] != 8 || data[3]&0xe0 != 0 {
		return nil, .Unsupported_Feature
	}

	trailer_start := len(data) - 8
	position := 10
	flags := data[3]
	if flags&GZIP_FLAG_EXTRA != 0 {
		extra_length, ok := read_u16le(data, position)
		if !ok {
			return nil, .Truncated
		}
		position += 2
		if u64(extra_length) > u64(trailer_start-position) {
			return nil, .Truncated
		}
		position += int(extra_length)
	}
	if flags&GZIP_FLAG_NAME != 0 && !gzip_skip_zero_terminated(data, &position, trailer_start) {
		return nil, .Truncated
	}
	if flags&GZIP_FLAG_COMMENT != 0 && !gzip_skip_zero_terminated(data, &position, trailer_start) {
		return nil, .Truncated
	}
	if flags&GZIP_FLAG_HEADER_CRC != 0 {
		header_crc_position := position
		header_crc, ok := read_u16le(data, position)
		if !ok || header_crc_position+2 > trailer_start {
			return nil, .Truncated
		}
		if u16(crc32(0, data[:header_crc_position])&0xffff) != header_crc {
			return nil, .Checksum_Mismatch
		}
		position += 2
	}
	if position >= trailer_start {
		return nil, .Truncated
	}

	stored_crc, crc_ok := read_u32le(data, trailer_start)
	stored_size, size_ok := read_u32le(data, trailer_start+4)
	if !crc_ok || !size_ok {
		return nil, .Truncated
	}
	compressed := data[position:trailer_start]
	output, consumed, err := inflate_raw_with_consumed(compressed, u64(stored_size), u64(GZIP_MAX_OUTPUT))
	if err != .None {
		return nil, err
	}
	if consumed != len(compressed) {
		delete(output)
		return nil, .Invalid_Archive
	}
	if crc32(0, output) != stored_crc {
		delete(output)
		return nil, .Checksum_Mismatch
	}
	return output, .None
}
