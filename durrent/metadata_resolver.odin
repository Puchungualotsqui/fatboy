package durrent

import "core:sync"
import "core:time"

Metadata_Resolver_Cancel_Token :: struct {
	Mutex:     sync.Mutex,
	Requested: bool,
}

Metadata_Resolver_Options :: struct {
	Total_Timeout:         time.Duration,
	Peer_Connect_Timeout:  time.Duration,
	Peer_Metadata_Timeout: time.Duration,
	Tracker_Timeout_Seconds: int,
	Retry_Count:           u32,
	Peer_Limit:            u32,
	Max_Metadata_Size:     u32,
	Enable_DHT:            bool,
	Bootstrap:             []DHT_Node,
	Cancel:                ^Metadata_Resolver_Cancel_Token,
}

Metadata_Resolver_Error :: enum {
	None,
	Invalid_Magnet,
	Cancelled,
	Timed_Out,
	No_Peers,
	Tracker,
	DHT,
	Metadata,
	Out_Of_Memory,
}

metadata_resolver_candidate :: struct {
	Address:  string,
	Endpoint: PEX_Peer,
}

Metadata_Resolver_Cancel :: proc(token: ^Metadata_Resolver_Cancel_Token) {
	if token == nil {
		return
	}
	sync.mutex_lock(&token.Mutex)
	token.Requested = true
	sync.mutex_unlock(&token.Mutex)
}


Metadata_Resolver_Is_Cancelled :: proc(token: ^Metadata_Resolver_Cancel_Token) -> bool {
	if token == nil {
		return false
	}
	sync.mutex_lock(&token.Mutex)
	defer sync.mutex_unlock(&token.Mutex)
	return token.Requested
}


Metadata_Resolver_Default_Options :: proc() -> Metadata_Resolver_Options {
	return Metadata_Resolver_Options{
		Total_Timeout = 180 * time.Second,
		Peer_Connect_Timeout = 5 * time.Second,
		Peer_Metadata_Timeout = 20 * time.Second,
		Tracker_Timeout_Seconds = 20,
		Retry_Count = 3,
		Peer_Limit = 8,
		Max_Metadata_Size = Metadata_Default_Max_Size,
		Enable_DHT = true,
	}
}


metadata_resolver_expired :: proc(deadline: time.Time) -> bool {
	return time.diff(deadline, time.now()) <= 0
}


metadata_resolver_cancelled :: proc(options: Metadata_Resolver_Options) -> bool {
	return Metadata_Resolver_Is_Cancelled(options.Cancel)
}


metadata_resolver_add_candidate :: proc(
	candidates: ^[dynamic]metadata_resolver_candidate,
	endpoint: PEX_Peer,
	limit: u32,
) -> bool {
	if candidates == nil || endpoint.Port == 0 || (limit > 0 && u32(len(candidates)) >= limit) {
		return false
	}
	address := PEX_Peer_Address(endpoint)
	for candidate in candidates {
		if candidate.Address == address {
			delete(address)
			return false
		}
	}
	append(candidates, metadata_resolver_candidate{
		Address = address,
		Endpoint = endpoint,
	})
	return true
}


metadata_resolver_destroy_candidates :: proc(candidates: ^[dynamic]metadata_resolver_candidate) {
	if candidates == nil {
		return
	}
	for &candidate in candidates {
		delete(candidate.Address)
	}
	delete(candidates^)
}


metadata_resolver_tracker_options :: proc(options: Metadata_Resolver_Options) -> Tracker_HTTP_Options {
	seconds := options.Tracker_Timeout_Seconds
	if seconds <= 0 {
		seconds = 20
	}
	return Tracker_HTTP_Options{
		Connect_Timeout_Seconds = seconds if seconds < 10 else 10,
		Total_Timeout_Seconds = seconds,
		Max_Redirects = 3,
		Max_Response_Bytes = 4 * 1024 * 1024,
	}
}


metadata_resolver_add_tracker_peers :: proc(
	candidates: ^[dynamic]metadata_resolver_candidate,
	response: ^Tracker_Announce_Response,
	limit: u32,
) {
	if candidates == nil || response == nil {
		return
	}
	for tracker_peer in response.Peers {
		endpoint: PEX_Peer
		endpoint.IP[0] = tracker_peer.IP[0]
		endpoint.IP[1] = tracker_peer.IP[1]
		endpoint.IP[2] = tracker_peer.IP[2]
		endpoint.IP[3] = tracker_peer.IP[3]
		endpoint.Port = tracker_peer.Port
		if !metadata_resolver_add_candidate(candidates, endpoint, limit) &&
			limit > 0 && u32(len(candidates)) >= limit {
			return
		}
	}
	for tracker_peer in response.Peers6 {
		endpoint: PEX_Peer
		endpoint.IP = tracker_peer.IP
		endpoint.Port = tracker_peer.Port
		endpoint.IPv6 = true
		if !metadata_resolver_add_candidate(candidates, endpoint, limit) &&
			limit > 0 && u32(len(candidates)) >= limit {
			return
		}
	}
}


metadata_resolver_add_dht_peers :: proc(
	candidates: ^[dynamic]metadata_resolver_candidate,
	result: ^DHT_Lookup_Result,
	limit: u32,
) {
	if candidates == nil || result == nil {
		return
	}
	for endpoint in result.Peers {
		peer: PEX_Peer
		peer.IP = endpoint.IP
		peer.Port = endpoint.Port
		peer.IPv6 = endpoint.IPv6
		if !metadata_resolver_add_candidate(candidates, peer, limit) &&
			limit > 0 && u32(len(candidates)) >= limit {
			return
		}
	}
}


metadata_resolver_bootstrap_from_candidates :: proc(
	candidates: []metadata_resolver_candidate,
	bootstrap: ^[dynamic]DHT_Node,
) {
	if bootstrap == nil {
		return
	}
	for candidate, index in candidates {
		if len(bootstrap) >= 16 {
			break
		}
		append(bootstrap, DHT_Node{
			ID = DHT_Node_ID_Generate(u64(index + 1)),
			Endpoint = DHT_Endpoint{
				IP = candidate.Endpoint.IP,
				Port = candidate.Endpoint.Port,
				IPv6 = candidate.Endpoint.IPv6,
			},
		})
	}
}


metadata_resolver_try_peer :: proc(
	candidate: metadata_resolver_candidate,
	info_hash: Torrent_Hash,
	peer_id: [20]byte,
	options: Metadata_Resolver_Options,
	deadline: time.Time,
) -> ([]byte, Metadata_Resolver_Error) {
	if metadata_resolver_cancelled(options) {
		return nil, .Cancelled
	}

	session: Peer_Session
	if Peer_Session_Init_Metadata(&session, info_hash, peer_id) != .None {
		return nil, .Metadata
	}
	defer Destroy_Peer_Session(&session)

	connect_timeout := options.Peer_Connect_Timeout
	if connect_timeout <= 0 {
		connect_timeout = 5 * time.Second
	}
	if Peer_Session_Connect(&session, candidate.Address, connect_timeout) != .None {
		return nil, .No_Peers
	}

	downloader: Metadata_Downloader
	metadata_error := Metadata_Downloader_Init(
		&downloader,
		info_hash,
		options.Max_Metadata_Size,
	)
	if metadata_error != .None {
		return nil, .Metadata
	}
	defer Metadata_Downloader_Destroy(&downloader)

	peer_deadline := time.time_add(time.now(), options.Peer_Metadata_Timeout)
	if options.Peer_Metadata_Timeout <= 0 {
		peer_deadline = time.time_add(time.now(), 20*time.Second)
	}
	for !metadata_resolver_expired(deadline) && !metadata_resolver_expired(peer_deadline) {
		if metadata_resolver_cancelled(options) {
			return nil, .Cancelled
		}

		poll_error := Peer_Session_Poll(&session)
		if poll_error != .None &&
			poll_error != .Timeout {
			break
		}

		for {
			event, event_ok := Peer_Session_Next_Event(&session)
			if !event_ok {
				break
			}
			event_error := Metadata_Downloader_Handle_Event(
				&downloader,
				&session,
				&event,
			)
			Destroy_Peer_Event(&event)
			if event_error != .None {
				break
			}
		}

		if Metadata_Downloader_Is_Complete(&downloader) {
			metadata, finish_error := Metadata_Downloader_Finish_Bencoded(&downloader)
			if finish_error == .None {
				return metadata, .None
			}
			return nil, .Metadata
		}
		time.sleep(10 * time.Millisecond)
	}

	if metadata_resolver_cancelled(options) {
		return nil, .Cancelled
	}
	if metadata_resolver_expired(deadline) {
		return nil, .Timed_Out
	}
	return nil, .No_Peers
}


Resolve_Magnet_Metadata :: proc(
	magnet: ^Magnet_Link,
	peer_id: [20]byte,
	options: Metadata_Resolver_Options,
) -> ([]byte, Metadata_Resolver_Error) {
	if magnet == nil {
		return nil, .Invalid_Magnet
	}
	if options.Max_Metadata_Size == 0 {
		return nil, .Metadata
	}
	if metadata_resolver_cancelled(options) {
		return nil, .Cancelled
	}

	total_timeout := options.Total_Timeout
	if total_timeout <= 0 {
		total_timeout = 180 * time.Second
	}
	deadline := time.time_add(time.now(), total_timeout)
	peer_limit := options.Peer_Limit
	if peer_limit == 0 {
		peer_limit = 8
	}
	retry_count := options.Retry_Count
	if retry_count == 0 {
		retry_count = 1
	}

	request := Tracker_Announce_Request{
		Info_Hash = magnet.Info_Hash,
		Peer_ID = peer_id,
		Port = 0,
		Left = 0,
		Compact = true,
		Event = .Started,
	}
	tracker: Tracker_Manager
	tracker_error := Tracker_Manager_Init_Magnet(&tracker, magnet, request)
	if tracker_error != .None && tracker_error != .No_Trackers {
		return nil, .Tracker
	}
	defer Tracker_Manager_Destroy(&tracker)

	candidates: [dynamic]metadata_resolver_candidate
	defer metadata_resolver_destroy_candidates(&candidates)
	bootstrap: [dynamic]DHT_Node
	defer delete(bootstrap)
	for node in options.Bootstrap {
		append(&bootstrap, node)
	}

	for attempt := u32(0); attempt < retry_count; attempt += 1 {
		if metadata_resolver_cancelled(options) {
			return nil, .Cancelled
		}
		if metadata_resolver_expired(deadline) {
			return nil, .Timed_Out
		}

		if len(tracker.Tiers) > 0 {
			if attempt > 0 {
				_ = Tracker_Manager_Set_Event(&tracker, .Started)
			}
			response, announce_error := Tracker_Manager_Announce(
				&tracker,
				time.now(),
				metadata_resolver_tracker_options(options),
			)
			if announce_error == .None {
				metadata_resolver_add_tracker_peers(&candidates, &response, peer_limit)
			}
			Destroy_Tracker_Response(&response)
		}

		if options.Enable_DHT && len(bootstrap) == 0 && len(candidates) > 0 {
			metadata_resolver_bootstrap_from_candidates(candidates[:], &bootstrap)
		}
		if options.Enable_DHT && len(bootstrap) > 0 && !metadata_resolver_expired(deadline) {
			dht: DHT_Client
			dht_error := DHT_Client_Init(
				&dht,
				nil,
				DHT_Node_ID_Generate(u64(attempt + 100)),
				0,
			)
			if dht_error == .None {
				dht_options := DHT_Default_Network_Options()
				dht_options.Timeout = time.Second
				dht_options.Max_Queries = 8
				result, lookup_error := DHT_Client_Get_Peers(
					&dht,
					magnet.Info_Hash,
					bootstrap[:],
					dht_options,
				)
				if lookup_error == .None {
					metadata_resolver_add_dht_peers(&candidates, &result, peer_limit)
				}
				Destroy_DHT_Lookup_Result(&result)
			}
			DHT_Client_Destroy(&dht)
		}

		for candidate in candidates {
			if metadata_resolver_cancelled(options) {
				return nil, .Cancelled
			}
			if metadata_resolver_expired(deadline) {
				return nil, .Timed_Out
			}
			metadata, peer_error := metadata_resolver_try_peer(
				candidate,
				magnet.Info_Hash,
				peer_id,
				options,
				deadline,
			)
			if peer_error == .None {
				return metadata, .None
			}
			if peer_error == .Cancelled {
				return nil, peer_error
			}
		}
	}

	if metadata_resolver_cancelled(options) {
		return nil, .Cancelled
	}
	if metadata_resolver_expired(deadline) {
		return nil, .Timed_Out
	}
	if len(candidates) == 0 {
		return nil, .No_Peers
	}
	return nil, .Metadata
}
