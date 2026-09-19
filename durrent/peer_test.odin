package durrent

import "core:testing"


peer_test_hash :: Torrent_Hash{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19}

peer_test_session :: proc() -> Peer_Session {
	peer_id: [20]byte
	peer_id[0] = 0x2d
	peer_id[1] = 0x44
	session: Peer_Session
	Peer_Session_Init(&session, peer_test_hash, peer_id, 4, 4, 16)
	return session
}

peer_test_remote_handshake :: proc() -> [Handshake_Length]byte {
	peer_id: [20]byte
	peer_id[0] = 0x50
	peer_id[1] = 0x45
	peer_id[2] = 0x45
	peer_id[3] = 0x52
	return Wire_Handshake_Serialize(Wire_Handshake{
		Info_Hash = peer_test_hash,
		Peer_ID = peer_id,
	})
}

peer_test_append_wire :: proc(buffer: ^[dynamic]byte, message: Wire_Message_View) -> bool {
	encoded, encode_error := Wire_Message_Encode(message)
	if encode_error != .None {
		return false
	}
	append(buffer, ..encoded)
	delete(encoded)
	return true
}

@(test)
peer_handshake_and_fragmented_messages_test :: proc(t: ^testing.T) {
	session := peer_test_session()
	defer Destroy_Peer_Session(&session)
	testing.expect_value(t, Peer_Session_Begin(&session), Peer_Error.None)
	output, output_error := Peer_Session_Take_Output(&session)
	testing.expect_value(t, output_error, Peer_Error.None)
	testing.expect_value(t, len(output), Handshake_Length)
	delete(output)

	handshake := peer_test_remote_handshake()
	testing.expect_value(t, Peer_Session_Feed(&session, handshake[:10]), Peer_Error.None)
	testing.expect_value(t, session.State, Peer_State.Handshaking)
	testing.expect_value(t, Peer_Session_Feed(&session, handshake[10:]), Peer_Error.None)
	testing.expect_value(t, session.State, Peer_State.Ready)
	event, event_ok := Peer_Session_Next_Event(&session)
	testing.expect(t, event_ok)
	testing.expect_value(t, event.Kind, Peer_Event_Kind.Handshake)
	Destroy_Peer_Event(&event)

	wire: [dynamic]byte
	testing.expect(t, peer_test_append_wire(&wire, Wire_Message_View{Kind = .Unchoke}))
	testing.expect(t, peer_test_append_wire(&wire, Wire_Message_View{Kind = .Bitfield, Payload = []byte{0xc0}}))
	testing.expect(t, peer_test_append_wire(&wire, Wire_Message_View{Kind = .Have, Index = 2}))
	testing.expect(t, peer_test_append_wire(&wire, Wire_Message_View{Kind = .Interested}))
	testing.expect(t, peer_test_append_wire(&wire, Wire_Message_View{Kind = .Keep_Alive}))
	testing.expect_value(t, Peer_Session_Feed(&session, wire[:]), Peer_Error.None)
	delete(wire)
	testing.expect(t, !session.Remote_Choking)
	testing.expect(t, session.Remote_Interested)
	testing.expect(t, Peer_Session_Remote_Has_Piece(&session, 0))
	testing.expect(t, Peer_Session_Remote_Has_Piece(&session, 2))

	testing.expect_value(t, Peer_Session_Queue_Request(&session, 0, 0, 4), Peer_Error.None)
	request, request_error := Peer_Session_Take_Output(&session)
	testing.expect_value(t, request_error, Peer_Error.None)
	parsed_request, parsed_request_error := Wire_Message_Parse(request)
	delete(request)
	testing.expect_value(t, parsed_request_error, Wire_Error.None)
	testing.expect_value(t, parsed_request.Message.Kind, Wire_Message_Kind.Request)
	testing.expect_value(t, parsed_request.Message.Index, u32(0))
}

@(test)
peer_piece_request_and_event_test :: proc(t: ^testing.T) {
	session := peer_test_session()
	defer Destroy_Peer_Session(&session)
	Peer_Session_Begin(&session)
	handshake := peer_test_remote_handshake()
	Peer_Session_Feed(&session, handshake[:])
	Peer_Session_Queue_Interested(&session, true)
	peer_test_take_all_events(&session)

	unchoke: [dynamic]byte
	testing.expect(t, peer_test_append_wire(&unchoke, Wire_Message_View{Kind = .Unchoke}))
	testing.expect_value(t, Peer_Session_Feed(&session, unchoke[:]), Peer_Error.None)
	delete(unchoke)
	testing.expect_value(t, Peer_Session_Queue_Request(&session, 0, 0, 4), Peer_Error.None)
	testing.expect_value(t, Peer_Session_Queue_Cancel(&session, 0, 0, 4), Peer_Error.None)

	piece: [dynamic]byte
	testing.expect(t, peer_test_append_wire(&piece, Wire_Message_View{
		Kind = .Piece,
		Index = 0,
		Begin = 0,
		Payload = []byte{'t', 'e', 's', 't'},
	}))
	testing.expect_value(t, Peer_Session_Feed(&session, piece[:]), Peer_Error.None)
	delete(piece)
	found_piece := false
	for {
		event, event_ok := Peer_Session_Next_Event(&session)
		if !event_ok {
			break
		}
		if event.Kind == .Piece {
			found_piece = bytes_equal(event.Payload, []byte{'t', 'e', 's', 't'})
		}
		Destroy_Peer_Event(&event)
	}
	testing.expect(t, found_piece)
}

@(test)
peer_invalid_handshake_and_piece_test :: proc(t: ^testing.T) {
	session := peer_test_session()
	defer Destroy_Peer_Session(&session)
	Peer_Session_Begin(&session)
	bad_peer_id: [20]byte
	bad_peer_id[0] = 1
	bad_handshake := Wire_Handshake_Serialize(Wire_Handshake{Peer_ID = bad_peer_id})
	testing.expect_value(t, Peer_Session_Feed(&session, bad_handshake[:]), Peer_Error.Info_Hash_Mismatch)
	testing.expect_value(t, session.State, Peer_State.Failed)
	testing.expect_value(t, session.Error, Peer_Error.Info_Hash_Mismatch)

	transport: Peer_Transport
	testing.expect_value(t, Peer_Transport_Queue(&transport, []byte{'x'}), Peer_Transport_Error.Disconnected)
	testing.expect_value(t, Peer_Transport_Flush(&transport), Peer_Transport_Error.Disconnected)
	Peer_Transport_Close(&transport)
}

peer_test_take_all_events :: proc(session: ^Peer_Session) {
	for {
		event, event_ok := Peer_Session_Next_Event(session)
		if !event_ok {
			return
		}
		Destroy_Peer_Event(&event)
	}
}
