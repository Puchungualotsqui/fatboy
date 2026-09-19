package durrent

import "core:testing"

metadata_test_torrent :: proc() -> Torrent {
	data: [dynamic]byte
	prefix := "d4:infod6:lengthi4e4:name4:test12:piece lengthi4e6:pieces20:"
	append(&data, ..transmute([]byte)prefix)
	for i := 0; i < 20; i += 1 {
		append(&data, byte(0))
	}
	append(&data, 'e', 'e')
	torrent, torrent_error := Parse_Torrent(data[:])
	delete(data)
	if torrent_error != .None {
		return Torrent{}
	}
	return torrent
}

metadata_test_session :: proc(info_hash: Torrent_Hash) -> Peer_Session {
	peer_id: [20]byte
	peer_id[0] = 0x50
	peer_id[1] = 0x45
	session: Peer_Session
	Peer_Session_Init(&session, info_hash, peer_id, 1, 4, 4)
	Peer_Session_Begin(&session)
	output, _ := Peer_Session_Take_Output(&session)
	delete(output)
	remote := Wire_Handshake{Info_Hash = info_hash, Peer_ID = peer_id}
	remote.Reserved[5] = 0x10
	encoded := Wire_Handshake_Serialize(remote)
	Peer_Session_Feed(&session, encoded[:])
	return session
}

metadata_test_handshake :: proc(size: u32) -> []byte {
	payload: [dynamic]byte
	append(&payload, 'd', '1', ':', 'm', 'd', '1', '1', ':')
	append(&payload, ..[]byte{'u', 't', '_', 'm', 'e', 't', 'a', 'd', 'a', 't', 'a'})
	append(&payload, 'i', '3', 'e', 'e', '1', '3', ':', 'm', 'e', 't', 'a', 'd', 'a', 't', 'a', '_', 's', 'i', 'z', 'e', 'i')
	metadata_append_unsigned(&payload, size)
	append(&payload, 'e', 'e')
	return payload[:]
}

metadata_test_piece :: proc(data: []byte) -> []byte {
	payload: [dynamic]byte
	append(&payload, 'd', '8', ':', 'm', 's', 'g', '_', 't', 'y', 'p', 'e', 'i', '1', 'e', '5', ':', 'p', 'i', 'e', 'c', 'e', 'i', '0', 'e', 'e')
	append(&payload, ..data)
	return payload[:]
}

metadata_test_frame :: proc(extension_id: byte, payload: []byte) -> []byte {
	wire_payload: [dynamic]byte
	append(&wire_payload, extension_id)
	append(&wire_payload, ..payload)
	frame, _ := Wire_Message_Encode(Wire_Message_View{Kind = .Extended, Payload = wire_payload[:]})
	delete(wire_payload)
	return frame
}

@(test)
metadata_exchange_assembly_and_hash_test :: proc(t: ^testing.T) {
	torrent := metadata_test_torrent()
	defer Destroy_Torrent(&torrent)
	session := metadata_test_session(torrent.Info_Hash)
	defer Destroy_Peer_Session(&session)
	downloader: Metadata_Downloader
	defer Metadata_Downloader_Destroy(&downloader)
	testing.expect_value(t, Metadata_Downloader_Init(&downloader, torrent.Info_Hash), Metadata_Error.None)

	event, event_ok := Peer_Session_Next_Event(&session)
	testing.expect(t, event_ok)
	testing.expect_value(t, event.Kind, Peer_Event_Kind.Handshake)
	testing.expect_value(t, Metadata_Downloader_Handle_Event(&downloader, &session, &event), Metadata_Error.None)
	Destroy_Peer_Event(&event)
	output, output_error := Peer_Session_Take_Output(&session)
	testing.expect_value(t, output_error, Peer_Error.None)
	initial, initial_error := Wire_Message_Parse(output)
	testing.expect_value(t, initial_error, Wire_Error.None)
	testing.expect_value(t, initial.Message.Kind, Wire_Message_Kind.Extended)
	testing.expect_value(t, initial.Message.Payload[0], byte(0))
	delete(output)

	handshake_payload := metadata_test_handshake(u32(len(torrent.Info_Bytes)))
	frame := metadata_test_frame(0, handshake_payload)
	delete(handshake_payload)
	testing.expect_value(t, Peer_Session_Feed(&session, frame), Peer_Error.None)
	delete(frame)
	event, event_ok = Peer_Session_Next_Event(&session)
	testing.expect(t, event_ok)
	testing.expect_value(t, event.Kind, Peer_Event_Kind.Extended)
	testing.expect_value(t, Metadata_Downloader_Handle_Event(&downloader, &session, &event), Metadata_Error.None)
	Destroy_Peer_Event(&event)

	output, output_error = Peer_Session_Take_Output(&session)
	testing.expect_value(t, output_error, Peer_Error.None)
	request, request_error := Wire_Message_Parse(output)
	testing.expect_value(t, request_error, Wire_Error.None)
	testing.expect_value(t, request.Message.Payload[0], byte(3))
	request_header, request_decode_error := Bencode_Decode_Default(request.Message.Payload[1:])
	testing.expect_value(t, request_decode_error, Bencode_Error.None)
	testing.expect_value(t, request_header.Kind, Bencode_Kind.Dictionary)
	request_type, request_type_ok := Bencode_As_Integer(Bencode_Dictionary_Get(&request_header, "msg_type"))
	testing.expect(t, request_type_ok)
	testing.expect_value(t, request_type, i64(0))
	Destroy_Bencode_Value(&request_header)
	delete(output)

	piece_payload := metadata_test_piece(torrent.Info_Bytes)
	frame = metadata_test_frame(3, piece_payload)
	delete(piece_payload)
	testing.expect_value(t, Peer_Session_Feed(&session, frame), Peer_Error.None)
	delete(frame)
	event, event_ok = Peer_Session_Next_Event(&session)
	testing.expect(t, event_ok)
	testing.expect_value(t, Metadata_Downloader_Handle_Event(&downloader, &session, &event), Metadata_Error.None)
	Destroy_Peer_Event(&event)
	testing.expect(t, Metadata_Downloader_Is_Complete(&downloader))

	result, finish_error := Metadata_Downloader_Finish(&downloader)
	testing.expect_value(t, finish_error, Metadata_Error.None)
	testing.expect(t, result.Info_Hash == torrent.Info_Hash)
	Destroy_Torrent(&result)

	bad_hash: Torrent_Hash
	downloader.Info_Hash = bad_hash
	_, finish_error = Metadata_Downloader_Finish(&downloader)
	testing.expect_value(t, finish_error, Metadata_Error.Hash_Mismatch)
}

@(test)
metadata_rejects_size_limit_test :: proc(t: ^testing.T) {
	info_hash: Torrent_Hash
	session := metadata_test_session(info_hash)
	defer Destroy_Peer_Session(&session)
	downloader: Metadata_Downloader
	defer Metadata_Downloader_Destroy(&downloader)
	testing.expect_value(t, Metadata_Downloader_Init(&downloader, info_hash, 8), Metadata_Error.None)
	event, event_ok := Peer_Session_Next_Event(&session)
	testing.expect(t, event_ok)
	testing.expect_value(t, Metadata_Downloader_Handle_Event(&downloader, &session, &event), Metadata_Error.None)
	Destroy_Peer_Event(&event)

	payload := metadata_test_handshake(9)
	frame := metadata_test_frame(0, payload)
	delete(payload)
	testing.expect_value(t, Peer_Session_Feed(&session, frame), Peer_Error.None)
	delete(frame)
	event, event_ok = Peer_Session_Next_Event(&session)
	testing.expect(t, event_ok)
	testing.expect_value(t, Metadata_Downloader_Handle_Event(&downloader, &session, &event), Metadata_Error.Metadata_Too_Large)
	Destroy_Peer_Event(&event)
}
