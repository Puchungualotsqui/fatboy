package durrent

import "core:encoding/endian"


import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"

Torrent_Storage_Error :: enum {
	None,
	Invalid_Storage,
	Invalid_Torrent,
	Invalid_Path,
	Unsafe_Path,
	Path_Collision,
	Invalid_Offset,
	Invalid_Length,
	Invalid_Piece,
	Piece_Mismatch,
	Not_Open,
	IO,
	Out_Of_Memory,
}

Torrent_Storage_File :: struct {
	Path:   string,
	Offset: u64,
	Length: u64,
	Handle: ^os.File,
}

Torrent_Storage :: struct {
	Mutex:        sync.Mutex,
	Root:         string,
	Resume_Path:  string,
	Files:        [dynamic]Torrent_Storage_File,
	Piece_Hashes: [dynamic]Torrent_Hash,
	Pieces:       Bitfield,
	Piece_Length: u64,
	Total_Length: u64,
	Info_Hash:    Torrent_Hash,
	Open:         bool,
}

Torrent_Storage_Open :: proc(storage: ^Torrent_Storage, torrent: ^Torrent, output_directory: string, verify_existing := true) -> Torrent_Storage_Error {
	if storage == nil || torrent == nil {
		return .Invalid_Storage
	}
	sync.mutex_lock(&storage.Mutex)
	defer sync.mutex_unlock(&storage.Mutex)
	if storage.Open {
		return .Invalid_Storage
	}
	if len(output_directory) == 0 || len(torrent.Name) == 0 || !Torrent_Is_Safe_Path_Component(torrent.Name) || torrent.Piece_Length == 0 || torrent.Piece_Length > u64(0x7fff_ffff_ffff_ffff) {
		return .Invalid_Torrent
	}
	piece_count, piece_count_ok := Piece_Count(torrent.Total_Length, torrent.Piece_Length)
	if !piece_count_ok || piece_count != u32(len(torrent.Piece_Hashes)) {
		return .Invalid_Torrent
	}
	if storage_prepare_directory(output_directory) != .None {
		return .Unsafe_Path
	}

	storage.Piece_Length = torrent.Piece_Length
	storage.Total_Length = torrent.Total_Length
	storage.Info_Hash = torrent.Info_Hash
	storage.Root = strings.clone(output_directory, context.allocator)
	if torrent.Multi_File {
		root, root_error := storage_join({output_directory, string(torrent.Name)})
		if root_error != .None {
			storage_clear_locked(storage)
			return root_error
		}
		delete(storage.Root)
		storage.Root = root
	}
	if storage_prepare_directory(storage.Root) != .None {
		storage_clear_locked(storage)
		return .Unsafe_Path
	}

	resume_name: [dynamic]byte
	append(&resume_name, byte('.'))
	append(&resume_name, ..torrent.Name)
	append(&resume_name, ".durrent.resume")
	resume_path, resume_error := storage_join({output_directory, string(resume_name[:])})
	storage.Resume_Path = resume_path
	delete(resume_name)
	if resume_error != .None {
		storage_clear_locked(storage)
		return resume_error
	}

	if path_error := storage_validate_file_paths(storage.Root, torrent); path_error != .None {
		storage_clear_locked(storage)
		return path_error
	}

	for hash in torrent.Piece_Hashes {
		append(&storage.Piece_Hashes, hash)
	}
	pieces, pieces_error := Bitfield_Init(piece_count)
	if pieces_error != .None {
		storage_clear_locked(storage)
		return .Out_Of_Memory
	}
	storage.Pieces = pieces

	for torrent_file, file_index in torrent.Files {
		if torrent_file.Length > u64(0x7fff_ffff_ffff_ffff) || len(torrent_file.Path) == 0 {
			storage_clear_locked(storage)
			return .Invalid_Torrent
		}
		if !torrent.Multi_File && (len(torrent.Files) != 1 || len(torrent_file.Path) != 1 || !bytes_equal(torrent_file.Path[0], torrent.Name)) {
			storage_clear_locked(storage)
			return .Invalid_Torrent
		}
		if torrent.Multi_File {
			for component in torrent_file.Path {
				if !Torrent_Is_Safe_Path_Component(component) {
					storage_clear_locked(storage)
					return .Unsafe_Path
				}
			}
		}
		path, path_error := storage_file_path(storage.Root, torrent, torrent_file.Path)
		if path_error != .None {
			storage_clear_locked(storage)
			return path_error
		}
		if storage_path_seen(storage.Files, path) {
			delete(path)
			storage_clear_locked(storage)
			return .Path_Collision
		}
		if storage_prepare_file_parent(storage.Root, torrent, torrent_file.Path) != .None {
			delete(path)
			storage_clear_locked(storage)
			return .Unsafe_Path
		}
		if storage_existing_file_is_unsafe(path) {
			delete(path)
			storage_clear_locked(storage)
			return .Unsafe_Path
		}
		handle, open_error := os.open(path, os.O_RDWR|os.O_CREATE)
		if open_error != nil {
			delete(path)
			storage_clear_locked(storage)
			return .IO
		}
		if os.truncate(handle, i64(torrent_file.Length)) != nil {
			os.close(handle)
			delete(path)
			storage_clear_locked(storage)
			return .IO
		}
		append(&storage.Files, Torrent_Storage_File{
			Path = path,
			Offset = 0,
			Length = torrent_file.Length,
			Handle = handle,
		})
		_ = file_index
	}
	storage.Total_Length = 0
	for &file in storage.Files {
		file.Offset = storage.Total_Length
		storage.Total_Length += file.Length
	}
	if storage.Total_Length != torrent.Total_Length {
		storage_clear_locked(storage)
		return .Invalid_Torrent
	}
	storage.Open = true
	storage_load_resume_locked(storage)
	if verify_existing {
		_, verify_error := storage_verify_all_locked(storage)
		if verify_error != .None {
			storage_clear_locked(storage)
			return .IO
		}
	}
	if storage_save_resume_locked(storage) != .None {
		storage_clear_locked(storage)
		return .IO
	}
	return .None
}

Torrent_Storage_Close :: proc(storage: ^Torrent_Storage) -> Torrent_Storage_Error {
	if storage == nil {
		return .Invalid_Storage
	}
	sync.mutex_lock(&storage.Mutex)
	defer sync.mutex_unlock(&storage.Mutex)
	if !storage.Open {
		return .None
	}
	result := storage_flush_locked(storage)
	storage_clear_locked(storage)
	return result
}

Destroy_Torrent_Storage :: proc(storage: ^Torrent_Storage) {
	if storage != nil {
		Torrent_Storage_Close(storage)
	}
}

Torrent_Storage_Flush :: proc(storage: ^Torrent_Storage) -> Torrent_Storage_Error {
	if storage == nil {
		return .Invalid_Storage
	}
	sync.mutex_lock(&storage.Mutex)
	defer sync.mutex_unlock(&storage.Mutex)
	if !storage.Open {
		return .Not_Open
	}
	return storage_flush_locked(storage)
}

Torrent_Storage_Read :: proc(storage: ^Torrent_Storage, offset: u64, destination: []byte) -> Torrent_Storage_Error {
	if storage == nil {
		return .Invalid_Storage
	}
	sync.mutex_lock(&storage.Mutex)
	defer sync.mutex_unlock(&storage.Mutex)
	if !storage.Open {
		return .Not_Open
	}
	return storage_read_locked(storage, offset, destination)
}

Torrent_Storage_Write :: proc(storage: ^Torrent_Storage, offset: u64, data: []byte) -> Torrent_Storage_Error {
	if storage == nil {
		return .Invalid_Storage
	}
	sync.mutex_lock(&storage.Mutex)
	defer sync.mutex_unlock(&storage.Mutex)
	if !storage.Open {
		return .Not_Open
	}
	return storage_write_locked(storage, offset, data)
}

Torrent_Storage_Read_Piece :: proc(storage: ^Torrent_Storage, index: u32) -> ([]byte, Torrent_Storage_Error) {
	if storage == nil {
		return nil, .Invalid_Storage
	}
	sync.mutex_lock(&storage.Mutex)
	defer sync.mutex_unlock(&storage.Mutex)
	if !storage.Open {
		return nil, .Not_Open
	}
	length := Piece_Length(index, storage.Piece_Length, storage.Total_Length)
	if length == 0 && storage.Total_Length != 0 {
		return nil, .Invalid_Piece
	}
	data, alloc_error := make([]byte, int(length), context.allocator)
	if alloc_error != nil {
		return nil, .Out_Of_Memory
	}
	if storage_read_locked(storage, u64(index)*storage.Piece_Length, data) != .None {
		delete(data)
		return nil, .IO
	}
	return data, .None
}

Torrent_Storage_Write_Piece :: proc(storage: ^Torrent_Storage, index: u32, data: []byte) -> Torrent_Storage_Error {
	if storage == nil {
		return .Invalid_Storage
	}
	sync.mutex_lock(&storage.Mutex)
	defer sync.mutex_unlock(&storage.Mutex)
	if !storage.Open {
		return .Not_Open
	}
	length := Piece_Length(index, storage.Piece_Length, storage.Total_Length)
	if length == 0 && storage.Total_Length != 0 || len(data) != int(length) || index >= u32(len(storage.Piece_Hashes)) {
		return .Invalid_Piece
	}
	if !Verify_Piece(data, &storage.Piece_Hashes[index]) {
		Bitfield_Clear_Piece(&storage.Pieces, index)
		return .Piece_Mismatch
	}
	if storage_write_locked(storage, u64(index)*storage.Piece_Length, data) != .None {
		return .IO
	}
	Bitfield_Set_Piece(&storage.Pieces, index)
	return .None
}

Torrent_Storage_Write_Block :: proc(storage: ^Torrent_Storage, index, begin: u32, data: []byte) -> Torrent_Storage_Error {
	if storage == nil {
		return .Invalid_Storage
	}
	sync.mutex_lock(&storage.Mutex)
	defer sync.mutex_unlock(&storage.Mutex)
	if !storage.Open {
		return .Not_Open
	}
	length := Piece_Length(index, storage.Piece_Length, storage.Total_Length)
	if length == 0 && storage.Total_Length != 0 || begin >= length || begin % Block_Size != 0 {
		return .Invalid_Piece
	}
	expected := length - begin
	if expected > u32(Block_Size) {
		expected = u32(Block_Size)
	}
	if len(data) != int(expected) {
		return .Invalid_Length
	}
	return storage_write_locked(storage, u64(index)*storage.Piece_Length+u64(begin), data)
}

Torrent_Storage_Verify_Piece :: proc(storage: ^Torrent_Storage, index: u32) -> (bool, Torrent_Storage_Error) {
	if storage == nil {
		return false, .Invalid_Storage
	}
	sync.mutex_lock(&storage.Mutex)
	defer sync.mutex_unlock(&storage.Mutex)
	if !storage.Open {
		return false, .Not_Open
	}
	return storage_verify_piece_locked(storage, index)
}

Torrent_Storage_Verify_All :: proc(storage: ^Torrent_Storage) -> (u32, Torrent_Storage_Error) {
	if storage == nil {
		return 0, .Invalid_Storage
	}
	sync.mutex_lock(&storage.Mutex)
	defer sync.mutex_unlock(&storage.Mutex)
	if !storage.Open {
		return 0, .Not_Open
	}
	return storage_verify_all_locked(storage)
}

Torrent_Storage_Has_Piece :: proc(storage: ^Torrent_Storage, index: u32) -> bool {
	if storage == nil {
		return false
	}
	sync.mutex_lock(&storage.Mutex)
	defer sync.mutex_unlock(&storage.Mutex)
	return storage.Open && Bitfield_Has_Piece(&storage.Pieces, index)
}

storage_verify_all_locked :: proc(storage: ^Torrent_Storage) -> (u32, Torrent_Storage_Error) {
	count: u32
	for index: u32 = 0; index < u32(len(storage.Piece_Hashes)); index += 1 {
		valid, verify_error := storage_verify_piece_locked(storage, index)
		if verify_error != .None {
			return count, verify_error
		}
		if valid {
			count += 1
		}
	}
	return count, .None
}

storage_verify_piece_locked :: proc(storage: ^Torrent_Storage, index: u32) -> (bool, Torrent_Storage_Error) {
	if index >= u32(len(storage.Piece_Hashes)) {
		return false, .Invalid_Piece
	}
	length := Piece_Length(index, storage.Piece_Length, storage.Total_Length)
	if length == 0 && storage.Total_Length != 0 {
		return false, .Invalid_Piece
	}
	data, alloc_error := make([]byte, int(length), context.allocator)
	if alloc_error != nil {
		return false, .Out_Of_Memory
	}
	defer delete(data)
	if storage_read_locked(storage, u64(index)*storage.Piece_Length, data) != .None {
		return false, .IO
	}
	valid := Verify_Piece(data, &storage.Piece_Hashes[index])
	if valid {
		Bitfield_Set_Piece(&storage.Pieces, index)
	} else {
		Bitfield_Clear_Piece(&storage.Pieces, index)
	}
	return valid, .None
}

storage_read_locked :: proc(storage: ^Torrent_Storage, offset: u64, destination: []byte) -> Torrent_Storage_Error {
	if offset > storage.Total_Length || u64(len(destination)) > storage.Total_Length-offset || offset > u64(0x7fff_ffff_ffff_ffff) {
		return .Invalid_Offset
	}
	position := offset
	written := 0
	for &file in storage.Files {
		if position >= file.Offset+file.Length {
			continue
		}
		local := position-file.Offset
		available := file.Length-local
		amount := min(available, u64(len(destination)-written))
		if amount == 0 {
			break
		}
		n, read_error := os.read_at(file.Handle, destination[written:written+int(amount)], i64(local))
		if read_error != nil || n != int(amount) {
			return .IO
		}
		position += amount
		written += int(amount)
		if written == len(destination) {
			return .None
		}
	}
	return .None if written == len(destination) else .IO
}

storage_write_locked :: proc(storage: ^Torrent_Storage, offset: u64, data: []byte) -> Torrent_Storage_Error {
	if offset > storage.Total_Length || u64(len(data)) > storage.Total_Length-offset || offset > u64(0x7fff_ffff_ffff_ffff) {
		return .Invalid_Offset
	}
	position := offset
	written := 0
	for &file in storage.Files {
		if position >= file.Offset+file.Length {
			continue
		}
		local := position-file.Offset
		available := file.Length-local
		amount := min(available, u64(len(data)-written))
		if amount == 0 {
			break
		}
		n, write_error := os.write_at(file.Handle, data[written:written+int(amount)], i64(local))
		if write_error != nil || n != int(amount) {
			return .IO
		}
		position += amount
		written += int(amount)
		if written == len(data) {
			return .None
		}
	}
	return .None if written == len(data) else .IO
}

storage_flush_locked :: proc(storage: ^Torrent_Storage) -> Torrent_Storage_Error {
	for file in storage.Files {
		if os.flush(file.Handle) != nil || os.sync(file.Handle) != nil {
			return .IO
		}
	}
	return storage_save_resume_locked(storage)
}

storage_save_resume_locked :: proc(storage: ^Torrent_Storage) -> Torrent_Storage_Error {
	if len(storage.Resume_Path) == 0 {
		return .Invalid_Path
	}
	data: [dynamic]byte
	append(&data, "DURRRES1")
	append(&data, ..storage.Info_Hash[:])
	piece_count: [4]byte
	endian.put_u32(piece_count[:], .Big, storage.Pieces.Piece_Count)
	append(&data, ..piece_count[:])
	append(&data, ..storage.Pieces.Bytes)
	temporary, temporary_error := strings.concatenate({storage.Resume_Path, ".tmp"}, context.allocator)
	if temporary_error != nil {
		delete(data)
		return .Out_Of_Memory
	}
	defer delete(temporary)
	if os.write_entire_file(temporary, data[:]) != nil {
		delete(data)
		return .IO
	}
	delete(data)
	if os.rename(temporary, storage.Resume_Path) != nil {
		os.remove(temporary)
		return .IO
	}
	return .None
}

storage_load_resume_locked :: proc(storage: ^Torrent_Storage) {
	data, read_error := os.read_entire_file_from_path(storage.Resume_Path, context.allocator)
	if read_error != nil {
		return
	}
	defer delete(data)
	minimum := 8 + 20 + 4
	if len(data) < minimum || !bytes_equal(data[:8], []byte{'D', 'U', 'R', 'R', 'R', 'E', 'S', '1'}) || !bytes_equal(data[8:28], storage.Info_Hash[:]) {
		return
	}
	piece_count, piece_count_ok := endian.get_u32(data[28:32], .Big)
	if !piece_count_ok || piece_count != storage.Pieces.Piece_Count {
		return
	}
	loaded, loaded_error := Bitfield_From_Raw(data[32:], piece_count)
	if loaded_error != .None {
		return
	}
	Destroy_Bitfield(&storage.Pieces)
	storage.Pieces = loaded
}

storage_validate_file_paths :: proc(root: string, torrent: ^Torrent) -> Torrent_Storage_Error {
	for file_index := 0; file_index < len(torrent.Files); file_index += 1 {
		path, path_error := storage_file_path(root, torrent, torrent.Files[file_index].Path)
		if path_error != .None {
			return path_error
		}
		for previous_index := 0; previous_index < file_index; previous_index += 1 {
			previous, previous_error := storage_file_path(root, torrent, torrent.Files[previous_index].Path)
			if previous_error != .None {
				delete(path)
				return previous_error
			}
			collision := previous == path
			delete(previous)
			if collision {
				delete(path)
				return .Path_Collision
			}
		}
		delete(path)
	}
	return .None
}

storage_file_path :: proc(root: string, torrent: ^Torrent, path: [dynamic][]byte) -> (string, Torrent_Storage_Error) {
	parts: [dynamic]string
	append(&parts, root)
	for component in path {
		append(&parts, string(component))
	}
	defer delete(parts)
	return storage_join(parts[:])
}

storage_prepare_file_parent :: proc(root: string, torrent: ^Torrent, path: [dynamic][]byte) -> Torrent_Storage_Error {
	parts: [dynamic]string
	append(&parts, root)
	for index := 0; index+1 < len(path); index += 1 {
		append(&parts, string(path[index]))
	}
	current, current_error := storage_join(parts[:])
	delete(parts)
	if current_error != .None {
		return current_error
	}
	defer delete(current)
	return storage_prepare_directory(current)
}

storage_prepare_directory :: proc(path: string) -> Torrent_Storage_Error {
	info, info_error := os.lstat(path, context.temp_allocator)
	if info_error == nil {
		defer os.file_info_delete(info, context.temp_allocator)
		return .None if info.type == .Directory else .Unsafe_Path
	}
	if info_error != .Not_Exist {
		return .IO
	}
	return .None if os.make_directory_all(path) == nil else .IO
}

storage_existing_file_is_unsafe :: proc(path: string) -> bool {
	info, info_error := os.lstat(path, context.temp_allocator)
	if info_error == .Not_Exist {
		return false
	}
	if info_error != nil {
		return true
	}
	defer os.file_info_delete(info, context.temp_allocator)
	return info.type != .Regular
}

storage_join :: proc(parts: []string) -> (string, Torrent_Storage_Error) {
	if len(parts) == 0 {
		return "", .Invalid_Path
	}
	path, join_error := filepath.join(parts, context.allocator)
	if join_error != nil {
		return "", .Invalid_Path
	}
	return path, .None
}

storage_path_seen :: proc(files: [dynamic]Torrent_Storage_File, path: string) -> bool {
	for file in files {
		if file.Path == path {
			return true
		}
	}
	return false
}

storage_clear_locked :: proc(storage: ^Torrent_Storage) {
	for &file in storage.Files {
		if file.Handle != nil {
			os.close(file.Handle)
		}
		delete(file.Path)
	}
	delete(storage.Files)
	delete(storage.Piece_Hashes)
	Destroy_Bitfield(&storage.Pieces)
	delete(storage.Root)
	delete(storage.Resume_Path)
	storage.Files = nil
	storage.Piece_Hashes = nil
	storage.Pieces = Bitfield{}
	storage.Root = ""
	storage.Resume_Path = ""
	storage.Piece_Length = 0
	storage.Total_Length = 0
	storage.Info_Hash = Torrent_Hash{}
	storage.Open = false
}

Torrent_Storage_Total_Pieces :: proc(storage: ^Torrent_Storage) -> u32 {
	if storage == nil {
		return 0
	}
	sync.mutex_lock(&storage.Mutex)
	defer sync.mutex_unlock(&storage.Mutex)
	return storage.Pieces.Piece_Count if storage.Open else 0
}

Torrent_Storage_Total_Length :: proc(storage: ^Torrent_Storage) -> u64 {
	if storage == nil {
		return 0
	}
	sync.mutex_lock(&storage.Mutex)
	defer sync.mutex_unlock(&storage.Mutex)
	return storage.Total_Length if storage.Open else 0
}

Torrent_Storage_File_Offset :: proc(storage: ^Torrent_Storage, index: int) -> (u64, bool) {
	if storage == nil {
		return 0, false
	}
	sync.mutex_lock(&storage.Mutex)
	defer sync.mutex_unlock(&storage.Mutex)
	if !storage.Open || index < 0 || index >= len(storage.Files) {
		return 0, false
	}
	return storage.Files[index].Offset, true
}
