package durrent

import "core:sync"
import "core:time"

Piece_Request :: struct {
	Peer_ID:  u64,
	Index:    u32,
	Begin:    u32,
	Length:   u32,
	Sent_At:  time.Time,
	Attempts: u32,
}

Piece_Scheduler_Peer :: struct {
	ID:         u64,
	Pieces:     Bitfield,
	In_Flight:  [dynamic]Piece_Request,
	Session:    ^Peer_Session,
	Choked:     bool,
}

Piece_Scheduler :: struct {
	Mutex:                    sync.Mutex,
	Piece_Count:              u32,
	Piece_Length:             u64,
	Total_Length:             u64,
	Completed:                Bitfield,
	Block_Received:           [dynamic][]byte,
	Availability:             []u32,
	Peers:                    [dynamic]Piece_Scheduler_Peer,
	Request_Timeout:          time.Duration,
	Max_Requests_Per_Peer:    u32,
	Endgame_Piece_Threshold:  u32,
	Seeding:                  bool,
}

Piece_Scheduler_Error :: enum {
	None,
	Invalid_Scheduler,
	Invalid_Piece,
	Invalid_Peer,
	Peer_Exists,
	Choked,
	No_Request,
	Invalid_Bitfield,
	Out_Of_Memory,
	Peer,
}

Piece_Scheduler_Init :: proc(
	scheduler: ^Piece_Scheduler,
	piece_count: u32,
	piece_length, total_length: u64,
	request_timeout: time.Duration,
) -> Piece_Scheduler_Error {
	if scheduler == nil || piece_length == 0 {
		return .Invalid_Scheduler
	}
	Piece_Scheduler_Destroy(scheduler)
	count, count_ok := Piece_Count(total_length, piece_length)
	if !count_ok || count != piece_count {
		return .Invalid_Scheduler
	}
	completed, completed_error := Bitfield_Init(piece_count)
	if completed_error != .None {
		return .Out_Of_Memory
	}
	block_received: [dynamic][]byte
	for index: u32 = 0; index < piece_count; index += 1 {
		length := Piece_Length(index, piece_length, total_length)
		block_count := u32((u64(length)+u64(Block_Size)-1)/u64(Block_Size))
		bitmap, bitmap_error := make([]byte, int((u64(block_count)+7)/8), context.allocator)
		if bitmap_error != nil {
			for existing in block_received {
				delete(existing)
			}
			delete(block_received)
			Destroy_Bitfield(&completed)
			return .Out_Of_Memory
		}
		append(&block_received, bitmap)
	}
	availability, alloc_error := make([]u32, int(piece_count), context.allocator)
	if alloc_error != nil {
		for existing in block_received {
			delete(existing)
		}
		delete(block_received)
		Destroy_Bitfield(&completed)
		return .Out_Of_Memory
	}
	scheduler.Piece_Count = piece_count
	scheduler.Piece_Length = piece_length
	scheduler.Total_Length = total_length
	scheduler.Completed = completed
	scheduler.Block_Received = block_received
	scheduler.Availability = availability
	scheduler.Request_Timeout = request_timeout
	scheduler.Max_Requests_Per_Peer = 5
	scheduler.Endgame_Piece_Threshold = 2
	scheduler.Seeding = piece_count == 0
	return .None
}

Piece_Scheduler_Destroy :: proc(scheduler: ^Piece_Scheduler) {
	if scheduler == nil {
		return
	}
	sync.mutex_lock(&scheduler.Mutex)
	defer sync.mutex_unlock(&scheduler.Mutex)
	for &peer in scheduler.Peers {
		Destroy_Bitfield(&peer.Pieces)
		delete(peer.In_Flight)
	}
	delete(scheduler.Peers)
	Destroy_Bitfield(&scheduler.Completed)
	for bitmap in scheduler.Block_Received {
		delete(bitmap)
	}
	delete(scheduler.Block_Received)
	delete(scheduler.Availability)
	scheduler.Peers = nil
	scheduler.Block_Received = nil
	scheduler.Availability = nil
	scheduler.Piece_Count = 0
	scheduler.Piece_Length = 0
	scheduler.Total_Length = 0
	scheduler.Request_Timeout = 0
	scheduler.Max_Requests_Per_Peer = 0
	scheduler.Endgame_Piece_Threshold = 0
	scheduler.Seeding = false
}

Piece_Scheduler_Add_Peer :: proc(
	scheduler: ^Piece_Scheduler,
	id: u64,
	pieces: ^Bitfield,
	session: ^Peer_Session,
) -> Piece_Scheduler_Error {
	if scheduler == nil || pieces == nil {
		return .Invalid_Scheduler
	}
	sync.mutex_lock(&scheduler.Mutex)
	defer sync.mutex_unlock(&scheduler.Mutex)
	if scheduler.Piece_Count != pieces.Piece_Count {
		return .Invalid_Bitfield
	}
	if piece_scheduler_find_peer(scheduler, id) != nil {
		return .Peer_Exists
	}
	copy, copy_error := Bitfield_From_Raw(pieces.Bytes, scheduler.Piece_Count)
	if copy_error != .None {
		return .Out_Of_Memory
	}
	for index: u32 = 0; index < scheduler.Piece_Count; index += 1 {
		if Bitfield_Has_Piece(&copy, index) {
			scheduler.Availability[index] += 1
		}
	}
	append(&scheduler.Peers, Piece_Scheduler_Peer{
		ID = id,
		Pieces = copy,
		Session = session,
		Choked = true,
	})
	return .None
}

Piece_Scheduler_Remove_Peer :: proc(scheduler: ^Piece_Scheduler, id: u64) -> Piece_Scheduler_Error {
	if scheduler == nil {
		return .Invalid_Scheduler
	}
	sync.mutex_lock(&scheduler.Mutex)
	defer sync.mutex_unlock(&scheduler.Mutex)
	for &peer, peer_index in scheduler.Peers {
		if peer.ID != id {
			continue
		}
		for index: u32 = 0; index < scheduler.Piece_Count; index += 1 {
			if Bitfield_Has_Piece(&peer.Pieces, index) {
				scheduler.Availability[index] -= 1
			}
		}
		Destroy_Bitfield(&peer.Pieces)
		delete(peer.In_Flight)
		copy(scheduler.Peers[peer_index:], scheduler.Peers[peer_index+1:])
		resize(&scheduler.Peers, len(scheduler.Peers)-1)
		return .None
	}
	return .Invalid_Peer
}

Piece_Scheduler_Update_Peer_Bitfield :: proc(scheduler: ^Piece_Scheduler, id: u64, pieces: ^Bitfield) -> Piece_Scheduler_Error {
	if scheduler == nil || pieces == nil {
		return .Invalid_Scheduler
	}
	sync.mutex_lock(&scheduler.Mutex)
	defer sync.mutex_unlock(&scheduler.Mutex)
	if pieces.Piece_Count != scheduler.Piece_Count {
		return .Invalid_Bitfield
	}
	peer := piece_scheduler_find_peer(scheduler, id)
	if peer == nil {
		return .Invalid_Peer
	}
	for index: u32 = 0; index < scheduler.Piece_Count; index += 1 {
		old := Bitfield_Has_Piece(&peer.Pieces, index)
		new := Bitfield_Has_Piece(pieces, index)
		if old == new {
			continue
		}
		if new {
			scheduler.Availability[index] += 1
		} else {
			scheduler.Availability[index] -= 1
		}
	}
	copy, copy_error := Bitfield_From_Raw(pieces.Bytes, scheduler.Piece_Count)
	if copy_error != .None {
		return .Out_Of_Memory
	}
	Destroy_Bitfield(&peer.Pieces)
	peer.Pieces = copy
	return .None
}

Piece_Scheduler_Peer_Have :: proc(scheduler: ^Piece_Scheduler, id: u64, index: u32) -> Piece_Scheduler_Error {
	if scheduler == nil {
		return .Invalid_Scheduler
	}
	sync.mutex_lock(&scheduler.Mutex)
	defer sync.mutex_unlock(&scheduler.Mutex)
	if index >= scheduler.Piece_Count {
		return .Invalid_Piece
	}
	peer := piece_scheduler_find_peer(scheduler, id)
	if peer == nil {
		return .Invalid_Peer
	}
	if !Bitfield_Has_Piece(&peer.Pieces, index) {
		Bitfield_Set_Piece(&peer.Pieces, index)
		scheduler.Availability[index] += 1
	}
	return .None
}

Piece_Scheduler_Set_Peer_Choked :: proc(scheduler: ^Piece_Scheduler, id: u64, choked: bool) -> Piece_Scheduler_Error {
	if scheduler == nil {
		return .Invalid_Scheduler
	}
	sync.mutex_lock(&scheduler.Mutex)
	defer sync.mutex_unlock(&scheduler.Mutex)
	peer := piece_scheduler_find_peer(scheduler, id)
	if peer == nil {
		return .Invalid_Peer
	}
	peer.Choked = choked
	return .None
}

Piece_Scheduler_Set_Completed :: proc(scheduler: ^Piece_Scheduler, completed: ^Bitfield) -> Piece_Scheduler_Error {
	if scheduler == nil || completed == nil {
		return .Invalid_Scheduler
	}
	sync.mutex_lock(&scheduler.Mutex)
	defer sync.mutex_unlock(&scheduler.Mutex)
	if completed.Piece_Count != scheduler.Piece_Count {
		return .Invalid_Bitfield
	}
	copy, copy_error := Bitfield_From_Raw(completed.Bytes, scheduler.Piece_Count)
	if copy_error != .None {
		return .Out_Of_Memory
	}
	Destroy_Bitfield(&scheduler.Completed)
	scheduler.Completed = copy
	for index: u32 = 0; index < scheduler.Piece_Count; index += 1 {
		if Bitfield_Has_Piece(&scheduler.Completed, index) {
			piece_scheduler_mark_all_blocks_locked(scheduler, index)
		}
	}
	scheduler.Seeding = Bitfield_Is_Complete(&scheduler.Completed)
	return .None
}

Piece_Scheduler_Next_Request :: proc(
	scheduler: ^Piece_Scheduler,
	peer_id: u64,
	now: time.Time,
) -> (Piece_Request, bool, Piece_Scheduler_Error) {
	if scheduler == nil {
		return Piece_Request{}, false, .Invalid_Scheduler
	}
	sync.mutex_lock(&scheduler.Mutex)
	defer sync.mutex_unlock(&scheduler.Mutex)
	peer := piece_scheduler_find_peer(scheduler, peer_id)
	if peer == nil {
		return Piece_Request{}, false, .Invalid_Peer
	}
	if peer.Choked {
		return Piece_Request{}, false, .Choked
	}
	if u32(len(peer.In_Flight)) >= scheduler.Max_Requests_Per_Peer {
		return Piece_Request{}, false, .No_Request
	}
	endgame := piece_scheduler_endgame_locked(scheduler)
	best_piece: u32
	best_begin: u32
	best_length: u32
	best_availability := u32(0xffffffff)
	found := false
	for index: u32 = 0; index < scheduler.Piece_Count; index += 1 {
		if Bitfield_Has_Piece(&scheduler.Completed, index) || !Bitfield_Has_Piece(&peer.Pieces, index) {
			continue
		}
		piece_length := Piece_Length(index, scheduler.Piece_Length, scheduler.Total_Length)
		if piece_length == 0 {
			continue
		}
		begin, length, block_found := piece_scheduler_find_block_locked(scheduler, peer, index, piece_length, endgame)
		if !block_found {
			continue
		}
		availability := scheduler.Availability[index]
		if found && availability > best_availability {
			continue
		}
		best_piece = index
		best_begin = begin
		best_length = length
		best_availability = availability
		found = true
	}
	if !found {
		return Piece_Request{}, false, .No_Request
	}
	request := Piece_Request{
		Peer_ID = peer_id,
		Index = best_piece,
		Begin = best_begin,
		Length = best_length,
		Sent_At = now,
		Attempts = 1,
	}
	append(&peer.In_Flight, request)
	return request, true, .None
}

Piece_Scheduler_Drop_Request :: proc(scheduler: ^Piece_Scheduler, peer_id: u64, index, begin: u32) -> Piece_Scheduler_Error {
	if scheduler == nil {
		return .Invalid_Scheduler
	}
	sync.mutex_lock(&scheduler.Mutex)
	defer sync.mutex_unlock(&scheduler.Mutex)
	peer := piece_scheduler_find_peer(scheduler, peer_id)
	if peer == nil {
		return .Invalid_Peer
	}
	piece_scheduler_remove_request_locked(peer, index, begin)
	return .None
}

Piece_Scheduler_Complete_Block :: proc(scheduler: ^Piece_Scheduler, index, begin: u32) -> Piece_Scheduler_Error {
	if scheduler == nil {
		return .Invalid_Scheduler
	}
	sync.mutex_lock(&scheduler.Mutex)
	defer sync.mutex_unlock(&scheduler.Mutex)
	if index >= scheduler.Piece_Count {
		return .Invalid_Piece
	}
	if !piece_scheduler_block_valid(scheduler, index, begin) {
		return .Invalid_Piece
	}
	for &peer in scheduler.Peers {
		piece_scheduler_remove_request_locked(&peer, index, begin)
	}
	piece_scheduler_mark_block_received_locked(scheduler, index, begin)
	return .None
}

Piece_Scheduler_Complete_Piece :: proc(scheduler: ^Piece_Scheduler, index: u32) -> Piece_Scheduler_Error {
	if scheduler == nil {
		return .Invalid_Scheduler
	}
	sessions: [dynamic]^Peer_Session
	sync.mutex_lock(&scheduler.Mutex)
	if index >= scheduler.Piece_Count {
		sync.mutex_unlock(&scheduler.Mutex)
		return .Invalid_Piece
	}
	Bitfield_Set_Piece(&scheduler.Completed, index)
	piece_scheduler_mark_all_blocks_locked(scheduler, index)
	for &peer in scheduler.Peers {
		piece_scheduler_remove_piece_requests_locked(&peer, index)
		if peer.Session != nil {
			append(&sessions, peer.Session)
		}
	}
	scheduler.Seeding = Bitfield_Is_Complete(&scheduler.Completed)
	sync.mutex_unlock(&scheduler.Mutex)
	for session in sessions {
		_ = Peer_Session_Queue_Have(session, index)
	}
	delete(sessions)
	return .None
}

Piece_Scheduler_Expire_Requests :: proc(scheduler: ^Piece_Scheduler, now: time.Time) -> ([dynamic]Piece_Request, Piece_Scheduler_Error) {
	expired: [dynamic]Piece_Request
	if scheduler == nil {
		return expired, .Invalid_Scheduler
	}
	sync.mutex_lock(&scheduler.Mutex)
	defer sync.mutex_unlock(&scheduler.Mutex)
	if scheduler.Request_Timeout <= 0 {
		return expired, .None
	}
	for &peer in scheduler.Peers {
		index := 0
		for index < len(peer.In_Flight) {
			request := peer.In_Flight[index]
			if time.diff(request.Sent_At, now) < scheduler.Request_Timeout {
				index += 1
				continue
			}
			request.Attempts += 1
			append(&expired, request)
			copy(peer.In_Flight[index:], peer.In_Flight[index+1:])
			resize(&peer.In_Flight, len(peer.In_Flight)-1)
		}
	}
	return expired, .None
}

Piece_Scheduler_Is_Endgame :: proc(scheduler: ^Piece_Scheduler) -> bool {
	if scheduler == nil {
		return false
	}
	sync.mutex_lock(&scheduler.Mutex)
	defer sync.mutex_unlock(&scheduler.Mutex)
	return piece_scheduler_endgame_locked(scheduler)
}

Piece_Scheduler_Is_Seeding :: proc(scheduler: ^Piece_Scheduler) -> bool {
	if scheduler == nil {
		return false
	}
	sync.mutex_lock(&scheduler.Mutex)
	defer sync.mutex_unlock(&scheduler.Mutex)
	return scheduler.Seeding
}

Piece_Scheduler_Availability :: proc(scheduler: ^Piece_Scheduler, index: u32) -> (u32, bool) {
	if scheduler == nil {
		return 0, false
	}
	sync.mutex_lock(&scheduler.Mutex)
	defer sync.mutex_unlock(&scheduler.Mutex)
	if index >= scheduler.Piece_Count {
		return 0, false
	}
	return scheduler.Availability[index], true
}

Piece_Scheduler_Peer_Request_Count :: proc(scheduler: ^Piece_Scheduler, peer_id: u64) -> (u32, bool) {
	if scheduler == nil {
		return 0, false
	}
	sync.mutex_lock(&scheduler.Mutex)
	defer sync.mutex_unlock(&scheduler.Mutex)
	peer := piece_scheduler_find_peer(scheduler, peer_id)
	if peer == nil {
		return 0, false
	}
	return u32(len(peer.In_Flight)), true
}

piece_scheduler_block_valid :: proc(scheduler: ^Piece_Scheduler, index, begin: u32) -> bool {
	if index >= scheduler.Piece_Count || begin % Block_Size != 0 {
		return false
	}
	length := Piece_Length(index, scheduler.Piece_Length, scheduler.Total_Length)
	return length > 0 && begin < length
}

piece_scheduler_block_received :: proc(scheduler: ^Piece_Scheduler, index, begin: u32) -> bool {
	if !piece_scheduler_block_valid(scheduler, index, begin) || index >= u32(len(scheduler.Block_Received)) {
		return false
	}
	return piece_bitmap_has(scheduler.Block_Received[index], begin/Block_Size)
}

piece_scheduler_mark_block_received_locked :: proc(scheduler: ^Piece_Scheduler, index, begin: u32) {
	if index < u32(len(scheduler.Block_Received)) {
		piece_bitmap_set(scheduler.Block_Received[index], begin/Block_Size)
	}
}

piece_scheduler_mark_all_blocks_locked :: proc(scheduler: ^Piece_Scheduler, index: u32) {
	if index >= scheduler.Piece_Count || index >= u32(len(scheduler.Block_Received)) {
		return
	}
	length := Piece_Length(index, scheduler.Piece_Length, scheduler.Total_Length)
	block_count := u32((u64(length)+u64(Block_Size)-1)/u64(Block_Size))
	for block: u32 = 0; block < block_count; block += 1 {
		piece_bitmap_set(scheduler.Block_Received[index], block)
	}
}

piece_scheduler_find_peer :: proc(scheduler: ^Piece_Scheduler, id: u64) -> ^Piece_Scheduler_Peer {
	for &peer in scheduler.Peers {
		if peer.ID == id {
			return &peer
		}
	}
	return nil
}

piece_scheduler_find_block_locked :: proc(
	scheduler: ^Piece_Scheduler,
	peer: ^Piece_Scheduler_Peer,
	index: u32,
	piece_length: u32,
	endgame: bool,
) -> (u32, u32, bool) {
	block_count := u32((u64(piece_length)+u64(Block_Size)-1)/u64(Block_Size))
	for block_index: u32 = 0; block_index < block_count; block_index += 1 {
		begin := block_index * Block_Size
		length := piece_length - begin
		if length > Block_Size {
			length = Block_Size
		}
		if piece_scheduler_peer_has_request(peer, index, begin) || piece_scheduler_block_received(scheduler, index, begin) {
			continue
		}
		if !endgame && piece_scheduler_any_request(scheduler, index, begin) {
			continue
		}
		return begin, length, true
	}
	return 0, 0, false
}

piece_scheduler_peer_has_request :: proc(peer: ^Piece_Scheduler_Peer, index, begin: u32) -> bool {
	for request in peer.In_Flight {
		if request.Index == index && request.Begin == begin {
			return true
		}
	}
	return false
}

piece_scheduler_any_request :: proc(scheduler: ^Piece_Scheduler, index, begin: u32) -> bool {
	for &peer in scheduler.Peers {
		if piece_scheduler_peer_has_request(&peer, index, begin) {
			return true
		}
	}
	return false
}

piece_scheduler_endgame_locked :: proc(scheduler: ^Piece_Scheduler) -> bool {
	missing: u32
	for index: u32 = 0; index < scheduler.Piece_Count; index += 1 {
		if !Bitfield_Has_Piece(&scheduler.Completed, index) {
			missing += 1
		}
	}
	return missing <= scheduler.Endgame_Piece_Threshold
}

piece_scheduler_remove_request_locked :: proc(peer: ^Piece_Scheduler_Peer, index, begin: u32) {
	index_to_remove := -1
	for request, request_index in peer.In_Flight {
		if request.Index == index && request.Begin == begin {
			index_to_remove = request_index
			break
		}
	}
	if index_to_remove >= 0 {
		copy(peer.In_Flight[index_to_remove:], peer.In_Flight[index_to_remove+1:])
		resize(&peer.In_Flight, len(peer.In_Flight)-1)
	}
}

piece_scheduler_remove_piece_requests_locked :: proc(peer: ^Piece_Scheduler_Peer, index: u32) {
	request_index := 0
	for request_index < len(peer.In_Flight) {
		if peer.In_Flight[request_index].Index != index {
			request_index += 1
			continue
		}
		copy(peer.In_Flight[request_index:], peer.In_Flight[request_index+1:])
		resize(&peer.In_Flight, len(peer.In_Flight)-1)
	}
}
