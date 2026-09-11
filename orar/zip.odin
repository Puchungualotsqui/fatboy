package orar

import "core:strings"

ZIP_LOCAL_FILE_SIGNATURE :: u32(0x04034b50)
ZIP_CENTRAL_SIGNATURE :: u32(0x02014b50)
ZIP_END_SIGNATURE :: u32(0x06054b50)
ZIP64_END_SIGNATURE :: u32(0x06064b50)
ZIP64_LOCATOR_SIGNATURE :: u32(0x07064b50)

ZIP_METHOD_STORE :: u16(0)
ZIP_METHOD_DEFLATE :: u16(8)
ZIP_METHOD_DEFLATE64 :: u16(9)
ZIP_METHOD_BZIP2 :: u16(12)
ZIP_METHOD_LZMA :: u16(14)
ZIP_METHOD_XZ :: u16(95)
ZIP_METHOD_PPMD :: u16(98)

zip_end_record :: struct {
	Offset:       int,
	Entries:      u64,
	Directory_Size: u64,
	Directory_Offset: u64,
	Comment_Offset: int,
	Comment_Size: u16,
}

parse_zip :: proc(archive: ^Archive) -> Error {
	data := archive.Data
	end, err := zip_find_end(data)
	if err != .None {
		return err
	}
	if end.Comment_Size > 0 {
		comment_end := end.Comment_Offset + int(end.Comment_Size)
		if comment_end > len(data) {
			return .Truncated
		}
		archive.Comment = strings.clone(string(data[end.Comment_Offset:comment_end]), context.allocator)
	}
	if end.Entries > u64(len(data)) || end.Directory_Offset > u64(len(data)) {
		return .Truncated
	}
	if end.Directory_Size > u64(len(data)-int(end.Directory_Offset)) {
		return .Truncated
	}

	directory_offset := int(end.Directory_Offset)
	// ZIP files with a prepended data stub store offsets relative to the
	// logical ZIP start. Recover that base when the central directory would
	// otherwise point before the physical file.
	base := 0
	if directory_offset+int(end.Directory_Size) > end.Offset {
		if int(end.Directory_Size) > end.Offset {
			return .Invalid_Archive
		}
		base = end.Offset - directory_offset - int(end.Directory_Size)
		directory_offset += base
	}
	if directory_offset < 0 || directory_offset+int(end.Directory_Size) > len(data) {
		return .Truncated
	}

	position := directory_offset
	for index := u64(0); index < end.Entries; index += 1 {
		if position+46 > len(data) {
			return .Truncated
		}
		signature, ok := read_u32le(data, position)
		if !ok || signature != ZIP_CENTRAL_SIGNATURE {
			return .Invalid_Archive
		}
		flags, flags_ok := read_u16le(data, position+8)
		if !flags_ok {
			return .Truncated
		}
		method, method_ok := read_u16le(data, position+10)
		if !method_ok {
			return .Truncated
		}
		dosdate, dosdate_ok := read_u32le(data, position+12)
		if !dosdate_ok {
			return .Truncated
		}
		entry_crc, crc_ok := read_u32le(data, position+16)
		if !crc_ok {
			return .Truncated
		}
		compressed32, compressed_ok := read_u32le(data, position+20)
		if !compressed_ok {
			return .Truncated
		}
		uncompressed32, uncompressed_ok := read_u32le(data, position+24)
		if !uncompressed_ok {
			return .Truncated
		}
		name_length, name_ok := read_u16le(data, position+28)
		if !name_ok {
			return .Truncated
		}
		extra_length, extra_ok := read_u16le(data, position+30)
		if !extra_ok {
			return .Truncated
		}
		comment_length, comment_ok := read_u16le(data, position+32)
		if !comment_ok {
			return .Truncated
		}
		disk, disk_ok := read_u16le(data, position+34)
		if !disk_ok {
			return .Truncated
		}
		external_attributes, attributes_ok := read_u32le(data, position+38)
		if !attributes_ok {
			return .Truncated
		}
		local_offset32, offset_ok := read_u32le(data, position+42)
		if !offset_ok {
			return .Truncated
		}
		if disk != 0 {
			return .Unsupported_Feature
		}

		header_size := 46 + int(name_length) + int(extra_length) + int(comment_length)
		if header_size < 46 || position+header_size > len(data) {
			return .Truncated
		}
		name_start := position + 46
		name_end := name_start + int(name_length)
		extra_start := name_end
		extra_end := extra_start + int(extra_length)
		name, raw_name := archive_name_from_bytes(data[name_start:name_end], flags&(1<<11) != 0)

		compressed := u64(compressed32)
		uncompressed := u64(uncompressed32)
		local_offset := u64(local_offset32)
		if !zip_apply_zip64_extra(data[extra_start:extra_end], compressed32 == 0xffffffff, uncompressed32 == 0xffffffff, local_offset32 == 0xffffffff, &compressed, &uncompressed, &local_offset) {
			delete(name)
			delete(raw_name)
			return .Invalid_Archive
		}
		if local_offset > u64(len(data)) {
			delete(name)
			delete(raw_name)
			return .Truncated
		}
		local_position := int(local_offset) + base
		if local_position < 0 || local_position+30 > len(data) {
			delete(name)
			delete(raw_name)
			return .Truncated
		}
		local_signature, local_ok := read_u32le(data, local_position)
		if !local_ok || local_signature != ZIP_LOCAL_FILE_SIGNATURE {
			delete(name)
			delete(raw_name)
			return .Invalid_Archive
		}
		local_name_length, local_name_ok := read_u16le(data, local_position+26)
		local_extra_length, local_extra_ok := read_u16le(data, local_position+28)
		if !local_name_ok || !local_extra_ok {
			delete(name)
			delete(raw_name)
			return .Truncated
		}
		data_offset := local_position + 30 + int(local_name_length) + int(local_extra_length)
		if data_offset < local_position || !valid_range(data, data_offset, compressed) {
			delete(name)
			delete(raw_name)
			return .Truncated
		}

		kind := Entry_Kind.File
		if len(name) > 0 && name[len(name)-1] == '/' {
			kind = .Directory
		} else if external_attributes&0x10 != 0 {
			kind = .Directory
		} else if (external_attributes>>16)&0xf000 == 0xa000 {
			kind = .Symlink
		}
		append(&archive.Entries, Entry{
			Name = name,
			Raw_Name = raw_name,
			Kind = kind,
			Size = uncompressed,
			Compressed_Size = compressed,
			Offset = i64(local_position),
			Filetime = dos_datetime_to_filetime(dosdate),
			Method = method,
			Flags = flags,
			CRC32 = entry_crc,
			Data_Offset = i64(data_offset),
			Format_Index = int(method),
		})
		position += header_size
	}
	if len(archive.Entries) == 0 {
		return .Invalid_Archive
	}
	return .None
}

zip_find_end :: proc(data: []byte) -> (zip_end_record, Error) {
	result: zip_end_record
	if len(data) < 22 {
		return result, .Truncated
	}
	start := len(data) - 22 - 0xffff
	if start < 0 {
		start = 0
	}
	for position := len(data) - 22; position >= start; position -= 1 {
		signature, ok := read_u32le(data, position)
		if !ok || signature != ZIP_END_SIGNATURE {
			continue
		}
		comment_length, comment_ok := read_u16le(data, position+20)
		if !comment_ok || position+22+int(comment_length) > len(data) {
			continue
		}
		disk, disk_ok := read_u16le(data, position+4)
		disk_directory, disk_directory_ok := read_u16le(data, position+6)
		entries_disk, entries_disk_ok := read_u16le(data, position+8)
		entries, entries_ok := read_u16le(data, position+10)
		directory_size, directory_size_ok := read_u32le(data, position+12)
		directory_offset, directory_offset_ok := read_u32le(data, position+16)
		if !disk_ok || !disk_directory_ok || !entries_disk_ok || !entries_ok || !directory_size_ok || !directory_offset_ok {
			return result, .Truncated
		}
		if disk != 0 || disk_directory != 0 || entries_disk != entries {
			return result, .Unsupported_Feature
		}
		result = zip_end_record{
			Offset = position,
			Entries = u64(entries),
			Directory_Size = u64(directory_size),
			Directory_Offset = u64(directory_offset),
			Comment_Offset = position + 22,
			Comment_Size = comment_length,
		}
		if entries == 0xffff || directory_size == 0xffffffff || directory_offset == 0xffffffff {
			if position < 20 {
				return result, .Truncated
			}
			locator_signature, locator_ok := read_u32le(data, position-20)
			if !locator_ok || locator_signature != ZIP64_LOCATOR_SIGNATURE {
				return result, .Invalid_Archive
			}
			zip64_offset, offset_ok := read_u64le(data, position-12)
			if !offset_ok || zip64_offset > u64(len(data)) || zip64_offset+56 > u64(len(data)) {
				return result, .Truncated
			}
			zip64_position := int(zip64_offset)
			zip64_signature, signature_ok := read_u32le(data, zip64_position)
			if !signature_ok || zip64_signature != ZIP64_END_SIGNATURE {
				return result, .Invalid_Archive
			}
			entries_disk64, entries_disk64_ok := read_u64le(data, zip64_position+24)
			entries64, entries64_ok := read_u64le(data, zip64_position+32)
			directory_size64, size64_ok := read_u64le(data, zip64_position+40)
			directory_offset64, offset64_ok := read_u64le(data, zip64_position+48)
			if !entries_disk64_ok || !entries64_ok || !size64_ok || !offset64_ok || entries_disk64 != entries64 {
				return result, .Invalid_Archive
			}
			if entries == 0xffff {
				result.Entries = entries64
			}
			if directory_size == 0xffffffff {
				result.Directory_Size = directory_size64
			}
			if directory_offset == 0xffffffff {
				result.Directory_Offset = directory_offset64
			}
		}
		return result, .None
	}
	return result, .Invalid_Archive
}

zip_apply_zip64_extra :: proc(
	extra: []byte,
	need_compressed: bool,
	need_uncompressed: bool,
	need_offset: bool,
	compressed: ^u64,
	uncompressed: ^u64,
	offset: ^u64,
) -> bool {
	position := 0
	for position+4 <= len(extra) {
		kind, kind_ok := read_u16le(extra, position)
		length, length_ok := read_u16le(extra, position+2)
		if !kind_ok || !length_ok || position+4+int(length) > len(extra) {
			return false
		}
		if kind == 0x0001 {
			read_position := position + 4
			if need_uncompressed {
				value, ok := read_u64le(extra, read_position)
				if !ok {
					return false
				}
				uncompressed^ = value
				read_position += 8
			}
			if need_compressed {
				value, ok := read_u64le(extra, read_position)
				if !ok {
					return false
				}
				compressed^ = value
				read_position += 8
			}
			if need_offset {
				value, ok := read_u64le(extra, read_position)
				if !ok {
					return false
				}
				offset^ = value
			}
			return true
		}
		position += 4 + int(length)
	}
	return !need_compressed && !need_uncompressed && !need_offset
}

decode_zip_entry :: proc(archive: ^Archive, index: int) -> ([]byte, Error) {
	if archive == nil || index < 0 || index >= len(archive.Entries) {
		return nil, .Invalid_State
	}
	entry := archive.Entries[index]
	if entry.Flags&1 != 0 {
		return nil, .Encrypted
	}
	if entry.Size > 0x7fffffffffffffff || entry.Compressed_Size > u64(len(archive.Data)) {
		return nil, .Limit_Exceeded
	}
	compressed_start := int(entry.Data_Offset)
	if !valid_range(archive.Data, compressed_start, entry.Compressed_Size) {
		return nil, .Truncated
	}
	compressed := archive.Data[compressed_start:compressed_start+int(entry.Compressed_Size)]
	result: []byte
	err: Error = .None
	switch entry.Method {
	case ZIP_METHOD_STORE:
		if entry.Compressed_Size != entry.Size {
			return nil, .Invalid_Archive
		}
		allocated, alloc_error := make([]byte, int(entry.Size), context.allocator)
		if alloc_error != nil {
			return nil, .Out_Of_Memory
		}
		result = allocated
		copy(result, compressed)
	case ZIP_METHOD_DEFLATE:
		result, err = inflate_raw(compressed, entry.Size)
		if err != .None {
			return nil, err
		}
	case ZIP_METHOD_DEFLATE64, ZIP_METHOD_BZIP2, ZIP_METHOD_LZMA, ZIP_METHOD_XZ, ZIP_METHOD_PPMD:
		return nil, .Unsupported_Feature
	case:
		return nil, .Unsupported_Feature
	}
	if crc32(0, result) != entry.CRC32 {
		delete(result)
		return nil, .Checksum_Mismatch
	}
	return result, .None
}
