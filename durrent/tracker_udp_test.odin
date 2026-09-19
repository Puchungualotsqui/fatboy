package durrent

import endian "core:encoding/endian"
import "core:testing"

@(test)
tracker_udp_connect_codec_test :: proc(t: ^testing.T) {
	transaction := u32(0x10203040)
	request := UDP_Tracker_Encode_Connect_Request(transaction)

	testing.expect_value(t, request[8], byte(0))
	response: [16]byte
	endian.put_u32(response[0:4], .Big, 0)
	endian.put_u32(response[4:8], .Big, transaction)
	endian.put_u64(response[8:16], .Big, u64(0x9988776655443322))
	connection, parse_error := UDP_Tracker_Parse_Connect_Response(response[:], transaction)
	testing.expect_value(t, parse_error, UDP_Tracker_Error.None)
	testing.expect_value(t, connection, u64(0x9988776655443322))
	_, parse_error = UDP_Tracker_Parse_Connect_Response(response[:], transaction+1)
	testing.expect_value(t, parse_error, UDP_Tracker_Error.Transaction_Mismatch)
}

@(test)
tracker_udp_announce_codec_ipv4_test :: proc(t: ^testing.T) {
	request := tracker_test_request()
	request.Event = .Started
	request.Downloaded = 10
	request.Left = 20
	request.Uploaded = 30
	packet := UDP_Tracker_Encode_Announce_Request(0x1122334455667788, 7, 8, request)
	transaction, transaction_ok := endian.get_u32(packet[12:16], .Big)
	testing.expect(t, transaction_ok)
	testing.expect_value(t, transaction, u32(7))
	testing.expect_value(t, packet[80], byte(0))
	testing.expect_value(t, packet[83], byte(2))
	testing.expect_value(t, packet[96], byte(0x1a))
	testing.expect_value(t, packet[97], byte(0xe1))

	response: [32]byte
	endian.put_u32(response[0:4], .Big, 1)
	endian.put_u32(response[4:8], .Big, 7)
	endian.put_u32(response[8:12], .Big, 1800)
	endian.put_u32(response[12:16], .Big, 2)
	endian.put_u32(response[16:20], .Big, 5)
	response[20] = 127
	response[21] = 0
	response[22] = 0
	response[23] = 1
	response[24] = 0x1a
	response[25] = 0xe1
	response[26] = 10
	response[27] = 0
	response[28] = 0
	response[29] = 2
	response[30] = 0x1a
	response[31] = 0xe2
	parsed, parse_error := UDP_Tracker_Parse_Announce_Response(response[:], 7)
	testing.expect_value(t, parse_error, UDP_Tracker_Error.None)
	testing.expect_value(t, parsed.Interval, u64(1800))
	testing.expect_value(t, len(parsed.Peers), 2)
	testing.expect_value(t, parsed.Peers[1].IP[3], byte(2))
	testing.expect_value(t, parsed.Peers[1].Port, u16(6882))
	Destroy_Tracker_Response(&parsed)
}

@(test)
tracker_udp_announce_codec_ipv6_test :: proc(t: ^testing.T) {
	response: [38]byte
	endian.put_u32(response[0:4], .Big, 1)
	endian.put_u32(response[4:8], .Big, 9)
	endian.put_u32(response[8:12], .Big, 60)
	endian.put_u32(response[12:16], .Big, 1)
	endian.put_u32(response[16:20], .Big, 3)
	for i := 0; i < 16; i += 1 {
		response[20+i] = byte(i)
	}
	response[36] = 0x1a
	response[37] = 0xe1
	parsed, parse_error := UDP_Tracker_Parse_Announce_Response(response[:], 9, true)
	testing.expect_value(t, parse_error, UDP_Tracker_Error.None)
	testing.expect_value(t, len(parsed.Peers6), 1)
	testing.expect_value(t, parsed.Peers6[0].IP[15], byte(15))
	testing.expect_value(t, parsed.Peers6[0].Port, u16(6881))
	Destroy_Tracker_Response(&parsed)
}

@(test)
tracker_udp_url_validation_test :: proc(t: ^testing.T) {
	testing.expect(t, tracker_url_is_udp("udp://tracker.example:6969/announce"))
	testing.expect(t, !tracker_url_is_udp("http://tracker.example/announce"))
	authority, authority_ok := udp_tracker_authority("udp://[::1]:6969/announce")
	testing.expect(t, authority_ok)
	testing.expect_value(t, authority, "[::1]:6969")
	client: UDP_Tracker_Client
	testing.expect_value(t, UDP_Tracker_Client_Init(&client, "udp://tracker.example"), UDP_Tracker_Error.Invalid_URL)
}
