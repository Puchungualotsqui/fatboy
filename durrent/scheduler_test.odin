package durrent

import "core:testing"
import "core:time"

scheduler_test_bitfield :: proc(piece_count: u32, pieces: ..u32) -> Bitfield {
	result, _ := Bitfield_Init(piece_count)
	for index in pieces {
		Bitfield_Set_Piece(&result, index)
	}
	return result
}

scheduler_test_session :: proc() -> Peer_Session {
	info_hash: Torrent_Hash
	peer_id: [20]byte
	session: Peer_Session
	Peer_Session_Init(&session, info_hash, peer_id, 4, 4, 16)
	Peer_Session_Begin(&session)
	handshake := Wire_Handshake_Serialize(Wire_Handshake{Info_Hash = info_hash, Peer_ID = peer_id})
	Peer_Session_Feed(&session, handshake[:])
	output, _ := Peer_Session_Take_Output(&session)
	delete(output)
	return session
}

@(test)
piece_scheduler_rarest_first_and_pipeline_test :: proc(t: ^testing.T) {
	scheduler: Piece_Scheduler
	defer Piece_Scheduler_Destroy(&scheduler)
	testing.expect_value(t, Piece_Scheduler_Init(&scheduler, 4, 4, 16, time.Second), Piece_Scheduler_Error.None)

	first := scheduler_test_bitfield(4, 0, 1)
	second := scheduler_test_bitfield(4, 1, 2)
	defer Destroy_Bitfield(&first)
	defer Destroy_Bitfield(&second)
	testing.expect_value(t, Piece_Scheduler_Add_Peer(&scheduler, 10, &first, nil), Piece_Scheduler_Error.None)
	testing.expect_value(t, Piece_Scheduler_Add_Peer(&scheduler, 20, &second, nil), Piece_Scheduler_Error.None)
	testing.expect_value(t, Piece_Scheduler_Set_Peer_Choked(&scheduler, 10, false), Piece_Scheduler_Error.None)
	testing.expect_value(t, Piece_Scheduler_Set_Peer_Choked(&scheduler, 20, false), Piece_Scheduler_Error.None)

	availability, availability_ok := Piece_Scheduler_Availability(&scheduler, 0)
	testing.expect(t, availability_ok)
	testing.expect_value(t, availability, u32(1))
	availability, _ = Piece_Scheduler_Availability(&scheduler, 1)
	testing.expect_value(t, availability, u32(2))

	now := time.now()
	request, found, request_error := Piece_Scheduler_Next_Request(&scheduler, 10, now)
	testing.expect(t, found)
	testing.expect_value(t, request_error, Piece_Scheduler_Error.None)
	testing.expect_value(t, request.Index, u32(0))
	testing.expect_value(t, request.Begin, u32(0))
	testing.expect_value(t, request.Length, u32(4))

	request, found, request_error = Piece_Scheduler_Next_Request(&scheduler, 20, now)
	testing.expect(t, found)
	testing.expect_value(t, request_error, Piece_Scheduler_Error.None)
	testing.expect_value(t, request.Index, u32(2))
	testing.expect_value(t, request.Begin, u32(0))

	testing.expect_value(t, Piece_Scheduler_Complete_Block(&scheduler, 0, 0), Piece_Scheduler_Error.None)
	testing.expect(t, Piece_Scheduler_Is_Piece_Ready(&scheduler, 0))
	testing.expect_value(t, Piece_Scheduler_Reset_Piece(&scheduler, 0), Piece_Scheduler_Error.None)
	testing.expect(t, !Piece_Scheduler_Is_Piece_Ready(&scheduler, 0))
	request_count, request_count_ok := Piece_Scheduler_Peer_Request_Count(&scheduler, 10)
	testing.expect(t, request_count_ok)
	testing.expect_value(t, request_count, u32(0))
}

@(test)
piece_scheduler_finishes_active_piece_before_opening_new_piece_test :: proc(t: ^testing.T) {
	scheduler: Piece_Scheduler
	defer Piece_Scheduler_Destroy(&scheduler)
	testing.expect_value(t, Piece_Scheduler_Init(&scheduler, 2, 32 * 1024, 64 * 1024, time.Second), Piece_Scheduler_Error.None)
	first := scheduler_test_bitfield(2, 0, 1)
	second := scheduler_test_bitfield(2, 1)
	defer Destroy_Bitfield(&first)
	defer Destroy_Bitfield(&second)
	testing.expect_value(t, Piece_Scheduler_Add_Peer(&scheduler, 1, &first, nil), Piece_Scheduler_Error.None)
	testing.expect_value(t, Piece_Scheduler_Add_Peer(&scheduler, 2, &second, nil), Piece_Scheduler_Error.None)
	testing.expect_value(t, Piece_Scheduler_Set_Peer_Choked(&scheduler, 1, false), Piece_Scheduler_Error.None)

	// Piece 0 is rarer, but piece 1 has already received its first block. The
	// next request should complete the active piece rather than start piece 0.
	testing.expect_value(t, Piece_Scheduler_Complete_Block(&scheduler, 1, 0), Piece_Scheduler_Error.None)
	request, found, request_error := Piece_Scheduler_Next_Request(&scheduler, 1, time.now())
	testing.expect(t, found)
	testing.expect_value(t, request_error, Piece_Scheduler_Error.None)
	testing.expect_value(t, request.Index, u32(1))
	testing.expect_value(t, request.Begin, Block_Size)
}

@(test)
piece_scheduler_cached_request_state_cleanup_test :: proc(t: ^testing.T) {
	scheduler: Piece_Scheduler
	defer Piece_Scheduler_Destroy(&scheduler)
	testing.expect_value(t, Piece_Scheduler_Init(&scheduler, 1, 32 * 1024, 32 * 1024, time.Second), Piece_Scheduler_Error.None)
	pieces := scheduler_test_bitfield(1, 0)
	defer Destroy_Bitfield(&pieces)
	testing.expect_value(t, Piece_Scheduler_Add_Peer(&scheduler, 1, &pieces, nil), Piece_Scheduler_Error.None)
	testing.expect_value(t, Piece_Scheduler_Set_Peer_Choked(&scheduler, 1, false), Piece_Scheduler_Error.None)

	request, found, request_error := Piece_Scheduler_Next_Request(&scheduler, 1, time.now())
	testing.expect(t, found)
	testing.expect_value(t, request_error, Piece_Scheduler_Error.None)
	testing.expect_value(t, scheduler.Outstanding_Block_Count[0], u32(1))
	testing.expect_value(t, scheduler.Block_Requested[0][0], byte(1))
	testing.expect_value(t, Piece_Scheduler_Drop_Request(&scheduler, 1, request.Index, request.Begin), Piece_Scheduler_Error.None)
	testing.expect_value(t, scheduler.Outstanding_Block_Count[0], u32(0))
	testing.expect_value(t, scheduler.Block_Requested[0][0], byte(0))

	request, found, request_error = Piece_Scheduler_Next_Request(&scheduler, 1, time.now())
	testing.expect(t, found)
	testing.expect_value(t, request_error, Piece_Scheduler_Error.None)
	testing.expect_value(t, Piece_Scheduler_Complete_Block(&scheduler, request.Index, request.Begin), Piece_Scheduler_Error.None)
	testing.expect_value(t, scheduler.Outstanding_Block_Count[0], u32(0))
	testing.expect_value(t, scheduler.Received_Block_Count[0], u32(1))
}

@(test)
piece_scheduler_expiry_endgame_and_seeding_test :: proc(t: ^testing.T) {
	scheduler: Piece_Scheduler
	defer Piece_Scheduler_Destroy(&scheduler)
	testing.expect_value(t, Piece_Scheduler_Init(&scheduler, 3, 4, 12, time.Second), Piece_Scheduler_Error.None)
	pieces := scheduler_test_bitfield(3, 0, 1, 2)
	defer Destroy_Bitfield(&pieces)
	testing.expect_value(t, Piece_Scheduler_Add_Peer(&scheduler, 1, &pieces, nil), Piece_Scheduler_Error.None)
	testing.expect_value(t, Piece_Scheduler_Set_Peer_Choked(&scheduler, 1, false), Piece_Scheduler_Error.None)

	old := time.time_add(time.now(), -2*time.Second)
	_, found, request_error := Piece_Scheduler_Next_Request(&scheduler, 1, old)
	testing.expect(t, found)
	testing.expect_value(t, request_error, Piece_Scheduler_Error.None)
	expired, expire_error := Piece_Scheduler_Expire_Requests(&scheduler, time.now())
	testing.expect_value(t, expire_error, Piece_Scheduler_Error.None)
	testing.expect_value(t, len(expired), 1)
	testing.expect_value(t, expired[0].Attempts, u32(2))
	delete(expired)
	// Expiry must release cached request state so another peer can retry it.
	_, found, request_error = Piece_Scheduler_Next_Request(&scheduler, 1, time.now())
	testing.expect(t, found)
	testing.expect_value(t, request_error, Piece_Scheduler_Error.None)

	testing.expect_value(t, Piece_Scheduler_Complete_Piece(&scheduler, 0), Piece_Scheduler_Error.None)
	testing.expect(t, Piece_Scheduler_Is_Endgame(&scheduler))
	testing.expect_value(t, Piece_Scheduler_Complete_Piece(&scheduler, 1), Piece_Scheduler_Error.None)
	testing.expect(t, !Piece_Scheduler_Is_Seeding(&scheduler))
	testing.expect_value(t, Piece_Scheduler_Complete_Piece(&scheduler, 2), Piece_Scheduler_Error.None)
	testing.expect(t, Piece_Scheduler_Is_Seeding(&scheduler))
}

@(test)
piece_scheduler_announces_have_test :: proc(t: ^testing.T) {
	session := scheduler_test_session()
	defer Destroy_Peer_Session(&session)
	scheduler: Piece_Scheduler
	defer Piece_Scheduler_Destroy(&scheduler)
	testing.expect_value(t, Piece_Scheduler_Init(&scheduler, 1, 4, 4, time.Second), Piece_Scheduler_Error.None)
	pieces := scheduler_test_bitfield(1, 0)
	defer Destroy_Bitfield(&pieces)
	testing.expect_value(t, Piece_Scheduler_Add_Peer(&scheduler, 1, &pieces, &session), Piece_Scheduler_Error.None)
	testing.expect_value(t, Piece_Scheduler_Complete_Piece(&scheduler, 0), Piece_Scheduler_Error.None)

	output, output_error := Peer_Session_Take_Output(&session)
	testing.expect_value(t, output_error, Peer_Error.None)
	message, message_error := Wire_Message_Parse(output)
	delete(output)
	testing.expect_value(t, message_error, Wire_Error.None)
	testing.expect_value(t, message.Message.Kind, Wire_Message_Kind.Have)
	testing.expect_value(t, message.Message.Index, u32(0))
}
