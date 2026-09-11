package orar


// RAR5 is deliberately implemented separately from rar.odin.  Although both
// formats share a signature prefix, their block headers, metadata, and
// compression bit streams are unrelated.
RAR5_SIGNATURE_SIZE :: 8
RAR5_TYPE_MAIN :: u64(1)
RAR5_TYPE_FILE :: u64(2)
RAR5_TYPE_SERVICE :: u64(3)
RAR5_TYPE_ENCRYPTION :: u64(4)
RAR5_TYPE_END :: u64(5)

RAR5_HEADER_EXTRA :: u64(1 << 0)
RAR5_HEADER_DATA :: u64(1 << 1)
RAR5_HEADER_SKIP_UNKNOWN :: u64(1 << 2)
RAR5_HEADER_SPLIT_BEFORE :: u64(1 << 3)
RAR5_HEADER_SPLIT_AFTER :: u64(1 << 4)

RAR5_MAIN_VOLUME :: u64(1 << 0)
RAR5_MAIN_VOLUME_NUMBER :: u64(1 << 1)
RAR5_MAIN_SOLID :: u64(1 << 2)

RAR5_FILE_DIRECTORY :: u16(1 << 0)
RAR5_FILE_UNKNOWN_SIZE :: u16(1 << 3)
RAR5_FILE_SOLID :: u16(1 << 6)
RAR5_FILE_HAS_CRC :: u16(1 << 7)
RAR5_FILE_ENCRYPTED :: u16(1 << 8)
RAR5_FILE_SERVICE :: u16(1 << 9)
RAR5_FILE_SPLIT_BEFORE :: u16(1 << 10)
RAR5_FILE_SPLIT_AFTER :: u16(1 << 11)

RAR5_DICT_BASE :: u64(0x20000)
RAR5_DICT_MAX :: u64(64 * 1024 * 1024)
RAR5_MAX_HEADER_SIZE :: u64(2 * 1024 * 1024)
RAR5_MAX_NAME_SIZE :: u64(8 * 1024 * 1024)

RAR5_HUFF_BC :: 20
RAR5_HUFF_NC :: 306
RAR5_HUFF_DC :: 64
RAR5_HUFF_LDC :: 16
RAR5_HUFF_RC :: 44
RAR5_HUFF_TABLE_SIZE :: RAR5_HUFF_NC + RAR5_HUFF_DC + RAR5_HUFF_LDC + RAR5_HUFF_RC
RAR5_HUFF_MAX_NODES :: 2048

rar5_huffman_node :: struct {
    branch: [2]int,
}

rar5_huffman_code :: struct {
    nodes: [dynamic]rar5_huffman_node,
    symbol_count: int,
}

rar5_bit_reader :: struct {
    data: []byte,
    bit: int,
    end: int,
}

rar5_decoder :: struct {
    window: []byte,
    mask: u64,
    position: u64,
    reps: [4]u32,
    last_length: int,
    tables_ready: bool,
    bit: rar5_bit_reader,
    bc: rar5_huffman_code,
    main: rar5_huffman_code,
    distance: rar5_huffman_code,
    low_distance: rar5_huffman_code,
    repeat_length: rar5_huffman_code,
}

rar5_read_vint :: proc(data: []byte, cursor: ^int, end: int) -> (u64, bool) {
    value: u64 = 0
    shift: int = 0
    for index := 0; index < 10; index += 1 {
        if cursor^ < 0 || cursor^ >= end || cursor^ >= len(data) {
            return 0, false
        }
        current := data[cursor^]
        payload := u64(current & 0x7f)
        if shift >= 64 || payload > ((u64(0xffffffffffffffff) - value) >> u32(shift)) {
            return 0, false
        }
        value |= payload << u32(shift)
        cursor^ += 1
        if (current & 0x80) == 0 {
            return value, true
        }
        shift += 7
    }
    return 0, false
}

rar5_read_u32_cursor :: proc(data: []byte, cursor: ^int, end: int) -> (u32, bool) {
    if cursor^ < 0 || cursor^+4 > end || cursor^+4 > len(data) {
        return 0, false
    }
    value := u32(data[cursor^]) | u32(data[cursor^+1]) << 8 |
        u32(data[cursor^+2]) << 16 | u32(data[cursor^+3]) << 24
    cursor^ += 4
    return value, true
}

rar5_extra_contains_encryption :: proc(extra: []byte) -> (bool, bool) {
    cursor := 0
    for cursor < len(extra) {
        record_size, ok := rar5_read_vint(extra, &cursor, len(extra))
        if !ok || record_size > u64(len(extra)-cursor) || record_size == 0 {
            return false, false
        }
        record_end := cursor + int(record_size)
        record_type, type_ok := rar5_read_vint(extra, &cursor, record_end)
        if !type_ok {
            return false, false
        }
        if record_type == 1 {
            return true, true
        }
        cursor = record_end
    }
    return false, true
}

rar5_parse_file_header :: proc(
    body: []byte,
    common_flags: u64,
    data_size: u64,
    has_data: bool,
    position: int,
    header_end: int,
    service: bool,
) -> (Entry, Error) {
    result := Entry{}
    cursor := 0
    file_flags, ok := rar5_read_vint(body, &cursor, len(body))
    if !ok {
        return result, .Truncated
    }
    unpacked_size: u64
    unpacked_size, ok = rar5_read_vint(body, &cursor, len(body))
    if !ok {
        return result, .Truncated
    }
    attributes: u64
    attributes, ok = rar5_read_vint(body, &cursor, len(body))
    if !ok {
        return result, .Truncated
    }
    _ = attributes

    if (file_flags & u64(RAR5_FILE_UNKNOWN_SIZE)) != 0 {
        return result, .Unsupported_Feature
    }
    is_directory := (file_flags & u64(RAR5_FILE_DIRECTORY)) != 0
    if is_directory {
        if unpacked_size != 0 || data_size != 0 {
            return result, .Invalid_Archive
        }
    } else if !has_data {
        return result, .Invalid_Archive
    }

    filetime: i64 = 0
    if (file_flags & u64(1 << 1)) != 0 {
        timestamp, time_ok := rar5_read_u32_cursor(body, &cursor, len(body))
        if !time_ok {
            return result, .Truncated
        }
        filetime = (i64(timestamp) + 11644473600) * 10000000
    }

    checksum: u32 = 0
    has_checksum := (file_flags & u64(1 << 2)) != 0
    if has_checksum {
        checksum_ok: bool
        checksum, checksum_ok = rar5_read_u32_cursor(body, &cursor, len(body))
        if !checksum_ok {
            return result, .Truncated
        }
    }

    compression_info, compression_ok := rar5_read_vint(body, &cursor, len(body))
    if !compression_ok {
        return result, .Truncated
    }
    version := compression_info & 0x3f
    method := (compression_info >> 7) & 7
    dictionary_power := (compression_info >> 10) & 15
    if version != 0 || method > 5 {
        return result, .Unsupported_Feature
    }
    if !is_directory {
        dictionary_size := RAR5_DICT_BASE << u32(dictionary_power)
        if dictionary_size > RAR5_DICT_MAX {
            return result, .Unsupported_Feature
        }
    }

    host_os, host_ok := rar5_read_vint(body, &cursor, len(body))
    if !host_ok {
        return result, .Truncated
    }
    if host_os > 1 {
        return result, .Unsupported_Feature
    }
    name_size, name_size_ok := rar5_read_vint(body, &cursor, len(body))
    if !name_size_ok || name_size > RAR5_MAX_NAME_SIZE || name_size > u64(len(body)-cursor) {
        return result, .Truncated
    }
    name_start := cursor
    name_end := cursor + int(name_size)
    cursor = name_end

    extra_size := len(body) - cursor
    encrypted_extra, extra_ok := rar5_extra_contains_encryption(body[cursor:])
    if !extra_ok {
        return result, .Invalid_Archive
    }
    if encrypted_extra {
        return result, .Encrypted
    }

    name, raw_name := archive_name_from_bytes(body[name_start:name_end], true)
    if len(name) == 0 {
        delete(name)
        delete(raw_name)
        return result, .Invalid_Archive
    }

    entry_flags: u16 = 0
    if is_directory {
        entry_flags |= RAR5_FILE_DIRECTORY
    }
    if (compression_info & (1 << 6)) != 0 {
        entry_flags |= RAR5_FILE_SOLID
    }
    if has_checksum {
        entry_flags |= RAR5_FILE_HAS_CRC
    }
    if service {
        entry_flags |= RAR5_FILE_SERVICE
    }
    if (common_flags & RAR5_HEADER_SPLIT_BEFORE) != 0 {
        entry_flags |= RAR5_FILE_SPLIT_BEFORE
    }
    if (common_flags & RAR5_HEADER_SPLIT_AFTER) != 0 {
        entry_flags |= RAR5_FILE_SPLIT_AFTER
    }

    result = Entry{
        Name = name,
        Raw_Name = raw_name,
        Kind = is_directory ? .Directory : .File,
        Size = unpacked_size,
        Compressed_Size = data_size,
        Offset = i64(position),
        Filetime = filetime,
        Method = u16(method),
        Flags = entry_flags,
        CRC32 = checksum,
        Data_Offset = i64(header_end),
        Format_Index = int(compression_info),
    }
    _ = extra_size
    return result, .None
}

parse_rar5 :: proc(archive: ^Archive) -> Error {
    if archive == nil {
        return .Invalid_State
    }
    data := archive.Data
    if len(data) < RAR5_SIGNATURE_SIZE {
        return .Truncated
    }
    signature := []byte{'R', 'a', 'r', '!', 0x1a, 0x07, 0x01, 0x00}
    for index in 0..<RAR5_SIGNATURE_SIZE {
        if data[index] != signature[index] {
            return .Unsupported_Format
        }
    }

    position := RAR5_SIGNATURE_SIZE
    saw_main := false
    saw_end := false
    archive_solid := false

    for position < len(data) {
        if position+4 > len(data) {
            return .Truncated
        }
        stored_crc := u32(data[position]) | u32(data[position+1]) << 8 |
            u32(data[position+2]) << 16 | u32(data[position+3]) << 24
        size_cursor := position + 4
        raw_size, size_ok := rar5_read_vint(data, &size_cursor, len(data))
        if !size_ok || raw_size == 0 || raw_size > RAR5_MAX_HEADER_SIZE {
            return .Invalid_Archive
        }
        size_length := size_cursor - (position + 4)
        body_start := size_cursor
        body_end_u := u64(body_start) + raw_size
        if body_end_u < u64(body_start) || body_end_u > u64(len(data)) {
            return .Truncated
        }
        body_end := int(body_end_u)
        if crc32(0, data[position+4:body_end]) != stored_crc {
            return .Invalid_Archive
        }

        body := data[body_start:body_end]
        cursor := 0
        header_type, type_ok := rar5_read_vint(body, &cursor, len(body))
        header_flags, flags_ok := rar5_read_vint(body, &cursor, len(body))
        if !type_ok || !flags_ok {
            return .Truncated
        }
        if (header_flags & (RAR5_HEADER_SPLIT_BEFORE | RAR5_HEADER_SPLIT_AFTER)) != 0 {
            return .Unsupported_Feature
        }

        extra_size: u64 = 0
        data_size: u64 = 0
        has_data := (header_flags & RAR5_HEADER_DATA) != 0
        if (header_flags & RAR5_HEADER_EXTRA) != 0 {
            extra_ok: bool
            extra_size, extra_ok = rar5_read_vint(body, &cursor, len(body))
            if !extra_ok || extra_size > u64(len(body)-cursor) {
                return .Truncated
            }
        }
        if has_data {
            data_ok: bool
            data_size, data_ok = rar5_read_vint(body, &cursor, len(body))
            if !data_ok {
                return .Truncated
            }
        }
        if extra_size > u64(len(body)-cursor) {
            return .Truncated
        }
        metadata_end := len(body) - int(extra_size)
        if metadata_end < cursor {
            return .Invalid_Archive
        }
        if data_size > u64(len(data)-body_end) {
            return .Truncated
        }
        data_end := body_end + int(data_size)

        switch header_type {
        case RAR5_TYPE_MAIN:
            if saw_main || position != RAR5_SIGNATURE_SIZE {
                return .Invalid_Archive
            }
            main_flags, main_ok := rar5_read_vint(body, &cursor, metadata_end)
            if !main_ok {
                return .Truncated
            }
            if cursor > metadata_end {
                return .Invalid_Archive
            }
            if (main_flags & (RAR5_MAIN_VOLUME | RAR5_MAIN_VOLUME_NUMBER)) != 0 {
                return .Unsupported_Feature
            }
            archive_solid = (main_flags & RAR5_MAIN_SOLID) != 0
            saw_main = true
        case RAR5_TYPE_FILE, RAR5_TYPE_SERVICE:
            if !saw_main || saw_end || cursor > metadata_end {
                return .Invalid_Archive
            }
            entry, entry_err := rar5_parse_file_header(
                body[cursor:metadata_end],
                header_flags,
                data_size,
                has_data,
                position,
                body_end,
                header_type == RAR5_TYPE_SERVICE,
            )
            if entry_err == .Encrypted {
                return .Encrypted
            }
            if entry_err != .None {
                return entry_err
            }
            if header_type == RAR5_TYPE_SERVICE {
                // Service data is not a logical file in this API.  It is safe
                // to discard it for non-solid archives; a solid service stream
                // would otherwise alter the compression dictionary invisibly.
                if archive_solid && data_size != 0 {
                    return .Unsupported_Feature
                }
                delete(entry.Name)
                delete(entry.Raw_Name)
            } else {
                append(&archive.Entries, entry)
            }
        case RAR5_TYPE_ENCRYPTION:
            return .Encrypted
        case RAR5_TYPE_END:
            if !saw_main || saw_end || cursor > metadata_end || has_data || extra_size != 0 {
                return .Invalid_Archive
            }
            saw_end = true
        case:
            if !saw_main || saw_end {
                return .Invalid_Archive
            }
            if (header_flags & RAR5_HEADER_SKIP_UNKNOWN) == 0 {
                return .Unsupported_Feature
            }
        }

        position = data_end
        if saw_end {
            break
        }
    }
    if !saw_main || !saw_end {
        return .Invalid_Archive
    }
    return .None
}

rar5_bit_read :: proc(reader: ^rar5_bit_reader, count: int) -> (u32, bool) {
    if reader == nil || count < 0 || count > 32 || reader.bit < 0 || reader.bit+count > reader.end*8 {
        return 0, false
    }
    value: u32 = 0
    for index := 0; index < count; index += 1 {
        byte_index := (reader.bit + index) >> 3
        bit_index := 7 - ((reader.bit + index) & 7)
        value = (value << 1) | u32((reader.data[byte_index] >> u8(bit_index)) & 1)
    }
    reader.bit += count
    return value, true
}

rar5_huffman_clear :: proc(code: ^rar5_huffman_code) {
    if code == nil {
        return
    }
    delete(code.nodes)
    code.nodes = nil
    code.symbol_count = 0
}

rar5_huffman_new_node :: proc(code: ^rar5_huffman_code) -> bool {
    if len(code.nodes) >= RAR5_HUFF_MAX_NODES {
        return false
    }
    append(&code.nodes, rar5_huffman_node{branch = {-1, -2}})
    return true
}

rar5_huffman_build :: proc(code: ^rar5_huffman_code, lengths: []byte, count: int) -> bool {
    rar5_huffman_clear(code)
    if count <= 0 || count > len(lengths) || !rar5_huffman_new_node(code) {
        return false
    }
    counts: [16]int
    for index := 0; index < count; index += 1 {
        length := int(lengths[index])
        if length < 0 || length > 15 {
            return false
        }
        if length != 0 {
            counts[length] += 1
        }
    }
    code_value: u32 = 0
    next_code: [16]u32
    for length := 1; length <= 15; length += 1 {
        code_value = (code_value + u32(counts[length-1])) << 1
        if code_value+u32(counts[length]) > (u32(1) << u32(length)) {
            return false
        }
        next_code[length] = code_value
    }
    for symbol := 0; symbol < count; symbol += 1 {
        length := int(lengths[symbol])
        if length == 0 {
            continue
        }
        value := next_code[length]
        next_code[length] += 1
        node := 0
        for bit_index := length - 1; bit_index >= 0; bit_index -= 1 {
            bit := int((value >> u32(bit_index)) & 1)
            child := code.nodes[node].branch[bit]
            if child == -1 || child == -2 {
                if !rar5_huffman_new_node(code) {
                    rar5_huffman_clear(code)
                    return false
                }
                child = len(code.nodes) - 1
                code.nodes[node].branch[bit] = child
            }
            node = child
            if node < 0 || node >= len(code.nodes) {
                rar5_huffman_clear(code)
                return false
            }
        }
        if code.nodes[node].branch[0] != -1 || code.nodes[node].branch[1] != -2 {
            rar5_huffman_clear(code)
            return false
        }
        code.nodes[node].branch = {symbol, symbol}
    }
    code.symbol_count = count
    return true
}

rar5_huffman_read :: proc(code: ^rar5_huffman_code, reader: ^rar5_bit_reader) -> (int, bool) {
    if code == nil || len(code.nodes) == 0 {
        return -1, false
    }
    node := 0
    for {
        if node < 0 || node >= len(code.nodes) {
            return -1, false
        }
        if code.nodes[node].branch[0] == code.nodes[node].branch[1] {
            return code.nodes[node].branch[0], true
        }
        bit, ok := rar5_bit_read(reader, 1)
        if !ok {
            return -1, false
        }
        node = code.nodes[node].branch[int(bit)]
        if node < 0 {
            return -1, false
        }
    }
}

rar5_parse_tables :: proc(decoder: ^rar5_decoder) -> Error {
    lengths: [RAR5_HUFF_BC]byte
    for index := 0; index < len(lengths); index += 1 {
        value, ok := rar5_bit_read(&decoder.bit, 4)
        if !ok {
            return .Truncated
        }
        if value == 15 {
            run, run_ok := rar5_bit_read(&decoder.bit, 4)
            if !run_ok {
                return .Truncated
            }
            if run == 0 {
                lengths[index] = 15
                index += 1
            } else {
                for step := 0; step < int(run)+2 && index < len(lengths); step += 1 {
                    lengths[index] = 0
                    index += 1
                }
                index -= 1
            }
        } else {
            lengths[index] = byte(value)
        }
    }
    if !rar5_huffman_build(&decoder.bc, lengths[:], len(lengths)) {
        return .Invalid_Archive
    }

    all_lengths: [RAR5_HUFF_TABLE_SIZE]byte
    index := 0
    for index < len(all_lengths) {
        symbol, ok := rar5_huffman_read(&decoder.bc, &decoder.bit)
        if !ok {
            return .Truncated
        }
        if symbol < 16 {
            all_lengths[index] = byte(symbol)
            index += 1
        } else if symbol < 18 {
            if index == 0 {
                return .Invalid_Archive
            }
            repeat_bits, repeat_ok := rar5_bit_read(&decoder.bit, symbol == 16 ? 3 : 7)
            if !repeat_ok {
                return .Truncated
            }
            repeat_count := int(repeat_bits) + (symbol == 16 ? 3 : 11)
            if index+repeat_count > len(all_lengths) {
                return .Invalid_Archive
            }
            for step := 0; step < repeat_count; step += 1 {
                all_lengths[index] = all_lengths[index-1]
                index += 1
            }
        } else if symbol == 18 || symbol == 19 {
            zero_bits, zero_ok := rar5_bit_read(&decoder.bit, symbol == 18 ? 3 : 7)
            if !zero_ok {
                return .Truncated
            }
            zero_count := int(zero_bits) + (symbol == 18 ? 3 : 11)
            if index+zero_count > len(all_lengths) {
                return .Invalid_Archive
            }
            for step := 0; step < zero_count; step += 1 {
                all_lengths[index] = 0
                index += 1
            }
        } else {
            return .Invalid_Archive
        }
    }

    if !rar5_huffman_build(&decoder.main, all_lengths[0:RAR5_HUFF_NC], RAR5_HUFF_NC) ||
       !rar5_huffman_build(&decoder.distance, all_lengths[RAR5_HUFF_NC:RAR5_HUFF_NC+RAR5_HUFF_DC], RAR5_HUFF_DC) ||
       !rar5_huffman_build(&decoder.low_distance, all_lengths[RAR5_HUFF_NC+RAR5_HUFF_DC:RAR5_HUFF_NC+RAR5_HUFF_DC+RAR5_HUFF_LDC], RAR5_HUFF_LDC) ||
       !rar5_huffman_build(&decoder.repeat_length, all_lengths[RAR5_HUFF_NC+RAR5_HUFF_DC+RAR5_HUFF_LDC:], RAR5_HUFF_RC) {
        return .Invalid_Archive
    }
    decoder.tables_ready = true
    return .None
}

rar5_decode_length :: proc(decoder: ^rar5_decoder, code: int) -> (int, Error) {
    if code < 0 || code >= 44 {
        return 0, .Invalid_Archive
    }
    if code < 8 {
        return code + 2, .None
    }
    bits := code/4 - 1
    extra, ok := rar5_bit_read(&decoder.bit, bits)
    if !ok {
        return 0, .Truncated
    }
    return 2 + ((4 | (code & 3)) << u32(bits)) + int(extra), .None
}

rar5_emit :: proc(decoder: ^rar5_decoder, output: []byte, member_start: u64, count: ^int, value: byte) -> Error {
    if decoder.position >= member_start {
        index := decoder.position - member_start
        if index > u64(0x7fffffffffffffff) {
            return .Limit_Exceeded
        }
        if output != nil {
            if index >= u64(len(output)) {
                return .Invalid_Archive
            }
            output[int(index)] = value
        }
        count^ += 1
    }
    decoder.window[decoder.position&decoder.mask] = value
    decoder.position += 1
    return .None
}

rar5_emit_match :: proc(decoder: ^rar5_decoder, output: []byte, member_start: u64, count: ^int, distance: int, length: int) -> Error {
    if distance <= 0 || length < 2 || u64(distance) > decoder.position {
        return .Invalid_Archive
    }
    for step := 0; step < length; step += 1 {
        source := (decoder.position - u64(distance)) & decoder.mask
        if err := rar5_emit(decoder, output, member_start, count, decoder.window[source]); err != .None {
            return err
        }
    }
    return .None
}

rar5_decode_block :: proc(decoder: ^rar5_decoder, payload: []byte, flags: byte, output: []byte, member_start: u64, count: ^int) -> Error {
    decoder.bit = rar5_bit_reader{data = payload, bit = 0, end = len(payload)*8}
    valid_bits := (flags & 7) + 1
    if len(payload) == 0 {
        return .Invalid_Archive
    }
    decoder.bit.end = (len(payload)-1)*8 + int(valid_bits)
    if (flags & 0x80) != 0 {
        if err := rar5_parse_tables(decoder); err != .None {
            return err
        }
    } else if !decoder.tables_ready {
        return .Invalid_Archive
    }

    for decoder.bit.bit < decoder.bit.end {
        symbol, ok := rar5_huffman_read(&decoder.main, &decoder.bit)
        if !ok {
            return .Truncated
        }
        if symbol < 256 {
            if err := rar5_emit(decoder, output, member_start, count, byte(symbol)); err != .None {
                return err
            }
            continue
        }
        if symbol == 256 {
            // Filter records require delayed output and are not safely
            // representable by this package's eager entry API.
            return .Unsupported_Feature
        }
        if symbol == 257 {
            if decoder.last_length != 0 {
                if err := rar5_emit_match(decoder, output, member_start, count, int(decoder.reps[0]), decoder.last_length); err != .None {
                    return err
                }
            }
            continue
        }
        if symbol >= 258 && symbol < 262 {
            cache_index := symbol - 258
            distance := decoder.reps[cache_index]
            for shift := cache_index; shift > 0; shift -= 1 {
                decoder.reps[shift] = decoder.reps[shift-1]
            }
            decoder.reps[0] = distance
            length_symbol, length_ok := rar5_huffman_read(&decoder.repeat_length, &decoder.bit)
            if !length_ok {
                return .Truncated
            }
            length, length_err := rar5_decode_length(decoder, length_symbol)
            if length_err != .None {
                return length_err
            }
            decoder.last_length = length
            if err := rar5_emit_match(decoder, output, member_start, count, int(distance), length); err != .None {
                return err
            }
            continue
        }
        if symbol < 262 {
            return .Invalid_Archive
        }

        length, length_err := rar5_decode_length(decoder, symbol-262)
        if length_err != .None {
            return length_err
        }
        distance_symbol, distance_ok := rar5_huffman_read(&decoder.distance, &decoder.bit)
        if !distance_ok {
            return .Truncated
        }
        if distance_symbol < 0 || distance_symbol >= 64 {
            return .Invalid_Archive
        }
        distance := 1 + distance_symbol
        if distance_symbol >= 4 {
            bits := distance_symbol/2 - 1
            base := (2 | (distance_symbol & 1)) << u32(bits)
            distance = 1 + base
            if bits < 4 {
                extra, extra_ok := rar5_bit_read(&decoder.bit, bits)
                if !extra_ok {
                    return .Truncated
                }
                distance += int(extra)
            } else {
                if bits > 4 {
                    extra, extra_ok := rar5_bit_read(&decoder.bit, bits-4)
                    if !extra_ok {
                        return .Truncated
                    }
                    distance += int(extra) << 4
                }
                low_symbol, low_ok := rar5_huffman_read(&decoder.low_distance, &decoder.bit)
                if !low_ok || low_symbol < 0 || low_symbol >= 16 {
                    return .Invalid_Archive
                }
                distance += low_symbol
            }
        }
        if distance > 0x100 {
            length += 1
            if distance > 0x2000 {
                length += 1
                if distance > 0x40000 {
                    length += 1
                }
            }
        }
        for shift := 3; shift > 0; shift -= 1 {
            decoder.reps[shift] = decoder.reps[shift-1]
        }
        decoder.reps[0] = u32(distance)
        decoder.last_length = length
        if err := rar5_emit_match(decoder, output, member_start, count, distance, length); err != .None {
            return err
        }
    }
    return .None
}

rar5_decoder_init :: proc(decoder: ^rar5_decoder, dictionary_power: int) -> Error {
    if dictionary_power < 0 || dictionary_power > 15 {
        return .Unsupported_Feature
    }
    dictionary_size := RAR5_DICT_BASE << u32(dictionary_power)
    if dictionary_size > RAR5_DICT_MAX || dictionary_size > u64(0x7fffffffffffffff) {
        return .Unsupported_Feature
    }
    window, alloc_error := make([]byte, int(dictionary_size), context.allocator)
    if alloc_error != nil {
        return .Out_Of_Memory
    }
    decoder^ = rar5_decoder{window = window, mask = dictionary_size-1}
    return .None
}

rar5_decoder_free :: proc(decoder: ^rar5_decoder) {
    if decoder == nil {
        return
    }
    delete(decoder.window)
    rar5_huffman_clear(&decoder.bc)
    rar5_huffman_clear(&decoder.main)
    rar5_huffman_clear(&decoder.distance)
    rar5_huffman_clear(&decoder.low_distance)
    rar5_huffman_clear(&decoder.repeat_length)
}

rar5_decode_member :: proc(
    decoder: ^rar5_decoder,
    data: []byte,
    output: []byte,
    member_start: u64,
) -> (int, Error) {
    position := 0
    count := 0
    saw_last := false
    for position < len(data) {
        if position+2 > len(data) {
            return count, .Truncated
        }
        flags := data[position]
        checksum := data[position+1]
        size_bytes := int((flags >> 3) & 7) + 1
        if size_bytes > 3 || position+2+size_bytes > len(data) {
            return count, .Invalid_Archive
        }
        block_size := 0
        for index := 0; index < size_bytes; index += 1 {
            block_size |= int(data[position+2+index]) << u32(8 * index)
        }
        expected_checksum: byte = byte(0x5a) ~ flags
        for index := 0; index < 3; index += 1 {
            size_byte: byte = 0
            if index < size_bytes {
                size_byte = data[position+2+index]
            }
            expected_checksum = expected_checksum ~ size_byte
        }
        if checksum != expected_checksum {
            return count, .Invalid_Archive
        }
        payload_start := position + 2 + size_bytes
        payload_end := payload_start + block_size
        if payload_end < payload_start || payload_end > len(data) {
            return count, .Truncated
        }
        if err := rar5_decode_block(decoder, data[payload_start:payload_end], flags, output, member_start, &count); err != .None {
            return count, err
        }
        position = payload_end
        saw_last = (flags & 0x40) != 0
        if saw_last {
            break
        }
    }
    if !saw_last || position != len(data) {
        return count, .Invalid_Archive
    }
    return count, .None
}

rar5_solid_start :: proc(archive: ^Archive, index: int) -> int {
    start := index
    if (archive.Entries[index].Flags & RAR5_FILE_SOLID) == 0 {
        return start
    }
    for start > 0 && (archive.Entries[start-1].Flags & RAR5_FILE_SOLID) != 0 {
        start -= 1
    }
    return start
}

rar5_feed_stored :: proc(decoder: ^rar5_decoder, data: []byte, output: []byte, member_start: u64) -> (int, Error) {
    count := 0
    for value in data {
        if err := rar5_emit(decoder, output, member_start, &count, value); err != .None {
            return count, err
        }
    }
    return count, .None
}

rar5_entry_dictionary_power :: proc(entry: Entry) -> int {
    return int((u32(entry.Format_Index) >> 10) & 15)
}

rar5_entry_version :: proc(entry: Entry) -> u32 {
    return u32(entry.Format_Index) & 0x3f
}

rar5_entry_is_solid :: proc(entry: Entry) -> bool {
    return (entry.Flags & RAR5_FILE_SOLID) != 0
}

rar5_entry_has_crc :: proc(entry: Entry) -> bool {
    return (entry.Flags & RAR5_FILE_HAS_CRC) != 0
}

rar5_entry_data_range :: proc(archive: ^Archive, entry: Entry) -> ([]byte, Error) {
    if entry.Compressed_Size > u64(len(archive.Data)) || entry.Compressed_Size > u64(0x7fffffffffffffff) {
        return nil, .Limit_Exceeded
    }
    start := int(entry.Data_Offset)
    if !valid_range(archive.Data, start, entry.Compressed_Size) {
        return nil, .Truncated
    }
    return archive.Data[start:start+int(entry.Compressed_Size)], .None
}

rar5_decode_rle_entry :: proc(archive: ^Archive, index: int) -> ([]byte, Error) {
    target := archive.Entries[index]
    if target.Size > u64(0x7fffffffffffffff) {
        return nil, .Limit_Exceeded
    }
    if target.Kind == .Directory {
        result, alloc_error := make([]byte, 0, context.allocator)
        if alloc_error != nil {
            return nil, .Out_Of_Memory
        }
        return result, .None
    }
    if target.Kind != .File || (target.Flags & RAR5_FILE_ENCRYPTED) != 0 {
        return nil, .Unsupported_Feature
    }

    start := rar5_solid_start(archive, index)
    dictionary_power := rar5_entry_dictionary_power(archive.Entries[start])
    decoder: rar5_decoder
    if err := rar5_decoder_init(&decoder, dictionary_power); err != .None {
        return nil, err
    }
    defer rar5_decoder_free(&decoder)

    result, alloc_error := make([]byte, int(target.Size), context.allocator)
    if alloc_error != nil {
        return nil, .Out_Of_Memory
    }
    target_count := 0
    for current_index := start; current_index <= index; current_index += 1 {
        current := archive.Entries[current_index]
        if current.Kind == .Directory {
            continue
        }
        if rar5_entry_version(current) != 0 || rar5_entry_dictionary_power(current) != dictionary_power {
            delete(result)
            return nil, .Unsupported_Feature
        }
        packed, packed_err := rar5_entry_data_range(archive, current)
        if packed_err != .None {
            delete(result)
            return nil, packed_err
        }
        member_start := decoder.position
        member_output: []byte
        temporary_output: []byte
        if current_index == index {
            member_output = result
        } else {
            temporary_output, temporary_error := make([]byte, int(current.Size), context.allocator)
            if temporary_error != nil {
                delete(result)
                return nil, .Out_Of_Memory
            }
            member_output = temporary_output
        }
        count: int
        decode_err: Error
        if current.Method == 0 {
            if current.Compressed_Size != current.Size {
                delete(result)
                return nil, .Invalid_Archive
            }
            count, decode_err = rar5_feed_stored(&decoder, packed, member_output, member_start)
        } else {
            count, decode_err = rar5_decode_member(&decoder, packed, member_output, member_start)
        }
        if decode_err != .None {
            delete(temporary_output)
            delete(result)
            return nil, decode_err
        }
        if u64(count) != current.Size {
            delete(temporary_output)
            delete(result)
            return nil, .Invalid_Archive
        }
        if current_index == index {
            target_count = count
        }
        if rar5_entry_has_crc(current) {
            if crc32(0, member_output) != current.CRC32 {
                delete(temporary_output)
                delete(result)
                return nil, .Checksum_Mismatch
            }
        }
        delete(temporary_output)
    }
    _ = target_count
    return result, .None
}

decode_rar5_entry :: proc(archive: ^Archive, index: int) -> ([]byte, Error) {
    if archive == nil || index < 0 || index >= len(archive.Entries) {
        return nil, .Invalid_State
    }
    return rar5_decode_rle_entry(archive, index)
}
