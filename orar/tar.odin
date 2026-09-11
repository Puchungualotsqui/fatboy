package orar

import "core:strings"

TAR_BLOCK_SIZE :: 512

TAR_TYPE_FILE :: byte('0')
TAR_TYPE_FILE_OLD :: byte(0)
TAR_TYPE_HARD_LINK :: byte('1')
TAR_TYPE_SOFT_LINK :: byte('2')
TAR_TYPE_DIRECTORY :: byte('5')
TAR_TYPE_GNU_LONGNAME :: byte('L')
TAR_TYPE_GNU_LONGLINK :: byte('K')
TAR_TYPE_PAX_GLOBAL :: byte('g')
TAR_TYPE_PAX_EXTENDED :: byte('x')

parse_tar :: proc(archive: ^Archive) -> Error {
	data := archive.Data
	if len(data) < TAR_BLOCK_SIZE {
		return .Truncated
	}

	position := 0
	parsed_any := false
	pending_name := ""
	pending_raw_name := ""
	pending_size: u64 = 0
	pending_size_set := false
	pending_filetime: i64 = 0
	pending_filetime_set := false

	for position+TAR_BLOCK_SIZE <= len(data) {
		header := data[position:position+TAR_BLOCK_SIZE]
		if tar_zero_block(header) {
			// POSIX tar writes two zero blocks. One complete zero block is
			// enough to establish the logical end, as unarr does.
			if parsed_any {
				break
			}
			return .Invalid_Archive
		}
		if !tar_validate_checksum(header) {
			return .Invalid_Archive
		}

		size, size_ok := tar_octal(header[124:136])
		if !size_ok {
			return .Invalid_Archive
		}
		mtime, mtime_ok := tar_octal(header[136:148])
		if !mtime_ok {
			return .Invalid_Archive
		}
		type := header[156]
		if type == TAR_TYPE_FILE_OLD {
			// GNU tar uses an old-style zero type flag for regular files.
			type = TAR_TYPE_FILE
			name_end := tar_field_end(header[0:100])
			if name_end > 0 && header[name_end-1] == '/' {
				type = TAR_TYPE_DIRECTORY
			}
		}

		data_offset := position + TAR_BLOCK_SIZE
		if size > u64(len(data)-data_offset) {
			return .Truncated
		}
		padded_size := ((size + TAR_BLOCK_SIZE - 1) / TAR_BLOCK_SIZE) * TAR_BLOCK_SIZE
		if padded_size > u64(len(data)-data_offset) {
			return .Truncated
		}

		if type == TAR_TYPE_PAX_GLOBAL || type == TAR_TYPE_PAX_EXTENDED {
			if type == TAR_TYPE_PAX_EXTENDED {
				pax_apply(data[data_offset:data_offset+int(size)], &pending_name, &pending_raw_name, &pending_size, &pending_size_set, &pending_filetime, &pending_filetime_set)
			}
			position = data_offset + int(padded_size)
			parsed_any = true
			continue
		}

		if type == TAR_TYPE_GNU_LONGNAME || type == TAR_TYPE_GNU_LONGLINK {
			name_data := data[data_offset:data_offset+int(size)]
			name_end := 0
			for name_end < len(name_data) && name_data[name_end] != 0 {
				name_end += 1
			}
			if len(pending_name) > 0 {
				delete(pending_name)
				delete(pending_raw_name)
			}
			long_name, long_raw := archive_name_from_bytes(name_data[:name_end], utf8_is_valid(name_data[:name_end]))
			pending_name = long_name
			pending_raw_name = long_raw
			position = data_offset + int(padded_size)
			parsed_any = true
			continue
		}

		name_bytes := tar_field_bytes(header[0:100])
		prefix_bytes := tar_field_bytes(header[345:500])
		full_name: [dynamic]byte
		if len(prefix_bytes) > 0 {
			append(&full_name, ..prefix_bytes)
			append(&full_name, byte('/'))
		}
		append(&full_name, ..name_bytes)
		name, raw_name := archive_name_from_bytes(full_name[:], utf8_is_valid(full_name[:]))
		delete(full_name)

		if len(pending_name) > 0 {
			delete(name)
			delete(raw_name)
			name = pending_name
			raw_name = pending_raw_name
			pending_name = ""
			pending_raw_name = ""
		}

		file_size := size
		if pending_size_set {
			file_size = pending_size
		}
		filetime := (i64(mtime) + 11644473600) * 10000000
		if pending_filetime_set {
			filetime = pending_filetime
		}

		kind := Entry_Kind.Other
		switch type {
		case TAR_TYPE_FILE:
			kind = .File
		case TAR_TYPE_DIRECTORY:
			kind = .Directory
		case TAR_TYPE_SOFT_LINK, TAR_TYPE_HARD_LINK:
			kind = .Symlink
		}

		append(&archive.Entries, Entry{
			Name = name,
			Raw_Name = raw_name,
			Kind = kind,
			Size = file_size,
			Compressed_Size = size,
			Offset = i64(position),
			Filetime = filetime,
			Method = u16(type),
			Data_Offset = i64(data_offset),
			Format_Index = int(type),
		})
		parsed_any = true
		pending_size_set = false
		pending_filetime_set = false
		position = data_offset + int(padded_size)
	}

	delete(pending_name)
	delete(pending_raw_name)
	if !parsed_any || len(archive.Entries) == 0 {
		return .Invalid_Archive
	}
	return .None
}

tar_zero_block :: proc(data: []byte) -> bool {
	if len(data) < TAR_BLOCK_SIZE {
		return false
	}
	for value in data[:TAR_BLOCK_SIZE] {
		if value != 0 {
			return false
		}
	}
	return true
}

tar_field_end :: proc(data: []byte) -> int {
	for index := 0; index < len(data); index += 1 {
		if data[index] == 0 {
			return index
		}
	}
	return len(data)
}

tar_field_bytes :: proc(data: []byte) -> []byte {
	return data[:tar_field_end(data)]
}

tar_octal :: proc(data: []byte) -> (u64, bool) {
	value: u64 = 0
	has_digit := false
	for c in data {
		if c == 0 || c == ' ' || c == '\t' {
			continue
		}
		if c < '0' || c > '7' {
			return 0, false
		}
		has_digit = true
		value = value*8 + u64(c-'0')
	}
	return value, has_digit
}

tar_validate_checksum :: proc(header: []byte) -> bool {
	if len(header) < TAR_BLOCK_SIZE {
		return false
	}
	stored, ok := tar_octal(header[148:156])
	if !ok {
		return false
	}
	unsigned_sum: u64 = 0
	signed_sum: i64 = 0
	for index := 0; index < TAR_BLOCK_SIZE; index += 1 {
		if index >= 148 && index < 156 {
			unsigned_sum += u64(' ')
			signed_sum += i64(' ')
		} else {
			unsigned_sum += u64(header[index])
			signed_sum += i64(i8(header[index]))
		}
	}
	if stored == unsigned_sum {
		return true
	}
	return signed_sum >= 0 && stored == u64(signed_sum)
}

pax_apply :: proc(
	data: []byte,
	pending_name: ^string,
	pending_raw_name: ^string,
	pending_size: ^u64,
	pending_size_set: ^bool,
	pending_filetime: ^i64,
	pending_filetime_set: ^bool,
) {
	position := 0
	for position < len(data) {
		space := position
		for space < len(data) && data[space] != ' ' {
			space += 1
		}
		if space == len(data) {
			break
		}
		length: u64 = 0
		valid_length := true
		for index := position; index < space; index += 1 {
			if data[index] < '0' || data[index] > '9' {
				valid_length = false
				break
			}
			length = length*10 + u64(data[index]-'0')
		}
		if !valid_length || length == 0 || length > u64(len(data)-position) {
			break
		}
		line_end := position + int(length)
		equal := space + 1
		for equal < line_end && data[equal] != '=' {
			equal += 1
		}
		if equal >= line_end {
			break
		}
		key := string(data[space+1:equal])
		value_end := line_end
		if value_end > position && data[value_end-1] == '\n' {
			value_end -= 1
		}
		value := string(data[equal+1:value_end])
		switch key {
		case "path":
			delete(pending_name^)
			delete(pending_raw_name^)
			pending_name^ = normalize_name(value)
			pending_raw_name^ = strings.clone(value, context.allocator)
		case "size":
			if number, ok := pax_unsigned(value); ok {
				pending_size^ = number
				pending_size_set^ = true
			}
		case "mtime":
			if number, ok := pax_decimal(value); ok {
				pending_filetime^ = (number + 11644473600) * 10000000
				pending_filetime_set^ = true
			}
		}
		position = line_end
	}
}

pax_unsigned :: proc(value: string) -> (u64, bool) {
	if len(value) == 0 {
		return 0, false
	}
	result: u64 = 0
	for c in value {
		if c < '0' || c > '9' {
			return 0, false
		}
		result = result*10 + u64(c-'0')
	}
	return result, true
}

pax_decimal :: proc(value: string) -> (i64, bool) {
	if len(value) == 0 {
		return 0, false
	}
	negative := value[0] == '-'
	start := 1 if negative else 0
	whole: i64 = 0
	for index := start; index < len(value) && value[index] != '.'; index += 1 {
		if value[index] < '0' || value[index] > '9' {
			return 0, false
		}
		whole = whole*10 + i64(value[index]-'0')
	}
	if negative {
		whole = -whole
	}
	return whole, true
}

decode_tar_entry :: proc(archive: ^Archive, index: int) -> ([]byte, Error) {
	if archive == nil || index < 0 || index >= len(archive.Entries) {
		return nil, .Invalid_State
	}
	entry := archive.Entries[index]
	if entry.Kind != .File && entry.Kind != .Other {
		result, alloc_error := make([]byte, 0, context.allocator)
		if alloc_error != nil {
			return nil, .Out_Of_Memory
		}
		return result, .None
	}
	if entry.Size > u64(len(archive.Data)) || !valid_range(archive.Data, int(entry.Data_Offset), entry.Size) {
		return nil, .Truncated
	}
	if entry.Size > 0x7fffffffffffffff {
		return nil, .Limit_Exceeded
	}
	result, alloc_error := make([]byte, int(entry.Size), context.allocator)
	if alloc_error != nil {
		return nil, .Out_Of_Memory
	}
	copy(result, archive.Data[int(entry.Data_Offset):int(entry.Data_Offset)+int(entry.Size)])
	return result, .None
}
