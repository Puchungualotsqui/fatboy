package durrent

import "core:fmt"
import "core:net"
import "core:sync"
import "core:time"

Peer_State :: enum {
	New,
	Handshaking,
	Ready,
	Closed,
	Failed,
}

Peer_Session_Mode :: enum {
	Torrent,
	Metadata,
}

Peer_Error :: enum {
	None,
	Invalid_Peer,
	Invalid_State,
	Protocol,
	Info_Hash_Mismatch,
	Invalid_Bitfield,
	Invalid_Piece,
	Transport,
	Timeout,
	Disconnected,
	Out_Of_Memory,
}

Peer_Event_Kind :: enum {
	Handshake,
	Keep_Alive,
	Choke,
	Unchoke,
	Interested,
	Not_Interested,
	Have,
	Bitfield,
	Request,
	Piece,
	Cancel,
	Port,
	Extended,
}

Peer_Event :: struct {
	Kind:    Peer_Event_Kind,
	Index:   u32,
	Begin:   u32,
	Length:  u32,
	Port:    u16,
	Payload: []byte,
}

Peer_Session :: struct {
	Mutex:             sync.Mutex,
	Transport:         Peer_Transport,
	State:             Peer_State,
	Mode:              Peer_Session_Mode,
	Error:             Peer_Error,
	Expected_Info_Hash: Torrent_Hash,
	Local_Peer_ID:     [20]byte,
	Remote_Peer_ID:    [20]byte,
	Remote_Extensions: bool,
	Piece_Count:       u32,
	Piece_Length:      u64,
	Total_Length:      u64,
	Remote_Pieces:     Bitfield,
	Remote_Choking:    bool,
	Local_Choking:     bool,
	Remote_Interested: bool,
	Local_Interested:  bool,
	Receive_Buffer:    [dynamic]byte,
	Outgoing:          [dynamic]byte,
	Events:            [dynamic]Peer_Event,
	// Disabled by default. MSE is configured by the session owner before a
	// connection is started; this preserves established plaintext behavior.
	MSE_Policy:        MSE_Policy,
	MSE:               MSE_Handshake_Engine,
	MSE_Negotiating:   bool,
	MSE_Active:        bool,
	MSE_Negotiated:    bool,
	MSE_Inbound:       bool,
	MSE_Plaintext_Retry_Used: bool,
	MSE_Started_At:    time.Time,
}

Peer_Session_Init :: proc(
	session: ^Peer_Session,
	info_hash: Torrent_Hash,
	peer_id: [20]byte,
	piece_count: u32,
	piece_length, total_length: u64,
) -> Peer_Error {
	if session == nil || piece_length == 0 {
		return .Invalid_Peer
	}
	Destroy_Peer_Session(session)
	pieces, pieces_error := Bitfield_Init(piece_count)
	if pieces_error != .None {
		return .Out_Of_Memory
	}
	session.Expected_Info_Hash = info_hash
	session.Local_Peer_ID = peer_id
	session.Mode = .Torrent
	session.Piece_Count = piece_count
	session.Piece_Length = piece_length
	session.Total_Length = total_length
	session.Remote_Pieces = pieces
	session.Remote_Choking = true
	session.Local_Choking = true
	session.State = .New
	return .None
}

Peer_Session_Init_Metadata :: proc(
	session: ^Peer_Session,
	info_hash: Torrent_Hash,
	peer_id: [20]byte,
) -> Peer_Error {
	if session == nil {
		return .Invalid_Peer
	}
	Destroy_Peer_Session(session)
	session.Expected_Info_Hash = info_hash
	session.Local_Peer_ID = peer_id
	session.Mode = .Metadata
	session.Piece_Count = 0
	session.Piece_Length = 1
	session.Total_Length = 0
	session.Remote_Choking = true
	session.Local_Choking = true
	session.State = .New
	return .None
}


Destroy_Peer_Session :: proc(session: ^Peer_Session) {
	if session == nil {
		return
	}
	// Closing is idempotent and also releases an owned uTP UDP socket. A failed
	// session may already have closed it, which is safe.
	Peer_Transport_Close(&session.Transport)
	Destroy_Bitfield(&session.Remote_Pieces)
	delete(session.Receive_Buffer)
	delete(session.Outgoing)
	MSE_Handshake_Destroy(&session.MSE)
	for &event in session.Events {
		Destroy_Peer_Event(&event)
	}
	delete(session.Events)
	session.State = .Closed
	session.Error = .None
}

Destroy_Peer_Event :: proc(event: ^Peer_Event) {
	if event == nil {
		return
	}
	delete(event.Payload)
	event^ = Peer_Event{}
}

// Peer_Session_Set_MSE_Policy must be called before connecting or accepting.
// It is intentionally opt-in while the MSE transport bridge is introduced.
Peer_Session_Set_MSE_Policy :: proc(session: ^Peer_Session, policy: MSE_Policy) -> Peer_Error {
	if session == nil {
		return .Invalid_Peer
	}
	sync.mutex_lock(&session.Mutex)
	defer sync.mutex_unlock(&session.Mutex)
	if session.State != .New {
		return .Invalid_State
	}
	session.MSE_Policy = policy
	return .None
}

Peer_Session_Connect :: proc(session: ^Peer_Session, address: string, timeout: time.Duration) -> Peer_Error {
	if session == nil {
		return .Invalid_Peer
	}
	sync.mutex_lock(&session.Mutex)
	defer sync.mutex_unlock(&session.Mutex)
	if session.State != .New {
		return .Invalid_State
	}
	transport_error := Peer_Transport_Connect(&session.Transport, address, timeout)
	if transport_error != .None {
		return peer_session_fail_locked(session, peer_transport_error(transport_error))
	}
	return peer_session_begin_outbound_locked(session)
}

// Starts an outbound dial without waiting for DNS/TCP completion. Pair with
// Peer_Session_Poll_Connect from an event loop.
Peer_Session_Begin_Shared_UTP_Connect :: proc(session: ^Peer_Session, socket: net.UDP_Socket, remote: net.Endpoint) -> Peer_Error {
	if session == nil { return .Invalid_Peer }
	sync.mutex_lock(&session.Mutex)
	defer sync.mutex_unlock(&session.Mutex)
	if session.State != .New { return .Invalid_State }
	transport_error := Peer_Transport_Begin_Shared_UTP_Connect(&session.Transport, socket, remote)
	if transport_error != .None { return peer_session_fail_locked(session, peer_transport_error(transport_error)) }
	return .None
}

Peer_Session_Accept_UTP :: proc(session: ^Peer_Session, connection: ^UTP_Connection) -> Peer_Error {
	if session == nil { return .Invalid_Peer }
	sync.mutex_lock(&session.Mutex)
	defer sync.mutex_unlock(&session.Mutex)
	if session.State != .New { return .Invalid_State }
	transport_error := Peer_Transport_Adopt_UTP(&session.Transport, connection)
	if transport_error != .None { return peer_session_fail_locked(session, peer_transport_error(transport_error)) }
	return peer_session_begin_inbound_locked(session)
}

Peer_Session_Begin_UTP_Connect :: proc(session: ^Peer_Session, remote: net.Endpoint) -> Peer_Error {
	if session == nil {
		return .Invalid_Peer
	}
	sync.mutex_lock(&session.Mutex)
	defer sync.mutex_unlock(&session.Mutex)
	if session.State != .New {
		return .Invalid_State
	}
	transport_error := Peer_Transport_Begin_UTP_Connect(&session.Transport, remote)
	if transport_error != .None {
		return peer_session_fail_locked(session, peer_transport_error(transport_error))
	}
	return .None
}

Peer_Session_Begin_Connect :: proc(session: ^Peer_Session, address: string) -> Peer_Error {
	if session == nil {
		return .Invalid_Peer
	}
	sync.mutex_lock(&session.Mutex)
	defer sync.mutex_unlock(&session.Mutex)
	if session.State != .New {
		return .Invalid_State
	}
	transport_error := Peer_Transport_Begin_Connect(&session.Transport, address)
	if transport_error != .None {
		return peer_session_fail_locked(session, peer_transport_error(transport_error))
	}
	return .None
}

// Completes a previously started outbound dial when its worker finishes.
// done=false is not an error and means the dial is still pending.
Peer_Session_Poll_Connect :: proc(session: ^Peer_Session, timeout: time.Duration) -> (done: bool, err: Peer_Error) {
	if session == nil {
		return true, .Invalid_Peer
	}
	sync.mutex_lock(&session.Mutex)
	defer sync.mutex_unlock(&session.Mutex)
	if session.State != .New {
		return true, .Invalid_State
	}
	dial_done, transport_error := Peer_Transport_Poll_Connect(&session.Transport, timeout)
	if !dial_done {
		return false, .None
	}
	if transport_error != .None {
		return true, peer_session_fail_locked(session, peer_transport_error(transport_error))
	}
	return true, peer_session_begin_outbound_locked(session)
}

Peer_Session_Accept :: proc(session: ^Peer_Session, socket: net.TCP_Socket, timeout: time.Duration) -> Peer_Error {
	if session == nil {
		return .Invalid_Peer
	}
	sync.mutex_lock(&session.Mutex)
	defer sync.mutex_unlock(&session.Mutex)
	if session.State != .New {
		return .Invalid_State
	}
	transport_error := Peer_Transport_Adopt(&session.Transport, socket, timeout)
	if transport_error != .None {
		return peer_session_fail_locked(session, peer_transport_error(transport_error))
	}
	return peer_session_begin_inbound_locked(session)
}

Peer_Session_Begin :: proc(session: ^Peer_Session) -> Peer_Error {
	if session == nil {
		return .Invalid_Peer
	}
	sync.mutex_lock(&session.Mutex)
	defer sync.mutex_unlock(&session.Mutex)
	return peer_session_begin_locked(session)
}

Peer_Session_Feed :: proc(session: ^Peer_Session, data: []byte) -> Peer_Error {
	if session == nil {
		return .Invalid_Peer
	}
	sync.mutex_lock(&session.Mutex)
	defer sync.mutex_unlock(&session.Mutex)
	if session.State != .Handshaking && session.State != .Ready {
		return .Invalid_State
	}
	return peer_session_feed_locked(session, data)
}

Peer_Session_Poll :: proc(session: ^Peer_Session) -> Peer_Error {
	if session == nil {
		return .Invalid_Peer
	}
	sync.mutex_lock(&session.Mutex)
	defer sync.mutex_unlock(&session.Mutex)
	if session.State != .Handshaking && session.State != .Ready {
		return .Invalid_State
	}
	if len(session.Outgoing) > 0 {
		queued_bytes := len(session.Outgoing)
		queue_error := Peer_Transport_Queue(&session.Transport, session.Outgoing[:])
		if queue_error != .None {
			fmt.printf("[DURRENT-WIRE] queue failed error=%v bytes=%d\n", queue_error, queued_bytes)
			return peer_session_fail_locked(session, .Transport)
		}
		resize(&session.Outgoing, 0)
	}
	flush_error := Peer_Transport_Flush(&session.Transport)
	if flush_error != .None && flush_error != .Timeout {
		fmt.printf(
			"[DURRENT-WIRE] flush failed error=%v buffered=%d\n",
			flush_error,
			len(session.Transport.Write_Buffer),
		)
		return peer_session_fail_locked(session, .Transport)
	}
	if flush_error == .Timeout {
		return .Timeout
	}
	buffer: [16 * 1024]byte
	count, receive_error := Peer_Transport_Receive(&session.Transport, buffer[:])
	if receive_error == .Timeout {
		return .Timeout
	}
	if receive_error == .Disconnected {
		fmt.printf("[DURRENT-WIRE] peer disconnected\n")
		session.State = .Closed
		return .Disconnected
	}
	if receive_error != .None {
		fmt.printf("[DURRENT-WIRE] receive failed error=%v bytes=%d\n", receive_error, count)
		return peer_session_fail_locked(session, .Transport)
	}
	return peer_session_process_locked(session) if count == 0 else peer_session_feed_locked(session, buffer[:count])
}

Peer_Session_Take_Output :: proc(session: ^Peer_Session) -> ([]byte, Peer_Error) {
	if session == nil {
		return nil, .Invalid_Peer
	}
	sync.mutex_lock(&session.Mutex)
	defer sync.mutex_unlock(&session.Mutex)
	result, alloc_error := make([]byte, len(session.Outgoing), context.allocator)
	if alloc_error != nil {
		return nil, .Out_Of_Memory
	}
	copy(result, session.Outgoing[:])
	resize(&session.Outgoing, 0)
	return result, .None
}

Peer_Session_Next_Event :: proc(session: ^Peer_Session) -> (Peer_Event, bool) {
	if session == nil {
		return Peer_Event{}, false
	}
	sync.mutex_lock(&session.Mutex)
	defer sync.mutex_unlock(&session.Mutex)
	if len(session.Events) == 0 {
		return Peer_Event{}, false
	}
	result := session.Events[0]
	copy(session.Events[:], session.Events[1:])
	resize(&session.Events, len(session.Events)-1)
	return result, true
}

Peer_Session_Queue_Interested :: proc(session: ^Peer_Session, interested: bool) -> Peer_Error {
	kind := Wire_Message_Kind.Interested if interested else Wire_Message_Kind.Not_Interested
	if session == nil {
		return .Invalid_Peer
	}
	sync.mutex_lock(&session.Mutex)
	defer sync.mutex_unlock(&session.Mutex)
	if session.State != .Ready {
		return .Invalid_State
	}
	error := peer_session_queue_locked(session, Wire_Message_View{Kind = kind})
	if error == .None {
		session.Local_Interested = interested
	}
	return error
}

Peer_Session_Queue_Have :: proc(session: ^Peer_Session, index: u32) -> Peer_Error {
	if session == nil {
		return .Invalid_Peer
	}
	sync.mutex_lock(&session.Mutex)
	defer sync.mutex_unlock(&session.Mutex)
	if session.State != .Ready || index >= session.Piece_Count {
		return .Invalid_State
	}
	return peer_session_queue_locked(session, Wire_Message_View{Kind = .Have, Index = index})
}

Peer_Session_Queue_Piece :: proc(session: ^Peer_Session, index, begin: u32, payload: []byte) -> Peer_Error {
	if session == nil {
		return .Invalid_Peer
	}
	sync.mutex_lock(&session.Mutex)
	defer sync.mutex_unlock(&session.Mutex)
	if session.State != .Ready || !peer_piece_payload_valid(session, index, begin, payload) {
		return .Invalid_State
	}
	return peer_session_queue_locked(session, Wire_Message_View{
		Kind = .Piece,
		Index = index,
		Begin = begin,
		Payload = payload,
	})
}

Peer_Session_Queue_Request :: proc(session: ^Peer_Session, index, begin, length: u32) -> Peer_Error {
	if session == nil {
		return .Invalid_Peer
	}
	sync.mutex_lock(&session.Mutex)
	defer sync.mutex_unlock(&session.Mutex)
	if session.State != .Ready || session.Remote_Choking {
		return .Invalid_State
	}
	if !peer_block_valid(session, index, begin, length) {
		return .Invalid_Piece
	}
	return peer_session_queue_locked(session, Wire_Message_View{
		Kind = .Request,
		Index = index,
		Begin = begin,
		Length = length,
	})
}

Peer_Session_Queue_Cancel :: proc(session: ^Peer_Session, index, begin, length: u32) -> Peer_Error {
	if session == nil {
		return .Invalid_Peer
	}
	sync.mutex_lock(&session.Mutex)
	defer sync.mutex_unlock(&session.Mutex)
	if session.State != .Ready || !peer_block_valid(session, index, begin, length) {
		return .Invalid_State
	}
	return peer_session_queue_locked(session, Wire_Message_View{
		Kind = .Cancel,
		Index = index,
		Begin = begin,
		Length = length,
	})
}

Peer_Session_Queue_Keep_Alive :: proc(session: ^Peer_Session) -> Peer_Error {
	if session == nil {
		return .Invalid_Peer
	}
	sync.mutex_lock(&session.Mutex)
	defer sync.mutex_unlock(&session.Mutex)
	if session.State != .Ready {
		return .Invalid_State
	}
	return peer_session_queue_locked(session, Wire_Message_View{Kind = .Keep_Alive})
}

Peer_Session_Queue_Extended :: proc(session: ^Peer_Session, extension_id: byte, payload: []byte) -> Peer_Error {
	if session == nil {
		return .Invalid_Peer
	}
	message_payload, alloc_error := make([]byte, len(payload)+1, context.allocator)
	if alloc_error != nil {
		return .Out_Of_Memory
	}
	message_payload[0] = extension_id
	copy(message_payload[1:], payload)
	sync.mutex_lock(&session.Mutex)
	defer sync.mutex_unlock(&session.Mutex)
	if session.State != .Ready {
		delete(message_payload)
		return .Invalid_State
	}
	error := peer_session_queue_locked(session, Wire_Message_View{Kind = .Extended, Payload = message_payload})
	delete(message_payload)
	return error
}

Peer_Session_Supports_Extensions :: proc(session: ^Peer_Session) -> bool {
	if session == nil {
		return false
	}
	sync.mutex_lock(&session.Mutex)
	defer sync.mutex_unlock(&session.Mutex)
	return session.State == .Ready && session.Remote_Extensions
}

Peer_Session_Remote_Has_Piece :: proc(session: ^Peer_Session, index: u32) -> bool {
	if session == nil {
		return false
	}
	sync.mutex_lock(&session.Mutex)
	defer sync.mutex_unlock(&session.Mutex)
	return Bitfield_Has_Piece(&session.Remote_Pieces, index)
}

peer_session_begin_locked :: proc(session: ^Peer_Session) -> Peer_Error {
	if session.State != .New {
		return .Invalid_State
	}
	return peer_session_begin_plain_locked(session)
}

peer_session_feed_locked :: proc(session: ^Peer_Session, data: []byte) -> Peer_Error {
	feed_data := data
	if session.MSE_Inbound && !session.MSE_Negotiating && session.MSE_Policy == .Preferred {
		append(&session.Receive_Buffer, ..data)
		if len(session.Receive_Buffer) < 20 {
			return .None
		}
		protocol := BitTorrent_Protocol_String
		if session.Receive_Buffer[0] == byte(19) && bytes_equal(session.Receive_Buffer[1:20], transmute([]byte)protocol) {
			// A preferred inbound session accepts an ordinary PWP peer unchanged.
			session.MSE_Inbound = false
			return peer_session_process_locked(session)
		}
		raw := session.Receive_Buffer
		session.Receive_Buffer = nil
		defer delete(raw)
		if peer_session_mse_start_responder_locked(session) != .None {
			return .Protocol
		}
		feed_data = raw[:]
	}
	if session.MSE_Negotiating {
		mse_error := MSE_Handshake_Feed(&session.MSE, feed_data)
		peer_session_mse_drain_outgoing_locked(session)
		if mse_error != .None {
			return peer_session_fail_locked(session, .Protocol)
		}
		return peer_session_mse_finish_locked(session)
	}
	if session.MSE_Active {
		if MSE_Handshake_Feed(&session.MSE, feed_data) != .None {
			return peer_session_fail_locked(session, .Protocol)
		}
		payload := MSE_Handshake_Take_Payload(&session.MSE)
		defer delete(payload)
		append(&session.Receive_Buffer, ..payload[:])
		return peer_session_process_locked(session)
	}
	append(&session.Receive_Buffer, ..feed_data)
	return peer_session_process_locked(session)
}

peer_session_process_locked :: proc(session: ^Peer_Session) -> Peer_Error {
	if session.State == .Handshaking {
		if len(session.Receive_Buffer) < Handshake_Length {
			return .None
		}
		handshake, handshake_error := Wire_Handshake_Parse(session.Receive_Buffer[:Handshake_Length])
		if handshake_error != .None {
			return peer_session_fail_locked(session, .Protocol)
		}
		if handshake.Info_Hash != session.Expected_Info_Hash {
			return peer_session_fail_locked(session, .Info_Hash_Mismatch)
		}
		session.Remote_Peer_ID = handshake.Peer_ID
		session.Remote_Extensions = handshake.Reserved[5]&0x10 != 0
		session.State = .Ready
		if peer_session_event_locked(session, Peer_Event{Kind = .Handshake}) != .None {
			return peer_session_fail_locked(session, .Out_Of_Memory)
		}
		peer_session_consume_locked(session, Handshake_Length)
	}
	for session.State == .Ready && len(session.Receive_Buffer) > 0 {
		parsed, parse_error := Wire_Message_Parse(session.Receive_Buffer[:])
		if parse_error == .Incomplete {
			return .None
		}
		if parse_error != .None {
			return peer_session_fail_locked(session, .Protocol)
		}
		message_error := peer_session_message_locked(session, parsed.Message)
		if message_error != .None {
			return peer_session_fail_locked(session, message_error)
		}
		peer_session_consume_locked(session, parsed.Consumed)
	}
	return .None
}

peer_session_message_locked :: proc(session: ^Peer_Session, message: Wire_Message_View) -> Peer_Error {
	event := Peer_Event{
		Kind = peer_event_kind(message.Kind),
		Index = message.Index,
		Begin = message.Begin,
		Length = message.Length,
		Port = message.Port,
	}
	switch message.Kind {
	case .Keep_Alive:
		{}
	case .Choke:
		session.Remote_Choking = true
	case .Unchoke:
		session.Remote_Choking = false
	case .Interested:
		session.Remote_Interested = true
	case .Not_Interested:
		session.Remote_Interested = false
	case .Have:
		if session.Mode != .Metadata {
			if message.Index >= session.Piece_Count {
				return .Invalid_Piece
			}
			Bitfield_Set_Piece(&session.Remote_Pieces, message.Index)
		}
	case .Bitfield:
		if session.Mode != .Metadata {
			if !peer_bitfield_valid(message.Payload, session.Piece_Count) {
				return .Invalid_Bitfield
			}
			bitfield, bitfield_error := Bitfield_From_Raw(message.Payload, session.Piece_Count)
			if bitfield_error != .None {
				return .Invalid_Bitfield
			}
			Destroy_Bitfield(&session.Remote_Pieces)
			session.Remote_Pieces = bitfield
		}
	case .Request, .Cancel:
		if session.Mode != .Metadata && !peer_block_valid(session, message.Index, message.Begin, message.Length) {
			return .Invalid_Piece
		}
	case .Piece:
		if session.Mode != .Metadata && !peer_piece_payload_valid(session, message.Index, message.Begin, message.Payload) {
			return .Invalid_Piece
		}
	case .Port, .Extended:
		{}
	}
	if len(message.Payload) > 0 {
		payload, payload_ok := torrent_clone(message.Payload)
		if !payload_ok {
			return .Out_Of_Memory
		}
		event.Payload = payload
	}
	return peer_session_event_locked(session, event)
}

peer_session_queue_locked :: proc(session: ^Peer_Session, message: Wire_Message_View) -> Peer_Error {
	encoded, encode_error := Wire_Message_Encode(message)
	if encode_error != .None {
		return .Protocol
	}
	if session.MSE_Active {
		mse_error := MSE_Handshake_Queue_Payload(&session.MSE, encoded)
		delete(encoded)
		if mse_error != .None {
			return .Protocol
		}
		peer_session_mse_drain_outgoing_locked(session)
		return .None
	}
	append(&session.Outgoing, ..encoded)
	delete(encoded)
	return .None
}

peer_session_event_locked :: proc(session: ^Peer_Session, event: Peer_Event) -> Peer_Error {
	append(&session.Events, event)
	return .None
}

peer_session_consume_locked :: proc(session: ^Peer_Session, count: int) {
	remaining := len(session.Receive_Buffer)-count
	if remaining > 0 {
		copy(session.Receive_Buffer[:remaining], session.Receive_Buffer[count:])
	}
	resize(&session.Receive_Buffer, remaining)
}

peer_session_fail_locked :: proc(session: ^Peer_Session, error: Peer_Error) -> Peer_Error {
	session.Error = error
	session.State = .Failed
	Peer_Transport_Close(&session.Transport)
	return error
}

peer_block_valid :: proc(session: ^Peer_Session, index, begin, length: u32) -> bool {
	if index >= session.Piece_Count || length == 0 || length > Block_Size {
		return false
	}
	piece_length := Piece_Length(index, session.Piece_Length, session.Total_Length)
	return piece_length > 0 && begin < piece_length && begin % Block_Size == 0 && u64(begin)+u64(length) <= u64(piece_length)
}

peer_piece_payload_valid :: proc(session: ^Peer_Session, index, begin: u32, payload: []byte) -> bool {
	return peer_block_valid(session, index, begin, u32(len(payload)))
}

peer_bitfield_valid :: proc(data: []byte, piece_count: u32) -> bool {
	expected := int((u64(piece_count)+7)/8)
	if len(data) != expected || expected == 0 || piece_count%8 == 0 {
		return len(data) == expected
	}
	unused := byte(8-piece_count%8)
	return data[len(data)-1]&(byte((1<<unused)-1)) == 0
}

peer_event_kind :: proc(kind: Wire_Message_Kind) -> Peer_Event_Kind {
	switch kind {
	case .Keep_Alive: return .Keep_Alive
	case .Choke: return .Choke
	case .Unchoke: return .Unchoke
	case .Interested: return .Interested
	case .Not_Interested: return .Not_Interested
	case .Have: return .Have
	case .Bitfield: return .Bitfield
	case .Request: return .Request
	case .Piece: return .Piece
	case .Cancel: return .Cancel
	case .Port: return .Port
	case .Extended: return .Extended
	}
	return .Keep_Alive
}

peer_transport_error :: proc(error: Peer_Transport_Error) -> Peer_Error {
	switch error {
	case .Timeout: return .Timeout
	case .Disconnected: return .Disconnected
	case .None: return .None
	case .Invalid_Transport, .Already_Connected, .Resolve, .Connect, .Read, .Write, .Out_Of_Memory:
		return .Transport
	}
	return .Transport
}
