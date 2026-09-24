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
	Type:        UTP_Packet_Type,
	Sequence:    u16,
	Payload:     []byte,
	Sent_At:     time.Time,
	Retransmits: u32,
}

UTP_Connection :: struct {
	Socket:             net.UDP_Socket,
	Socket_Open:        bool,
	Remote:             net.Endpoint,
	Send_Connection_ID: u16,
	Receive_Connection_ID: u16,
	State:              UTP_State,
	Next_Sequence:      u16,
	Last_Acknowledgement: u16,
	Reply_Microseconds: u32,
	Receive_Started:    bool,
	Window:             u32,
	Remote_Window:      u32,
	Outgoing:           [dynamic]byte,
	Received:           [dynamic]byte,
	Unacked:            [dynamic]UTP_Unacked_Packet,
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
	case net.IP4_Address:
		bind_address = net.IP4_Any
	case net.IP6_Address:
		bind_address = net.IP6_Any
	case:
		return .Socket
	}
	socket, socket_error := net.make_bound_udp_socket(bind_address, 0)
	if socket_error != nil || net.set_blocking(socket, false) != nil {
		if socket_error == nil {
			net.close(socket)
		}
		return .Socket
	}
	utp_next_connection_id += 1
	if utp_next_connection_id == 0 {
		utp_next_connection_id = 1
	}
	connection.Socket = socket
	connection.Socket_Open = true
	connection.Remote = remote
	// BEP 29 assigns the initiator's receive ID at random. The return path and
	// all packets after SYN use that ID plus one.
	connection.Receive_Connection_ID = utp_next_connection_id
	connection.Send_Connection_ID = utp_next_connection_id + 1
	connection.State = .Syn_Sent
	connection.Next_Sequence = 1
	connection.Window = UTP_Initial_Window
	connection.Remote_Window = UTP_Initial_Window
	return utp_connection_send_syn(connection)
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
	buffer: [UTP_Max_Packet_Size]byte
	for _ in 0..<16 {
		count, _, receive_error := net.recv_udp(connection.Socket, buffer[:])
		if receive_error == .Timeout || receive_error == .Would_Block {
			break
		}
		if receive_error != .None {
			connection.State = .Failed
			return .Socket
		}
		if count < UTP_Header_Length {
			continue
		}
		header, header_error := UTP_Header_Parse(buffer[:count])
		payload_offset, payload_error := utp_packet_payload_offset(buffer[:count], header.Extension)
		if header_error != .None || payload_error != .None || header.Connection_ID != connection.Receive_Connection_ID {
			continue
		}
		connection.Reply_Microseconds = utp_timestamp_microseconds() - header.Timestamp_Microseconds
		connection.Remote_Window = header.Window_Size
		utp_connection_acknowledge(connection, header.Acknowledgement)
		switch header.Type {
		case .State:
			if connection.State == .Syn_Sent {
				connection.Last_Acknowledgement = header.Sequence
				connection.State = .Connected
			}
		case .Data:
			if connection.State != .Connected {
				continue
			}
			if !connection.Receive_Started {
				connection.Last_Acknowledgement = header.Sequence
				connection.Receive_Started = true
				append(&connection.Received, ..buffer[payload_offset:count])
			} else if header.Sequence == connection.Last_Acknowledgement+1 {
				connection.Last_Acknowledgement = header.Sequence
				append(&connection.Received, ..buffer[payload_offset:count])
			}
			if utp_connection_send_control(connection, .State, connection.Next_Sequence) != .None {
				return .Socket
			}
		case .Fin, .Reset:
			connection.State = .Closed
			return .Disconnected
		case .Syn:
			// Per-connection sockets are outbound only. A shared listener performs
			// inbound SYN demultiplexing when that capability is enabled.
		}
	}
	if connection.State == .Connected {
		return utp_connection_flush_data(connection)
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

UTP_Connection_Close :: proc(connection: ^UTP_Connection) {
	if connection == nil {
		return
	}
	if connection.Socket_Open {
		if connection.State == .Connected {
			_ = utp_connection_send_control(connection, .Fin, connection.Next_Sequence)
		}
		net.close(connection.Socket)
	}
	for &packet in connection.Unacked {
		delete(packet.Payload)
	}
	delete(connection.Unacked)
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
	header := UTP_Header{
		Type = packet_type,
		Connection_ID = connection.Send_Connection_ID,
		Timestamp_Microseconds = utp_timestamp_microseconds(),
		Timestamp_Difference = connection.Reply_Microseconds,
		Window_Size = u32(UTP_Max_Window-len(connection.Received)) if len(connection.Received) < UTP_Max_Window else 0,
		Sequence = sequence,
		Acknowledgement = connection.Last_Acknowledgement,
	}
	encoded := UTP_Header_Encode(header)
	_, send_error := net.send_udp(connection.Socket, encoded[:], connection.Remote)
	if send_error != .None && send_error != .Would_Block && send_error != .Timeout {
		connection.State = .Failed
		return .Socket
	}
	if packet_type == .Fin {
		append(&connection.Unacked, UTP_Unacked_Packet{Type = packet_type, Sequence = sequence, Sent_At = time.now()})
	}
	return .None
}

utp_connection_flush_data :: proc(connection: ^UTP_Connection) -> UTP_Error {
	in_flight: u32
	for packet in connection.Unacked {
		in_flight += u32(len(packet.Payload))
	}
	for len(connection.Outgoing) > 0 && in_flight < connection.Window && in_flight < connection.Remote_Window {
		count := len(connection.Outgoing)
		if count > UTP_Max_Payload_Size {
			count = UTP_Max_Payload_Size
		}
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
		append(&connection.Unacked, UTP_Unacked_Packet{Type = .Data, Sequence = header.Sequence, Payload = payload, Sent_At = time.now()})
		remaining := len(connection.Outgoing)-count
		if remaining > 0 {
			copy(connection.Outgoing[:remaining], connection.Outgoing[count:])
		}
		resize(&connection.Outgoing, remaining)
		in_flight += u32(count)
	}
	return .None
}

utp_connection_acknowledge :: proc(connection: ^UTP_Connection, acknowledgement: u16) {
	index := 0
	for index < len(connection.Unacked) {
		packet := connection.Unacked[index]
		if !utp_sequence_not_after(packet.Sequence, acknowledgement) {
			index += 1
			continue
		}
		delete(packet.Payload)
		remaining := len(connection.Unacked)-index-1
		if remaining > 0 {
			copy(connection.Unacked[index:index+remaining], connection.Unacked[index+1:])
		}
		resize(&connection.Unacked, len(connection.Unacked)-1)
		if connection.Window < UTP_Max_Window {
			connection.Window += UTP_Max_Payload_Size
			if connection.Window > UTP_Max_Window {
				connection.Window = UTP_Max_Window
			}
		}
	}
}

utp_connection_retransmit_due :: proc(connection: ^UTP_Connection) -> UTP_Error {
	now := time.now()
	for &packet in connection.Unacked {
		if time.diff(packet.Sent_At, now) < UTP_Retransmit_Timeout {
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

utp_sequence_not_after :: proc(sequence, acknowledgement: u16) -> bool {
	return i16(sequence-acknowledgement) <= 0
}
