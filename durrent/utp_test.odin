package durrent

import "core:net"
import "core:testing"
import "core:time"

@(test)
utp_header_roundtrip_and_extension_skip_test :: proc(t: ^testing.T) {
	header := UTP_Header{
		Type = .Data,
		Extension = 1,
		Connection_ID = 0x1234,
		Timestamp_Microseconds = 0x10203040,
		Timestamp_Difference = 0x50607080,
		Window_Size = 0x00112233,
		Sequence = 0x4455,
		Acknowledgement = 0x6677,
	}
	encoded := UTP_Header_Encode(header)
	parsed, parse_error := UTP_Header_Parse(encoded[:])
	testing.expect_value(t, parse_error, UTP_Error.None)
	testing.expect_value(t, parsed.Type, UTP_Packet_Type.Data)
	testing.expect_value(t, parsed.Connection_ID, u16(0x1234))
	testing.expect_value(t, parsed.Timestamp_Microseconds, u32(0x10203040))
	testing.expect_value(t, parsed.Acknowledgement, u16(0x6677))

	packet: [dynamic]byte
	append(&packet, ..encoded[:])
	// A selective-ACK extension with four bytes, followed by a PWP payload.
	append(&packet, byte(0), byte(4), byte(0), byte(0), byte(0), byte(1), byte('o'), byte('k'))
	offset, extension_error := utp_packet_payload_offset(packet[:], parsed.Extension)
	defer delete(packet)
	testing.expect_value(t, extension_error, UTP_Error.None)
	testing.expect_value(t, offset, UTP_Header_Length+6)
	testing.expect(t, bytes_equal(packet[offset:], []byte{'o', 'k'}))
}

@(test)
utp_sequence_wraparound_test :: proc(t: ^testing.T) {
	testing.expect(t, utp_sequence_not_after(1, 1))
	testing.expect(t, utp_sequence_not_after(0xffff, 1))
	testing.expect(t, !utp_sequence_not_after(2, 1))
}

@(test)
utp_outbound_handshake_and_data_test :: proc(t: ^testing.T) {
	server, server_error := net.make_bound_udp_socket(net.IP4_Loopback, 0)
	testing.expect_value(t, server_error, nil)
	defer net.close(server)
	testing.expect_value(t, net.set_option(server, .Receive_Timeout, time.Second), nil)
	endpoint, endpoint_error := net.bound_endpoint(server)
	testing.expect_value(t, endpoint_error, nil)

	connection: UTP_Connection
	defer UTP_Connection_Close(&connection)
	testing.expect_value(t, UTP_Connection_Begin(&connection, endpoint), UTP_Error.None)

	wire: [UTP_Max_Packet_Size]byte
	count, source, receive_error := net.recv_udp(server, wire[:])
	testing.expect_value(t, receive_error, net.UDP_Recv_Error.None)
	syn, syn_error := UTP_Header_Parse(wire[:count])
	testing.expect_value(t, syn_error, UTP_Error.None)
	testing.expect_value(t, syn.Type, UTP_Packet_Type.Syn)

	state := UTP_Header_Encode(UTP_Header{
		Type = .State,
		Connection_ID = syn.Connection_ID,
		Sequence = 100,
		Acknowledgement = syn.Sequence,
		Window_Size = UTP_Initial_Window,
	})
	_, send_error := net.send_udp(server, state[:], source)
	testing.expect_value(t, send_error, net.UDP_Send_Error.None)
	testing.expect_value(t, UTP_Connection_Poll(&connection), UTP_Error.None)
	testing.expect_value(t, connection.State, UTP_State.Connected)

	testing.expect_value(t, UTP_Connection_Queue(&connection, []byte{'o', 'k'}), UTP_Error.None)
	testing.expect_value(t, UTP_Connection_Poll(&connection), UTP_Error.None)
	count, _, receive_error = net.recv_udp(server, wire[:])
	testing.expect_value(t, receive_error, net.UDP_Recv_Error.None)
	data, data_error := UTP_Header_Parse(wire[:count])
	testing.expect_value(t, data_error, UTP_Error.None)
	testing.expect_value(t, data.Type, UTP_Packet_Type.Data)
	testing.expect_value(t, data.Connection_ID, syn.Connection_ID+1)
	testing.expect_value(t, data.Acknowledgement, u16(100))
	testing.expect(t, bytes_equal(wire[UTP_Header_Length:count], []byte{'o', 'k'}))
}
