package durrent

import "core:crypto/hash"

Torrent_Hash :: [20]byte

Torrent_File :: struct {
	Length: u64,
	Path:   [dynamic][]byte,
}

Torrent_Tracker_Tier :: struct {
	URLs: [dynamic][]byte,
}

// Torrent owns all byte slices and dynamic arrays reachable from it. The
// Info_Bytes field is the ordered bencoded info dictionary used to calculate
// Info_Hash; it must not be rebuilt from an unordered map.
Torrent :: struct {
	Announce:       []byte,
	Announce_List:  [dynamic]Torrent_Tracker_Tier,
	Name:           []byte,
	Piece_Length:   u64,
	Piece_Hashes:   [dynamic]Torrent_Hash,
	Files:          [dynamic]Torrent_File,
	Multi_File:     bool,
	Total_Length:   u64,
	Comment:        []byte,
	Has_Comment:    bool,
	Creation_Date:  i64,
	Has_Creation_Date: bool,
	Created_By:     []byte,
	Info_Bytes:     []byte,
	Info_Hash:      Torrent_Hash,
	URL_List:       [dynamic][]byte,
}

Torrent_Error :: enum {
	None,
	Invalid_Bencode,
	Missing_Field,
	Invalid_Field,
	Unsafe_Path,
	Out_Of_Memory,
}

Destroy_Torrent :: proc(torrent: ^Torrent) {
	if torrent == nil {
		return
	}

	delete(torrent.Announce)
	delete(torrent.Name)
	delete(torrent.Comment)
	delete(torrent.Created_By)
	delete(torrent.Info_Bytes)

	for i := 0; i < len(torrent.Announce_List); i += 1 {
		for url in torrent.Announce_List[i].URLs {
			delete(url)
		}
		delete(torrent.Announce_List[i].URLs)
	}
	delete(torrent.Announce_List)

	for i := 0; i < len(torrent.Files); i += 1 {
		for path_component in torrent.Files[i].Path {
			delete(path_component)
		}
		delete(torrent.Files[i].Path)
	}
	delete(torrent.Files)

	for url in torrent.URL_List {
		delete(url)
	}
	delete(torrent.URL_List)

	delete(torrent.Piece_Hashes)
	torrent^ = Torrent{}
}

Parse_Torrent :: proc(data: []byte) -> (Torrent, Torrent_Error) {
	root, bencode_error := Bencode_Decode_Default(data)
	if bencode_error != .None {
		return Torrent{}, .Invalid_Bencode
	}
	defer Destroy_Bencode_Value(&root)

	result: Torrent
	info := Bencode_Dictionary_Get(&root, "info")
	if info == nil || info.Kind != .Dictionary {
		return result, .Missing_Field
	}

	announce := Bencode_Dictionary_Get(&root, "announce")
	if announce != nil {
		if announce.Kind != .String {
			return result, .Invalid_Field
		}
		announce_copy, announce_ok := torrent_clone(announce.String)
		if !announce_ok {
			Destroy_Torrent(&result)
			return Torrent{}, .Out_Of_Memory
		}
		result.Announce = announce_copy
	}
	if result.Announce == nil {
		announce_copy, announce_ok := torrent_clone([]byte{})
		if !announce_ok {
			Destroy_Torrent(&result)
			return Torrent{}, .Out_Of_Memory
		}
		result.Announce = announce_copy
	}

	announce_list := Bencode_Dictionary_Get(&root, "announce-list")
	if announce_list != nil {
		if announce_list.Kind != .List {
			Destroy_Torrent(&result)
			return Torrent{}, .Invalid_Field
		}
		for tier_index := 0; tier_index < len(announce_list.List); tier_index += 1 {
			tier_value := &announce_list.List[tier_index]
			if tier_value.Kind != .List {
				continue
			}
			tier: Torrent_Tracker_Tier
			for url_index := 0; url_index < len(tier_value.List); url_index += 1 {
				url_value := &tier_value.List[url_index]
				if url_value.Kind != .String {
					continue
				}
				url, ok := torrent_clone(url_value.String)
				if !ok {
					delete(tier.URLs)
					Destroy_Torrent(&result)
					return Torrent{}, .Out_Of_Memory
				}
				append(&tier.URLs, url)
			}
			append(&result.Announce_List, tier)
		}
	}
	if len(result.Announce) == 0 && len(result.Announce_List) > 0 && len(result.Announce_List[0].URLs) > 0 {
		delete(result.Announce)
		announce_copy, announce_ok := torrent_clone(result.Announce_List[0].URLs[0])
		if !announce_ok {
			Destroy_Torrent(&result)
			return Torrent{}, .Out_Of_Memory
		}
		result.Announce = announce_copy
	}

	name_value := Bencode_Dictionary_Get(info, "name")
	if name_value == nil || name_value.Kind != .String || len(name_value.String) == 0 {
		Destroy_Torrent(&result)
		return Torrent{}, .Missing_Field
	}
	if !Torrent_Is_Safe_Path_Component(name_value.String) {
		Destroy_Torrent(&result)
		return Torrent{}, .Unsafe_Path
	}
	name_copy, name_ok := torrent_clone(name_value.String)
	if !name_ok {
		Destroy_Torrent(&result)
		return Torrent{}, .Out_Of_Memory
	}
	result.Name = name_copy

	piece_length_value := Bencode_Dictionary_Get(info, "piece length")
	piece_length, piece_length_ok := torrent_non_negative_integer(piece_length_value)
	if !piece_length_ok || piece_length == 0 {
		Destroy_Torrent(&result)
		return Torrent{}, .Invalid_Field
	}
	result.Piece_Length = piece_length

	pieces_value := Bencode_Dictionary_Get(info, "pieces")
	if pieces_value == nil || pieces_value.Kind != .String || len(pieces_value.String) % 20 != 0 {
		Destroy_Torrent(&result)
		return Torrent{}, .Invalid_Field
	}
	for piece_position := 0; piece_position < len(pieces_value.String); piece_position += 20 {
		piece_hash: Torrent_Hash
		copy(piece_hash[:], pieces_value.String[piece_position:piece_position+20])
		append(&result.Piece_Hashes, piece_hash)
	}

	files_value := Bencode_Dictionary_Get(info, "files")
	length_value := Bencode_Dictionary_Get(info, "length")
	if files_value != nil && length_value != nil {
		Destroy_Torrent(&result)
		return Torrent{}, .Invalid_Field
	}
	if files_value != nil {
		result.Multi_File = true
		if files_value.Kind != .List || len(files_value.List) == 0 {
			Destroy_Torrent(&result)
			return Torrent{}, .Invalid_Field
		}
		for file_index := 0; file_index < len(files_value.List); file_index += 1 {
			file_value := &files_value.List[file_index]
			if file_value.Kind != .Dictionary {
				Destroy_Torrent(&result)
				return Torrent{}, .Invalid_Field
			}
			file_length_value := Bencode_Dictionary_Get(file_value, "length")
			file_length, file_length_ok := torrent_non_negative_integer(file_length_value)
			if !file_length_ok || result.Total_Length > u64_max - file_length {
				Destroy_Torrent(&result)
				return Torrent{}, .Invalid_Field
			}
			path_value := Bencode_Dictionary_Get(file_value, "path")
			if path_value == nil || path_value.Kind != .List || len(path_value.List) == 0 {
				Destroy_Torrent(&result)
				return Torrent{}, .Invalid_Field
			}

			file: Torrent_File
			file.Length = file_length
			for path_index := 0; path_index < len(path_value.List); path_index += 1 {
				component_value := &path_value.List[path_index]
				if component_value.Kind != .String || !Torrent_Is_Safe_Path_Component(component_value.String) {
					for component in file.Path {
						delete(component)
					}
					delete(file.Path)
					Destroy_Torrent(&result)
					return Torrent{}, .Unsafe_Path
				}
				component, ok := torrent_clone(component_value.String)
				if !ok {
					for existing in file.Path {
						delete(existing)
					}
					delete(file.Path)
					Destroy_Torrent(&result)
					return Torrent{}, .Out_Of_Memory
				}
				append(&file.Path, component)
			}
			append(&result.Files, file)
			result.Total_Length += file_length
		}
	} else {
		file_length, file_length_ok := torrent_non_negative_integer(length_value)
		if !file_length_ok {
			Destroy_Torrent(&result)
			return Torrent{}, .Missing_Field
		}
		file: Torrent_File
		file.Length = file_length
		name_copy, name_ok := torrent_clone(result.Name)
		if !name_ok {
			Destroy_Torrent(&result)
			return Torrent{}, .Out_Of_Memory
		}
		append(&file.Path, name_copy)
		append(&result.Files, file)
		result.Total_Length = file_length
	}

	expected_piece_count, piece_count_ok := Piece_Count(result.Total_Length, result.Piece_Length)
	if !piece_count_ok || expected_piece_count != u32(len(result.Piece_Hashes)) {
		Destroy_Torrent(&result)
		return Torrent{}, .Invalid_Field
	}

	result.Info_Bytes = Bencode_Encode(info)
	if result.Info_Bytes == nil {
		Destroy_Torrent(&result)
		return Torrent{}, .Out_Of_Memory
	}
	hash.hash_bytes_to_buffer(hash.Algorithm.Insecure_SHA1, result.Info_Bytes, result.Info_Hash[:])

	comment := Bencode_Dictionary_Get(&root, "comment")
	if comment != nil {
		if comment.Kind != .String {
			Destroy_Torrent(&result)
			return Torrent{}, .Invalid_Field
		}
		comment_copy, comment_ok := torrent_clone(comment.String)
		if !comment_ok {
			Destroy_Torrent(&result)
			return Torrent{}, .Out_Of_Memory
		}
		result.Comment = comment_copy
		result.Has_Comment = true
	}

	creation_date := Bencode_Dictionary_Get(&root, "creation date")
	if creation_date != nil {
		if creation_date.Kind != .Integer {
			Destroy_Torrent(&result)
			return Torrent{}, .Invalid_Field
		}
		result.Creation_Date = creation_date.Integer
		result.Has_Creation_Date = true
	}

	created_by := Bencode_Dictionary_Get(&root, "created by")
	if created_by != nil {
		if created_by.Kind != .String {
			Destroy_Torrent(&result)
			return Torrent{}, .Invalid_Field
		}
		created_by_copy, created_by_ok := torrent_clone(created_by.String)
		if !created_by_ok {
			Destroy_Torrent(&result)
			return Torrent{}, .Out_Of_Memory
		}
		result.Created_By = created_by_copy
	}

	url_list := Bencode_Dictionary_Get(&root, "url-list")
	if url_list != nil {
		switch url_list.Kind {
		case .String:
			url, url_ok := torrent_clone(url_list.String)
			if !url_ok {
				Destroy_Torrent(&result)
				return Torrent{}, .Out_Of_Memory
			}
			append(&result.URL_List, url)
		case .List:
			for i := 0; i < len(url_list.List); i += 1 {
				url_value := &url_list.List[i]
				if url_value.Kind != .String {
					continue
				}
				url, url_ok := torrent_clone(url_value.String)
				if !url_ok {
					Destroy_Torrent(&result)
					return Torrent{}, .Out_Of_Memory
				}
				append(&result.URL_List, url)
			}
		case .Integer:
			{}
		case .Dictionary:
			{}
		case:
			Destroy_Torrent(&result)
			return Torrent{}, .Invalid_Field
		}
	}

	return result, .None
}

Torrent_Is_Safe_Path_Component :: proc(component: []byte) -> bool {
	if len(component) == 0 || bytes_equal(component, []byte{'.'}) || bytes_equal(component, []byte{'.', '.'}) {
		return false
	}
	if component[0] == '/' || component[0] == '\\' || component[len(component)-1] == '.' || component[len(component)-1] == ' ' {
		return false
	}
	for c in component {
		if c < 0x20 || c == '/' || c == '\\' || c == 0 || c == ':' || c == '<' || c == '>' || c == '"' || c == '|' || c == '?' || c == '*' {
			return false
		}
	}
	return !torrent_is_reserved_windows_device(component)
}

torrent_is_reserved_windows_device :: proc(component: []byte) -> bool {
	base_length := len(component)
	for i := 0; i < len(component); i += 1 {
		if component[i] == '.' {
			base_length = i
			break
		}
	}
	if base_length == 3 {
		if torrent_ascii_equal_ignore_case(component[:base_length], []byte{'C', 'O', 'N'}) ||
			torrent_ascii_equal_ignore_case(component[:base_length], []byte{'P', 'R', 'N'}) ||
			torrent_ascii_equal_ignore_case(component[:base_length], []byte{'A', 'U', 'X'}) ||
			torrent_ascii_equal_ignore_case(component[:base_length], []byte{'N', 'U', 'L'}) {
			return true
		}
	}
	if base_length == 4 &&
		(torrent_ascii_equal_ignore_case(component[:3], []byte{'C', 'O', 'M'}) || torrent_ascii_equal_ignore_case(component[:3], []byte{'L', 'P', 'T'})) &&
		component[3] >= '1' && component[3] <= '9' {
		return true
	}
	return false
}

torrent_ascii_equal_ignore_case :: proc(a, b: []byte) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i := 0; i < len(a); i += 1 {
		left := a[i]
		right := b[i]
		if left >= 'a' && left <= 'z' {
			left -= 'a' - 'A'
		}
		if right >= 'a' && right <= 'z' {
			right -= 'a' - 'A'
		}
		if left != right {
			return false
		}
	}
	return true
}

torrent_non_negative_integer :: proc(value: ^Bencode_Value) -> (u64, bool) {
	if value == nil || value.Kind != .Integer || value.Integer < 0 {
		return 0, false
	}
	return u64(value.Integer), true
}

torrent_clone :: proc(source: []byte) -> ([]byte, bool) {
	result, alloc_error := make([]byte, len(source), context.allocator)
	if alloc_error != nil {
		return nil, false
	}
	copy(result, source)
	return result, true
}

u64_max :: u64(18446744073709551615)
