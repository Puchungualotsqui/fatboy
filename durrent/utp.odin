package durrent

import endian "core:encoding/endian"
import "core:net"
import "core:time"

// BEP 29/uTP is a reliable, ordered byte stream carried in UDP datagrams. This
// implementation deliberately keeps PWP above this layer, just like TCP.
UTP_Header_Length :: 20
UTP_Max_Packet_Size :: 1200
UTP_Max_Payload_Size :: UTP_Max_Packet_Size - UTP_Header_Length
UTP_Initial_Window :: 4 * UTP_Max_Payload_Size
UTP_Max_Window :: 64 * UTP_Max_Payload_Size
UTP_Retransmit_Timeout :: 500 * time.Millisecond
UTP_Max_Retransmits :: 5
UTP_Max_Reorder_Packets :: 128
UTP_Max_Receive_Buffer :: 2 * UTP_Max_Window
UTP_Initial_Retransmit_Timeout :: 500 * time.Millisecond
UTP_Max_Retransmit_Timeout :: 30 * time.Second
UTP_Delay_Target_Microseconds :: u32(100000)

UTP_Packet_Type :: enum byte {
	Data = 0,
	Fin = 1,
	State = 2,
	Reset = 3,
	Syn = 4,
}

UTP_State :: enum {
	Closed,
	Syn_Sent,
	Connected,
	Failed,
}

UTP_Error :: enum {
	None,
	Invalid_Connection,
	Socket,
	Protocol,
	Disconnected,
	Timeout,
	Out_Of_Memory,
}

UTP_Header :: struct {
	Type:                 UTP_Packet_Type,
	Extension:            byte,
	Connection_ID:        u16,
	Timestamp_Microseconds: u32,
	Timestamp_Difference: u32,
	Window_Size:          u32,
	Sequence:             u16,
	Acknowledgement:      u16,
}

UTP_Unacked_Packet :: struct {
	Type:          UTP_Packet_Type,
	Sequence:      u16,
	Payload:       []byte,
	Sent_At:       time.Time,
	First_Sent_At: time.Time,
	Retransmits:   u32,
	Sacked:        bool,
}

UTP_Reorder_Packet :: struct {
	Sequence: u16,
	Payload:  []byte,
}

UTP_Connection :: struct {
	Socket:             net.UDP_Socket,
	Socket_Open:        bool,
	Owns_Socket:        bool,
	Remote:             net.Endpoint,
	Send_Connection_ID: u16,
	Receive_Connection_ID: u16,
	State:              UTP_State,
	Next_Sequence:      u16,
	Last_Acknowledgement: u16,
	Reply_Microseconds: u32,
	Peer_Delay_Microseconds: u32,
	Receive_Started:    bool,
	Window:             u32,
	Remote_Window:      u32,
	Outgoing:           [dynamic]byte,
	Received:           [dynamic]byte,
	Reorder:            [dynamic]UTP_Reorder_Packet,
	Reorder_Bytes:      u32,
	Unacked:            [dynamic]UTP_Unacked_Packet,
	In_Flight:          u32,
	RTT:                time.Duration,
	RTT_Variance:       time.Duration,
	Retransmit_Timeout: time.Duration,
	Have_RTT:           bool,
	Base_Delay:         u32,
	Have_Base_Delay:    bool,
	Pacing_Credit:      f64,
	Pacing_Updated_At:  time.Time,
	Last_Activity:      time.Time,
}

utp_next_connection_id: u16 = 0xD001

UTP_Header_Encode :: proc(header: UTP_Header) -> [UTP_Header_Length]byte {
	result: [UTP_Header_Length]byte
	result[0] = byte(u8(header.Type)<<4 | 1)
	result[1] = header.Extension
	endian.put_u16(result[2:4], .Big, header.Connection_ID)
	endian.put_u32(result[4:8], .Big, header.Timestamp_Microseconds)
	endian.put_u32(result[8:12], .Big, header.Timestamp_Difference)
	endian.put_u32(result[12:16], .Big, header.Window_Size)
	endian.put_u16(result[16:18], .Big, header.Sequence)
	endian.put_u16(result[18:20], .Big, header.Acknowledgement)
	return result
}

UTP_Header_Parse :: proc(packet: []byte) -> (UTP_Header, UTP_Error) {
	if len(packet) < UTP_Header_Length {
		return UTP_Header{}, .Protocol
	}
	version := packet[0] & 0x0f
	packet_type := packet[0] >> 4
	if version != 1 || packet_type > u8(UTP_Packet_Type.Syn) {
		return UTP_Header{}, .Protocol
	}
	return UTP_Header{
		Type = UTP_Packet_Type(packet_type),
		Extension = packet[1],
		Connection_ID = endian.unchecked_get_u16be(packet[2:4]),
		Timestamp_Microseconds = endian.unchecked_get_u32be(packet[4:8]),
		Timestamp_Difference = endian.unchecked_get_u32be(packet[8:12]),
		Window_Size = endian.unchecked_get_u32be(packet[12:16]),
		Sequence = endian.unchecked_get_u16be(packet[16:18]),
		Acknowledgement = endian.unchecked_get_u16be(packet[18:20]),
	}, .None
}

UTP_Connection_Begin :: proc(connection: ^UTP_Connection, remote: net.Endpoint) -> UTP_Error {
	if connection == nil || connection.State != .Closed {
		return .Invalid_Connection
	}
	bind_address: net.Address
	switch address in remote.address {
	case net.IP4_Address: bind_address = net.IP4_Any
	case net.IP6_Address: bind_address = net.IP6_Any
	case: return .Socket
	}
	socket, socket_error := net.make_bound_udp_socket(bind_address, 0)
	if socket_error != nil || net.set_blocking(socket, false) != nil {
		if socket_error == nil { net.close(socket) }
		return .Socket
	}
	return UTP_Connection_Begin_Shared(connection, socket, remote, true)
}

// Begin_Shared borrows a listener-owned UDP socket when owns_socket is false.
// The caller remains responsible for delivering matching datagrams through
// UTP_Connection_Handle_Datagram.
UTP_Connection_Begin_Shared :: proc(connection: ^UTP_Connection, socket: net.UDP_Socket, remote: net.Endpoint, owns_socket := false) -> UTP_Error {
	if connection == nil || connection.State != .Closed || socket == net.UDP_Socket(0) {
		return .Invalid_Connection
	}
	utp_next_connection_id += 1
	if utp_next_connection_id == 0 || utp_next_connection_id == 0xffff {
		utp_next_connection_id = 1
	}
	connection.Socket = socket
	connection.Socket_Open = true
	connection.Owns_Socket = owns_socket
	connection.Remote = remote
	connection.Receive_Connection_ID = utp_next_connection_id
	connection.Send_Connection_ID = utp_next_connection_id + 1
	connection.State = .Syn_Sent
	connection.Next_Sequence = 1
	connection.Window = UTP_Initial_Window
	connection.Remote_Window = UTP_Initial_Window
	connection.Retransmit_Timeout = UTP_Initial_Retransmit_Timeout
	connection.Pacing_Credit = f64(UTP_Initial_Window)
	connection.Pacing_Updated_At = time.now()
	connection.Last_Activity = connection.Pacing_Updated_At
	return utp_connection_send_syn(connection)
}

// UTP_Connection_Accept_Shared creates the responder half of a validated SYN.
UTP_Connection_Accept_Shared :: proc(connection: ^UTP_Connection, socket: net.UDP_Socket, remote: net.Endpoint, syn: UTP_Header) -> UTP_Error {
	if connection == nil || connection.State != .Closed || socket == net.UDP_Socket(0) || syn.Type != .Syn {
		return .Invalid_Connection
	}
	utp_next_connection_id += 1
	if utp_next_connection_id == 0 { utp_next_connection_id = 1 }
	connection.Socket = socket
	connection.Socket_Open = true
	connection.Remote = remote
	connection.Send_Connection_ID = syn.Connection_ID
	connection.Receive_Connection_ID = syn.Connection_ID + 1
	connection.State = .Connected
	connection.Next_Sequence = utp_next_connection_id
	connection.Last_Acknowledgement = syn.Sequence
	connection.Receive_Started = true
	connection.Window = UTP_Initial_Window
	connection.Remote_Window = syn.Window_Size
	connection.Retransmit_Timeout = UTP_Initial_Retransmit_Timeout
	connection.Pacing_Credit = f64(UTP_Initial_Window)
	connection.Pacing_Updated_At = time.now()
	connection.Last_Activity = connection.Pacing_Updated_At
	connection.Reply_Microseconds = utp_timestamp_microseconds() - syn.Timestamp_Microseconds
	return utp_connection_send_control(connection, .State, connection.Next_Sequence)
}

UTP_Connection_Queue :: proc(connection: ^UTP_Connection, data: []byte) -> UTP_Error {
	if connection == nil || connection.State != .Connected {
		return .Disconnected
	}
	append(&connection.Outgoing, ..data)
	return .None
}

UTP_Connection_Poll :: proc(connection: ^UTP_Connection) -> UTP_Error {
	if connection == nil || !connection.Socket_Open || connection.State == .Closed || connection.State == .Failed {
		return .Disconnected
	}
	if utp_connection_retransmit_due(connection) != .None {
		return .Timeout
	}
	if !connection.Owns_Socket {
		return utp_connection_flush_data(connection) if connection.State == .Connected else .None
	}
	buffer: [UTP_Max_Packet_Size]byte
	for _ in 0..<16 {
		count, source, receive_error := net.recv_udp(connection.Socket, buffer[:])
		if receive_error == .Timeout || receive_error == .Would_Block {
			break
		}
		if receive_error != .None {
			connection.State = .Failed
			return .Socket
		}
		handle_error := UTP_Connection_Handle_Datagram(connection, buffer[:count], source)
		if handle_error != .None && handle_error != .Protocol {
			return handle_error
		}
	}
	if connection.State == .Connected {
		return utp_connection_flush_data(connection)
	}
	return .None
}

// Handle_Datagram is used by both dedicated outbound sockets and the loop's
// shared UDP listener. It authenticates the stream by endpoint and receive ID.
UTP_Connection_Handle_Datagram :: proc(connection: ^UTP_Connection, packet: []byte, source: net.Endpoint) -> UTP_Error {
	if connection == nil || !connection.Socket_Open || !utp_endpoint_equal(source, connection.Remote) {
		return .Protocol
	}
	header, header_error := UTP_Header_Parse(packet)
	if header_error != .None || header.Connection_ID != connection.Receive_Connection_ID {
		return .Protocol
	}
	payload_offset, payload_error := utp_packet_payload_offset(packet, header.Extension)
	if payload_error != .None {
		return payload_error
	}
	connection.Last_Activity = time.now()
	connection.Reply_Microseconds = utp_timestamp_microseconds() - header.Timestamp_Microseconds
	connection.Peer_Delay_Microseconds = header.Timestamp_Difference
	connection.Remote_Window = header.Window_Size
	utp_connection_acknowledge(connection, header.Acknowledgement, packet, header)
	switch header.Type {
	case .State:
		if connection.State == .Syn_Sent {
			// A valid response must acknowledge our SYN. This prevents an unrelated
			// state packet from turning a pending connection into a PWP stream.
			if header.Acknowledgement != 1 {
				return .Protocol
			}
			connection.Last_Acknowledgement = header.Sequence
			connection.Receive_Started = true
			connection.State = .Connected
		}
	case .Data:
		if connection.State != .Connected {
			return .Protocol
		}
		if utp_connection_receive_data(connection, header.Sequence, packet[payload_offset:]) != .None {
			return .Out_Of_Memory
		}
		if utp_connection_send_control(connection, .State, connection.Next_Sequence) != .None {
			return .Socket
		}
	case .Fin:
		if connection.State == .Connected {
			connection.Last_Acknowledgement = header.Sequence
			_ = utp_connection_send_control(connection, .State, connection.Next_Sequence)
		}
		connection.State = .Closed
		return .Disconnected
	case .Reset:
		connection.State = .Closed
		return .Disconnected
	case .Syn:
		return .Protocol
	}
	return .None
}

UTP_Connection_Take_Received :: proc(connection: ^UTP_Connection, destination: []byte) -> int {
	if connection == nil || len(destination) == 0 || len(connection.Received) == 0 {
		return 0
	}
	count := len(destination) if len(destination) < len(connection.Received) else len(connection.Received)
	copy(destination[:count], connection.Received[:count])
	remaining := len(connection.Received)-count
	if remaining > 0 {
		copy(connection.Received[:remaining], connection.Received[count:])
	}
	resize(&connection.Received, remaining)
	return count
}

utp_connection_receive_data :: proc(connection: ^UTP_Connection, sequence: u16, payload: []byte) -> UTP_Error {
	if len(connection.Received)+int(connection.Reorder_Bytes)+len(payload) > UTP_Max_Receive_Buffer {
		return .Out_Of_Memory
	}
	if sequence == connection.Last_Acknowledgement+1 {
		append(&connection.Received, ..payload)
		connection.Last_Acknowledgement = sequence
		for {
			index := utp_connection_find_reorder(connection, connection.Last_Acknowledgement+1)
			if index < 0 { break }
			queued := connection.Reorder[index]
			append(&connection.Received, ..queued.Payload)
			connection.Reorder_Bytes -= u32(len(queued.Payload))
			delete(queued.Payload)
			utp_connection_remove_reorder(connection, index)
			connection.Last_Acknowledgement += 1
		}
		return .None
	}
	if !utp_sequence_after(sequence, connection.Last_Acknowledgement) ||
		!utp_sequence_within(sequence, connection.Last_Acknowledgement, UTP_Max_Reorder_Packets) {
		return .None
	}
	if utp_connection_find_reorder(connection, sequence) >= 0 || len(connection.Reorder) >= UTP_Max_Reorder_Packets {
		return .None
	}
	copy_payload, allocation_error := make([]byte, len(payload), context.allocator)
	if allocation_error != nil { return .Out_Of_Memory }
	copy(copy_payload, payload)
	append(&connection.Reorder, UTP_Reorder_Packet{Sequence = sequence, Payload = copy_payload})
	connection.Reorder_Bytes += u32(len(copy_payload))
	return .None
}

utp_connection_find_reorder :: proc(connection: ^UTP_Connection, sequence: u16) -> int {
	for packet, index in connection.Reorder {
		if packet.Sequence == sequence { return index }
	}
	return -1
}

utp_connection_remove_reorder :: proc(connection: ^UTP_Connection, index: int) {
	remaining := len(connection.Reorder)-index-1
	if remaining > 0 { copy(connection.Reorder[index:index+remaining], connection.Reorder[index+1:]) }
	resize(&connection.Reorder, len(connection.Reorder)-1)
}

UTP_Connection_Close :: proc(connection: ^UTP_Connection) {
	if connection == nil {
		return
	}
	if connection.Socket_Open {
		if connection.State == .Connected {
			_ = utp_connection_send_control(connection, .Fin, connection.Next_Sequence+1)
		}
		if connection.Owns_Socket { net.close(connection.Socket) }
	}
	for &packet in connection.Unacked {
		delete(packet.Payload)
	}
	delete(connection.Unacked)
	for &packet in connection.Reorder { delete(packet.Payload) }
	delete(connection.Reorder)
	delete(connection.Outgoing)
	delete(connection.Received)
	connection^ = UTP_Connection{}
}

utp_connection_send_syn :: proc(connection: ^UTP_Connection) -> UTP_Error {
	header := UTP_Header{
		Type = .Syn,
		Connection_ID = connection.Receive_Connection_ID,
		Timestamp_Microseconds = utp_timestamp_microseconds(),
		Window_Size = UTP_Max_Window,
		Sequence = connection.Next_Sequence,
	}
	encoded := UTP_Header_Encode(header)
	_, send_error := net.send_udp(connection.Socket, encoded[:], connection.Remote)
	if send_error != .None && send_error != .Would_Block && send_error != .Timeout {
		connection.State = .Failed
		return .Socket
	}
	append(&connection.Unacked, UTP_Unacked_Packet{Type = .Syn, Sequence = connection.Next_Sequence, Sent_At = time.now()})
	return .None
}

utp_connection_send_control :: proc(connection: ^UTP_Connection, packet_type: UTP_Packet_Type, sequence: u16) -> UTP_Error {
	sack := utp_connection_sack(connection)
	defer delete(sack)
	header := UTP_Header{
		Type = packet_type,
		Extension = 1 if len(sack) > 0 else 0,
		Connection_ID = connection.Send_Connection_ID,
		Timestamp_Microseconds = utp_timestamp_microseconds(),
		Timestamp_Difference = connection.Reply_Microseconds,
		Window_Size = u32(UTP_Max_Receive_Buffer-len(connection.Received)-int(connection.Reorder_Bytes)) if len(connection.Received)+int(connection.Reorder_Bytes) < UTP_Max_Receive_Buffer else 0,
		Sequence = sequence,
		Acknowledgement = connection.Last_Acknowledgement,
	}
	encoded := UTP_Header_Encode(header)
	wire: [dynamic]byte
	append(&wire, ..encoded[:])
	if len(sack) > 0 {
		append(&wire, byte(0), byte(len(sack)))
		append(&wire, ..sack)
	}
	_, send_error := net.send_udp(connection.Socket, wire[:], connection.Remote)
	delete(wire)
	if send_error != .None && send_error != .Would_Block && send_error != .Timeout {
		connection.State = .Failed
		return .Socket
	}
	if packet_type == .Fin {
		now := time.now()
		append(&connection.Unacked, UTP_Unacked_Packet{Type = packet_type, Sequence = sequence, Sent_At = now, First_Sent_At = now})
	}
	return .None
}

utp_connection_sack :: proc(connection: ^UTP_Connection) -> []byte {
	if connection == nil || len(connection.Reorder) == 0 { return nil }
	mask: [4]byte
	for packet in connection.Reorder {
		offset := i32(packet.Sequence)-i32(connection.Last_Acknowledgement)-2
		if offset >= 0 && offset < 32 { mask[offset/8] |= byte(1) << u8(offset%8) }
	}
	result, allocation_error := make([]byte, len(mask), context.allocator)
	if allocation_error != nil { return nil }
	copy(result, mask[:])
	return result
}

utp_connection_flush_data :: proc(connection: ^UTP_Connection) -> UTP_Error {
	utp_connection_update_pacing(connection)
	for len(connection.Outgoing) > 0 && connection.In_Flight < connection.Window && connection.In_Flight < connection.Remote_Window && connection.Pacing_Credit >= 1 {
		count := len(connection.Outgoing)
		credit := connection.Window-connection.In_Flight
		if connection.Remote_Window-connection.In_Flight < credit { credit = connection.Remote_Window-connection.In_Flight }
		if u32(count) > credit { count = int(credit) }
		if count > UTP_Max_Payload_Size { count = UTP_Max_Payload_Size }
		if f64(count) > connection.Pacing_Credit { count = int(connection.Pacing_Credit) }
		if count <= 0 { break }
		payload, allocation_error := make([]byte, count, context.allocator)
		if allocation_error != nil {
			return .Out_Of_Memory
		}
		copy(payload, connection.Outgoing[:count])
		header := UTP_Header{
			Type = .Data,
			Connection_ID = connection.Send_Connection_ID,
			Timestamp_Microseconds = utp_timestamp_microseconds(),
			Timestamp_Difference = connection.Reply_Microseconds,
			Window_Size = u32(UTP_Max_Window-len(connection.Received)) if len(connection.Received) < UTP_Max_Window else 0,
			Sequence = connection.Next_Sequence + 1,
			Acknowledgement = connection.Last_Acknowledgement,
		}
		encoded := UTP_Header_Encode(header)
		packet: [dynamic]byte
		append(&packet, ..encoded[:])
		append(&packet, ..payload[:])
		_, send_error := net.send_udp(connection.Socket, packet[:], connection.Remote)
		delete(packet)
		if send_error == .Would_Block || send_error == .Timeout {
			delete(payload)
			return .Timeout
		}
		if send_error != .None {
			delete(payload)
			connection.State = .Failed
			return .Socket
		}
		connection.Next_Sequence = header.Sequence
		now := time.now()
		append(&connection.Unacked, UTP_Unacked_Packet{Type = .Data, Sequence = header.Sequence, Payload = payload, Sent_At = now, First_Sent_At = now})
		remaining := len(connection.Outgoing)-count
		if remaining > 0 {
			copy(connection.Outgoing[:remaining], connection.Outgoing[count:])
		}
		resize(&connection.Outgoing, remaining)
		connection.In_Flight += u32(count)
		connection.Pacing_Credit -= f64(count)
	}
	return .None
}

utp_connection_acknowledge :: proc(connection: ^UTP_Connection, acknowledgement: u16, wire: []byte, header: UTP_Header) {
	if !utp_sequence_not_after(acknowledgement, connection.Next_Sequence) {
		return // Never accept an ACK for data that was not sent.
	}
	utp_connection_mark_acked(connection, acknowledgement, false)
	offset := UTP_Header_Length
	extension := header.Extension
	for extension != 0 && offset+2 <= len(wire) {
		next_extension := wire[offset]
		length := int(wire[offset+1])
		offset += 2
		if offset+length > len(wire) { return }
		if extension == 1 {
			for byte_index := 0; byte_index < length; byte_index += 1 {
				for bit := 0; bit < 8; bit += 1 {
					if wire[offset+byte_index]&(byte(1)<<u8(bit)) != 0 {
						sequence := acknowledgement + u16(2+byte_index*8+bit)
						utp_connection_mark_acked(connection, sequence, true)
					}
				}
			}
		}
		offset += length
		extension = next_extension
	}
}

utp_connection_mark_acked :: proc(connection: ^UTP_Connection, acknowledgement: u16, selective: bool) {
	index := 0
	for index < len(connection.Unacked) {
		packet := connection.Unacked[index]
		matched := packet.Sequence == acknowledgement if selective else utp_sequence_not_after(packet.Sequence, acknowledgement)
		if !matched { index += 1; continue }
		if packet.Retransmits == 0 {
			utp_connection_update_rtt(connection, time.since(packet.First_Sent_At))
		}
		connection.In_Flight -= u32(len(packet.Payload))
		utp_connection_update_ledbat(connection, u32(len(packet.Payload)))
		delete(packet.Payload)
		remaining := len(connection.Unacked)-index-1
		if remaining > 0 { copy(connection.Unacked[index:index+remaining], connection.Unacked[index+1:]) }
		resize(&connection.Unacked, len(connection.Unacked)-1)
	}
}

utp_connection_update_rtt :: proc(connection: ^UTP_Connection, sample: time.Duration) {
	if sample <= 0 { return }
	if !connection.Have_RTT {
		connection.RTT = sample
		connection.RTT_Variance = sample / 2
		connection.Have_RTT = true
	} else {
		delta := connection.RTT - sample
		if delta < 0 { delta = -delta }
		connection.RTT_Variance += (delta-connection.RTT_Variance) / 4
		connection.RTT += (sample-connection.RTT) / 8
	}
	connection.Retransmit_Timeout = connection.RTT + 4*connection.RTT_Variance
	if connection.Retransmit_Timeout < UTP_Initial_Retransmit_Timeout { connection.Retransmit_Timeout = UTP_Initial_Retransmit_Timeout }
	if connection.Retransmit_Timeout > UTP_Max_Retransmit_Timeout { connection.Retransmit_Timeout = UTP_Max_Retransmit_Timeout }
}

utp_connection_update_ledbat :: proc(connection: ^UTP_Connection, acknowledged_bytes: u32) {
	delay := connection.Peer_Delay_Microseconds
	if !connection.Have_Base_Delay || delay < connection.Base_Delay {
		connection.Base_Delay = delay
		connection.Have_Base_Delay = true
	}
	queue_delay := delay-connection.Base_Delay if delay >= connection.Base_Delay else 0
	off_target := i64(UTP_Delay_Target_Microseconds)-i64(queue_delay)
	change := i64(acknowledged_bytes) * off_target / i64(UTP_Delay_Target_Microseconds)
	window := i64(connection.Window) + change
	if window < UTP_Max_Payload_Size { window = UTP_Max_Payload_Size }
	if window > UTP_Max_Window { window = UTP_Max_Window }
	connection.Window = u32(window)
}

utp_connection_update_pacing :: proc(connection: ^UTP_Connection) {
	now := time.now()

	elapsed := time.diff(connection.Pacing_Updated_At, now)
	if elapsed <= 0 { return }
	rtt := connection.RTT if connection.Have_RTT && connection.RTT > 0 else UTP_Initial_Retransmit_Timeout
	connection.Pacing_Credit += f64(connection.Window) * time.duration_seconds(elapsed) / time.duration_seconds(rtt)
	if connection.Pacing_Credit > f64(UTP_Initial_Window) { connection.Pacing_Credit = f64(UTP_Initial_Window) }
	connection.Pacing_Updated_At = now
}

utp_connection_retransmit_due :: proc(connection: ^UTP_Connection) -> UTP_Error {
	now := time.now()
	rto := connection.Retransmit_Timeout if connection.Retransmit_Timeout > 0 else UTP_Initial_Retransmit_Timeout
	for &packet in connection.Unacked {
		if packet.Sacked || time.diff(packet.Sent_At, now) < rto {
			continue
		}
		if packet.Retransmits >= UTP_Max_Retransmits {
			connection.State = .Failed
			return .Timeout
		}
		connection_id := connection.Receive_Connection_ID if packet.Type == .Syn else connection.Send_Connection_ID
		header := UTP_Header{
			Type = packet.Type,
			Connection_ID = connection_id,
			Timestamp_Microseconds = utp_timestamp_microseconds(),
			Timestamp_Difference = connection.Reply_Microseconds,
			Window_Size = u32(UTP_Max_Window-len(connection.Received)) if len(connection.Received) < UTP_Max_Window else 0,
			Sequence = packet.Sequence,
			Acknowledgement = connection.Last_Acknowledgement,
		}
		encoded := UTP_Header_Encode(header)
		wire: [dynamic]byte
		append(&wire, ..encoded[:])
		append(&wire, ..packet.Payload)
		_, send_error := net.send_udp(connection.Socket, wire[:], connection.Remote)
		delete(wire)
		if send_error != .None && send_error != .Would_Block && send_error != .Timeout {
			connection.State = .Failed
			return .Socket
		}
		packet.Sent_At = now
		packet.Retransmits += 1
		connection.Retransmit_Timeout *= 2
		if connection.Retransmit_Timeout > UTP_Max_Retransmit_Timeout { connection.Retransmit_Timeout = UTP_Max_Retransmit_Timeout }
		connection.Window /= 2
		if connection.Window < UTP_Max_Payload_Size {
			connection.Window = UTP_Max_Payload_Size
		}
	}
	return .None
}

utp_packet_payload_offset :: proc(packet: []byte, first_extension: byte) -> (int, UTP_Error) {
	offset := UTP_Header_Length
	extension := first_extension
	for extension != 0 {
		if offset+2 > len(packet) {
			return 0, .Protocol
		}
		next_extension := packet[offset]
		length := int(packet[offset+1])
		offset += 2
		if offset+length > len(packet) {
			return 0, .Protocol
		}
		offset += length
		extension = next_extension
	}
	return offset, .None
}

utp_timestamp_microseconds :: proc() -> u32 {
	return u32(time.time_to_unix_nano(time.now()) / 1000)
}

utp_endpoint_equal :: proc(left, right: net.Endpoint) -> bool {
	if left.port != right.port { return false }
	#partial switch left_address in left.address {
	case net.IP4_Address:
		#partial switch right_address in right.address {
		case net.IP4_Address: return left_address == right_address
		}
	case net.IP6_Address:
		#partial switch right_address in right.address {
		case net.IP6_Address: return left_address == right_address
		}
	}
	return false
}

utp_sequence_after :: proc(left, right: u16) -> bool {
	return i16(left-right) > 0
}

utp_sequence_within :: proc(sequence, base: u16, distance: int) -> bool {
	return utp_sequence_after(sequence, base) && i16(sequence-base) <= i16(distance)
}

utp_sequence_not_after :: proc(sequence, acknowledgement: u16) -> bool {
	return i16(sequence-acknowledgement) <= 0
}
