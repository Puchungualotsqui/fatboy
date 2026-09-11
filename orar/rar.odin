package orar

// RAR 4.x block and compression constants.  RAR 5 has a different block
// format and is rejected as an unsupported feature.
RAR_SIGNATURE_SIZE :: 7
RAR_TYPE_MAIN_HEADER :: byte(0x73)
RAR_TYPE_FILE_HEADER :: byte(0x74)
RAR_TYPE_NEWSUB_HEADER :: byte(0x7a)
RAR_TYPE_END_HEADER :: byte(0x7b)

RAR_MHD_VOLUME :: u16(1 << 0)
RAR_MHD_COMMENT :: u16(1 << 1)
RAR_MHD_LOCK :: u16(1 << 2)
RAR_MHD_SOLID :: u16(1 << 3)
RAR_MHD_PACK_COMMENT :: u16(1 << 4)
RAR_MHD_AV :: u16(1 << 5)
RAR_MHD_PROTECT :: u16(1 << 6)
RAR_MHD_PASSWORD :: u16(1 << 7)
RAR_MHD_FIRSTVOLUME :: u16(1 << 8)
RAR_MHD_ENCRYPTVER :: u16(1 << 9)
RAR_MHD_LONG_BLOCK :: u16(1 << 15)

RAR_LHD_SPLIT_BEFORE :: u16(1 << 0)
RAR_LHD_SPLIT_AFTER :: u16(1 << 1)
RAR_LHD_PASSWORD :: u16(1 << 2)
RAR_LHD_COMMENT :: u16(1 << 3)
RAR_LHD_SOLID :: u16(1 << 4)
RAR_LHD_DIRECTORY :: u16(0x00e0)
RAR_LHD_LARGE :: u16(1 << 8)
RAR_LHD_UNICODE :: u16(1 << 9)
RAR_LHD_SALT :: u16(1 << 10)
RAR_LHD_VERSION :: u16(1 << 11)
RAR_LHD_EXTTIME :: u16(1 << 12)
RAR_LHD_EXTFLAGS :: u16(1 << 13)
RAR_LHD_LONG_BLOCK :: u16(1 << 15)

RAR_METHOD_STORE :: byte(0x30)
RAR_METHOD_FASTEST :: byte(0x31)
RAR_METHOD_FAST :: byte(0x32)
RAR_METHOD_NORMAL :: byte(0x33)
RAR_METHOD_GOOD :: byte(0x34)
RAR_METHOD_BEST :: byte(0x35)

RAR_LZSS_WINDOW_SIZE :: 0x400000
RAR_LZSS_WINDOW_MASK :: RAR_LZSS_WINDOW_SIZE - 1
RAR_LZSS_MAX_TREE_NODES :: 8192

RAR_V2_MAINCODE_SIZE :: 298
RAR_V2_OFFSETCODE_SIZE :: 48
RAR_V2_LENGTHCODE_SIZE :: 28
RAR_V2_TABLE_SIZE :: RAR_V2_MAINCODE_SIZE + RAR_V2_OFFSETCODE_SIZE + RAR_V2_LENGTHCODE_SIZE

RAR_V3_MAINCODE_SIZE :: 299
RAR_V3_OFFSETCODE_SIZE :: 60
RAR_V3_LOWOFFSETCODE_SIZE :: 17
RAR_V3_LENGTHCODE_SIZE :: 28
RAR_V3_TABLE_SIZE :: RAR_V3_MAINCODE_SIZE + RAR_V3_OFFSETCODE_SIZE + RAR_V3_LOWOFFSETCODE_SIZE + RAR_V3_LENGTHCODE_SIZE

RAR_LENGTH_BASES: [28]u32 = {
	0, 1, 2, 3, 4, 5, 6,
	7, 8, 10, 12, 14, 16, 20,
	24, 28, 32, 40, 48, 56, 64,
	80, 96, 112, 128, 160, 192, 224,
}

RAR_LENGTH_BITS: [28]byte = {
	0, 0, 0, 0, 0, 0, 0,
	0, 1, 1, 1, 1, 2, 2,
	2, 2, 3, 3, 3, 3, 4,
	4, 4, 4, 5, 5, 5, 5,
}

RAR_V2_OFFSET_BASES: [48]u32 = {
	0, 1, 2, 3, 4, 6, 8, 12,
	16, 24, 32, 48, 64, 96, 128, 192,
	256, 384, 512, 768, 1024, 1536, 2048, 3072,
	4096, 6144, 8192, 12288, 16384, 24576, 32768, 49152,
	65536, 98304, 131072, 196608, 262144, 327680, 393216, 458752,
	524288, 589824, 655360, 720896, 786432, 851968, 917504, 983040,
}

RAR_V2_OFFSET_BITS: [48]byte = {
	0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4,
	5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10,
	11, 11, 12, 12, 13, 13, 14, 14, 15, 15, 16, 16,
	16, 16, 16, 16, 16, 16, 16, 16,
	16, 16, 16, 16,
}

RAR_V3_OFFSET_BASES: [60]u32 = {
	0, 1, 2, 3, 4, 6, 8, 12,
	16, 24, 32, 48, 64, 96, 128, 192,
	256, 384, 512, 768, 1024, 1536, 2048, 3072,
	4096, 6144, 8192, 12288, 16384, 24576, 32768, 49152,
	65536, 98304, 131072, 196608, 262144, 327680, 393216, 458752,
	524288, 589824, 655360, 720896, 786432, 851968, 917504, 983040,
	1048576, 1310720, 1572864, 1835008, 2097152, 2359296, 2621440, 2883584,
	3145728, 3407872, 3670016, 3932160,
}

RAR_V3_OFFSET_BITS: [60]byte = {
	0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4,
	5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10,
	11, 11, 12, 12, 13, 13, 14, 14, 15, 15, 16, 16,
	16, 16, 16, 16, 16, 16, 16, 16,
	16, 16, 16, 16,
	18, 18, 18, 18, 18, 18, 18, 18,
	18, 18, 18, 18,
}

RAR_SHORT_BASES: [8]u32 = {0, 4, 8, 16, 32, 64, 128, 192}
RAR_SHORT_BITS: [8]byte = {2, 2, 3, 4, 5, 6, 6, 6}

rar_huffman_node :: struct {
	branches: [2]int,
}

rar_huffman_code :: struct {
	nodes: [dynamic]rar_huffman_node,
}

rar_bit_reader :: struct {
	data:      []byte,
	offset:    int,
	end:       int,
	bits:      u64,
	available: int,
}

rar_v2_decoder :: struct {
	maincode:   rar_huffman_code,
	offsetcode: rar_huffman_code,
	lengthcode: rar_huffman_code,
	lengthtable: [RAR_V2_TABLE_SIZE]byte,
	lastoffset: u32,
	lastlength: u32,
	oldoffset: [4]u32,
	oldoffsetindex: u32,
	channel: byte,
	numchannels: byte,
}

rar_v3_decoder :: struct {
	maincode:      rar_huffman_code,
	offsetcode:    rar_huffman_code,
	lowoffsetcode: rar_huffman_code,
	lengthcode:    rar_huffman_code,
	lengthtable:   [RAR_V3_TABLE_SIZE]byte,
	lastlength:    u32,
	lastoffset:    u32,
	oldoffset:     [4]u32,
	lastlowoffset: u32,
	numlowoffsetrepeats: u32,
}

rar_decoder :: struct {
	version:        int,
	br:             rar_bit_reader,
	window:         []byte,
	position:       u64,
	start_new_table: bool,
	v2:             rar_v2_decoder,
	v3:             rar_v3_decoder,
}

rar_output_sink :: struct {
	data:       []byte,
	start:      u64,
	end:        u64,
	crc:        u32,
	crc_enabled: bool,
	count:      u64,
}

// parse_rar eagerly validates every RAR4 block and records enough offsets for
// whole-entry extraction.  The compressed bitstream itself is decoded lazily by
// decode_rar_entry because solid archives require replaying prior members.
parse_rar :: proc(archive: ^Archive) -> Error {
	if archive == nil {
		return .Invalid_State
	}
	data := archive.Data
	if len(data) < RAR_SIGNATURE_SIZE {
		return .Truncated
	}
	if data[0] != 'R' || data[1] != 'a' || data[2] != 'r' || data[3] != '!' ||
		data[4] != 0x1a || data[5] != 0x07 {
		return .Unsupported_Format
	}
	if data[6] != 0x00 {
		// RAR5 uses the same six-byte prefix but a different seventh byte and
		// block format.  Do not attempt to interpret it as RAR4.
		return .Unsupported_Feature
	}

	position := RAR_SIGNATURE_SIZE
	saw_main := false
	saw_end := false
	main_flags: u16 = 0

	for position < len(data) {
		if position+7 > len(data) {
			return .Truncated
		}

		stored_crc, crc_ok := read_u16le(data, position)
		header_type := data[position+2]
		flags, flags_ok := read_u16le(data, position+3)
		header_size, size_ok := read_u16le(data, position+5)
		if !crc_ok || !flags_ok || !size_ok {
			return .Truncated
		}
		if header_size < 7 {
			return .Invalid_Archive
		}

		header_end_u := u64(position) + u64(header_size)
		if header_end_u < u64(position) || header_end_u > u64(len(data)) {
			return .Truncated
		}
		header_end := int(header_end_u)
		has_data_size := header_type == RAR_TYPE_FILE_HEADER || (flags & RAR_LHD_LONG_BLOCK) != 0
		data_size: u64 = 0
		if has_data_size {
			if header_size < 11 {
				return .Invalid_Archive
			}
			packed_low, packed_ok := read_u32le(data, position+7)
			if !packed_ok {
				return .Truncated
			}
			data_size = u64(packed_low)
		}

		// RAR stores the low 16 bits of the CRC-32 of the complete header,
		// excluding the two-byte CRC field itself.
		calculated_crc := crc32(0, data[position+2:header_end]) & 0xffff
		if calculated_crc != u32(stored_crc) {
			return .Invalid_Archive
		}

		data_end_u := header_end_u + data_size
		if data_end_u < header_end_u || data_end_u > u64(len(data)) {
			return .Truncated
		}
		data_end := int(data_end_u)

		switch header_type {
		case RAR_TYPE_MAIN_HEADER:
			if position != RAR_SIGNATURE_SIZE || saw_main || header_size < 13 {
				return .Invalid_Archive
			}
			if (flags & (RAR_MHD_VOLUME | RAR_MHD_PASSWORD | RAR_MHD_ENCRYPTVER)) != 0 {
				return .Unsupported_Feature
			}
			main_flags = flags
			saw_main = true

		case RAR_TYPE_FILE_HEADER:
			if !saw_main || saw_end {
				return .Invalid_Archive
			}
			entry, err := rar_parse_file_header(data, position, header_end, data_size, flags, main_flags)
			if err != .None {
				return err
			}
			// LHD_LARGE extends the packed size with a high 32-bit word
			// stored in the file header, so recalculate the block end after
			// parsing the complete entry header.
			data_size = entry.Compressed_Size
			data_end_u = header_end_u + data_size
			if data_end_u < header_end_u || data_end_u > u64(len(data)) {
				return .Truncated
			}
			data_end = int(data_end_u)
			append(&archive.Entries, entry)

		case RAR_TYPE_END_HEADER:
			if !saw_main || saw_end {
				return .Invalid_Archive
			}
			saw_end = true

		case RAR_TYPE_NEWSUB_HEADER:
			if !saw_main || saw_end {
				return .Invalid_Archive
			}
			// New-sub headers are comments and recovery/subheaders.  They can
			// be skipped safely because their declared data range was checked.

		case:
			if !saw_main || saw_end {
				return .Invalid_Archive
			}
			// Unknown optional RAR4 blocks are skipped only when their complete
			// header and data ranges are valid.  They cannot create entries.
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

rar_parse_file_header :: proc(
	data: []byte,
	position: int,
	header_end: int,
	packed_size: u64,
	flags: u16,
	main_flags: u16,
) -> (Entry, Error) {
	result := Entry{}
	full_packed_size := packed_size
	// The fixed file fields follow the common 11-byte block prefix.  Check
	// against header_end as well as the backing slice so a short header cannot
	// consume bytes belonging to the packed data or the next block.
	if header_end < position+32 || !valid_range(data, position+11, 21) {
		return result, .Truncated
	}

	fixed := position + 11
	uncompressed_low, size_ok := read_u32le(data, fixed)
	entry_crc, crc_ok := read_u32le(data, fixed+5)
	dos_date, date_ok := read_u32le(data, fixed+9)
	name_length, name_length_ok := read_u16le(data, fixed+15)
	attributes, attributes_ok := read_u32le(data, fixed+17)
	if !size_ok || !crc_ok || !date_ok || !name_length_ok || !attributes_ok {
		return result, .Truncated
	}

	version := data[fixed+13]
	method := data[fixed+14]
	uncompressed_size := u64(uncompressed_low)
	name_start := fixed + 21
	if (flags & RAR_LHD_LARGE) != 0 {
		if name_start+8 > header_end || !valid_range(data, name_start, 8) {
			return result, .Truncated
		}
		packed_high, packed_high_ok := read_u32le(data, name_start)
		uncompressed_high, uncompressed_high_ok := read_u32le(data, name_start+4)
		if !packed_high_ok || !uncompressed_high_ok {
			return result, .Truncated
		}
		full_packed_size |= u64(packed_high) << 32
		uncompressed_size |= u64(uncompressed_high) << 32
		name_start += 8
	}

	name_end_u := u64(name_start) + u64(name_length)
	if name_end_u < u64(name_start) || name_end_u > u64(header_end) {
		return result, .Truncated
	}
	name_end := int(name_end_u)
	name_bytes := data[name_start:name_end]
	if (flags & RAR_LHD_SALT) != 0 {
		if name_end+8 > header_end {
			return result, .Truncated
		}
	}

	name, raw_name := rar_name_from_bytes(name_bytes, (flags & RAR_LHD_UNICODE) != 0)
	kind := Entry_Kind.File
	if (flags & RAR_LHD_DIRECTORY) == RAR_LHD_DIRECTORY || (attributes & 0x10) != 0 {
		kind = .Directory
	} else if len(name) > 0 && name[len(name)-1] == '/' {
		kind = .Directory
	}

	stored_flags := flags
	// RAR 1.5/2.0 uses the main-header solid bit instead of the per-file
	// solid bit.  Mirroring it into Entry.Flags keeps replay self-contained.
	if version < 20 && (main_flags & RAR_MHD_SOLID) != 0 {
		stored_flags |= RAR_LHD_SOLID
	}

	result = Entry{
		Name = name,
		Raw_Name = raw_name,
		Kind = kind,
		Size = uncompressed_size,
		Compressed_Size = full_packed_size,
		Offset = i64(position),
		Filetime = dos_datetime_to_filetime(dos_date),
		Method = u16(method),
		Flags = stored_flags,
		CRC32 = entry_crc,
		Data_Offset = i64(header_end),
		// RAR's version byte is the format-specific index.  Method remains
		// the public compression method, as it does for the other backends.
		Format_Index = int(version),
	}
	return result, .None
}

rar_name_from_bytes :: proc(value: []byte, unicode: bool) -> (string, string) {
	if !unicode {
		return archive_name_from_bytes(value, false)
	}

	base_end := 0
	for base_end < len(value) && value[base_end] != 0 {
		base_end += 1
	}
	if base_end == len(value) || base_end+1 >= len(value) {
		return archive_name_from_bytes(value[:base_end], false)
	}

	decoded, ok := rar_decode_unicode_name(value, base_end)
	if !ok {
		return archive_name_from_bytes(value[:base_end], false)
	}

	decoded_name := normalize_name(string(decoded[:]))
	delete(decoded)
	unused, raw_name := archive_name_from_bytes(value, true)
	delete(unused)
	return decoded_name, raw_name
}

// RAR's Unicode name field is an ANSI name followed by a compact stream of
// two-bit commands.  This is the encoding used by RAR4, not UTF-16.
rar_decode_unicode_name :: proc(value: []byte, base_end: int) -> ([dynamic]byte, bool) {
	output: [dynamic]byte
	input := base_end + 1
	if input >= len(value) {
		return output, false
	}
	highbyte := value[input]
	input += 1
	flagbyte: byte = 0
	flagbits := 0
	source := 0

	for input < len(value) {
		if flagbits == 0 {
			flagbyte = value[input]
			input += 1
			flagbits = 8
		}
		flagbits -= 2
		command := (flagbyte >> u8(flagbits)) & 3
		switch command {
		case 0:
			if input >= len(value) || source >= base_end {
				delete(output)
				return nil, false
			}
			append_utf8(&output, u32(value[input]))
			input += 1
			source += 1
		case 1:
			if input >= len(value) || source >= base_end {
				delete(output)
				return nil, false
			}
			append_utf8(&output, (u32(highbyte)<<8)|u32(value[input]))
			input += 1
			source += 1
		case 2:
			if input+1 >= len(value) || source >= base_end {
				delete(output)
				return nil, false
			}
			append_utf8(&output, (u32(value[input+1])<<8)|u32(value[input]))
			input += 2
			source += 1
		case 3:
			if input >= len(value) {
				delete(output)
				return nil, false
			}
			count_byte := value[input]
			input += 1
			count := int(count_byte & 0x7f) + 2
			correction: byte = 0
			if (count_byte & 0x80) != 0 {
				if input >= len(value) {
					delete(output)
					return nil, false
				}
				correction = value[input]
				input += 1
			}
			if source+count > base_end {
				delete(output)
				return nil, false
			}
			for step := 0; step < count; step += 1 {
				value_byte := value[source+step]
				if (count_byte & 0x80) != 0 {
					value_byte += correction
				}
				append_utf8(&output, (u32(highbyte)<<8)|u32(value_byte))
			}
			source += count
		}
	}
	if source != base_end {
		delete(output)
		return nil, false
	}
	return output, true
}

rar_entry_version :: proc(entry: Entry) -> (int, Error) {
	version := entry.Format_Index
	if version == 20 || version == 26 || version == 29 || version == 36 {
		return version, .None
	}
	return 0, .Unsupported_Feature
}

rar_method_supported :: proc(method: u16) -> bool {
	switch byte(method) {
	case RAR_METHOD_FASTEST, RAR_METHOD_FAST, RAR_METHOD_NORMAL, RAR_METHOD_GOOD, RAR_METHOD_BEST:
		return true
	}
	return false
}

rar_entry_unsupported :: proc(entry: Entry) -> Error {
	if (entry.Flags & (RAR_LHD_PASSWORD | RAR_LHD_SALT | RAR_LHD_SPLIT_BEFORE | RAR_LHD_SPLIT_AFTER)) != 0 {
		return .Unsupported_Feature
	}
	if entry.Method == u16(RAR_METHOD_STORE) {
		// Stored members do not use a compression-version decoder.  Old RAR
		// writers may use version bytes that are not meaningful to v2/v3 LZSS.
		return .None
	}
	if !rar_method_supported(entry.Method) {
		return .Unsupported_Feature
	}
	_, err := rar_entry_version(entry)
	return err
}

rar_entry_is_solid :: proc(entry: Entry) -> bool {
	return (entry.Flags & RAR_LHD_SOLID) != 0
}

rar_solid_start :: proc(archive: ^Archive, index: int) -> int {
	start := index
	if !rar_entry_is_solid(archive.Entries[index]) {
		return start
	}
	for start > 0 {
		previous := archive.Entries[start-1]
		if !rar_entry_is_solid(previous) {
			break
		}
		// Stored members reset unarr's decompressor state even when their
		// payload is empty; they cannot be part of the preceding LZSS stream.
		if previous.Method == u16(RAR_METHOD_STORE) {
			break
		}
		start -= 1
	}
	return start
}

// decode_rar_entry always allocates an independent complete output buffer.
// Solid members are decoded from the first member of their contiguous solid
// run so that dictionary and Huffman state are reconstructed deterministically.
decode_rar_entry :: proc(archive: ^Archive, index: int) -> ([]byte, Error) {
	if archive == nil || index < 0 || index >= len(archive.Entries) {
		return nil, .Invalid_State
	}
	entry := archive.Entries[index]

	// Check flags before handling directories: an encrypted or split directory
	// must not appear successfully extractable just because it has no payload.
	if err := rar_entry_unsupported(entry); err != .None {
		return nil, err
	}
	if entry.Kind == .Directory {
		if entry.Size != 0 || entry.Compressed_Size != 0 {
			return nil, .Unsupported_Feature
		}
		result, alloc_error := make([]byte, 0, context.allocator)
		if alloc_error != nil {
			return nil, .Out_Of_Memory
		}
		return result, .None
	}
	if entry.Kind != .File && entry.Kind != .Other {
		return nil, .Unsupported_Feature
	}
	if entry.Size > 0x7fffffffffffffff || entry.Compressed_Size > u64(len(archive.Data)) {
		return nil, .Limit_Exceeded
	}
	data_start := int(entry.Data_Offset)
	if !valid_range(archive.Data, data_start, entry.Compressed_Size) {
		return nil, .Truncated
	}

	if entry.Method == u16(RAR_METHOD_STORE) {
		if entry.Compressed_Size != entry.Size {
			return nil, .Invalid_Archive
		}
		result, alloc_error := make([]byte, int(entry.Size), context.allocator)
		if alloc_error != nil {
			return nil, .Out_Of_Memory
		}
		copy(result, archive.Data[data_start:data_start+int(entry.Compressed_Size)])
		if crc32(0, result) != entry.CRC32 {
			delete(result)
			return nil, .Checksum_Mismatch
		}
		return result, .None
	}

	return rar_decode_compressed_entry(archive, index)
}

rar_decode_compressed_entry :: proc(archive: ^Archive, index: int) -> ([]byte, Error) {
	target := archive.Entries[index]
	start := rar_solid_start(archive, index)

	// Find the first actual compressed member.  A zero-sized directory or
	// stored record can be present at the beginning of a solid run and must not
	// be mistaken for the version-bearing LZSS stream.
	first_compressed := -1
	version: int = 0
	for current_index := start; current_index <= index; current_index += 1 {
		current := archive.Entries[current_index]
		if err := rar_entry_unsupported(current); err != .None {
			return nil, err
		}
		if current.Kind == .Directory {
			if current.Size != 0 || current.Compressed_Size != 0 {
				return nil, .Unsupported_Feature
			}
			continue
		}
		if current.Kind != .File && current.Kind != .Other {
			return nil, .Unsupported_Feature
		}
		if current.Size > 0x7fffffffffffffff || current.Compressed_Size > u64(len(archive.Data)) {
			return nil, .Limit_Exceeded
		}
		current_start := int(current.Data_Offset)
		if !valid_range(archive.Data, current_start, current.Compressed_Size) {
			return nil, .Truncated
		}
		if current.Method == u16(RAR_METHOD_STORE) {
			if current.Size != 0 || current.Compressed_Size != 0 {
				return nil, .Unsupported_Feature
			}
			continue
		}
		current_version, current_version_err := rar_entry_version(current)
		if current_version_err != .None {
			return nil, current_version_err
		}
		if first_compressed < 0 {
			first_compressed = current_index
			version = current_version
		} else if rar_normalize_rar_version(current_version) != rar_normalize_rar_version(version) {
			return nil, .Unsupported_Feature
		}
	}
	if first_compressed < 0 {
		return nil, .Invalid_Archive
	}

	decoder: rar_decoder
	if err := rar_decoder_init(&decoder, version); err != .None {
		return nil, err
	}

	result, alloc_error := make([]byte, int(target.Size), context.allocator)
	if alloc_error != nil {
		rar_decoder_free(&decoder)
		return nil, .Out_Of_Memory
	}

	logical_start: u64 = 0
	decoder_started := false
	for current_index := start; current_index <= index; current_index += 1 {
		current := archive.Entries[current_index]
		if current.Kind == .Directory {
			// The scan above already checked the size.  Directories contribute no
			// bytes to the solid dictionary.
			continue
		}
		if current.Kind != .File && current.Kind != .Other {
			delete(result)
			rar_decoder_free(&decoder)
			return nil, .Unsupported_Feature
		}
		if current.Method == u16(RAR_METHOD_STORE) {
			// An empty stored record is metadata only.  A non-empty one was
			// rejected during the validation scan.
			continue
		}

		current_start := int(current.Data_Offset)
		rar_begin_payload(&decoder, archive.Data, current_start, int(current.Compressed_Size), decoder_started)
		decoder_started = true
		logical_end := logical_start + current.Size
		if logical_end < logical_start {
			delete(result)
			rar_decoder_free(&decoder)
			return nil, .Limit_Exceeded
		}

		is_target := current_index == index
		sink := rar_output_sink{
			start = logical_start,
			end = logical_end,
			crc = 0,
			crc_enabled = true,
		}
		if is_target {
			sink.data = result
		}

		// A match may have crossed a previous member boundary.  Its bytes are
		// already in the LZSS window and must be assigned to this member before
		// reading another compressed command.
		if decoder.position > logical_start {
			pending_end := decoder.position
			if pending_end > logical_end {
				pending_end = logical_end
			}
			if pending_end > logical_start {
				rar_copy_window_to_sink(&decoder, &sink, logical_start, pending_end)
			}
		}
		if decoder.position < logical_end {
			if err := rar_decode_until(&decoder, logical_end, &sink); err != .None {
				delete(result)
				rar_decoder_free(&decoder)
				return nil, err
			}
		}
		if sink.count != current.Size {
			delete(result)
			rar_decoder_free(&decoder)
			return nil, .Invalid_Archive
		}
		if sink.crc != current.CRC32 {
			delete(result)
			rar_decoder_free(&decoder)
			return nil, .Checksum_Mismatch
		}
		logical_start = logical_end
	}

	rar_decoder_free(&decoder)
	return result, .None
}

rar_normalize_rar_version :: proc(version: int) -> int {
	switch version {
	case 20, 26:
		return 2
	case 29, 36:
		return 3
	}
	return 0
}

rar_decoder_init :: proc(decoder: ^rar_decoder, version: int) -> Error {
	normalized := rar_normalize_rar_version(version)
	if normalized == 0 {
		return .Unsupported_Feature
	}
	decoder^ = rar_decoder{
		version = normalized,
		start_new_table = true,
	}
	window, alloc_error := make([]byte, RAR_LZSS_WINDOW_SIZE, context.allocator)
	if alloc_error != nil {
		return .Out_Of_Memory
	}
	decoder.window = window
	return .None
}

rar_decoder_free :: proc(decoder: ^rar_decoder) {
	if decoder == nil {
		return
	}
	rar_huffman_clear(&decoder.v2.maincode)
	rar_huffman_clear(&decoder.v2.offsetcode)
	rar_huffman_clear(&decoder.v2.lengthcode)
	rar_huffman_clear(&decoder.v3.maincode)
	rar_huffman_clear(&decoder.v3.offsetcode)
	rar_huffman_clear(&decoder.v3.lowoffsetcode)
	rar_huffman_clear(&decoder.v3.lengthcode)
	delete(decoder.window)
	decoder.window = nil
}

rar_begin_payload :: proc(decoder: ^rar_decoder, data: []byte, start: int, size: int, continuation: bool) {
	end := start + size
	if continuation {
		// Match unarr's br_clear_leftover_bits: discard partial bits while
		// retaining complete buffered bytes from the preceding solid block.
		decoder.br.available &= ~int(7)
		if decoder.br.available == 0 {
			decoder.br.bits = 0
		}
		decoder.br.data = data
		decoder.br.offset = start
		decoder.br.end = end
	} else {
		decoder.br = rar_bit_reader{data = data, offset = start, end = end}
		decoder.position = 0
		decoder.start_new_table = true
	}
}

rar_bit_fill :: proc(reader: ^rar_bit_reader, bits: int) -> bool {
	if bits < 0 || bits > 64 {
		return false
	}
	if reader.available >= bits {
		return true
	}
	count := (64 - reader.available) / 8
	if count > reader.end-reader.offset {
		count = reader.end - reader.offset
	}
	if count <= 0 || reader.available+count*8 < bits {
		return false
	}
	for index := 0; index < count; index += 1 {
		reader.bits = (reader.bits << 8) | u64(reader.data[reader.offset])
		reader.offset += 1
	}
	reader.available += count * 8
	return reader.available >= bits
}

rar_bit_read :: proc(reader: ^rar_bit_reader, bits: int) -> (u64, bool) {
	if bits < 0 || bits > 63 {
		return 0, false
	}
	if bits == 0 {
		return 0, true
	}

	// The bit buffer is kept in big-endian stream order: unread bits occupy
	// the low `available` bits of `reader.bits`.  Consume the current buffer
	// before refilling so requests which straddle a 64-bit buffer boundary do
	// not reject otherwise valid input.
	result: u64 = 0
	remaining := bits
	for remaining > 0 {
		if reader.available == 0 {
			reader.bits = 0
			if !rar_bit_fill(reader, 1) {
				return 0, false
			}
		}
		take := remaining
		if take > reader.available {
			take = reader.available
		}
		shift := reader.available - take
		mask := (u64(1) << u64(take)) - 1
		part := (reader.bits >> u64(shift)) & mask
		result = (result << u64(take)) | part
		reader.available -= take
		remaining -= take
		if reader.available == 0 {
			reader.bits = 0
		}
	}
	return result, true
}

rar_bit_required :: proc(reader: ^rar_bit_reader, bits: int) -> (u64, Error) {
	value, ok := rar_bit_read(reader, bits)
	if !ok {
		return 0, .Truncated
	}
	return value, .None
}

rar_huffman_clear :: proc(code: ^rar_huffman_code) {
	if code == nil {
		return
	}
	delete(code.nodes)
	code.nodes = nil
}

rar_huffman_new_node :: proc(code: ^rar_huffman_code) -> bool {
	if len(code.nodes) >= RAR_LZSS_MAX_TREE_NODES {
		return false
	}
	node := rar_huffman_node{}
	node.branches[0] = -1
	node.branches[1] = -2
	append(&code.nodes, node)
	return true
}

rar_huffman_build :: proc(code: ^rar_huffman_code, lengths: []byte, symbol_count: int) -> bool {
	rar_huffman_clear(code)
	if symbol_count <= 0 || symbol_count > len(lengths) || !rar_huffman_new_node(code) {
		return false
	}

	symbols_left := symbol_count
	code_bits := 0
	for length := 1; length <= 15; length += 1 {
		for symbol := 0; symbol < symbol_count; symbol += 1 {
			if int(lengths[symbol]) != length {
				continue
			}
			current := 0
			for bit_position := length - 1; bit_position >= 0; bit_position -= 1 {
				if current < 0 || current >= len(code.nodes) {
					return false
				}
				if code.nodes[current].branches[0] == code.nodes[current].branches[1] {
					return false
				}
				bit := (code_bits >> u32(bit_position)) & 1
				child := code.nodes[current].branches[bit]
				if child < 0 {
					if !rar_huffman_new_node(code) {
						return false
					}
					child = len(code.nodes) - 1
					code.nodes[current].branches[bit] = child
				}
				current = child
			}
			if current < 0 || current >= len(code.nodes) ||
				code.nodes[current].branches[0] != -1 || code.nodes[current].branches[1] != -2 {
				return false
			}
			code.nodes[current].branches[0] = symbol
			code.nodes[current].branches[1] = symbol
			symbols_left -= 1
			if symbols_left <= 0 {
				return true
			}
			code_bits += 1
		}
		code_bits <<= 1
	}
	return true
}

rar_huffman_read :: proc(code: ^rar_huffman_code, reader: ^rar_bit_reader) -> (int, Error) {
	if code == nil || len(code.nodes) == 0 {
		return -1, .Invalid_Archive
	}
	node := 0
	for {
		if node < 0 || node >= len(code.nodes) {
			return -1, .Invalid_Archive
		}
		if code.nodes[node].branches[0] == code.nodes[node].branches[1] {
			return code.nodes[node].branches[0], .None
		}
		bit, ok := rar_bit_read(reader, 1)
		if !ok {
			return -1, .Truncated
		}
		child := code.nodes[node].branches[int(bit)]
		if child < 0 {
			return -1, .Invalid_Archive
		}
		node = child
	}
}

rar_read_symbol :: proc(decoder: ^rar_decoder, code: ^rar_huffman_code) -> (int, Error) {
	return rar_huffman_read(code, &decoder.br)
}

rar_parse_codes :: proc(decoder: ^rar_decoder) -> Error {
	if decoder.version == 2 {
		return rar_parse_codes_v2(decoder)
	}
	return rar_parse_codes_v3(decoder)
}

rar_parse_codes_v2 :: proc(decoder: ^rar_decoder) -> Error {
	state := &decoder.v2
	rar_huffman_clear(&state.maincode)
	rar_huffman_clear(&state.offsetcode)
	rar_huffman_clear(&state.lengthcode)

	audio_value, audio_err := rar_bit_required(&decoder.br, 1)
	if audio_err != .None {
		return audio_err
	}
	new_table, table_err := rar_bit_required(&decoder.br, 1)
	if table_err != .None {
		return table_err
	}
	if audio_value != 0 {
		return .Unsupported_Feature
	}
	if new_table == 0 {
		for index := 0; index < len(state.lengthtable); index += 1 {
			state.lengthtable[index] = 0
		}
	}

	prelengths: [19]byte
	for index := 0; index < len(prelengths); index += 1 {
		value, err := rar_bit_required(&decoder.br, 4)
		if err != .None {
			return err
		}
		prelengths[index] = byte(value)
	}
	precode: rar_huffman_code
	if !rar_huffman_build(&precode, prelengths[:], len(prelengths)) {
		rar_huffman_clear(&precode)
		return .Invalid_Archive
	}

	count := RAR_V2_TABLE_SIZE
	for index := 0; index < count; {
		value, err := rar_read_symbol(decoder, &precode)
		if err != .None {
			rar_huffman_clear(&precode)
			return err
		}
		if value < 16 {
			state.lengthtable[index] = (state.lengthtable[index] + byte(value)) & 0x0f
			index += 1
		} else if value == 16 {
			if index == 0 {
				rar_huffman_clear(&precode)
				return .Invalid_Archive
			}
			repeat_bits, repeat_err := rar_bit_required(&decoder.br, 2)
			if repeat_err != .None {
				rar_huffman_clear(&precode)
				return repeat_err
			}
			repeat := int(repeat_bits) + 3
			for step := 0; step < repeat && index < count; step += 1 {
				state.lengthtable[index] = state.lengthtable[index-1]
				index += 1
			}
		} else {
			zero_count: int
			if value == 17 {
				zero_bits, zero_err := rar_bit_required(&decoder.br, 3)
				if zero_err != .None {
					rar_huffman_clear(&precode)
					return zero_err
				}
				zero_count = int(zero_bits) + 3
			} else if value == 18 {
				zero_bits, zero_err := rar_bit_required(&decoder.br, 7)
				if zero_err != .None {
					rar_huffman_clear(&precode)
					return zero_err
				}
				zero_count = int(zero_bits) + 11
			} else {
				rar_huffman_clear(&precode)
				return .Invalid_Archive
			}
			for step := 0; step < zero_count && index < count; step += 1 {
				state.lengthtable[index] = 0
				index += 1
			}
		}
	}
	rar_huffman_clear(&precode)

	if !rar_huffman_build(&state.maincode, state.lengthtable[0:RAR_V2_MAINCODE_SIZE], RAR_V2_MAINCODE_SIZE) ||
		!rar_huffman_build(&state.offsetcode, state.lengthtable[RAR_V2_MAINCODE_SIZE:RAR_V2_MAINCODE_SIZE+RAR_V2_OFFSETCODE_SIZE], RAR_V2_OFFSETCODE_SIZE) ||
		!rar_huffman_build(&state.lengthcode, state.lengthtable[RAR_V2_MAINCODE_SIZE+RAR_V2_OFFSETCODE_SIZE:], RAR_V2_LENGTHCODE_SIZE) {
		return .Invalid_Archive
	}
	decoder.start_new_table = false
	return .None
}

rar_parse_codes_v3 :: proc(decoder: ^rar_decoder) -> Error {
	state := &decoder.v3
	rar_huffman_clear(&state.maincode)
	rar_huffman_clear(&state.offsetcode)
	rar_huffman_clear(&state.lowoffsetcode)
	rar_huffman_clear(&state.lengthcode)
	decoder.br.available &= ~int(7)
	if decoder.br.available == 0 {
		decoder.br.bits = 0
	}

	ppmd, ppmd_err := rar_bit_required(&decoder.br, 1)
	if ppmd_err != .None {
		return ppmd_err
	}
	if ppmd != 0 {
		return .Unsupported_Feature
	}
	table_flag, table_err := rar_bit_required(&decoder.br, 1)
	if table_err != .None {
		return table_err
	}
	if table_flag == 0 {
		for index := 0; index < len(state.lengthtable); index += 1 {
			state.lengthtable[index] = 0
		}
	}

	bitlengths: [20]byte
	for index := 0; index < len(bitlengths); index += 1 {
		value, err := rar_bit_required(&decoder.br, 4)
		if err != .None {
			return err
		}
		bitlengths[index] = byte(value)
		if value == 15 {
			zero_bits, zero_err := rar_bit_required(&decoder.br, 4)
			if zero_err != .None {
				return zero_err
			}
			if zero_bits != 0 {
				zero_count := int(zero_bits) + 2
				for step := 0; step < zero_count && index < len(bitlengths); step += 1 {
					bitlengths[index] = 0
					index += 1
				}
				index -= 1
			}
		}
	}

	precode: rar_huffman_code
	if !rar_huffman_build(&precode, bitlengths[:], len(bitlengths)) {
		rar_huffman_clear(&precode)
		return .Invalid_Archive
	}
	for index := 0; index < RAR_V3_TABLE_SIZE; {
		value, err := rar_read_symbol(decoder, &precode)
		if err != .None {
			rar_huffman_clear(&precode)
			return err
		}
		if value < 16 {
			state.lengthtable[index] = (state.lengthtable[index] + byte(value)) & 0x0f
			index += 1
		} else if value < 18 {
			if index == 0 {
				rar_huffman_clear(&precode)
				return .Invalid_Archive
			}
			repeat_count: int
			if value == 16 {
				repeat_bits, repeat_err := rar_bit_required(&decoder.br, 3)
				if repeat_err != .None {
					rar_huffman_clear(&precode)
					return repeat_err
				}
				repeat_count = int(repeat_bits) + 3
			} else {
				repeat_bits, repeat_err := rar_bit_required(&decoder.br, 7)
				if repeat_err != .None {
					rar_huffman_clear(&precode)
					return repeat_err
				}
				repeat_count = int(repeat_bits) + 11
			}
			for step := 0; step < repeat_count && index < RAR_V3_TABLE_SIZE; step += 1 {
				state.lengthtable[index] = state.lengthtable[index-1]
				index += 1
			}
		} else {
			zero_count: int
			if value == 18 {
				zero_bits, zero_err := rar_bit_required(&decoder.br, 3)
				if zero_err != .None {
					rar_huffman_clear(&precode)
					return zero_err
				}
				zero_count = int(zero_bits) + 3
			} else if value == 19 {
				zero_bits, zero_err := rar_bit_required(&decoder.br, 7)
				if zero_err != .None {
					rar_huffman_clear(&precode)
					return zero_err
				}
				zero_count = int(zero_bits) + 11
			} else {
				rar_huffman_clear(&precode)
				return .Invalid_Archive
			}
			for step := 0; step < zero_count && index < RAR_V3_TABLE_SIZE; step += 1 {
				state.lengthtable[index] = 0
				index += 1
			}
		}
	}
	rar_huffman_clear(&precode)

	if !rar_huffman_build(&state.maincode, state.lengthtable[0:RAR_V3_MAINCODE_SIZE], RAR_V3_MAINCODE_SIZE) ||
		!rar_huffman_build(&state.offsetcode, state.lengthtable[RAR_V3_MAINCODE_SIZE:RAR_V3_MAINCODE_SIZE+RAR_V3_OFFSETCODE_SIZE], RAR_V3_OFFSETCODE_SIZE) ||
		!rar_huffman_build(&state.lowoffsetcode, state.lengthtable[RAR_V3_MAINCODE_SIZE+RAR_V3_OFFSETCODE_SIZE:RAR_V3_MAINCODE_SIZE+RAR_V3_OFFSETCODE_SIZE+RAR_V3_LOWOFFSETCODE_SIZE], RAR_V3_LOWOFFSETCODE_SIZE) ||
		!rar_huffman_build(&state.lengthcode, state.lengthtable[RAR_V3_MAINCODE_SIZE+RAR_V3_OFFSETCODE_SIZE+RAR_V3_LOWOFFSETCODE_SIZE:], RAR_V3_LENGTHCODE_SIZE) {
		return .Invalid_Archive
	}
	decoder.start_new_table = false
	return .None
}

rar_crc_byte :: proc(seed: u32, value: byte) -> u32 {
	crc := seed ~ u32(0xffffffff)
	crc = crc ~ u32(value)
	for bit := 0; bit < 8; bit += 1 {
		mask := u32(0) - (crc & 1)
		crc = (crc >> 1) ~ (u32(0xedb88320) & mask)
	}
	return crc ~ u32(0xffffffff)
}

rar_sink_write :: proc(sink: ^rar_output_sink, position: u64, value: byte) {
	if position < sink.start || position >= sink.end {
		return
	}
	if sink.data != nil {
		index := int(position - sink.start)
		if index >= 0 && index < len(sink.data) {
			sink.data[index] = value
		}
	}
	if sink.crc_enabled {
		sink.crc = rar_crc_byte(sink.crc, value)
	}
	sink.count += 1
}

rar_copy_window_to_sink :: proc(decoder: ^rar_decoder, sink: ^rar_output_sink, start: u64, end: u64) {
	if end <= start {
		return
	}
	for position := start; position < end; position += 1 {
		index := int(position & u64(RAR_LZSS_WINDOW_MASK))
		rar_sink_write(sink, position, decoder.window[index])
	}
}

rar_emit_literal :: proc(decoder: ^rar_decoder, sink: ^rar_output_sink, value: byte) {
	index := int(decoder.position & u64(RAR_LZSS_WINDOW_MASK))
	decoder.window[index] = value
	rar_sink_write(sink, decoder.position, value)
	decoder.position += 1
}

rar_emit_match :: proc(decoder: ^rar_decoder, sink: ^rar_output_sink, offset: int, length: int) -> Error {
	if offset <= 0 || offset > RAR_LZSS_WINDOW_SIZE || length < 2 {
		return .Invalid_Archive
	}
	for step := 0; step < length; step += 1 {
		position := decoder.position + u64(step)
		destination := int(position & u64(RAR_LZSS_WINDOW_MASK))
		source := (int(position & u64(RAR_LZSS_WINDOW_MASK)) - offset) & RAR_LZSS_WINDOW_MASK
		value := decoder.window[source]
		decoder.window[destination] = value
		rar_sink_write(sink, position, value)
	}
	decoder.position += u64(length)
	return .None
}

rar_read_extra :: proc(decoder: ^rar_decoder, count: byte) -> (u32, Error) {
	if count == 0 {
		return 0, .None
	}
	value, err := rar_bit_required(&decoder.br, int(count))
	return u32(value), err
}

rar_read_rar_length :: proc(decoder: ^rar_decoder, symbol: int, extra_base: u32) -> (int, Error) {
	if symbol < 0 || symbol >= len(RAR_LENGTH_BASES) {
		return 0, .Invalid_Archive
	}
	extra, err := rar_read_extra(decoder, RAR_LENGTH_BITS[symbol])
	if err != .None {
		return 0, err
	}
	return int(RAR_LENGTH_BASES[symbol] + extra_base + extra), .None
}

rar_expand_v2 :: proc(decoder: ^rar_decoder, sink: ^rar_output_sink, target_end: u64) -> Error {
	state := &decoder.v2
	for decoder.position < target_end {
		if decoder.start_new_table {
			if err := rar_parse_codes_v2(decoder); err != .None {
				return err
			}
		}
		symbol, symbol_err := rar_read_symbol(decoder, &state.maincode)
		if symbol_err != .None {
			return symbol_err
		}
		if symbol < 256 {
			rar_emit_literal(decoder, sink, byte(symbol))
			continue
		}

		offset: u32
		length: int
		if symbol == 256 {
			offset = state.lastoffset
			length = int(state.lastlength)
			if length < 2 {
				return .Invalid_Archive
			}
		} else if symbol <= 260 {
			old_index := (state.oldoffsetindex - u32(symbol-256)) & 3
			offset = state.oldoffset[int(old_index)]
			length_symbol, length_err := rar_read_symbol(decoder, &state.lengthcode)
			if length_err != .None {
				return length_err
			}
			length, length_err = rar_read_rar_length(decoder, length_symbol, 2)
			if length_err != .None {
				return length_err
			}
			if offset >= 0x40000 {
				length += 1
			}
			if offset >= 0x2000 {
				length += 1
			}
			if offset >= 0x101 {
				length += 1
			}
		} else if symbol <= 268 {
			short_index := symbol - 261
			if short_index < 0 || short_index >= len(RAR_SHORT_BASES) {
				return .Invalid_Archive
			}
			extra, extra_err := rar_read_extra(decoder, RAR_SHORT_BITS[short_index])
			if extra_err != .None {
				return extra_err
			}
			offset = RAR_SHORT_BASES[short_index] + 1 + extra
			length = 2
		} else if symbol == 269 {
			decoder.start_new_table = true
			continue
		} else {
			length_symbol := symbol - 270
			if length_symbol < 0 || length_symbol >= len(RAR_LENGTH_BASES) {
				return .Invalid_Archive
			}
			length_value, length_err := rar_read_rar_length(decoder, length_symbol, 3)
			if length_err != .None {
				return length_err
			}
			length = length_value
			offset_symbol, offset_err := rar_read_symbol(decoder, &state.offsetcode)
			if offset_err != .None {
				return offset_err
			}
			if offset_symbol < 0 || offset_symbol >= len(RAR_V2_OFFSET_BASES) {
				return .Invalid_Archive
			}
			offset = RAR_V2_OFFSET_BASES[offset_symbol] + 1
			extra, extra_err := rar_read_extra(decoder, RAR_V2_OFFSET_BITS[offset_symbol])
			if extra_err != .None {
				return extra_err
			}
			offset += extra
			if offset >= 0x40000 {
				length += 1
			}
			if offset >= 0x2000 {
				length += 1
			}
		}

		state.lastoffset = offset
		state.lastlength = u32(length)
		state.oldoffset[int(state.oldoffsetindex & 3)] = offset
		state.oldoffsetindex += 1
		if err := rar_emit_match(decoder, sink, int(offset), length); err != .None {
			return err
		}
	}
	return .None
}

rar_expand_v3 :: proc(decoder: ^rar_decoder, sink: ^rar_output_sink, target_end: u64) -> Error {
	state := &decoder.v3
	for decoder.position < target_end {
		if decoder.start_new_table {
			if err := rar_parse_codes_v3(decoder); err != .None {
				return err
			}
		}
		symbol, symbol_err := rar_read_symbol(decoder, &state.maincode)
		if symbol_err != .None {
			return symbol_err
		}
		if symbol < 256 {
			rar_emit_literal(decoder, sink, byte(symbol))
			continue
		}
		if symbol == 256 {
			first, first_err := rar_bit_required(&decoder.br, 1)
			if first_err != .None {
				return first_err
			}
			if first == 0 {
				second, second_err := rar_bit_required(&decoder.br, 1)
				if second_err != .None {
					return second_err
				}
				decoder.start_new_table = second != 0
				continue
			}
			if err := rar_parse_codes_v3(decoder); err != .None {
				return err
			}
			continue
		}
		if symbol == 257 {
			// 257 is the RAR VM/filter control symbol.  Running it would need
			// the optional RAR virtual machine, so never return its raw bytes.
			return .Unsupported_Feature
		}

		offset: u32
		length: int
		if symbol == 258 {
			if state.lastlength == 0 {
				continue
			}
			offset = state.lastoffset
			length = int(state.lastlength)
		} else if symbol <= 262 {
			old_index := symbol - 259
			if old_index < 0 || old_index >= 4 {
				return .Invalid_Archive
			}
			length_symbol, length_err := rar_read_symbol(decoder, &state.lengthcode)
			if length_err != .None {
				return length_err
			}
			offset = state.oldoffset[old_index]
			length, length_err = rar_read_rar_length(decoder, length_symbol, 2)
			if length_err != .None {
				return length_err
			}
			for shift := old_index; shift > 0; shift -= 1 {
				state.oldoffset[shift] = state.oldoffset[shift-1]
			}
			state.oldoffset[0] = offset
		} else if symbol <= 270 {
			short_index := symbol - 263
			if short_index < 0 || short_index >= len(RAR_SHORT_BASES) {
				return .Invalid_Archive
			}
			extra, extra_err := rar_read_extra(decoder, RAR_SHORT_BITS[short_index])
			if extra_err != .None {
				return extra_err
			}
			offset = RAR_SHORT_BASES[short_index] + 1 + extra
			length = 2
			for shift := 3; shift > 0; shift -= 1 {
				state.oldoffset[shift] = state.oldoffset[shift-1]
			}
			state.oldoffset[0] = offset
		} else {
			length_symbol := symbol - 271
			if length_symbol < 0 || length_symbol >= len(RAR_LENGTH_BASES) {
				return .Invalid_Archive
			}
			length_value, length_err := rar_read_rar_length(decoder, length_symbol, 3)
			if length_err != .None {
				return length_err
			}
			length = length_value
			offset_symbol, offset_err := rar_read_symbol(decoder, &state.offsetcode)
			if offset_err != .None {
				return offset_err
			}
			if offset_symbol < 0 || offset_symbol >= len(RAR_V3_OFFSET_BASES) {
				return .Invalid_Archive
			}
			offset = RAR_V3_OFFSET_BASES[offset_symbol] + 1
			if offset_symbol > 9 {
				if RAR_V3_OFFSET_BITS[offset_symbol] > 4 {
					extra, extra_err := rar_read_extra(decoder, RAR_V3_OFFSET_BITS[offset_symbol]-4)
					if extra_err != .None {
						return extra_err
					}
					offset += extra << 4
				}
				if state.numlowoffsetrepeats > 0 {
					state.numlowoffsetrepeats -= 1
					offset += state.lastlowoffset
				} else {
					low_symbol, low_err := rar_read_symbol(decoder, &state.lowoffsetcode)
					if low_err != .None {
						return low_err
					}
					if low_symbol == 16 {
						state.numlowoffsetrepeats = 15
						offset += state.lastlowoffset
					} else if low_symbol >= 0 && low_symbol < 16 {
						offset += u32(low_symbol)
						state.lastlowoffset = u32(low_symbol)
					} else {
						return .Invalid_Archive
					}
				}
			} else {
				extra, extra_err := rar_read_extra(decoder, RAR_V3_OFFSET_BITS[offset_symbol])
				if extra_err != .None {
					return extra_err
				}
				offset += extra
			}
			if offset >= 0x40000 {
				length += 1
			}
			if offset >= 0x2000 {
				length += 1
			}
			for shift := 3; shift > 0; shift -= 1 {
				state.oldoffset[shift] = state.oldoffset[shift-1]
			}
			state.oldoffset[0] = offset
		}

		state.lastoffset = offset
		state.lastlength = u32(length)
		if err := rar_emit_match(decoder, sink, int(offset), length); err != .None {
			return err
		}
	}
	return .None
}

rar_decode_until :: proc(decoder: ^rar_decoder, target_end: u64, sink: ^rar_output_sink) -> Error {
	if decoder.version == 2 {
		return rar_expand_v2(decoder, sink, target_end)
	}
	return rar_expand_v3(decoder, sink, target_end)
}
