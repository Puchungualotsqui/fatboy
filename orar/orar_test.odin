package orar

import "core:os"
import "core:testing"

@(test)
format_detection_and_rejection_test :: proc(t: ^testing.T) {
	testing.expect_value(t, Detect([]byte{'R', 'a', 'r', '!', 0x1a, 0x07, 0x00}), Format.RAR4)
	testing.expect_value(t, Detect([]byte{'R', 'a', 'r', '!', 0x1a, 0x07, 0x01, 0x00}), Format.RAR5)
	testing.expect_value(t, Detect([]byte{0x50, 0x4b, 0x03, 0x04}), Format.ZIP)
	testing.expect_value(t, Detect([]byte{'n', 'o', 't', ' ', 'a', 'r', 'c', 'h'}), Format.Unknown)
	_, err := Open_Bytes([]byte{'n', 'o', 't', ' ', 'a', 'n', ' ', 'a', 'r', 'c', 'h', 'i', 'v', 'e'})
	testing.expect_value(t, err, Error.Unsupported_Format)
}

@(test)
tar_iteration_and_extraction_test :: proc(t: ^testing.T) {
	payload := []byte{'t', 'a', 'r', ' ', 'p', 'a', 'y', 'l', 'o', 'a', 'd'}
	archive_data := make_test_tar("folder/file.txt", payload)
	defer delete(archive_data)

	archive, err := Open_Bytes(archive_data)
	testing.expect_value(t, err, Error.None)
	defer Destroy_Archive(&archive)
	testing.expect_value(t, archive.Format, Format.TAR)
	entry, entry_err := Next(&archive)
	testing.expect_value(t, entry_err, Error.None)
	testing.expect_value(t, entry.Name, "folder/file.txt")
	testing.expect_value(t, entry.Size, u64(len(payload)))
	output, output_err := Extract_Current(&archive)
	testing.expect_value(t, output_err, Error.None)
	defer delete(output)
	testing.expect(t, bytes_equal_orar(output, payload))
	_, end_err := Next(&archive)
	testing.expect_value(t, end_err, Error.End)
}

@(test)
zip_store_and_deflate_test :: proc(t: ^testing.T) {
	stored_payload := []byte{'s', 't', 'o', 'r', 'e', 'd'}
	stored_archive_data := make_test_zip("stored.txt", stored_payload, 0, stored_payload, crc32(0, stored_payload))
	defer delete(stored_archive_data)
	stored_archive, stored_err := Open_Bytes(stored_archive_data)
	testing.expect_value(t, stored_err, Error.None)
	defer Destroy_Archive(&stored_archive)
	stored_entry, stored_entry_err := Next(&stored_archive)
	testing.expect_value(t, stored_entry_err, Error.None)
	testing.expect_value(t, stored_entry.Name, "stored.txt")

	stored_output, stored_output_err := Extract_Current(&stored_archive)

	testing.expect_value(t, stored_output_err, Error.None)
	defer delete(stored_output)
	testing.expect(t, bytes_equal_orar(stored_output, stored_payload))

	deflate_payload: [dynamic]byte
	for repeat := 0; repeat < 32; repeat += 1 {
		append(&deflate_payload, "hello from orar\n")
	}
	compressed := []byte{
		203, 72, 205, 201, 201, 87, 72, 43, 202, 207, 85, 200,
		47, 74, 44, 226, 202, 24, 229, 231, 140, 36, 62, 0,
	}
	defer delete(deflate_payload)
	deflate_archive_data := make_test_zip("deflate.txt", deflate_payload[:], 8, compressed, 1536462382)
	defer delete(deflate_archive_data)
	deflate_archive, deflate_err := Open_Bytes(deflate_archive_data)
	testing.expect_value(t, deflate_err, Error.None)
	defer Destroy_Archive(&deflate_archive)
	_, deflate_entry_err := Next(&deflate_archive)
	testing.expect_value(t, deflate_entry_err, Error.None)
	deflate_output, deflate_output_err := Extract_Current(&deflate_archive)
	testing.expect_value(t, deflate_output_err, Error.None)
	defer delete(deflate_output)
	testing.expect(t, bytes_equal_orar(deflate_output, deflate_payload[:]))
}

@(test)
archive_corpus_test :: proc(t: ^testing.T) {
	paths := []string{
		"unarr/test/corpus/integration/lipsum.tar",
		"unarr/test/corpus/integration/lipsum_zip_copy.zip",
		"unarr/test/corpus/integration/lipsum_zip_default.zip",
	}
	for path in paths {
		if !os.exists(path) {
			return
		}
		archive, open_err := Open_File(path)
		testing.expect_value(t, open_err, Error.None)
		if open_err != .None {
			continue
		}
		entry_count := 0
		for {
			entry, entry_err := Next(&archive)
			if entry_err == .End {
				break
			}
			testing.expect_value(t, entry_err, Error.None)
			if entry_err != .None {
				break
			}
			output, extract_err := Extract_Current(&archive)
			testing.expect_value(t, extract_err, Error.None)
			if extract_err == .None {
				testing.expect_value(t, u64(len(output)), entry.Size)
			}
			delete(output)
			entry_count += 1
		}
		testing.expect(t, entry_count > 0)
		Destroy_Archive(&archive)
	}
}

@(test)
rar4_corpus_compressed_test :: proc(t: ^testing.T) {
	paths := []string{
		"unarr/test/corpus/integration/lipsum_rar4_default.rar",
		"unarr/test/corpus/integration/lipsum_rar4_max.rar",
	}
	for path in paths {
		if !os.exists(path) {
			return
		}
		archive, open_err := Open_File(path)
		testing.expect_value(t, open_err, Error.None)
		if open_err != .None {
			continue
		}
		entry, entry_err := Next(&archive)
		testing.expect_value(t, entry_err, Error.None)
		if entry_err == .None {
			output, extract_err := Extract_Current(&archive)
			testing.expect_value(t, extract_err, Error.None)
			testing.expect_value(t, u64(len(output)), entry.Size)
			delete(output)
		}
		Destroy_Archive(&archive)
	}
}

@(test)
rar5_stored_test :: proc(t: ^testing.T) {
	payload := []byte{'r', 'a', 'r', '5', ' ', 'p', 'a', 'y', 'l', 'o', 'a', 'd'}
	archive_data := make_test_rar5("rar5.txt", payload)
	defer delete(archive_data)

	archive, err := Open_Bytes(archive_data)
	testing.expect_value(t, err, Error.None)
	defer Destroy_Archive(&archive)
	testing.expect_value(t, archive.Format, Format.RAR5)
	entry, entry_err := Next(&archive)
	testing.expect_value(t, entry_err, Error.None)
	testing.expect_value(t, entry.Name, "rar5.txt")
	testing.expect_value(t, entry.Size, u64(len(payload)))
	output, output_err := Extract_Current(&archive)
	testing.expect_value(t, output_err, Error.None)
	defer delete(output)
	testing.expect(t, bytes_equal_orar(output, payload))
}

@(test)
rar4_stored_test :: proc(t: ^testing.T) {
	payload := []byte{'r', 'a', 'r', ' ', 'p', 'a', 'y', 'l', 'o', 'a', 'd'}
	archive_data := make_test_rar("rar.txt", payload)
	defer delete(archive_data)

	archive, err := Open_Bytes(archive_data)
	testing.expect_value(t, err, Error.None)
	defer Destroy_Archive(&archive)
	testing.expect_value(t, archive.Format, Format.RAR4)
	entry, entry_err := Next(&archive)
	testing.expect_value(t, entry_err, Error.None)
	testing.expect_value(t, entry.Name, "rar.txt")
	output, output_err := Extract_Current(&archive)
	testing.expect_value(t, output_err, Error.None)
	defer delete(output)
	testing.expect(t, bytes_equal_orar(output, payload))
}

bytes_equal_orar :: proc(left, right: []byte) -> bool {
	if len(left) != len(right) {
		return false
	}
	for index := 0; index < len(left); index += 1 {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}

append_u16le_test :: proc(data: ^[dynamic]byte, value: u16) {
	append(data, byte(value&0xff))
	append(data, byte(value>>8))
}

append_u32le_test :: proc(data: ^[dynamic]byte, value: u32) {
	append(data, byte(value&0xff))
	append(data, byte((value>>8)&0xff))
	append(data, byte((value>>16)&0xff))
	append(data, byte(value>>24))
}

set_u16le_test :: proc(data: []byte, offset: int, value: u16) {
	data[offset] = byte(value & 0xff)
	data[offset+1] = byte(value >> 8)
}

set_u32le_test :: proc(data: []byte, offset: int, value: u32) {
	data[offset] = byte(value & 0xff)
	data[offset+1] = byte((value >> 8) & 0xff)
	data[offset+2] = byte((value >> 16) & 0xff)
	data[offset+3] = byte(value >> 24)
}

make_test_zip :: proc(name: string, uncompressed: []byte, method: u16, compressed: []byte, checksum: u32) -> []byte {
	result: [dynamic]byte
	name_bytes := transmute([]byte)name
	append_u32le_test(&result, ZIP_LOCAL_FILE_SIGNATURE)
	append_u16le_test(&result, 20)
	append_u16le_test(&result, 0)
	append_u16le_test(&result, method)
	append_u16le_test(&result, 0)
	append_u16le_test(&result, 0)
	append_u32le_test(&result, checksum)
	append_u32le_test(&result, u32(len(compressed)))
	append_u32le_test(&result, u32(len(uncompressed)))
	append_u16le_test(&result, u16(len(name_bytes)))
	append_u16le_test(&result, 0)
	append(&result, ..name_bytes)
	append(&result, ..compressed)

	central_offset := len(result)
	append_u32le_test(&result, ZIP_CENTRAL_SIGNATURE)
	append_u16le_test(&result, 20)
	append_u16le_test(&result, 20)
	append_u16le_test(&result, 0)
	append_u16le_test(&result, method)
	append_u16le_test(&result, 0)
	append_u16le_test(&result, 0)
	append_u32le_test(&result, checksum)
	append_u32le_test(&result, u32(len(compressed)))
	append_u32le_test(&result, u32(len(uncompressed)))
	append_u16le_test(&result, u16(len(name_bytes)))
	append_u16le_test(&result, 0)
	append_u16le_test(&result, 0)
	append_u16le_test(&result, 0)
	append_u16le_test(&result, 0)
	append_u32le_test(&result, 0)
	append_u32le_test(&result, 0)
	append(&result, ..name_bytes)

	central_size := len(result) - central_offset
	append_u32le_test(&result, ZIP_END_SIGNATURE)
	append_u16le_test(&result, 0)
	append_u16le_test(&result, 0)
	append_u16le_test(&result, 1)
	append_u16le_test(&result, 1)
	append_u32le_test(&result, u32(central_size))
	append_u32le_test(&result, u32(central_offset))
	append_u16le_test(&result, 0)

	return result[:]
}

make_test_tar :: proc(name: string, payload: []byte) -> []byte {
	block_count := 2 + (len(payload)+TAR_BLOCK_SIZE-1)/TAR_BLOCK_SIZE
	result, alloc_error := make([]byte, block_count*TAR_BLOCK_SIZE, context.allocator)
	if alloc_error != nil {
		return nil
	}
	header := result[:TAR_BLOCK_SIZE]
	copy(header[0:100], transmute([]byte)name)
	write_tar_octal_test(header[100:108], 0o644)
	write_tar_octal_test(header[108:116], 0)
	write_tar_octal_test(header[116:124], 0)
	write_tar_octal_test(header[124:136], u64(len(payload)))
	write_tar_octal_test(header[136:148], 0)
	for index := 148; index < 156; index += 1 {
		header[index] = ' '
	}
	header[156] = TAR_TYPE_FILE
	copy(header[257:265], []byte{'u', 's', 't', 'a', 'r', 0, '0', '0'})
	checksum: u64 = 0
	for value in header {
		checksum += u64(value)
	}
	write_tar_checksum_test(header[148:156], checksum)
	copy(result[TAR_BLOCK_SIZE:TAR_BLOCK_SIZE+len(payload)], payload)
	return result
}

write_tar_octal_test :: proc(field: []byte, value: u64) {
	remaining := value
	for index := 0; index < len(field); index += 1 {
		field[index] = 0
	}
	position := len(field) - 1
	field[position] = 0
	if position > 0 {
		position -= 1
	}
	for position >= 0 && remaining > 0 {
		field[position] = byte('0') + byte(remaining&7)
		remaining >>= 3
		position -= 1
	}
	for index := 0; index+1 < len(field); index += 1 {
		if field[index] == 0 {
			field[index] = '0'
		}
	}
}

write_tar_checksum_test :: proc(field: []byte, value: u64) {
	remaining := value
	for index := 0; index < 6; index += 1 {
		field[5-index] = byte('0') + byte(remaining&7)
		remaining >>= 3
	}
	field[6] = 0
	field[7] = ' '
}

make_test_rar :: proc(name: string, payload: []byte) -> []byte {
	result: [dynamic]byte
	append(&result, ..[]byte{'R', 'a', 'r', '!', 0x1a, 0x07, 0x00})

	main_start := len(result)
	for index := 0; index < 13; index += 1 {
		append(&result, byte(0))
	}
	set_u16le_test(result[:], main_start+5, 13)
	set_u16le_test(result[:], main_start+3, 0)
	result[main_start+2] = RAR_TYPE_MAIN_HEADER
	set_u16le_test(result[:], main_start, u16(crc32(0, result[main_start+2:main_start+13])&0xffff))

	name_bytes := transmute([]byte)name
	file_start := len(result)
	file_header_size := 32 + len(name_bytes)
	for index := 0; index < file_header_size; index += 1 {
		append(&result, byte(0))
	}
	result[file_start+2] = RAR_TYPE_FILE_HEADER
	set_u16le_test(result[:], file_start+3, 0)
	set_u16le_test(result[:], file_start+5, u16(file_header_size))
	set_u32le_test(result[:], file_start+7, u32(len(payload)))
	set_u32le_test(result[:], file_start+11, u32(len(payload)))
	result[file_start+15] = 0
	set_u32le_test(result[:], file_start+16, crc32(0, payload))
	set_u32le_test(result[:], file_start+20, 0)
	result[file_start+24] = 29
	result[file_start+25] = RAR_METHOD_STORE
	set_u16le_test(result[:], file_start+26, u16(len(name_bytes)))
	set_u32le_test(result[:], file_start+28, 0)
	copy(result[file_start+32:file_start+32+len(name_bytes)], name_bytes)
	set_u16le_test(result[:], file_start, u16(crc32(0, result[file_start+2:file_start+file_header_size])&0xffff))
	append(&result, ..payload)

	end_start := len(result)
	for index := 0; index < 7; index += 1 {
		append(&result, byte(0))
	}
	result[end_start+2] = RAR_TYPE_END_HEADER
	set_u16le_test(result[:], end_start+5, 7)
	set_u16le_test(result[:], end_start, u16(crc32(0, result[end_start+2:end_start+7])&0xffff))
	return result[:]
}

append_vint_test :: proc(data: ^[dynamic]byte, value: u64) {
	remaining := value
	for {
		part := byte(remaining & 0x7f)
		remaining >>= 7
		if remaining != 0 {
			part |= 0x80
		}
		append(data, part)
		if remaining == 0 {
			break
		}
	}
}

append_rar5_header_test :: proc(result: ^[dynamic]byte, body: []byte, payload: []byte) {
	tail: [dynamic]byte
	append_vint_test(&tail, u64(len(body)))
	append(&tail, ..body)
	append_u32le_test(result, crc32(0, tail[:]))
	append(result, ..tail[:])
	append(result, ..payload)
	delete(tail)
}

make_test_rar5 :: proc(name: string, payload: []byte) -> []byte {
	result: [dynamic]byte
	append(&result, ..[]byte{'R', 'a', 'r', '!', 0x1a, 0x07, 0x01, 0x00})

	main_body: [dynamic]byte
	append_vint_test(&main_body, RAR5_TYPE_MAIN)
	append_vint_test(&main_body, 0)
	append_vint_test(&main_body, 0)
	append_rar5_header_test(&result, main_body[:], nil)
	delete(main_body)

	file_body: [dynamic]byte
	name_bytes := transmute([]byte)name
	append_vint_test(&file_body, RAR5_TYPE_FILE)
	append_vint_test(&file_body, RAR5_HEADER_DATA)
	append_vint_test(&file_body, u64(len(payload)))
	append_vint_test(&file_body, 1 << 2)
	append_vint_test(&file_body, u64(len(payload)))
	append_vint_test(&file_body, 0)
	append_u32le_test(&file_body, crc32(0, payload))
	append_vint_test(&file_body, 0)
	append_vint_test(&file_body, 0)
	append_vint_test(&file_body, u64(len(name_bytes)))
	append(&file_body, ..name_bytes)
	append_rar5_header_test(&result, file_body[:], payload)
	delete(file_body)

	end_body: [dynamic]byte
	append_vint_test(&end_body, RAR5_TYPE_END)
	append_vint_test(&end_body, 0)
	append_vint_test(&end_body, 0)
	append_rar5_header_test(&result, end_body[:], nil)
	delete(end_body)
	return result[:]
}
