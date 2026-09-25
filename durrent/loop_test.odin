package durrent

import "core:os"
import "core:testing"
import "core:time"

loop_test_peer_id :: proc() -> [20]byte {
	result: [20]byte
	result[0] = 0x2d
	result[1] = 0x44
	result[2] = 0x55
	return result
}

@(test)
torrent_session_loop_tick_and_seeding_test :: proc(t: ^testing.T) {
	base, base_error := os.make_directory_temp("", "durrent-loop-*", context.allocator)
	testing.expect_value(t, base_error, nil)
	defer os.remove_all(base)
	defer delete(base)

	torrent := storage_test_single_torrent()
	defer Destroy_Torrent(&torrent)
	loop: Torrent_Session_Loop
	defer Torrent_Session_Loop_Destroy(&loop)
	peer_id := loop_test_peer_id()
	testing.expect_value(t, Torrent_Session_Loop_Open(&loop, &torrent, base, peer_id, 6881), Torrent_Loop_Error.None)

	stats, snapshot_error := Torrent_Session_Loop_Snapshot(&loop)
	testing.expect_value(t, snapshot_error, Torrent_Loop_Error.None)
	testing.expect_value(t, stats.State, Torrent_Loop_State.Paused)
	testing.expect_value(t, stats.Peer_Count, u32(0))
	testing.expect(t, !stats.Seeding)
	testing.expect_value(t, stats.Completed_Bytes, u64(0))

	testing.expect_value(t, Torrent_Storage_Write_Piece(&loop.Storage, 0, []byte{'a', 'b', 'c', 'd'}), Torrent_Storage_Error.None)
	verified, verify_error := Torrent_Storage_Verify_Piece(&loop.Storage, 0)
	testing.expect_value(t, verify_error, Torrent_Storage_Error.None)
	testing.expect(t, verified)
	testing.expect_value(t, Piece_Scheduler_Complete_Piece(&loop.Scheduler, 0), Piece_Scheduler_Error.None)
	testing.expect_value(t, Torrent_Storage_Write_Piece(&loop.Storage, 1, []byte{'e', 'f', 'g', 'h'}), Torrent_Storage_Error.None)
	verified, verify_error = Torrent_Storage_Verify_Piece(&loop.Storage, 1)
	testing.expect_value(t, verify_error, Torrent_Storage_Error.None)
	testing.expect(t, verified)
	testing.expect_value(t, Piece_Scheduler_Complete_Piece(&loop.Scheduler, 1), Piece_Scheduler_Error.None)

	loop.State = .Running
	testing.expect_value(t, Torrent_Session_Loop_Tick(&loop, time.time_add(time.now(), time.Second)), Torrent_Loop_Error.None)
	stats, snapshot_error = Torrent_Session_Loop_Snapshot(&loop)
	testing.expect_value(t, snapshot_error, Torrent_Loop_Error.None)
	testing.expect_value(t, stats.State, Torrent_Loop_State.Seeding)
	testing.expect(t, stats.Seeding)
	testing.expect_value(t, stats.Completed_Bytes, u64(8))
}

@(test)
torrent_session_loop_tracker_recovery_test :: proc(t: ^testing.T) {
	torrent := tracker_test_torrent()
	defer tracker_test_destroy_torrent(&torrent)
	loop := Torrent_Session_Loop{Peer_Limit = 32}
	defer Tracker_Manager_Destroy(&loop.Tracker)
	testing.expect_value(t, Tracker_Manager_Init(&loop.Tracker, &torrent, tracker_test_request()), Tracker_Manager_Error.None)

	now := time.now()
	loop.Tracker.Next_Announce = time.time_add(now, time.Hour)
	loop.Tracker.Has_Next = true
	loop.Next_Tracker_Recovery_Announce = now
	testing.expect(t, !Tracker_Manager_Announce_Due(&loop.Tracker, now))
	testing.expect(t, loop_tracker_recovery_announce_due_locked(&loop, now))
	testing.expect_value(t, Tracker_Manager_Request_Announce_Now(&loop.Tracker), Tracker_Manager_Error.None)
	testing.expect(t, Tracker_Manager_Announce_Due(&loop.Tracker, now))

	response: Tracker_Announce_Response
	append(&response.Peers, Tracker_Peer{IP = [4]byte{127, 0, 0, 1}, Port = 6881})
	loop_add_tracker_peers_locked(&loop, &response)
	Destroy_Tracker_Response(&response)
	testing.expect_value(t, len(loop.Pending_Peers), 1)
	delete(loop.Pending_Peers)
}

@(test)
torrent_session_loop_pause_and_resume_test :: proc(t: ^testing.T) {
	base, base_error := os.make_directory_temp("", "durrent-loop-pause-*", context.allocator)
	testing.expect_value(t, base_error, nil)
	defer os.remove_all(base)
	defer delete(base)

	torrent := storage_test_single_torrent()
	defer Destroy_Torrent(&torrent)
	loop: Torrent_Session_Loop
	defer Torrent_Session_Loop_Destroy(&loop)
	testing.expect_value(t, Torrent_Session_Loop_Open(&loop, &torrent, base, loop_test_peer_id(), 0), Torrent_Loop_Error.None)
	testing.expect_value(t, Torrent_Session_Loop_Start(&loop), Torrent_Loop_Error.None)
	testing.expect_value(t, Torrent_Session_Loop_Pause(&loop), Torrent_Loop_Error.None)
	stats, snapshot_error := Torrent_Session_Loop_Snapshot(&loop)
	testing.expect_value(t, snapshot_error, Torrent_Loop_Error.None)
	testing.expect_value(t, stats.State, Torrent_Loop_State.Paused)
	testing.expect_value(t, Torrent_Session_Loop_Resume(&loop), Torrent_Loop_Error.None)
	testing.expect_value(t, Torrent_Session_Loop_Shutdown(&loop), Torrent_Loop_Error.None)
}


@(test)
torrent_session_loop_worker_shutdown_test :: proc(t: ^testing.T) {
	base, base_error := os.make_directory_temp("", "durrent-loop-worker-*", context.allocator)
	testing.expect_value(t, base_error, nil)
	defer os.remove_all(base)
	defer delete(base)

	torrent := storage_test_single_torrent()
	defer Destroy_Torrent(&torrent)
	loop: Torrent_Session_Loop
	defer Torrent_Session_Loop_Destroy(&loop)
	testing.expect_value(t, Torrent_Session_Loop_Open(&loop, &torrent, base, loop_test_peer_id(), 6881), Torrent_Loop_Error.None)
	testing.expect_value(t, Torrent_Session_Loop_Start(&loop), Torrent_Loop_Error.None)
	testing.expect_value(t, Torrent_Session_Loop_Shutdown(&loop), Torrent_Loop_Error.None)
	_, snapshot_error := Torrent_Session_Loop_Snapshot(&loop)
	testing.expect_value(t, snapshot_error, Torrent_Loop_Error.Invalid_State)
}
