package durrent

import "core:crypto/hash"
import "core:fmt"
import "core:sync"

Metadata_Piece_Size :: u32(16 * 1024)
Metadata_Default_Max_Size :: u32(16 * 1024 * 1024)

Metadata_Error :: enum {
	None,
	Invalid_Downloader,
	Invalid_State,
	Unsupported,
	Invalid_Message,
	Invalid_Piece,
	Metadata_Too_Large,
	Incomplete,
	Hash_Mismatch,
	Invalid_Metadata,
	Out_Of_Memory,
}

Metadata_Downloader :: struct {
	Mutex:                 sync.Mutex,
	Info_Hash:             Torrent_Hash,
	Max_Size:              u32,
	Metadata_Size:         u32,
	Piece_Count:           u32,
	Received_Count:        u32,
	Remote_Extension_ID:   byte,
	Started:               bool,
	Complete:              bool,
	Data:                  []byte,
	Received:              []bool,
}

Metadata_Downloader_Init :: proc(
	downloader: ^Metadata_Downloader,
	info_hash: Torrent_Hash,
	max_size := Metadata_Default_Max_Size,
) -> Metadata_Error {
	if downloader == nil || max_size == 0 {
		return .Invalid_Downloader
	}
	Metadata_Downloader_Destroy(downloader)
	downloader.Info_Hash = info_hash
	downloader.Max_Size = max_size
	return .None
}

Metadata_Downloader_Destroy :: proc(downloader: ^Metadata_Downloader) {
	if downloader == nil {
		return
	}
	sync.mutex_lock(&downloader.Mutex)
	delete(downloader.Data)
	delete(downloader.Received)
	sync.mutex_unlock(&downloader.Mutex)
	// Keep the mutex object intact. Reset only the non-synchronization state
	// so later cleanup cannot operate on a zeroed synchronization object.
	downloader.Info_Hash = Torrent_Hash{}
	downloader.Max_Size = 0
	downloader.Metadata_Size = 0
	downloader.Piece_Count = 0
	downloader.Received_Count = 0
	downloader.Remote_Extension_ID = 0
	downloader.Started = false
	downloader.Complete = false
	downloader.Data = nil
	downloader.Received = nil
}

Metadata_Downloader_Begin :: proc(downloader: ^Metadata_Downloader, session: ^Peer_Session) -> Metadata_Error {
	if downloader == nil || session == nil {
		return .Invalid_Downloader
	}
	if !Peer_Session_Supports_Extensions(session) {
		return .Unsupported
	}
	sync.mutex_lock(&downloader.Mutex)
	defer sync.mutex_unlock(&downloader.Mutex)
	if downloader.Started {
		return .None
	}
	payload := metadata_handshake_payload()
	error := Peer_Session_Queue_Extended(session, 0, payload)
	delete(payload)
	if error != .None {
		return .Invalid_State if error == .Invalid_State else .Out_Of_Memory
	}
	downloader.Started = true
	return .None
}

Metadata_Downloader_Handle_Event :: proc(
	downloader: ^Metadata_Downloader,
	session: ^Peer_Session,
	event: ^Peer_Event,
) -> Metadata_Error {
	if downloader == nil || session == nil || event == nil {
		return .Invalid_Downloader
	}
	if event.Kind == .Handshake {
		return Metadata_Downloader_Begin(downloader, session)
	}
	if event.Kind != .Extended || len(event.Payload) == 0 {
		return .None
	}
	sync.mutex_lock(&downloader.Mutex)
	defer sync.mutex_unlock(&downloader.Mutex)
	if !downloader.Started {
		return .Invalid_State
	}
	extension_id := event.Payload[0]
	payload := event.Payload[1:]
	if extension_id == 0 {
		handshake_error := metadata_handle_handshake_locked(downloader, session, payload)
		if handshake_error == .None || downloader.Metadata_Size == 0 {
			return handshake_error
		}
		// A few peers have been observed to send their first metadata response
		// with extension id 0. If this is a valid piece, accept it; otherwise
		// preserve the handshake error.
		piece_error := metadata_handle_piece_locked(downloader, payload)
		return .None if piece_error == .None else handshake_error
	}
	if extension_id != downloader.Remote_Extension_ID || downloader.Metadata_Size == 0 {
		if downloader.Metadata_Size > 0 {
			fmt.printf(
				"[DURRENT-META] Probing extended message extension=%d expected=%d bytes=%d\n",
				extension_id,
				downloader.Remote_Extension_ID,
				len(event.Payload),
			)
			// The extension mapping is advisory in practice. Accept a payload
			// only when it is structurally a valid metadata piece, so PEX or
			// other extension traffic is still ignored safely.
			piece_error := metadata_handle_piece_locked(downloader, payload)
			if piece_error == .None {
				return .None
			}
		}
		return .None
	}
	return metadata_handle_piece_locked(downloader, payload)
}

Metadata_Downloader_Is_Complete :: proc(downloader: ^Metadata_Downloader) -> bool {
	if downloader == nil {
		return false
	}
	sync.mutex_lock(&downloader.Mutex)
	defer sync.mutex_unlock(&downloader.Mutex)
	return downloader.Complete
}


Metadata_Downloader_Retry_Missing :: proc(
	downloader: ^Metadata_Downloader,
	session: ^Peer_Session,
) -> Metadata_Error {
	if downloader == nil || session == nil {
		return .Invalid_Downloader
	}
	sync.mutex_lock(&downloader.Mutex)
	defer sync.mutex_unlock(&downloader.Mutex)
	if !downloader.Started || downloader.Metadata_Size == 0 {
		return .Invalid_State
	}
	if downloader.Complete {
		return .None
	}
	return metadata_queue_requests_locked(downloader, session, true)
}


Metadata_Downloader_Finish_Bencoded :: proc(downloader: ^Metadata_Downloader) -> ([]byte, Metadata_Error) {
	if downloader == nil {
		return nil, .Invalid_Downloader
	}
	sync.mutex_lock(&downloader.Mutex)
	if !downloader.Complete {
		sync.mutex_unlock(&downloader.Mutex)
		return nil, .Incomplete
	}
	data, alloc_error := torrent_clone(downloader.Data)
	info_hash := downloader.Info_Hash
	sync.mutex_unlock(&downloader.Mutex)
	if !alloc_error {
		return nil, .Out_Of_Memory
	}

	computed_hash: Torrent_Hash
	hash.hash_bytes_to_buffer(hash.Algorithm.Insecure_SHA1, data, computed_hash[:])
	if computed_hash != info_hash {
		delete(data)
		return nil, .Hash_Mismatch
	}

	metainfo: [dynamic]byte
	prefix := "d4:info"
	append(&metainfo, ..transmute([]byte)prefix)
	append(&metainfo, ..data)
	append(&metainfo, 'e')
	delete(data)
	return metainfo[:], .None
}


Metadata_Downloader_Finish :: proc(downloader: ^Metadata_Downloader) -> (Torrent, Metadata_Error) {
	metainfo, metadata_error := Metadata_Downloader_Finish_Bencoded(downloader)
	if metadata_error != .None {
		return Torrent{}, metadata_error
	}
	torrent, torrent_error := Parse_Torrent(metainfo)
	delete(metainfo)
	if torrent_error != .None {
		return Torrent{}, .Invalid_Metadata
	}
	return torrent, .None
}

metadata_handle_handshake_locked :: proc(
	downloader: ^Metadata_Downloader,
	session: ^Peer_Session,
	payload: []byte,
) -> Metadata_Error {
	handshake, decode_error := Bencode_Decode_Default(payload)
	if decode_error != .None {
		return .Invalid_Message
	}
	defer Destroy_Bencode_Value(&handshake)
	if handshake.Kind != .Dictionary {
		return .Invalid_Message
	}
	mapping := Bencode_Dictionary_Get(&handshake, "m")
	remote_id_value := Bencode_Dictionary_Get(mapping, "ut_metadata")
	remote_id, remote_id_ok := Bencode_As_Integer(remote_id_value)
	if !remote_id_ok || remote_id <= 0 || remote_id > 255 {
		return .Unsupported
	}
	size_value := Bencode_Dictionary_Get(&handshake, "metadata_size")
	size, size_ok := Bencode_As_Integer(size_value)
	if !size_ok || size <= 0 || u64(size) > u64(downloader.Max_Size) {
		return .Metadata_Too_Large if size > 0 else .Invalid_Message
	}
	if downloader.Metadata_Size != 0 {
		if downloader.Metadata_Size != u32(size) || downloader.Remote_Extension_ID != byte(remote_id) {
			return .Invalid_Message
		}
		return .None
	}
	piece_count := u32((u64(size)+u64(Metadata_Piece_Size)-1)/u64(Metadata_Piece_Size))
	data, data_error := make([]byte, int(size), context.allocator)
	received, received_error := make([]bool, int(piece_count), context.allocator)
	if data_error != nil || received_error != nil {
		if data_error == nil {
			delete(data)
		}
		if received_error == nil {
			delete(received)
		}
		return .Out_Of_Memory
	}
	downloader.Data = data
	downloader.Received = received
	downloader.Metadata_Size = u32(size)
	downloader.Piece_Count = piece_count
	downloader.Remote_Extension_ID = byte(remote_id)
	return metadata_queue_requests_locked(downloader, session)
}

metadata_handle_piece_locked :: proc(downloader: ^Metadata_Downloader, payload: []byte) -> Metadata_Error {
	parser := Bencode_Parser{Data = payload, Limits = Bencode_Default_Limits()}
	header, decode_error := bencode_parse_value(&parser, 0)
	if decode_error != .None || header.Kind != .Dictionary || parser.Position > len(payload) {
		return .Invalid_Message
	}
	defer Destroy_Bencode_Value(&header)
	message_type, message_type_ok := Bencode_As_Integer(Bencode_Dictionary_Get(&header, "msg_type"))
	piece, piece_ok := Bencode_As_Integer(Bencode_Dictionary_Get(&header, "piece"))
	if !message_type_ok || !piece_ok || message_type != 1 || piece < 0 || u64(piece) >= u64(downloader.Piece_Count) {
		return .Invalid_Piece
	}
	piece_index := u32(piece)
	start := u64(piece_index) * u64(Metadata_Piece_Size)
	remaining := u64(downloader.Metadata_Size) - start
	expected := int(remaining if remaining < u64(Metadata_Piece_Size) else u64(Metadata_Piece_Size))
	data := payload[parser.Position:]
	if len(data) != expected {
		return .Invalid_Piece
	}
	if downloader.Received[piece_index] {
		return .None if bytes_equal(downloader.Data[int(start):int(start)+expected], data) else .Invalid_Piece
	}
	copy(downloader.Data[int(start):int(start)+expected], data)
	downloader.Received[piece_index] = true
	downloader.Received_Count += 1
	if downloader.Received_Count == downloader.Piece_Count {
		downloader.Complete = true
	}
	return .None
}

metadata_queue_requests_locked :: proc(
	downloader: ^Metadata_Downloader,
	session: ^Peer_Session,
	missing_only := false,
) -> Metadata_Error {
	for piece: u32 = 0; piece < downloader.Piece_Count; piece += 1 {
		if missing_only && downloader.Received[piece] {
			continue
		}
		payload := metadata_request_payload(piece)
		error := Peer_Session_Queue_Extended(session, downloader.Remote_Extension_ID, payload)
		delete(payload)
		if error != .None {
			return .Invalid_State if error == .Invalid_State else .Out_Of_Memory
		}
	}
	return .None
}

metadata_handshake_payload :: proc() -> []byte {
	payload: [dynamic]byte
	append(&payload, 'd', '1', ':', 'm', 'd', '1', '1', ':')
	append(&payload, ..[]byte{'u', 't', '_', 'm', 'e', 't', 'a', 'd', 'a', 't', 'a'})
	append(&payload, 'i', '1', 'e', 'e', 'e')
	return payload[:]
}

metadata_request_payload :: proc(piece: u32) -> []byte {
	payload: [dynamic]byte
	append(&payload, 'd', '8', ':', 'm', 's', 'g', '_', 't', 'y', 'p', 'e', 'i', '0', 'e', '5', ':', 'p', 'i', 'e', 'c', 'e', 'i')
	metadata_append_unsigned(&payload, piece)
	append(&payload, 'e', 'e')
	return payload[:]
}

metadata_append_unsigned :: proc(output: ^[dynamic]byte, value: u32) {
	if output == nil {
		return
	}
	buffer: [10]byte
	position := len(buffer)
	if value == 0 {
		append(output, '0')
		return
	}
	current := value
	for current > 0 {
		position -= 1
		buffer[position] = byte(current%10) + '0'
		current /= 10
	}
	append(output, ..buffer[position:])
}
