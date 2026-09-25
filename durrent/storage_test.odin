package durrent

import "core:crypto/hash"
import "core:os"
import "core:path/filepath"
import "core:testing"

storage_test_hash :: proc(data: []byte) -> Torrent_Hash {
	result: Torrent_Hash
	hash.hash_bytes_to_buffer(hash.Algorithm.Insecure_SHA1, data, result[:])
	return result
}

storage_test_single_torrent :: proc() -> Torrent {
	result: Torrent
	result.Name = torrent_test_clone([]byte{'d', 'e', 'm', 'o', '.', 'b', 'i', 'n'})
	result.Piece_Length = 4
	result.Total_Length = 8
	append(&result.Piece_Hashes, storage_test_hash([]byte{'a', 'b', 'c', 'd'}))
	append(&result.Piece_Hashes, storage_test_hash([]byte{'e', 'f', 'g', 'h'}))
	file: Torrent_File
	file.Length = 8
	append(&file.Path, torrent_test_clone(result.Name))
	append(&result.Files, file)
	return result
}

storage_test_multi_torrent :: proc() -> Torrent {
	result: Torrent
	result.Name = torrent_test_clone([]byte{'r', 'o', 'o', 't'})
	result.Multi_File = true
	result.Piece_Length = 4
	result.Total_Length = 8
	append(&result.Piece_Hashes, storage_test_hash([]byte{'a', 'b', 'c', 'X'}))
	append(&result.Piece_Hashes, storage_test_hash([]byte{'Y', 'Z', '1', '2'}))

	first: Torrent_File
	first.Length = 3
	append(&first.Path, torrent_test_clone([]byte{'a', '.', 'b', 'i', 'n'}))
	append(&result.Files, first)

	second: Torrent_File
	second.Length = 5
	append(&second.Path, torrent_test_clone([]byte{'d', 'i', 'r'}))
	append(&second.Path, torrent_test_clone([]byte{'b', '.', 'b', 'i', 'n'}))
	append(&result.Files, second)
	return result
}

torrent_test_clone :: proc(data: []byte) -> []byte {
	result, _ := torrent_clone(data)
	return result
}

@(test)
torrent_storage_single_file_resume_test :: proc(t: ^testing.T) {
	base, base_error := os.make_directory_temp("", "durrent-single-*", context.allocator)
	testing.expect_value(t, base_error, nil)
	defer os.remove_all(base)
	defer delete(base)

	torrent := storage_test_single_torrent()
	defer Destroy_Torrent(&torrent)
	storage: Torrent_Storage
	defer Destroy_Torrent_Storage(&storage)
	testing.expect_value(t, Torrent_Storage_Open(&storage, &torrent, base), Torrent_Storage_Error.None)
	testing.expect_value(t, Torrent_Storage_Total_Pieces(&storage), u32(2))
	testing.expect_value(t, Torrent_Storage_Write_Piece(&storage, 0, []byte{'a', 'b', 'c', 'd'}), Torrent_Storage_Error.None)
	testing.expect_value(t, Torrent_Storage_Write_Piece(&storage, 1, []byte{'e', 'f', 'g', 'h'}), Torrent_Storage_Error.None)
	testing.expect(t, Torrent_Storage_Has_Piece(&storage, 0) && Torrent_Storage_Has_Piece(&storage, 1))

	read_piece, read_error := Torrent_Storage_Read_Piece(&storage, 0)
	testing.expect_value(t, read_error, Torrent_Storage_Error.None)
	testing.expect(t, bytes_equal(read_piece, []byte{'a', 'b', 'c', 'd'}))
	delete(read_piece)

	cross_file: [5]byte
	testing.expect_value(t, Torrent_Storage_Read(&storage, 2, cross_file[:]), Torrent_Storage_Error.None)
	testing.expect(t, bytes_equal(cross_file[:], []byte{'c', 'd', 'e', 'f', 'g'}))
	testing.expect_value(t, Torrent_Storage_Flush(&storage), Torrent_Storage_Error.None)
	testing.expect_value(t, Torrent_Storage_Close(&storage), Torrent_Storage_Error.None)

	testing.expect_value(t, Torrent_Storage_Open(&storage, &torrent, base), Torrent_Storage_Error.None)
	testing.expect(t, Torrent_Storage_Has_Piece(&storage, 0) && Torrent_Storage_Has_Piece(&storage, 1))
}

@(test)
torrent_storage_resume_location_and_lifecycle_test :: proc(t: ^testing.T) {
	base, base_error := os.make_directory_temp("", "durrent-resume-*", context.allocator)
	testing.expect_value(t, base_error, nil)
	defer os.remove_all(base)
	defer delete(base)

	torrent := storage_test_single_torrent()
	defer Destroy_Torrent(&torrent)
	resume_path, resume_path_error := storage_resume_path(base, torrent.Info_Hash)
	testing.expect_value(t, resume_path_error, Torrent_Storage_Error.None)
	defer delete(resume_path)
	expected_resume_path, expected_resume_path_error := filepath.join({base, ".fatboy", "durrent", "0000000000000000000000000000000000000000.resume"}, context.allocator)
	testing.expect_value(t, expected_resume_path_error, nil)
	defer delete(expected_resume_path)
	testing.expect_value(t, resume_path, expected_resume_path)

	storage: Torrent_Storage
	defer Destroy_Torrent_Storage(&storage)
	testing.expect_value(t, Torrent_Storage_Open(&storage, &torrent, base), Torrent_Storage_Error.None)
	testing.expect_value(t, storage.Resume_Path, resume_path)
	testing.expect(t, os.exists(resume_path))
	testing.expect_value(t, Torrent_Storage_Write_Piece(&storage, 0, []byte{'a', 'b', 'c', 'd'}), Torrent_Storage_Error.None)
	testing.expect_value(t, Torrent_Storage_Close(&storage), Torrent_Storage_Error.None)
	testing.expect(t, os.exists(resume_path))

	testing.expect_value(t, Torrent_Storage_Open(&storage, &torrent, base), Torrent_Storage_Error.None)
	testing.expect_value(t, Torrent_Storage_Write_Piece(&storage, 1, []byte{'e', 'f', 'g', 'h'}), Torrent_Storage_Error.None)
	testing.expect_value(t, Torrent_Storage_Close(&storage), Torrent_Storage_Error.None)
	testing.expect(t, !os.exists(resume_path))
}


@(test)
torrent_storage_multi_file_mapping_test :: proc(t: ^testing.T) {
	base, base_error := os.make_directory_temp("", "durrent-multi-*", context.allocator)
	testing.expect_value(t, base_error, nil)
	defer os.remove_all(base)
	defer delete(base)

	torrent := storage_test_multi_torrent()
	defer Destroy_Torrent(&torrent)
	storage: Torrent_Storage
	defer Destroy_Torrent_Storage(&storage)
	testing.expect_value(t, Torrent_Storage_Open(&storage, &torrent, base), Torrent_Storage_Error.None)
	testing.expect_value(t, Torrent_Storage_Write_Piece(&storage, 0, []byte{'a', 'b', 'c', 'X'}), Torrent_Storage_Error.None)
	testing.expect_value(t, Torrent_Storage_Write_Piece(&storage, 1, []byte{'Y', 'Z', '1', '2'}), Torrent_Storage_Error.None)

	first_path, first_path_error := filepath.join({base, "root", "a.bin"}, context.allocator)
	second_path, second_path_error := filepath.join({base, "root", "dir", "b.bin"}, context.allocator)
	testing.expect_value(t, first_path_error, nil)
	testing.expect_value(t, second_path_error, nil)
	defer delete(first_path)
	defer delete(second_path)
	first, first_error := os.read_entire_file_from_path(first_path, context.allocator)
	second, second_error := os.read_entire_file_from_path(second_path, context.allocator)
	testing.expect_value(t, first_error, nil)
	testing.expect_value(t, second_error, nil)
	defer delete(first)
	defer delete(second)
	testing.expect(t, bytes_equal(first, []byte{'a', 'b', 'c'}))
	testing.expect(t, bytes_equal(second, []byte{'X', 'Y', 'Z', '1', '2'}))
}

@(test)
torrent_storage_rejects_path_collision_test :: proc(t: ^testing.T) {
	base, base_error := os.make_directory_temp("", "durrent-collision-*", context.allocator)
	testing.expect_value(t, base_error, nil)
	defer os.remove_all(base)
	defer delete(base)

	torrent := storage_test_multi_torrent()
	defer Destroy_Torrent(&torrent)
	for component in torrent.Files[1].Path {
		delete(component)
	}
	delete(torrent.Files[1].Path)
	torrent.Files[1].Path = nil
	append(&torrent.Files[1].Path, torrent_test_clone(torrent.Files[0].Path[0]))
	storage: Torrent_Storage
	defer Destroy_Torrent_Storage(&storage)
	testing.expect_value(t, Torrent_Storage_Open(&storage, &torrent, base), Torrent_Storage_Error.Path_Collision)
}
