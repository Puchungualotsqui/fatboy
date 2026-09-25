package durrent

import "core:testing"
import "core:time"

tracker_test_torrent :: proc() -> Torrent {
	result: Torrent
	first: Torrent_Tracker_Tier
	first_url := "udp://first"
	append(&first.URLs, transmute([]byte)first_url)
	second: Torrent_Tracker_Tier
	second_url := "udp://second"
	append(&second.URLs, transmute([]byte)second_url)
	append(&result.Announce_List, first)
	append(&result.Announce_List, second)
	return result
}

tracker_test_destroy_torrent :: proc(torrent: ^Torrent) {
	for &tier in torrent.Announce_List {
		delete(tier.URLs)
	}
	delete(torrent.Announce_List)
}

tracker_test_request :: proc() -> Tracker_Announce_Request {
	return Tracker_Announce_Request{
		Info_Hash = Torrent_Hash{},
		Peer_ID = [20]byte{},
		Port = 6881,
		Compact = true,
	}
}

@(test)
tracker_http_scheme_and_options_test :: proc(t: ^testing.T) {
	request := tracker_test_request()
	response, status, http_error := Tracker_HTTP_Announce("udp://tracker.invalid:6969", request)
	Destroy_Tracker_Response(&response)
	testing.expect_value(t, status, 0)
	testing.expect_value(t, http_error, Tracker_HTTP_Error.Unsupported_Scheme)
	options := Tracker_HTTP_Default_Options()
	testing.expect_value(t, options.Connect_Timeout_Seconds, 10)
	testing.expect_value(t, options.Total_Timeout_Seconds, 30)
	testing.expect_value(t, options.Max_Redirects, 5)
	testing.expect_value(t, options.Max_Response_Bytes, 4*1024*1024)
}

@(test)
tracker_manager_tiers_events_and_retry_test :: proc(t: ^testing.T) {
	torrent := tracker_test_torrent()
	defer tracker_test_destroy_torrent(&torrent)
	manager: Tracker_Manager
	defer Tracker_Manager_Destroy(&manager)
	testing.expect_value(t, Tracker_Manager_Init(&manager, &torrent, tracker_test_request()), Tracker_Manager_Error.None)
	testing.expect_value(t, len(manager.Tiers), 2)
	testing.expect(t, Tracker_Manager_Announce_Due(&manager, time.now()))
	testing.expect_value(t, Tracker_Manager_Set_Stats(&manager, 10, 20, 30), Tracker_Manager_Error.None)
	testing.expect_value(t, manager.Request.Uploaded, u64(10))
	testing.expect_value(t, manager.Request.Downloaded, u64(20))
	testing.expect_value(t, manager.Request.Left, u64(30))
	testing.expect_value(t, Tracker_Manager_Set_Event(&manager, .Completed), Tracker_Manager_Error.None)
	testing.expect_value(t, manager.Event, Tracker_Event.Completed)

	now := time.now()
	response, announce_error := Tracker_Manager_Announce(&manager, now)
	Destroy_Tracker_Response(&response)
	testing.expect_value(t, announce_error, Tracker_Manager_Error.HTTP)
	testing.expect_value(t, Tracker_Manager_Failure_Count(&manager), u32(1))
	testing.expect(t, !Tracker_Manager_Announce_Due(&manager, now))
	testing.expect(t, Tracker_Manager_Announce_Due(&manager, time.time_add(now, 3*time.Second)))
}

@(test)
tracker_manager_request_announce_now_test :: proc(t: ^testing.T) {
	torrent := tracker_test_torrent()
	defer tracker_test_destroy_torrent(&torrent)
	manager: Tracker_Manager
	defer Tracker_Manager_Destroy(&manager)
	testing.expect_value(t, Tracker_Manager_Init(&manager, &torrent, tracker_test_request()), Tracker_Manager_Error.None)

	now := time.now()
	manager.Event = .Completed
	manager.Next_Announce = time.time_add(now, time.Hour)
	manager.Has_Next = true
	testing.expect(t, !Tracker_Manager_Announce_Due(&manager, now))
	testing.expect_value(t, Tracker_Manager_Request_Announce_Now(&manager), Tracker_Manager_Error.None)
	testing.expect(t, Tracker_Manager_Announce_Due(&manager, now))
	testing.expect_value(t, manager.Event, Tracker_Event.Completed)
}

@(test)
tracker_manager_no_trackers_test :: proc(t: ^testing.T) {
	torrent: Torrent
	manager: Tracker_Manager
	defer Tracker_Manager_Destroy(&manager)
	testing.expect_value(t, Tracker_Manager_Init(&manager, &torrent, tracker_test_request()), Tracker_Manager_Error.No_Trackers)
	response, announce_error := Tracker_Manager_Announce(&manager, time.now())
	Destroy_Tracker_Response(&response)
	testing.expect_value(t, announce_error, Tracker_Manager_Error.No_Trackers)
}
