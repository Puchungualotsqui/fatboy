package durrent

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
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
	Enable_PEX:            bool,
	// Disabled by default; callers can opt metadata peers into the same policy
	// used by normal torrent sessions.
	MSE_Policy:             MSE_Policy,
	Bootstrap:             []DHT_Node,
	Routing_Cache_Path:   string,
	Max_Candidates:       u32,
	Cancel:                ^Metadata_Resolver_Cancel_Token,
	// External_Cancel is retained when a batch uses its own cancellation token
	// to stop sibling peer attempts after one worker obtains metadata.
	External_Cancel:      ^Metadata_Resolver_Cancel_Token,
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
	Address:   string,
	Endpoint:  PEX_Peer,
	Attempted: bool,
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
		Peer_Connect_Timeout = 3 * time.Second,
		Peer_Metadata_Timeout = 10 * time.Second,
		Tracker_Timeout_Seconds = 20,
		Retry_Count = 3,
		Peer_Limit = 8,
		Max_Metadata_Size = Metadata_Default_Max_Size,
		Enable_DHT = true,
		Enable_PEX = true,
		Max_Candidates = 32,
	}
}


metadata_resolver_expired :: proc(deadline: time.Time) -> bool {
	// time.diff(a, b) returns b-a. A deadline is expired once now has
	// reached or passed it.
	return time.diff(deadline, time.now()) >= 0
}


metadata_resolver_cancelled :: proc(options: Metadata_Resolver_Options) -> bool {
	if Metadata_Resolver_Is_Cancelled(options.Cancel) {
		return true
	}
	if options.External_Cancel != options.Cancel {
		return Metadata_Resolver_Is_Cancelled(options.External_Cancel)
	}
	return false
}


metadata_resolver_endpoint_allowed :: proc(endpoint: PEX_Peer) -> bool {
	if endpoint.Port == 0 || endpoint.IPv6 {
		return endpoint.Port != 0
	}
	first := endpoint.IP[0]
	second := endpoint.IP[1]
	if first == 0 || first == 10 || first == 127 || first >= 224 {
		return false
	}
	if first == 100 && second >= 64 && second <= 127 {
		return false
	}
	if first == 169 && second == 254 {
		return false
	}
	if first == 172 && second >= 16 && second <= 31 {
		return false
	}
	if first == 192 && second == 168 {
		return false
	}
	return true
}


metadata_resolver_add_candidate :: proc(
	candidates: ^[dynamic]metadata_resolver_candidate,
	endpoint: PEX_Peer,
	limit: u32,
) -> bool {
	if candidates == nil || !metadata_resolver_endpoint_allowed(endpoint) ||
	   (limit > 0 && u32(len(candidates)) >= limit) {
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


metadata_resolver_prune_attempted :: proc(candidates: ^[dynamic]metadata_resolver_candidate) {
	if candidates == nil {
		return
	}
	remaining: [dynamic]metadata_resolver_candidate
	for candidate in candidates^ {
		if candidate.Attempted {
			delete(candidate.Address)
			continue
		}
		append(&remaining, candidate)
	}
	delete(candidates^)
	candidates^ = remaining
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


metadata_resolver_process_pex_event :: proc(
	event: ^Peer_Event,
	remote_pex_id: ^byte,
	candidates: ^[dynamic]metadata_resolver_candidate,
	limit: u32,
) {
	if event == nil || remote_pex_id == nil || candidates == nil || len(event.Payload) == 0 {
		return
	}
	extension_id := event.Payload[0]
	payload := event.Payload[1:]
	if extension_id == 0 {
		id, parse_error := PEX_Parse_Extension_Handshake(payload)
		if parse_error == .None {
			remote_pex_id^ = id
		}
		return
	}
	if extension_id != remote_pex_id^ || remote_pex_id^ == 0 {
		return
	}
	message, parse_error := PEX_Parse_Message(payload)
	if parse_error != .None {
		return
	}
	defer Destroy_PEX_Message(&message)
	before := len(candidates)
	for peer in message.Added {
		if len(candidates) >= int(limit) {
			break
		}
		_ = metadata_resolver_add_candidate(candidates, peer, limit)
	}
	if len(candidates) > before {
		fmt.printf("[DURRENT-META] PEX added candidates=%d total=%d\\n", len(candidates)-before, len(candidates))
	}
}


metadata_resolver_cleanup_peer :: proc(
	session: ^Peer_Session,
	downloader: ^Metadata_Downloader,
	address: string,
) {
	fmt.printf("[DURRENT-META] Cleanup downloader begin peer=%s\n", address)
	Metadata_Downloader_Destroy(downloader)
	fmt.printf("[DURRENT-META] Cleanup downloader done peer=%s\n", address)
	fmt.printf("[DURRENT-META] Cleanup session begin peer=%s\n", address)
	Destroy_Peer_Session(session)
	fmt.printf("[DURRENT-META] Cleanup session done peer=%s\n", address)
}


metadata_resolver_batch_job :: struct {
	Candidate:  metadata_resolver_candidate,
	Info_Hash:  Torrent_Hash,
	Peer_ID:    [20]byte,
	Options:    Metadata_Resolver_Options,
	Deadline:   time.Time,
	Metadata:   []byte,
	Error:      Metadata_Resolver_Error,
}


metadata_resolver_batch_execute :: proc(job: ^metadata_resolver_batch_job) {
	if job == nil {
		return
	}
	job.Metadata, job.Error = metadata_resolver_try_peer(
		job.Candidate,
		job.Info_Hash,
		job.Peer_ID,
		job.Options,
		job.Deadline,
		nil,
		0,
	)
	if job.Error == .None {
		// Stop sibling workers as soon as one peer has supplied valid metadata.
		Metadata_Resolver_Cancel(job.Options.Cancel)
	}
}


metadata_resolver_batch_worker :: proc(data: rawptr) {
	job := cast(^metadata_resolver_batch_job)data
	metadata_resolver_batch_execute(job)
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
	candidates: ^[dynamic]metadata_resolver_candidate,
	max_candidates: u32,
) -> ([]byte, Metadata_Resolver_Error) {
	fmt.printf("[DURRENT-META] Trying peer %s\n", candidate.Address)
	if metadata_resolver_cancelled(options) {
		return nil, .Cancelled
	}

	session: Peer_Session
	if Peer_Session_Init_Metadata(&session, info_hash, peer_id) != .None {
		return nil, .Metadata
	}
	if Peer_Session_Set_MSE_Policy(&session, options.MSE_Policy) != .None {
		Destroy_Peer_Session(&session)
		return nil, .Metadata
	}
	downloader: Metadata_Downloader
	defer metadata_resolver_cleanup_peer(&session, &downloader, candidate.Address)

	connect_timeout := options.Peer_Connect_Timeout
	if connect_timeout <= 0 {
		connect_timeout = 5 * time.Second
	}
	connect_error := Peer_Session_Connect(&session, candidate.Address, connect_timeout)
	if connect_error != .None {
		fmt.printf("[DURRENT-META] Peer connect failed address=%s error=%v\n", candidate.Address, connect_error)
		return nil, .No_Peers
	}
	fmt.printf("[DURRENT-META] Peer connected address=%s\n", candidate.Address)

	metadata_error := Metadata_Downloader_Init(
		&downloader,
		info_hash,
		options.Max_Metadata_Size,
	)
	if metadata_error != .None {
		return nil, .Metadata
	}
	remote_pex_id: byte
	pex_handshake_sent := false
	metadata_retry_at := time.time_add(time.now(), time.Second)

	peer_deadline := time.time_add(time.now(), options.Peer_Metadata_Timeout)
	if options.Peer_Metadata_Timeout <= 0 {
		peer_deadline = time.time_add(time.now(), 20*time.Second)
	}
	for !metadata_resolver_expired(deadline) && !metadata_resolver_expired(peer_deadline) {
		if metadata_resolver_cancelled(options) {
			return nil, .Cancelled
		}

		poll_error := Peer_Session_Poll(&session)
		if poll_error == .Timeout && Peer_Session_MSE_Early_Timed_Out(&session, connect_timeout) &&
		   Peer_Session_Reset_For_Plaintext_Retry(&session) == .None {
			if Peer_Session_Connect(&session, candidate.Address, connect_timeout) == .None {
				fmt.printf("[DURRENT-META] MSE Yb timeout; retrying plaintext on fresh TCP peer=%s\n", candidate.Address)
				continue
			}
		}
		if poll_error != .None &&
			poll_error != .Timeout {
			if Peer_Session_Can_Retry_Plaintext(&session) &&
			   Peer_Session_Reset_For_Plaintext_Retry(&session) == .None {
				retry_error := Peer_Session_Connect(&session, candidate.Address, connect_timeout)
				if retry_error == .None {
					fmt.printf("[DURRENT-META] MSE early failure; retrying plaintext on fresh TCP peer=%s\n", candidate.Address)
					continue
				}
			}
			if session.MSE_Policy != .Disabled && !session.MSE_Negotiated {
				fmt.printf("[DURRENT-MSE] terminal metadata negotiation failure peer=%s error=%v\n", candidate.Address, poll_error)
			}
			fmt.printf(
				"[DURRENT-META] Peer poll failed address=%s error=%v state=%v session_error=%v remote_extensions=%v events=%d\n",
				candidate.Address,
				poll_error,
				session.State,
				session.Error,
				session.Remote_Extensions,
				len(session.Events),
			)
			break
		}

		for {
			event, event_ok := Peer_Session_Next_Event(&session)
			if !event_ok {
				break
			}
			if event.Kind == .Handshake {
				if session.MSE_Negotiated {
					mode := "plaintext"
					if session.MSE_Active {
						mode = "RC4"
					}
					fmt.printf("[DURRENT-MSE] negotiated metadata peer=%s mode=%s\n", candidate.Address, mode)
					session.MSE_Negotiated = false
				}
				fmt.printf(
					"[DURRENT-META] Handshake received peer=%s remote_extensions=%v\n",
					candidate.Address,
					session.Remote_Extensions,
				)
			} else if event.Kind == .Extended {
				fmt.printf(
					"[DURRENT-META] Extended message received peer=%s bytes=%d\n",
					candidate.Address,
					len(event.Payload),
				)
			}
			event_error := Metadata_Downloader_Handle_Event(
				&downloader,
				&session,
				&event,
			)
			if options.Enable_PEX && event.Kind == .Handshake && !pex_handshake_sent {
				payload := PEX_Encode_Extension_Handshake()
				pex_error := Peer_Session_Queue_Extended(&session, 0, payload)
				delete(payload)
				pex_handshake_sent = pex_error == .None
				fmt.printf("[DURRENT-META] PEX handshake queued peer=%s result=%v\n", candidate.Address, pex_error)
			}
			if options.Enable_PEX && event.Kind == .Extended &&
			   candidates != nil && u32(len(candidates)) < max_candidates {
				metadata_resolver_process_pex_event(
					&event,
					&remote_pex_id,
					candidates,
					max_candidates,
				)
			}
			if event.Kind == .Extended && downloader.Metadata_Size > 0 && len(event.Payload) > 0 {
				fmt.printf(
					"[DURRENT-META] Metadata piece state peer=%s extension=%d remote_extension=%d received=%d/%d size=%d\n",
					candidate.Address,
					event.Payload[0],
					downloader.Remote_Extension_ID,
					downloader.Received_Count,
					downloader.Piece_Count,
					downloader.Metadata_Size,
				)
			}
			Destroy_Peer_Event(&event)
			if event_error != .None {
				fmt.printf("[DURRENT-META] Metadata event failed address=%s error=%v\n", candidate.Address, event_error)
				break
			}
		}

	if Metadata_Downloader_Is_Complete(&downloader) {
		metadata, finish_error := Metadata_Downloader_Finish_Bencoded(&downloader)
		if finish_error == .None {
			fmt.printf("[DURRENT-META] Metadata completed from peer %s bytes=%d\n", candidate.Address, len(metadata))
			return metadata, .None
		}
		fmt.printf("[DURRENT-META] Metadata verification failed address=%s error=%v\n", candidate.Address, finish_error)
		return nil, .Metadata
	}
		if downloader.Metadata_Size > 0 &&
		   !Metadata_Downloader_Is_Complete(&downloader) &&
		   metadata_resolver_expired(metadata_retry_at) {
			retry_error := Metadata_Downloader_Retry_Missing(&downloader, &session)
			fmt.printf(
				"[DURRENT-META] Metadata missing-piece retry peer=%s result=%v received=%d/%d\n",
				candidate.Address,
				retry_error,
				downloader.Received_Count,
				downloader.Piece_Count,
			)
			metadata_retry_at = time.time_add(time.now(), time.Second)
		}
		time.sleep(10 * time.Millisecond)
	}

	if metadata_resolver_cancelled(options) {
		return nil, .Cancelled
	}
	if metadata_resolver_expired(deadline) {
		fmt.printf("[DURRENT-META] Peer attempt timed out address=%s\n", candidate.Address)
		return nil, .Timed_Out
	}
	fmt.printf("[DURRENT-META] Peer attempt ended without metadata address=%s\n", candidate.Address)
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
	candidate_limit := options.Max_Candidates
	if candidate_limit == 0 {
		candidate_limit = 32
	}
	retry_count := options.Retry_Count
	if retry_count == 0 {
		retry_count = 1
	}

	fmt.printf(
		"[DURRENT-META] Resolve start trackers=%d peer_limit=%d retries=%d total_timeout=%v\n",
		len(magnet.Trackers),
		peer_limit,
		retry_count,
		total_timeout,
	)

	request := Tracker_Announce_Request{
		Info_Hash = magnet.Info_Hash,
		Peer_ID = peer_id,
		Port = 0,
		Left = 0,
		Compact = true,
		Event = .Started,
	}
	tracker_magnet: Magnet_Link
	tracker_magnet.Info_Hash = magnet.Info_Hash
	for tracker_url in magnet.Trackers {
		copy, copy_ok := torrent_clone(tracker_url)
		if !copy_ok {
			Destroy_Magnet_Link(&tracker_magnet)
			return nil, .Out_Of_Memory
		}
		append(&tracker_magnet.Trackers, copy)
	}
	if len(tracker_magnet.Trackers) == 0 {
		fallback_trackers := [4]string{
			"udp://tracker.opentrackr.org:1337/announce",
			"udp://open.stealth.si:80/announce",
			"udp://tracker.torrent.eu.org:451/announce",
			"http://tracker.openbittorrent.com:80/announce",
		}
		for tracker_url in fallback_trackers {
			copy := strings.clone(tracker_url, context.allocator)
			append(&tracker_magnet.Trackers, transmute([]byte)copy)
		}
		fmt.printf("[DURRENT-META] No magnet trackers; using fallback trackers=%d\n", len(tracker_magnet.Trackers))
	}
	defer Destroy_Magnet_Link(&tracker_magnet)
	tracker: Tracker_Manager
	tracker_error := Tracker_Manager_Init_Magnet(&tracker, &tracker_magnet, request)
	fmt.printf("[DURRENT-META] Tracker manager initialized result=%v\n", tracker_error)
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
		fmt.printf("[DURRENT-META] Attempt %d/%d candidates=%d\n", attempt+1, retry_count, len(candidates))
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
				before := len(candidates)
				metadata_resolver_add_tracker_peers(&candidates, &response, candidate_limit)
				fmt.printf(
					"[DURRENT-META] Tracker announce returned peers=%d new_candidates=%d\n",
					len(response.Peers)+len(response.Peers6),
					len(candidates)-before,
				)
			} else {
				fmt.printf("[DURRENT-META] Tracker announce failed error=%v\n", announce_error)
			}
			Destroy_Tracker_Response(&response)
		}

		if options.Enable_DHT && len(bootstrap) == 0 && len(candidates) > 0 {
			metadata_resolver_bootstrap_from_candidates(candidates[:], &bootstrap)
		}
		// Trackerless magnets use fallback trackers, but those responses can
		// fill the normal candidate budget with stale peers. Always reserve
		// additional capacity for DHT candidates in that case.
		dht_candidate_limit := candidate_limit + 16
		if len(magnet.Trackers) == 0 {
			dht_candidate_limit = candidate_limit + 32
		}
		if options.Enable_DHT && u32(len(candidates)) < dht_candidate_limit &&
		   !metadata_resolver_expired(deadline) {
			dht: DHT_Client
			dht_error := DHT_Client_Init(
				&dht,
				nil,
				DHT_Node_ID_Generate(u64(attempt + 100)),
				0,
			)
			fmt.printf("[DURRENT-META] DHT init result=%v bootstrap=%d\n", dht_error, len(bootstrap))
			if dht_error == .None {
				if len(options.Routing_Cache_Path) > 0 {
					load_error := DHT_Client_Load_Routing(&dht, options.Routing_Cache_Path)
					fmt.printf("[DURRENT-META] DHT routing cache load path=%s result=%v\n", options.Routing_Cache_Path, load_error)
				}
				dht_options := DHT_Default_Network_Options()
				dht_options.Timeout = time.Second
				dht_options.Max_Queries = 32
				result, lookup_error := DHT_Client_Get_Peers(
					&dht,
					magnet.Info_Hash,
					bootstrap[:],
					dht_options,
				)
				if lookup_error == .None {
					before := len(candidates)
					metadata_resolver_add_dht_peers(&candidates, &result, dht_candidate_limit)
					fmt.printf(
						"[DURRENT-META] DHT returned peers=%d new_candidates=%d\n",
						len(result.Peers),
						len(candidates)-before,
					)
				} else {
					fmt.printf("[DURRENT-META] DHT lookup failed error=%v\n", lookup_error)
				}
				Destroy_DHT_Lookup_Result(&result)
				if len(options.Routing_Cache_Path) > 0 {
					save_error := DHT_Client_Save_Routing(&dht, options.Routing_Cache_Path)
					fmt.printf("[DURRENT-META] DHT routing cache save path=%s result=%v\n", options.Routing_Cache_Path, save_error)
				}
			}
			DHT_Client_Destroy(&dht)
		}

		candidate_index := 0
		max_candidates := candidate_limit
		batch_limit := int(peer_limit)
		for candidate_index < len(candidates) {
			if metadata_resolver_cancelled(options) {
				return nil, .Cancelled
			}
			if metadata_resolver_expired(deadline) {
				return nil, .Timed_Out
			}

			batch_cancel: Metadata_Resolver_Cancel_Token
			jobs: [dynamic]^metadata_resolver_batch_job
			workers: [dynamic]^thread.Thread
			spawned := 0
			for candidate_index < len(candidates) && spawned < batch_limit {
				if candidates[candidate_index].Attempted {
					candidate_index += 1
					continue
				}

				candidates[candidate_index].Attempted = true
				job := new(metadata_resolver_batch_job, context.allocator)
				job.Candidate = candidates[candidate_index]
				job.Info_Hash = magnet.Info_Hash
				job.Peer_ID = peer_id
				job.Options = options
				job.Options.Cancel = &batch_cancel
				job.Options.External_Cancel = options.Cancel
				// PEX is optional and is intentionally excluded from concurrent
				// metadata probes. It would require synchronizing candidate storage,
				// while trackers and DHT already provide the initial peer set.
				job.Options.Enable_PEX = false
				job.Deadline = deadline
				job.Error = .No_Peers
				append(&jobs, job)
				candidate_index += 1
				spawned += 1

				worker := thread.create_and_start_with_data(
					job,
					metadata_resolver_batch_worker,
					nil,
					.Normal,
					false,
				)
				if worker != nil {
					append(&workers, worker)
				} else {
					// Thread creation is unusual to fail, but preserve a functional
					// fallback rather than silently discarding this candidate.
					metadata_resolver_batch_execute(job)
				}
			}

			fmt.printf("[DURRENT-META] Peer batch started size=%d\n", len(jobs))
			for worker in workers {
				if worker != nil {
					thread.destroy(worker)
				}
			}
			delete(workers)

			metadata: []byte
			for job in jobs {
				if job != nil && job.Error == .None {
					metadata = job.Metadata
					job.Metadata = nil
					break
				}
			}
			batch_cancelled := Metadata_Resolver_Is_Cancelled(&batch_cancel)
			for job in jobs {
				if job != nil {
					delete(job.Metadata)
					free(job)
				}
			}
			delete(jobs)
			if metadata != nil {
				return metadata, .None
			}
			if Metadata_Resolver_Is_Cancelled(options.Cancel) && !batch_cancelled {
				return nil, .Cancelled
			}
		}
		metadata_resolver_prune_attempted(&candidates)
	}

	if metadata_resolver_cancelled(options) {
		return nil, .Cancelled
	}
	if metadata_resolver_expired(deadline) {
		return nil, .Timed_Out
	}
	if len(candidates) == 0 {
		fmt.println("[DURRENT-META] Resolution ended with no peer candidates")
		return nil, .No_Peers
	}
	fmt.printf("[DURRENT-META] Resolution ended without metadata candidates=%d\n", len(candidates))
	return nil, .Metadata
}
