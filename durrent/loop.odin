package durrent


import "core:net"
import "core:sync"
import "core:thread"
import "core:time"
import "base:runtime"

Torrent_Loop_State :: enum {
	Closed,
	Paused,
	Running,
	Completed,
	Seeding,
	Failed,
	Stopping,
}

Torrent_Loop_Error :: enum {
	None,
	Invalid_Loop,
	Invalid_State,
	Invalid_Torrent,
	Storage,
	Scheduler,
	Tracker,
	Peer,
	Out_Of_Memory,
}

Torrent_Loop_Stats :: struct {
	State:                       Torrent_Loop_State,
	Peer_Count:                  u32,
	Connected_Peers:             u32,
	Bytes_Downloaded:            u64,
	Bytes_Uploaded:              u64,
	Download_Bytes_Per_Second:   f64,
	Upload_Bytes_Per_Second:     f64,
	Seeding:                     bool,
}

Torrent_Loop_Peer :: struct {
	ID:                   u64,
	Address:              string,
	Endpoint:             PEX_Peer,
	Session:              Peer_Session,
	Registered:           bool,
	Remote_PEX_ID:        byte,
	PEX_Handshake_Sent:   bool,
	PEX_Last_Sent:        time.Time,
}

Torrent_Session_Loop :: struct {
	Mutex:                 sync.Mutex,
	State:                 Torrent_Loop_State,
	Error:                 Torrent_Loop_Error,
	Info_Hash:             Torrent_Hash,
	Peer_ID:               [20]byte,
	Port:                  u16,
	Peer_Limit:            u32,
	Tick_Interval:         time.Duration,
	Peer_Connect_Timeout:  time.Duration,
	Scheduler:             Piece_Scheduler,
	Storage:               Torrent_Storage,
	Tracker:               Tracker_Manager,
	Peers:                 [dynamic]^Torrent_Loop_Peer,
	Next_Peer_ID:          u64,
	Worker:                ^thread.Thread,
	Stop_Requested:        bool,
	Bytes_Downloaded:      u64,
	Bytes_Uploaded:        u64,
	Download_Bytes_Per_Second: f64,
	Upload_Bytes_Per_Second:   f64,
	Stats_Time:            time.Time,
	Stats_Downloaded:      u64,
	Stats_Uploaded:        u64,
	PEX_Enabled:            bool,
	Listener:                net.TCP_Socket,
	Listener6:               net.TCP_Socket,
	Listener_Open:           bool,
	Listener6_Open:          bool,
	DHT:                     DHT_Client,
	DHT_Enabled:             bool,
	DHT_Worker:              ^thread.Thread,
	DHT_Worker_Started:      bool,
	DHT_Stop_Requested:      bool,
	DHT_Bootstrap:           [dynamic]DHT_Node,
	DHT_Result:              DHT_Lookup_Result,
	DHT_Result_Ready:        bool,
}

Torrent_Session_Loop_Open :: proc(
	loop: ^Torrent_Session_Loop,
	torrent: ^Torrent,
	output_directory: string,
	peer_id: [20]byte,
	port: u16,
) -> Torrent_Loop_Error {
	if loop == nil || torrent == nil {
		return .Invalid_Loop
	}
	if loop.State != .Closed {
		return .Invalid_State
	}
	if len(torrent.Piece_Hashes) == 0 && torrent.Total_Length != 0 {
		return .Invalid_Torrent
	}
	storage_error := Torrent_Storage_Open(&loop.Storage, torrent, output_directory)
	if storage_error != .None {
		return .Storage
	}
	piece_count := u32(len(torrent.Piece_Hashes))
	scheduler_error := Piece_Scheduler_Init(&loop.Scheduler, piece_count, torrent.Piece_Length, torrent.Total_Length, 30*time.Second)
	if scheduler_error != .None {
		Torrent_Storage_Close(&loop.Storage)
		return .Scheduler
	}
	if Piece_Scheduler_Set_Completed(&loop.Scheduler, &loop.Storage.Pieces) != .None {
		Piece_Scheduler_Destroy(&loop.Scheduler)
		Torrent_Storage_Close(&loop.Storage)
		return .Scheduler
	}
	listen_port := loop_open_listeners(loop, port)
	request := Tracker_Announce_Request{
		Info_Hash = torrent.Info_Hash,
		Peer_ID = peer_id,
		Port = listen_port,
		Compact = true,
		Left = torrent.Total_Length,
	}
	tracker_error := Tracker_Manager_Init(&loop.Tracker, torrent, request)
	if tracker_error != .None && tracker_error != .No_Trackers {
		Piece_Scheduler_Destroy(&loop.Scheduler)
		Torrent_Storage_Close(&loop.Storage)
		return .Tracker
	}
	loop.State = .Paused
	loop.Error = .None
	loop.Info_Hash = torrent.Info_Hash
	loop.Peer_ID = peer_id
	loop.Port = listen_port
	loop.Peer_Limit = 50
	loop.Tick_Interval = 50 * time.Millisecond
	loop.Peer_Connect_Timeout = 5 * time.Second
	loop.Next_Peer_ID = 1
	loop.Port = listen_port
	loop.PEX_Enabled = Torrent_Allows_Peer_Exchange(torrent)
	if Torrent_Allows_DHT(torrent) {
		loop.DHT_Enabled = DHT_Client_Init(&loop.DHT, torrent, DHT_Node_ID_Generate(u64(time.to_unix_seconds(time.now()))), listen_port) == .None
	}
	loop.Stats_Time = time.now()
	loop.Stats_Downloaded = 0
	loop.Stats_Uploaded = 0
	return .None
}

Torrent_Session_Loop_Start :: proc(loop: ^Torrent_Session_Loop) -> Torrent_Loop_Error {
	if loop == nil {
		return .Invalid_Loop
	}
	sync.mutex_lock(&loop.Mutex)
	defer sync.mutex_unlock(&loop.Mutex)
	if loop.State != .Paused && loop.State != .Completed && loop.State != .Seeding {
		return .Invalid_State
	}
	if loop.Worker != nil {
		return .Invalid_State
	}
	loop.Stop_Requested = false
	loop.State = .Running
	worker := thread.create(torrent_session_loop_worker)
	if worker == nil {
		loop.State = .Failed
		loop.Error = .Out_Of_Memory
		return .Out_Of_Memory
	}
	worker.data = loop
	loop.Worker = worker
	thread.start(worker)
	return .None
}

Torrent_Session_Loop_Tick :: proc(loop: ^Torrent_Session_Loop, now: time.Time) -> Torrent_Loop_Error {
	if loop == nil {
		return .Invalid_Loop
	}
	sync.mutex_lock(&loop.Mutex)
	defer sync.mutex_unlock(&loop.Mutex)
	if loop.State != .Running && loop.State != .Completed && loop.State != .Seeding {
		return .Invalid_State
	}
	if loop.Stop_Requested {
		return .Invalid_State
	}
	left := loop_remaining_bytes_locked(loop)
	_ = Tracker_Manager_Set_Stats(&loop.Tracker, loop.Bytes_Uploaded, loop.Bytes_Downloaded, left)
	expired, expire_error := Piece_Scheduler_Expire_Requests(&loop.Scheduler, now)
	delete(expired)
	if expire_error != .None {
		loop.Error = .Scheduler
		loop.State = .Failed
		return .Scheduler
	}
	if Tracker_Manager_Announce_Due(&loop.Tracker, now) {
		response, tracker_error := Tracker_Manager_Announce(&loop.Tracker, now)
		if tracker_error == .Out_Of_Memory {
			loop.Error = .Tracker
			loop.State = .Failed
			Destroy_Tracker_Response(&response)
			return .Tracker
		}
		if tracker_error == .None {
			loop_add_tracker_peers_locked(loop, &response)
		}
		Destroy_Tracker_Response(&response)
	}
	loop_accept_peers_locked(loop)
	loop_consume_dht_result_locked(loop)
	loop_poll_peers_locked(loop)
	loop_update_rates_locked(loop, now)
	if Piece_Scheduler_Is_Seeding(&loop.Scheduler) {
		if loop.State != .Seeding {
			loop.State = .Seeding
			_ = Tracker_Manager_Set_Event(&loop.Tracker, .Completed)
		}
	} else if loop.State == .Seeding {
		loop.State = .Running
	}
	return .None
}

Torrent_Session_Loop_Snapshot :: proc(loop: ^Torrent_Session_Loop) -> (Torrent_Loop_Stats, Torrent_Loop_Error) {
	if loop == nil {
		return Torrent_Loop_Stats{}, .Invalid_Loop
	}
	sync.mutex_lock(&loop.Mutex)
	defer sync.mutex_unlock(&loop.Mutex)
	if loop.State == .Closed {
		return Torrent_Loop_Stats{}, .Invalid_State
	}
	connected: u32
	for peer in loop.Peers {
		if peer.Session.State == .Ready {
			connected += 1
		}
	}
	return Torrent_Loop_Stats{
		State = loop.State,
		Peer_Count = u32(len(loop.Peers)),
		Connected_Peers = connected,
		Bytes_Downloaded = loop.Bytes_Downloaded,
		Bytes_Uploaded = loop.Bytes_Uploaded,
		Download_Bytes_Per_Second = loop.Download_Bytes_Per_Second,
		Upload_Bytes_Per_Second = loop.Upload_Bytes_Per_Second,
		Seeding = loop.State == .Seeding,
	}, .None
}

Torrent_Session_Loop_Shutdown :: proc(loop: ^Torrent_Session_Loop) -> Torrent_Loop_Error {
	if loop == nil {
		return .Invalid_Loop
	}
	sync.mutex_lock(&loop.Mutex)
	if loop.State == .Closed {
		sync.mutex_unlock(&loop.Mutex)
		return .None
	}
	loop.Stop_Requested = true
	loop.State = .Stopping
	worker := loop.Worker
	loop.Worker = nil
	sync.mutex_unlock(&loop.Mutex)
	if worker != nil {
		thread.destroy(worker)
	}
	loop_close_listeners(loop)
	if loop.DHT_Worker != nil {
		sync.mutex_lock(&loop.Mutex)
		loop.DHT_Stop_Requested = true
		dht_worker := loop.DHT_Worker
		loop.DHT_Worker = nil
		sync.mutex_unlock(&loop.Mutex)
		thread.destroy(dht_worker)
	}
	Destroy_DHT_Lookup_Result(&loop.DHT_Result)
	delete(loop.DHT_Bootstrap)
	if loop.DHT_Enabled {
		DHT_Client_Destroy(&loop.DHT)
		loop.DHT_Enabled = false
	}
	_ = Tracker_Manager_Set_Event(&loop.Tracker, .Stopped)
	response, _ := Tracker_Manager_Announce(&loop.Tracker, time.now())
	Destroy_Tracker_Response(&response)

	sync.mutex_lock(&loop.Mutex)
	for peer in loop.Peers {
		if peer.Registered {
			_ = Piece_Scheduler_Remove_Peer(&loop.Scheduler, peer.ID)
		}
		Destroy_Peer_Session(&peer.Session)
		delete(peer.Address)
		free(peer)
	}
	delete(loop.Peers)
	loop.Peers = nil
	Tracker_Manager_Destroy(&loop.Tracker)
	Piece_Scheduler_Destroy(&loop.Scheduler)
	Torrent_Storage_Close(&loop.Storage)
	loop.State = .Closed
	loop.Error = .None
	sync.mutex_unlock(&loop.Mutex)
	return .None
}

Torrent_Session_Loop_Destroy :: proc(loop: ^Torrent_Session_Loop) {
	if loop != nil {
		_ = Torrent_Session_Loop_Shutdown(loop)
	}
}

loop_open_listeners :: proc(loop: ^Torrent_Session_Loop, port: u16) -> u16 {
	if loop == nil {
		return port
	}
	actual_port := port
	listener, listener_error := net.listen_tcp(net.Endpoint{address = net.IP4_Any, port = int(port)})
	if listener_error == nil && net.set_blocking(listener, false) == nil {
		loop.Listener = listener
		loop.Listener_Open = true
		bound, bound_error := net.bound_endpoint(listener)
		if bound_error == nil && bound.port > 0 {
			actual_port = u16(bound.port)
		}
	} else if listener_error == nil {
		net.close(listener)
	}
	listener6, listener6_error := net.listen_tcp(net.Endpoint{address = net.IP6_Any, port = int(actual_port)})
	if listener6_error == nil && net.set_blocking(listener6, false) == nil {
		loop.Listener6 = listener6
		loop.Listener6_Open = true
	} else if listener6_error == nil {
		net.close(listener6)
	}
	return actual_port
}

loop_close_listeners :: proc(loop: ^Torrent_Session_Loop) {
	if loop == nil {
		return
	}
	if loop.Listener_Open {
		net.close(loop.Listener)
		loop.Listener_Open = false
	}
	if loop.Listener6_Open {
		net.close(loop.Listener6)
		loop.Listener6_Open = false
	}
}

loop_accept_peers_locked :: proc(loop: ^Torrent_Session_Loop) {
	if loop == nil || len(loop.Peers) >= int(loop.Peer_Limit) {
		return
	}
	for attempt := 0; attempt < 8 && len(loop.Peers) < int(loop.Peer_Limit); attempt += 1 {
		if !loop.Listener_Open {
			break
		}
		accepted, source, accept_error := net.accept_tcp(loop.Listener)
		if accept_error != nil {
			break
		}
		if net.set_blocking(accepted, false) != nil {
			net.close(accepted)
			continue
		}
		loop_add_incoming_peer_locked(loop, accepted, source)
	}
	for attempt := 0; attempt < 8 && len(loop.Peers) < int(loop.Peer_Limit); attempt += 1 {
		if !loop.Listener6_Open {
			break
		}
		accepted, source, accept_error := net.accept_tcp(loop.Listener6)
		if accept_error != nil {
			break
		}
		if net.set_blocking(accepted, false) != nil {
			net.close(accepted)
			continue
		}
		loop_add_incoming_peer_locked(loop, accepted, source)
	}
}

loop_add_incoming_peer_locked :: proc(loop: ^Torrent_Session_Loop, socket: net.TCP_Socket, source: net.Endpoint) {
	endpoint: PEX_Peer
	switch address in source.address {
	case net.IP4_Address:
		endpoint.IP[0] = address[0]
		endpoint.IP[1] = address[1]
		endpoint.IP[2] = address[2]
		endpoint.IP[3] = address[3]
	case net.IP6_Address:
		endpoint.IPv6 = true
		for index := 0; index < 8; index += 1 {
			value := u16(address[index])
			endpoint.IP[index*2] = byte(value >> 8)
			endpoint.IP[index*2+1] = byte(value)
		}
	}
	endpoint.Port = u16(source.port)
	address := PEX_Peer_Address(endpoint)
	if loop_has_peer_address(loop, address) {
		delete(address)
		net.close(socket)
		return
	}
	peer := new(Torrent_Loop_Peer, context.allocator)
	peer.ID = loop.Next_Peer_ID
	loop.Next_Peer_ID += 1
	peer.Address = address
	peer.Endpoint = endpoint
	peer_error := Peer_Session_Init(&peer.Session, loop.Info_Hash, loop.Peer_ID, loop.Scheduler.Piece_Count, loop.Scheduler.Piece_Length, loop.Scheduler.Total_Length)
	if peer_error == .None {
		peer_error = Peer_Session_Accept(&peer.Session, socket, loop.Peer_Connect_Timeout)
	}
	if peer_error != .None {
		Destroy_Peer_Session(&peer.Session)
		delete(peer.Address)
		free(peer)
		return
	}
	append(&loop.Peers, peer)
}

torrent_session_loop_dht_worker :: proc(thread_value: ^thread.Thread) {
	context = runtime.default_context()
	if thread_value == nil {
		return
	}
	loop := cast(^Torrent_Session_Loop)thread_value.data
	if loop == nil {
		return
	}
	bootstrap: [dynamic]DHT_Node
	sync.mutex_lock(&loop.Mutex)
	stop := loop.DHT_Stop_Requested || !loop.DHT_Enabled
	info_hash := loop.Info_Hash
	port := loop.Port
	append(&bootstrap, ..loop.DHT_Bootstrap[:])
	sync.mutex_unlock(&loop.Mutex)
	if stop || len(bootstrap) == 0 {
		delete(bootstrap)
		return
	}
	options := DHT_Default_Network_Options()
	options.Timeout = time.Second
	options.Max_Queries = 8
	result, lookup_error := DHT_Client_Get_Peers(&loop.DHT, info_hash, bootstrap[:], options)
	delete(bootstrap)
	if lookup_error == .None && len(result.Targets) > 0 {
		_, _ = DHT_Client_Announce_Peer(&loop.DHT, info_hash, port, result.Targets[:], options)
	}
	sync.mutex_lock(&loop.Mutex)
	if loop.DHT_Stop_Requested {
		sync.mutex_unlock(&loop.Mutex)
		Destroy_DHT_Lookup_Result(&result)
		return
	}
	Destroy_DHT_Lookup_Result(&loop.DHT_Result)
	loop.DHT_Result = result
	loop.DHT_Result_Ready = lookup_error == .None
	sync.mutex_unlock(&loop.Mutex)
}

torrent_session_loop_worker :: proc(thread_value: ^thread.Thread) {
	context = runtime.default_context()
	if thread_value == nil {
		return
	}
	loop := cast(^Torrent_Session_Loop)thread_value.data
	if loop == nil {
		return
	}
	for {
		sync.mutex_lock(&loop.Mutex)
		stop := loop.Stop_Requested
		interval := loop.Tick_Interval
		sync.mutex_unlock(&loop.Mutex)
		if stop {
			return
		}
		_ = Torrent_Session_Loop_Tick(loop, time.now())
		time.sleep(interval)
	}
}

loop_add_tracker_peers_locked :: proc(loop: ^Torrent_Session_Loop, response: ^Tracker_Announce_Response) {
	if response == nil {
		return
	}
	for tracker_peer in response.Peers {
		endpoint: PEX_Peer
		endpoint.IP[0] = tracker_peer.IP[0]
		endpoint.IP[1] = tracker_peer.IP[1]
		endpoint.IP[2] = tracker_peer.IP[2]
		endpoint.IP[3] = tracker_peer.IP[3]
		endpoint.Port = tracker_peer.Port
		loop_add_dht_bootstrap_locked(loop, endpoint)
		address := PEX_Peer_Address(endpoint)
		loop_add_peer_address_locked(loop, address, endpoint)
	}
	for tracker_peer in response.Peers6 {
		endpoint: PEX_Peer
		endpoint.IP = tracker_peer.IP
		endpoint.Port = tracker_peer.Port
		endpoint.IPv6 = true
		loop_add_dht_bootstrap_locked(loop, endpoint)
		address := PEX_Peer_Address(endpoint)
		loop_add_peer_address_locked(loop, address, endpoint)
	}
}

loop_add_dht_bootstrap_locked :: proc(loop: ^Torrent_Session_Loop, endpoint: PEX_Peer) {
	if loop == nil || !loop.DHT_Enabled || endpoint.Port == 0 {
		return
	}
	for existing in loop.DHT_Bootstrap {
		if existing.Endpoint.IP == endpoint.IP && existing.Endpoint.Port == endpoint.Port && existing.Endpoint.IPv6 == endpoint.IPv6 {
			return
		}
	}
	node: DHT_Node
	node.Endpoint.IP = endpoint.IP
	node.Endpoint.Port = endpoint.Port
	node.Endpoint.IPv6 = endpoint.IPv6
	append(&loop.DHT_Bootstrap, node)
	if loop.DHT_Worker == nil && !loop.DHT_Worker_Started {
		worker := thread.create(torrent_session_loop_dht_worker)
		if worker != nil {
			worker.data = loop
			loop.DHT_Worker = worker
			loop.DHT_Worker_Started = true
			loop.DHT_Stop_Requested = false
			thread.start(worker)
		}
	}
}

loop_consume_dht_result_locked :: proc(loop: ^Torrent_Session_Loop) {
	if loop == nil || !loop.DHT_Result_Ready {
		return
	}
	for endpoint in loop.DHT_Result.Peers {
		peer: PEX_Peer
		peer.IP = endpoint.IP
		peer.Port = endpoint.Port
		peer.IPv6 = endpoint.IPv6
		address := PEX_Peer_Address(peer)
		loop_add_peer_address_locked(loop, address, peer)
	}
	Destroy_DHT_Lookup_Result(&loop.DHT_Result)
	loop.DHT_Result_Ready = false
}

loop_add_peer_address_locked :: proc(loop: ^Torrent_Session_Loop, address: string, endpoint: PEX_Peer) {
	if loop == nil || len(loop.Peers) >= int(loop.Peer_Limit) || loop_has_peer_address(loop, address) {
		delete(address)
		return
	}
	peer := new(Torrent_Loop_Peer, context.allocator)
	peer.ID = loop.Next_Peer_ID
	loop.Next_Peer_ID += 1
	peer.Address = address
	peer.Endpoint = endpoint
	peer_error := Peer_Session_Init(&peer.Session, loop.Info_Hash, loop.Peer_ID, loop.Scheduler.Piece_Count, loop.Scheduler.Piece_Length, loop.Scheduler.Total_Length)
	if peer_error == .None {
		peer_error = Peer_Session_Connect(&peer.Session, address, loop.Peer_Connect_Timeout)
	}
	if peer_error != .None {
		Destroy_Peer_Session(&peer.Session)
		delete(peer.Address)
		free(peer)
		return
	}
	append(&loop.Peers, peer)
}

loop_poll_peers_locked :: proc(loop: ^Torrent_Session_Loop) {
	index := 0
	for index < len(loop.Peers) {
		peer := loop.Peers[index]
		poll_error := Peer_Session_Poll(&peer.Session)
		if poll_error != .None && poll_error != .Timeout {
			loop_remove_peer_locked(loop, index)
			continue
		}
		if peer.Session.State == .Ready && !peer.Registered {
			if Piece_Scheduler_Add_Peer(&loop.Scheduler, peer.ID, &peer.Session.Remote_Pieces, &peer.Session) != .None {
				loop_remove_peer_locked(loop, index)
				continue
			}
			peer.Registered = true
		}
		if loop.PEX_Enabled && peer.Session.State == .Ready && !peer.PEX_Handshake_Sent {
			payload := PEX_Encode_Extension_Handshake()
			if Peer_Session_Queue_Extended(&peer.Session, 0, payload) == .None {
				peer.PEX_Handshake_Sent = true
			}
			delete(payload)
		}
		loop_process_peer_events_locked(loop, peer)
		loop_queue_pex_snapshot_locked(loop, peer)
		if peer.Session.State == .Failed || peer.Session.State == .Closed {
			loop_remove_peer_locked(loop, index)
			continue
		}
		if peer.Registered {
			loop_queue_peer_requests_locked(loop, peer)
		}
		index += 1
	}
}

loop_process_peer_events_locked :: proc(loop: ^Torrent_Session_Loop, peer: ^Torrent_Loop_Peer) {
	for {
		event, found := Peer_Session_Next_Event(&peer.Session)
		if !found {
			return
		}
		switch event.Kind {
		case .Bitfield:
			bitfield, bitfield_error := Bitfield_From_Raw(event.Payload, loop.Scheduler.Piece_Count)
			if bitfield_error == .None {
				_ = Piece_Scheduler_Update_Peer_Bitfield(&loop.Scheduler, peer.ID, &bitfield)
			}
			Destroy_Bitfield(&bitfield)
		case .Have:
			_ = Piece_Scheduler_Peer_Have(&loop.Scheduler, peer.ID, event.Index)
		case .Choke:
			_ = Piece_Scheduler_Set_Peer_Choked(&loop.Scheduler, peer.ID, true)
		case .Unchoke:
			_ = Piece_Scheduler_Set_Peer_Choked(&loop.Scheduler, peer.ID, false)
		case .Piece:
			if Torrent_Storage_Write_Block(&loop.Storage, event.Index, event.Begin, event.Payload) == .None {
				loop.Bytes_Downloaded += u64(len(event.Payload))
				_ = Piece_Scheduler_Complete_Block(&loop.Scheduler, event.Index, event.Begin)
				valid, _ := Torrent_Storage_Verify_Piece(&loop.Storage, event.Index)
				if valid {
					_ = Piece_Scheduler_Complete_Piece(&loop.Scheduler, event.Index)
				}
			}
		case .Request:
			if !peer.Session.Local_Choking {
				block, alloc_error := make([]byte, int(event.Length), context.allocator)
				if alloc_error == nil {
					if Torrent_Storage_Read(&loop.Storage, u64(event.Index)*loop.Scheduler.Piece_Length+u64(event.Begin), block) == .None && Peer_Session_Queue_Piece(&peer.Session, event.Index, event.Begin, block) == .None {
						loop.Bytes_Uploaded += u64(len(block))
					}
					delete(block)
				}
			}
		case .Extended:
			loop_process_pex_event_locked(loop, peer, event.Payload)
		case .Handshake, .Keep_Alive, .Interested, .Not_Interested, .Cancel, .Port:
			{}
		}
		Destroy_Peer_Event(&event)
	}
}

loop_process_pex_event_locked :: proc(loop: ^Torrent_Session_Loop, peer: ^Torrent_Loop_Peer, payload: []byte) {
	if !loop.PEX_Enabled || peer == nil || len(payload) == 0 {
		return
	}
	extension_id := payload[0]
	if extension_id == 0 {
		remote_id, parse_error := PEX_Parse_Extension_Handshake(payload[1:])
		if parse_error == .None {
			peer.Remote_PEX_ID = remote_id
		}
		return
	}
	if peer.Remote_PEX_ID == 0 || extension_id != peer.Remote_PEX_ID {
		return
	}
	message, parse_error := PEX_Parse_Message(payload[1:])
	if parse_error == .None {
		for added in message.Added {
			address := PEX_Peer_Address(added)
			loop_add_peer_address_locked(loop, address, added)
		}
	}
	Destroy_PEX_Message(&message)
}

loop_queue_pex_snapshot_locked :: proc(loop: ^Torrent_Session_Loop, peer: ^Torrent_Loop_Peer) {
	if !loop.PEX_Enabled || peer == nil || peer.Remote_PEX_ID == 0 || peer.Session.State != .Ready {
		return
	}
	now := time.now()
	if time.diff(peer.PEX_Last_Sent, now) < 30*time.Second {
		return
	}
	added: [dynamic]PEX_Peer
	for other in loop.Peers {
		if other == peer || other.Session.State != .Ready || other.Endpoint.Port == 0 {
			continue
		}
		append(&added, other.Endpoint)
	}
	if len(added) == 0 {
		delete(added)
		return
	}
	payload := PEX_Encode_Message(added[:], nil)
	if Peer_Session_Queue_Extended(&peer.Session, peer.Remote_PEX_ID, payload) == .None {
		peer.PEX_Last_Sent = now
	}
	delete(payload)
	delete(added)
}

loop_queue_peer_requests_locked :: proc(loop: ^Torrent_Session_Loop, peer: ^Torrent_Loop_Peer) {
	for {
		request, found, request_error := Piece_Scheduler_Next_Request(&loop.Scheduler, peer.ID, time.now())
		if !found || request_error != .None {
			return
		}
		if Peer_Session_Queue_Request(&peer.Session, request.Index, request.Begin, request.Length) != .None {
			_ = Piece_Scheduler_Drop_Request(&loop.Scheduler, peer.ID, request.Index, request.Begin)
			return
		}
	}
}

loop_remove_peer_locked :: proc(loop: ^Torrent_Session_Loop, index: int) {
	peer := loop.Peers[index]
	if peer.Registered {
		_ = Piece_Scheduler_Remove_Peer(&loop.Scheduler, peer.ID)
	}
	Destroy_Peer_Session(&peer.Session)
	delete(peer.Address)
	free(peer)
	copy(loop.Peers[index:], loop.Peers[index+1:])
	resize(&loop.Peers, len(loop.Peers)-1)
}

loop_has_peer_address :: proc(loop: ^Torrent_Session_Loop, address: string) -> bool {
	for peer in loop.Peers {
		if peer.Address == address {
			return true
		}
	}
	return false
}

loop_remaining_bytes_locked :: proc(loop: ^Torrent_Session_Loop) -> u64 {
	left := loop.Scheduler.Total_Length
	for index: u32 = 0; index < loop.Scheduler.Piece_Count; index += 1 {
		if !Torrent_Storage_Has_Piece(&loop.Storage, index) {
			continue
		}
		piece_length := u64(Piece_Length(index, loop.Scheduler.Piece_Length, loop.Scheduler.Total_Length))
		left -= piece_length if piece_length <= left else left
	}
	return left
}

loop_update_rates_locked :: proc(loop: ^Torrent_Session_Loop, now: time.Time) {
	elapsed := time.diff(loop.Stats_Time, now)
	if elapsed <= 0 {
		return
	}
	seconds := time.duration_seconds(elapsed)
	loop.Download_Bytes_Per_Second = f64(loop.Bytes_Downloaded-loop.Stats_Downloaded) / seconds
	loop.Upload_Bytes_Per_Second = f64(loop.Bytes_Uploaded-loop.Stats_Uploaded) / seconds
	loop.Stats_Downloaded = loop.Bytes_Downloaded
	loop.Stats_Uploaded = loop.Bytes_Uploaded
	loop.Stats_Time = now
}
