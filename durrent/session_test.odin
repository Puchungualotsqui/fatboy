package durrent

import "core:testing"

@(test)
torrent_client_lifecycle_test :: proc(t: ^testing.T) {
	client: Torrent_Client
	defer Torrent_Client_Destroy(&client)
	testing.expect_value(t, Torrent_Client_Init(&client), Torrent_Client_Error.None)

	id, add_error := Torrent_Client_Add_Session(&client, Torrent_Session_Options{
		Info_Hash = Torrent_Hash{},
		Name = []byte{'d', 'e', 'm', 'o'},
		Total_Length = 100,
	})
	testing.expect_value(t, add_error, Torrent_Client_Error.None)

	snapshot, snapshot_error := Torrent_Client_Snapshot(&client, id)
	testing.expect_value(t, snapshot_error, Torrent_Client_Error.None)
	defer Destroy_Torrent_Session_Snapshot(&snapshot)
	testing.expect_value(t, snapshot.State, Torrent_State.Queued)
	testing.expect_value(t, snapshot.Progress.Fraction, f64(0))
	Destroy_Torrent_Session_Snapshot(&snapshot)

	testing.expect_value(t, Torrent_Client_Start(&client, id), Torrent_Client_Error.None)
	testing.expect_value(t, Torrent_Client_Report_Progress(&client, id, 25, 10, 4, 2), Torrent_Client_Error.None)
	testing.expect_value(t, Torrent_Client_Pause(&client, id), Torrent_Client_Error.None)
	testing.expect_value(t, Torrent_Client_Resume(&client, id), Torrent_Client_Error.None)
	testing.expect_value(t, Torrent_Client_Complete(&client, id), Torrent_Client_Error.None)
	testing.expect_value(t, Torrent_Client_Begin_Seeding(&client, id), Torrent_Client_Error.None)

	snapshot, snapshot_error = Torrent_Client_Snapshot(&client, id)
	testing.expect_value(t, snapshot_error, Torrent_Client_Error.None)
	defer Destroy_Torrent_Session_Snapshot(&snapshot)
	testing.expect_value(t, snapshot.State, Torrent_State.Seeding)
	testing.expect_value(t, snapshot.Progress.Bytes_Downloaded, u64(25))
	testing.expect_value(t, snapshot.Progress.Bytes_Uploaded, u64(10))
	testing.expect_value(t, snapshot.Progress.Fraction, f64(0.25))
	testing.expect_value(t, snapshot.Speed.Download_Bytes_Per_Second, f64(4))
}

@(test)
torrent_client_failure_retry_and_cancellation_test :: proc(t: ^testing.T) {
	client: Torrent_Client
	defer Torrent_Client_Destroy(&client)
	Torrent_Client_Init(&client)

	first, first_error := Torrent_Client_Add_Session(&client, Torrent_Session_Options{Total_Length = 1})
	second, second_error := Torrent_Client_Add_Session(&client, Torrent_Session_Options{Total_Length = 1})
	testing.expect_value(t, first_error, Torrent_Client_Error.None)
	testing.expect_value(t, second_error, Torrent_Client_Error.None)

	testing.expect_value(t, Torrent_Client_Start(&client, first), Torrent_Client_Error.None)
	testing.expect_value(t, Torrent_Client_Fail(&client, first, Torrent_Session_Error_Code.Network, []byte{'n', 'o'}), Torrent_Client_Error.None)
	failed, failed_error := Torrent_Client_Snapshot(&client, first)
	testing.expect_value(t, failed_error, Torrent_Client_Error.None)
	testing.expect_value(t, failed.State, Torrent_State.Failed)
	testing.expect_value(t, failed.Error.Code, Torrent_Session_Error_Code.Network)
	testing.expect(t, bytes_equal(failed.Error.Message, []byte{'n', 'o'}))
	Destroy_Torrent_Session_Snapshot(&failed)

	testing.expect_value(t, Torrent_Client_Retry(&client, first), Torrent_Client_Error.None)
	retried, retried_error := Torrent_Client_Snapshot(&client, first)
	testing.expect_value(t, retried_error, Torrent_Client_Error.None)
	testing.expect_value(t, retried.State, Torrent_State.Queued)
	testing.expect_value(t, retried.Error.Code, Torrent_Session_Error_Code.None)
	Destroy_Torrent_Session_Snapshot(&retried)

	testing.expect_value(t, Torrent_Client_Cancel(&client, second), Torrent_Client_Error.None)
	cancelled, cancelled_error := Torrent_Client_Snapshot(&client, second)
	testing.expect_value(t, cancelled_error, Torrent_Client_Error.None)
	testing.expect_value(t, cancelled.State, Torrent_State.Stopped)
	testing.expect(t, cancelled.Cancellation.Requested && cancelled.Cancellation.Acknowledged)
	Destroy_Torrent_Session_Snapshot(&cancelled)
}

@(test)
torrent_client_validation_and_shutdown_test :: proc(t: ^testing.T) {
	client: Torrent_Client
	id, add_error := Torrent_Client_Add_Session(&client, Torrent_Session_Options{})
	testing.expect_value(t, id, u64(0))
	testing.expect_value(t, add_error, Torrent_Client_Error.Not_Initialized)

	testing.expect_value(t, Torrent_Client_Init(&client), Torrent_Client_Error.None)
	id, add_error = Torrent_Client_Add_Session(&client, Torrent_Session_Options{Total_Length = 10})
	testing.expect_value(t, add_error, Torrent_Client_Error.None)
	testing.expect_value(t, Torrent_Client_Pause(&client, id), Torrent_Client_Error.Invalid_State)
	testing.expect_value(t, Torrent_Client_Report_Progress(&client, id, 11, 0, 0, 0), Torrent_Client_Error.Invalid_Progress)
	testing.expect_value(t, Torrent_Client_Report_Progress(&client, id, 0, 0, -1, 0), Torrent_Client_Error.Invalid_Progress)
	testing.expect_value(t, Torrent_Client_Fail(&client, id, Torrent_Session_Error_Code.None, nil), Torrent_Client_Error.Invalid_State)

	report, shutdown_error := Torrent_Client_Shutdown(&client)
	testing.expect_value(t, shutdown_error, Torrent_Client_Error.None)
	testing.expect(t, report.Requested && report.Completed)
	testing.expect_value(t, report.Sessions_Total, u32(1))
	testing.expect_value(t, report.Sessions_Stopped, u32(1))
	testing.expect_value(t, report.Sessions_Already_Stopped, u32(0))
	_, second_shutdown_error := Torrent_Client_Shutdown(&client)
	testing.expect_value(t, second_shutdown_error, Torrent_Client_Error.Not_Initialized)
	Torrent_Client_Destroy(&client)
}
