package durrent

import "core:sync"
import "core:time"

Tracker_Manager_Tier :: struct {
	URLs:    [dynamic][]byte,
	Current: int,
}

Tracker_Manager :: struct {
	Mutex:          sync.Mutex,
	Tiers:          [dynamic]Tracker_Manager_Tier,
	Request:        Tracker_Announce_Request,
	Event:          Tracker_Event,
	Current_Tier:   int,
	Next_Announce:  time.Time,
	Has_Next:       bool,
	Failures:       u32,
	Last_HTTP_Status: int,
}

Tracker_Manager_Error :: enum {
	None,
	Invalid_Manager,
	No_Trackers,
	HTTP,
	Tracker_Failure,
	Invalid_Response,
	Out_Of_Memory,
}

Tracker_Manager_Init_Magnet :: proc(
	manager: ^Tracker_Manager,
	magnet: ^Magnet_Link,
	request: Tracker_Announce_Request,
) -> Tracker_Manager_Error {
	if manager == nil || magnet == nil {
		return .Invalid_Manager
	}
	Tracker_Manager_Destroy(manager)
	sync.mutex_lock(&manager.Mutex)
	defer sync.mutex_unlock(&manager.Mutex)
	manager.Request = request
	manager.Event = .Started
	for tracker_url in magnet.Trackers {
		copy, copy_ok := torrent_clone(tracker_url)
		if !copy_ok {
			tracker_manager_clear_locked(manager)
			return .Out_Of_Memory
		}
		tier: Tracker_Manager_Tier
		append(&tier.URLs, copy)
		append(&manager.Tiers, tier)
	}
	return .None if len(manager.Tiers) > 0 else .No_Trackers
}


Tracker_Manager_Init :: proc(
	manager: ^Tracker_Manager,
	torrent: ^Torrent,
	request: Tracker_Announce_Request,
) -> Tracker_Manager_Error {
	if manager == nil || torrent == nil {
		return .Invalid_Manager
	}
	Tracker_Manager_Destroy(manager)
	sync.mutex_lock(&manager.Mutex)
	defer sync.mutex_unlock(&manager.Mutex)
	manager.Request = request
	manager.Event = .Started
	for source_tier in torrent.Announce_List {
		tier: Tracker_Manager_Tier
		for url in source_tier.URLs {
			copy, copy_ok := torrent_clone(url)
			if !copy_ok {
				tracker_manager_clear_locked(manager)
				return .Out_Of_Memory
			}
			append(&tier.URLs, copy)
		}
		if len(tier.URLs) > 0 {
			append(&manager.Tiers, tier)
		} else {
			delete(tier.URLs)
		}
	}
	if len(manager.Tiers) == 0 && len(torrent.Announce) > 0 {
		tier: Tracker_Manager_Tier
		copy, copy_ok := torrent_clone(torrent.Announce)
		if !copy_ok {
			tracker_manager_clear_locked(manager)
			return .Out_Of_Memory
		}
		append(&tier.URLs, copy)
		append(&manager.Tiers, tier)
	}
	return .None if len(manager.Tiers) > 0 else .No_Trackers
}

Tracker_Manager_Destroy :: proc(manager: ^Tracker_Manager) {
	if manager == nil {
		return
	}
	sync.mutex_lock(&manager.Mutex)
	defer sync.mutex_unlock(&manager.Mutex)
	tracker_manager_clear_locked(manager)
}

Tracker_Manager_Set_Stats :: proc(manager: ^Tracker_Manager, uploaded, downloaded, left: u64) -> Tracker_Manager_Error {
	if manager == nil {
		return .Invalid_Manager
	}
	sync.mutex_lock(&manager.Mutex)
	defer sync.mutex_unlock(&manager.Mutex)
	manager.Request.Uploaded = uploaded
	manager.Request.Downloaded = downloaded
	manager.Request.Left = left
	return .None
}

Tracker_Manager_Set_Event :: proc(manager: ^Tracker_Manager, event: Tracker_Event) -> Tracker_Manager_Error {
	if manager == nil {
		return .Invalid_Manager
	}
	sync.mutex_lock(&manager.Mutex)
	defer sync.mutex_unlock(&manager.Mutex)
	manager.Event = event
	return .None
}

Tracker_Manager_Announce_Due :: proc(manager: ^Tracker_Manager, now: time.Time) -> bool {
	if manager == nil {
		return false
	}
	sync.mutex_lock(&manager.Mutex)
	defer sync.mutex_unlock(&manager.Mutex)
	return !manager.Has_Next || time.diff(manager.Next_Announce, now) >= 0
}

Tracker_Manager_Next_Announce :: proc(manager: ^Tracker_Manager) -> (time.Time, bool) {
	if manager == nil {
		return time.Time{}, false
	}
	sync.mutex_lock(&manager.Mutex)
	defer sync.mutex_unlock(&manager.Mutex)
	return manager.Next_Announce, manager.Has_Next
}

Tracker_Manager_Announce :: proc(
	manager: ^Tracker_Manager,
	now: time.Time,
	options := Tracker_HTTP_Options{Connect_Timeout_Seconds = 10, Total_Timeout_Seconds = 30, Max_Redirects = 5, Max_Response_Bytes = 4 * 1024 * 1024},
) -> (Tracker_Announce_Response, Tracker_Manager_Error) {
	if manager == nil {
		return Tracker_Announce_Response{}, .Invalid_Manager
	}
	sync.mutex_lock(&manager.Mutex)
	if len(manager.Tiers) == 0 {
		sync.mutex_unlock(&manager.Mutex)
		return Tracker_Announce_Response{}, .No_Trackers
	}
	event := manager.Event
	request := manager.Request
	start_tier := manager.Current_Tier
	tier_count := len(manager.Tiers)
	sync.mutex_unlock(&manager.Mutex)

	last_error := Tracker_Manager_Error.HTTP
	for tier_offset := 0; tier_offset < tier_count; tier_offset += 1 {
		tier_index := (start_tier + tier_offset) % tier_count
		sync.mutex_lock(&manager.Mutex)
		tier := &manager.Tiers[tier_index]
		url_count := len(tier.URLs)
		start_url := tier.Current if tier_index == start_tier else 0
		sync.mutex_unlock(&manager.Mutex)
		for url_offset := 0; url_offset < url_count; url_offset += 1 {
			url_index := (start_url + url_offset) % url_count
			sync.mutex_lock(&manager.Mutex)
			url, url_ok := torrent_clone(manager.Tiers[tier_index].URLs[url_index])
			sync.mutex_unlock(&manager.Mutex)
			if !url_ok {
				last_error = .Out_Of_Memory
				continue
			}
			request.Event = event
			response: Tracker_Announce_Response
			status: int
			announce_error := Tracker_Manager_Error.None
			if tracker_url_is_udp(string(url)) {
				udp_response, udp_error := UDP_Tracker_Announce(string(url), request, UDP_Tracker_Default_Options())
				response = udp_response
				switch udp_error {
				case .None:
				case .Tracker_Failure: announce_error = .Tracker_Failure
				case .Invalid_Response, .Invalid_Peer: announce_error = .Invalid_Response
				case .Out_Of_Memory: announce_error = .Out_Of_Memory
				case .Invalid_Client, .Invalid_URL, .Resolve, .Socket, .Send, .Receive, .Timeout, .Transaction_Mismatch:
					announce_error = .HTTP
				}
			} else {
				http_response, http_status, http_error := Tracker_HTTP_Announce(string(url), request, options)
				response = http_response
				status = http_status
				if http_error != .None {
					if http_error == .Tracker_Failure {
						announce_error = .Tracker_Failure
					} else if http_error == .Invalid_Response {
						announce_error = .Invalid_Response
					} else if http_error == .Out_Of_Memory {
						announce_error = .Out_Of_Memory
					} else {
						announce_error = .HTTP
					}
				}
			}
			delete(url)
			if announce_error != .None {
				manager.Last_HTTP_Status = status
				last_error = announce_error
				Destroy_Tracker_Response(&response)
				continue
			}
			sync.mutex_lock(&manager.Mutex)
			manager.Current_Tier = tier_index
			manager.Tiers[tier_index].Current = url_index
			manager.Failures = 0
			manager.Last_HTTP_Status = status
			if event == .Stopped {
				manager.Has_Next = false
			} else {
				interval := tracker_manager_interval(response.Interval, response.Min_Interval, response.Has_Min_Interval)
				manager.Next_Announce = time.time_add(now, interval)
				manager.Has_Next = true
				if event == .Started || event == .Completed {
					manager.Event = .None
				}
			}
			sync.mutex_unlock(&manager.Mutex)
			return response, .None
		}
	}

	sync.mutex_lock(&manager.Mutex)
	manager.Failures += 1
	manager.Next_Announce = time.time_add(now, tracker_manager_retry_delay(manager.Failures))
	manager.Has_Next = true
	sync.mutex_unlock(&manager.Mutex)
	return Tracker_Announce_Response{}, last_error
}

Tracker_Manager_Failure_Count :: proc(manager: ^Tracker_Manager) -> u32 {
	if manager == nil {
		return 0
	}
	sync.mutex_lock(&manager.Mutex)
	defer sync.mutex_unlock(&manager.Mutex)
	return manager.Failures
}

tracker_manager_interval :: proc(interval, min_interval: u64, has_min: bool) -> time.Duration {
	seconds := interval
	if seconds == 0 {
		seconds = 1800
	}
	if has_min && min_interval > seconds {
		seconds = min_interval
	}
	max_seconds := u64(0x7fff_ffff_ffff_ffff) / u64(time.Second)
	if seconds > max_seconds {
		seconds = max_seconds
	}
	return time.Duration(seconds) * time.Second
}

tracker_manager_retry_delay :: proc(failures: u32) -> time.Duration {
	shift := failures if failures < 6 else 6
	return time.Duration(1<<shift) * time.Second
}

tracker_manager_clear_locked :: proc(manager: ^Tracker_Manager) {
	for &tier in manager.Tiers {
		for url in tier.URLs {
			delete(url)
		}
		delete(tier.URLs)
	}
	delete(manager.Tiers)
	manager.Tiers = nil
	manager.Request = Tracker_Announce_Request{}
	manager.Event = .None
	manager.Current_Tier = 0
	manager.Next_Announce = time.Time{}
	manager.Has_Next = false
	manager.Failures = 0
	manager.Last_HTTP_Status = 0
}
