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
