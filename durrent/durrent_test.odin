package durrent

import "core:testing"

@(test)
bencode_roundtrip_and_validation_test :: proc(t: ^testing.T) {
	input := []byte{'d', '1', ':', 'b', '1', ':', 'a', '1', ':', 'a', '1', ':', 'b', 'e'}
	value, err := Bencode_Decode_Default(input)
	testing.expect_value(t, err, Bencode_Error.None)
	defer Destroy_Bencode_Value(&value)
	testing.expect_value(t, value.Kind, Bencode_Kind.Dictionary)
	testing.expect_value(t, len(value.Dictionary), 2)
	encoded := Bencode_Encode(&value)
	defer delete(encoded)
	testing.expect(t, bytes_equal(encoded, input))

	duplicate := []byte{'d', '1', ':', 'a', '1', ':', 'x', '1', ':', 'a', '1', ':', 'y', 'e'}
	_, duplicate_error := Bencode_Decode_Default(duplicate)
	testing.expect_value(t, duplicate_error, Bencode_Error.Duplicate_Dictionary_Key)

	leading_zero := []byte{'i', '0', '1', 'e'}
	_, leading_zero_error := Bencode_Decode_Default(leading_zero)
	testing.expect_value(t, leading_zero_error, Bencode_Error.Leading_Zero)

	truncated := []byte{'l', '4', ':', 't', 'e', 's', 't'}
	_, truncated_error := Bencode_Decode_Default(truncated)
	testing.expect_value(t, truncated_error, Bencode_Error.Unexpected_End)
}

@(test)
magnet_hex_and_base32_test :: proc(t: ^testing.T) {
	hex_uri := "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=FitGirl%20Release&tr=https%3A%2F%2Ftracker.example%2Fannounce&tr=udp%3A%2F%2Ftracker.example%3A6969"
	magnet, err := Parse_Magnet(hex_uri)
	testing.expect_value(t, err, Magnet_Error.None)
	defer Destroy_Magnet_Link(&magnet)
	testing.expect_value(t, magnet.Info_Hash[0], byte(0x01))
	testing.expect_value(t, magnet.Info_Hash[19], byte(0x67))
	testing.expect(t, bytes_equal(magnet.Name, []byte{'F', 'i', 't', 'G', 'i', 'r', 'l', ' ', 'R', 'e', 'l', 'e', 'a', 's', 'e'}))
	testing.expect_value(t, len(magnet.Trackers), 2)
	testing.expect(t, bytes_equal(magnet.Trackers[0], []byte{'h', 't', 't', 'p', 's', ':', '/', '/', 't', 'r', 'a', 'c', 'k', 'e', 'r', '.', 'e', 'x', 'a', 'm', 'p', 'l', 'e', '/', 'a', 'n', 'n', 'o', 'u', 'n', 'c', 'e'}))

	base32_uri := "MAGNET:?XT=URN:BTIH:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&dn=zero"
	base32_magnet, base32_error := Parse_Magnet(base32_uri)
	testing.expect_value(t, base32_error, Magnet_Error.None)
	defer Destroy_Magnet_Link(&base32_magnet)
	for b in base32_magnet.Info_Hash {
		testing.expect_value(t, b, byte(0))
	}

	nonzero_uri := "magnet:?xt=urn:btih:AEBAGBAFAYDQQCIKBMGA2DQPCAIREEYU"
	nonzero_magnet, nonzero_error := Parse_Magnet(nonzero_uri)
	testing.expect_value(t, nonzero_error, Magnet_Error.None)
	defer Destroy_Magnet_Link(&nonzero_magnet)
	testing.expect_value(t, nonzero_magnet.Info_Hash[0], byte(1))
	testing.expect_value(t, nonzero_magnet.Info_Hash[19], byte(20))

	lower_uri := "magnet:?xt=urn:btih:aebagbafaydqqcikbmga2dqpcaireeyu"
	lower_magnet, lower_error := Parse_Magnet(lower_uri)
	testing.expect_value(t, lower_error, Magnet_Error.None)
	defer Destroy_Magnet_Link(&lower_magnet)
	testing.expect_value(t, lower_magnet.Info_Hash[0], byte(1))
	testing.expect_value(t, lower_magnet.Info_Hash[19], byte(20))

	_, bad_escape_error := Parse_Magnet("magnet:?xt=urn:btih:0000000000000000000000000000000000000000&dn=%ZZ")
	testing.expect_value(t, bad_escape_error, Magnet_Error.Invalid_Percent_Escape)
}

@(test)
torrent_parse_and_info_hash_test :: proc(t: ^testing.T) {
	data: [dynamic]byte
	append(&data, "d4:infod6:lengthi5e4:name4:test12:piece lengthi16384e6:pieces20:")
	for i := 0; i < 20; i += 1 {
		append(&data, byte(0))
	}
	append(&data, "ee")

	torrent, err := Parse_Torrent(data[:])
	delete(data)
	testing.expect_value(t, err, Torrent_Error.None)
	defer Destroy_Torrent(&torrent)
	testing.expect(t, bytes_equal(torrent.Name, []byte{'t', 'e', 's', 't'}))
	testing.expect_value(t, torrent.Piece_Length, u64(16384))
	testing.expect_value(t, len(torrent.Piece_Hashes), 1)
	testing.expect_value(t, torrent.Total_Length, u64(5))
	testing.expect_value(t, len(torrent.Files), 1)
	testing.expect(t, bytes_equal(torrent.Files[0].Path[0], []byte{'t', 'e', 's', 't'}))
	testing.expect_value(t, len(torrent.Info_Bytes), 78)

	unsafe_data: [dynamic]byte
	append(&unsafe_data, "d4:infod4:name2:..12:piece lengthi1e6:pieces0:6:lengthi0eee")
	_, unsafe_error := Parse_Torrent(unsafe_data[:])
	delete(unsafe_data)
	testing.expect_value(t, unsafe_error, Torrent_Error.Unsafe_Path)

	multi_data: [dynamic]byte
	append(&multi_data, "d4:infod4:name4:root12:piece lengthi16384e6:pieces20:")
	for i := 0; i < 20; i += 1 {
		append(&multi_data, byte(0))
	}
	append(&multi_data, "5:filesld6:lengthi2e4:pathl5:a.txteed6:lengthi3e4:pathl5:b.txteeeee")
	multi_torrent, multi_error := Parse_Torrent(multi_data[:])
	delete(multi_data)
	testing.expect_value(t, multi_error, Torrent_Error.None)
	defer Destroy_Torrent(&multi_torrent)
	testing.expect_value(t, len(multi_torrent.Files), 2)
	testing.expect_value(t, multi_torrent.Total_Length, u64(5))
	testing.expect(t, bytes_equal(multi_torrent.Files[1].Path[0], []byte{'b', '.', 't', 'x', 't'}))
}

@(test)
piece_geometry_and_progress_test :: proc(t: ^testing.T) {
	bitfield, bitfield_error := Bitfield_Init(10)
	testing.expect_value(t, bitfield_error, Piece_Error.None)
	defer Destroy_Bitfield(&bitfield)
	Bitfield_Set_Piece(&bitfield, 0)
	Bitfield_Set_Piece(&bitfield, 5)
	Bitfield_Set_Piece(&bitfield, 9)
	testing.expect_value(t, bitfield.Bytes[0], byte(0x84))
	testing.expect_value(t, bitfield.Bytes[1], byte(0x40))
	testing.expect_value(t, Bitfield_Count(&bitfield), u32(3))
	Bitfield_Clear_Piece(&bitfield, 5)
	testing.expect(t, !Bitfield_Has_Piece(&bitfield, 5))

	progress, progress_error := Piece_Progress_Init(7, 32769)
	testing.expect_value(t, progress_error, Piece_Error.None)
	defer Destroy_Piece_Progress(&progress)
	testing.expect_value(t, progress.Block_Count, u32(3))
	first_block: [16384]byte
	complete, add_error := Piece_Progress_Add_Block(&progress, 0, first_block[:])
	testing.expect_value(t, add_error, Piece_Error.None)
	testing.expect(t, !complete)
	Piece_Progress_Mark_Requested(&progress, 16384 / Block_Size)
	_, found := Piece_Progress_Next_Unrequested_Block(&progress)
	testing.expect(t, found)

	wrong_block: [2]byte
	_, wrong_error := Piece_Progress_Add_Block(&progress, 32768, wrong_block[:])
	testing.expect_value(t, wrong_error, Piece_Error.Invalid_Block)
	second_block: [16384]byte
	_, second_error := Piece_Progress_Add_Block(&progress, 16384, second_block[:])
	testing.expect_value(t, second_error, Piece_Error.None)
	testing.expect(t, !Piece_Progress_Is_Requested(&progress, 1))
	last_block: [1]byte
	complete_last, last_error := Piece_Progress_Add_Block(&progress, 32768, last_block[:])
	testing.expect_value(t, last_error, Piece_Error.None)
	testing.expect(t, complete_last && Piece_Progress_Is_Complete(&progress))

	expected_sha1 := Torrent_Hash{0xa9, 0x99, 0x3e, 0x36, 0x47, 0x06, 0x81, 0x6a, 0xba, 0x3e, 0x25, 0x71, 0x78, 0x50, 0xc2, 0x6c, 0x9c, 0xd0, 0xd8, 0x9d}
	testing.expect(t, Verify_Piece([]byte{'a', 'b', 'c'}, &expected_sha1))
	piece_count, piece_count_ok := Piece_Count(32769, 16384)
	testing.expect(t, piece_count_ok)
	testing.expect_value(t, piece_count, u32(3))
}

@(test)
wire_handshake_and_message_test :: proc(t: ^testing.T) {
	handshake: Wire_Handshake
	for i := 0; i < 20; i += 1 {
		handshake.Info_Hash[i] = byte(i)
		handshake.Peer_ID[i] = byte(0xa0 + i)
	}
	handshake.Reserved[5] = 0x10
	encoded_handshake := Wire_Handshake_Serialize(handshake)
	parsed_handshake, handshake_error := Wire_Handshake_Parse(encoded_handshake[:])
	testing.expect_value(t, handshake_error, Wire_Error.None)
	testing.expect_value(t, parsed_handshake.Info_Hash[19], byte(19))
	testing.expect_value(t, parsed_handshake.Peer_ID[0], byte(0xa0))

	request := Wire_Message_View{Kind = .Request, Index = 4, Begin = 16384, Length = 16384}
	wire_request, request_error := Wire_Message_Encode(request)
	testing.expect_value(t, request_error, Wire_Error.None)
	defer delete(wire_request)
	parsed_request, parse_error := Wire_Message_Parse(wire_request)
	testing.expect_value(t, parse_error, Wire_Error.None)
	testing.expect_value(t, parsed_request.Consumed, 17)
	testing.expect_value(t, parsed_request.Message.Kind, Wire_Message_Kind.Request)
	testing.expect_value(t, parsed_request.Message.Index, u32(4))
	testing.expect_value(t, parsed_request.Message.Length, u32(16384))

	invalid_request := Wire_Message_View{Kind = .Request, Length = 0}
	_, invalid_request_error := Wire_Message_Encode(invalid_request)
	testing.expect_value(t, invalid_request_error, Wire_Error.Invalid_Length)
	invalid_extension := Wire_Message_View{Kind = .Extended}
	_, invalid_extension_error := Wire_Message_Encode(invalid_extension)
	testing.expect_value(t, invalid_extension_error, Wire_Error.Invalid_Length)

	block := []byte{'o', 'k'}
	piece := Wire_Message_View{Kind = .Piece, Index = 1, Begin = 0, Payload = block}
	wire_piece, piece_error := Wire_Message_Encode(piece)
	testing.expect_value(t, piece_error, Wire_Error.None)
	defer delete(wire_piece)
	parsed_piece, parsed_piece_error := Wire_Message_Parse(wire_piece)
	testing.expect_value(t, parsed_piece_error, Wire_Error.None)
	testing.expect(t, bytes_equal(parsed_piece.Message.Payload, block))

	keep_alive, keep_alive_error := Wire_Message_Parse([]byte{0, 0, 0, 0})
	testing.expect_value(t, keep_alive_error, Wire_Error.None)
	testing.expect_value(t, keep_alive.Message.Kind, Wire_Message_Kind.Keep_Alive)
	testing.expect_value(t, keep_alive.Consumed, 4)
}

@(test)
tracker_query_and_response_test :: proc(t: ^testing.T) {
	request: Tracker_Announce_Request
	request.Compact = true
	request.Port = 6881
	request.Left = 123
	request.Event = .Started
	url, url_error := Tracker_Build_Announce_URL("https://tracker.example/announce", request)
	testing.expect_value(t, url_error, Tracker_Error.None)
	defer delete(url)
	url_prefix := "https://tracker.example/announce?info_hash="
	url_suffix := "&compact=1&event=started"
	testing.expect(t, bytes_equal(url[:len(url_prefix)], transmute([]byte)url_prefix))
	testing.expect(t, bytes_equal(url[len(url)-len(url_suffix):], transmute([]byte)url_suffix))

	response_data: [dynamic]byte
	append(&response_data, "d8:intervali1800e5:peers6:")
	append(&response_data, byte(127))
	append(&response_data, byte(0))
	append(&response_data, byte(0))
	append(&response_data, byte(1))
	append(&response_data, byte(0x1a))
	append(&response_data, byte(0xe1))
	append(&response_data, 'e')
	response, response_error := Tracker_Parse_Announce_Response(response_data[:])
	delete(response_data)
	testing.expect_value(t, response_error, Tracker_Error.None)
	defer Destroy_Tracker_Response(&response)
	testing.expect_value(t, response.Interval, u64(1800))
	testing.expect_value(t, len(response.Peers), 1)
	testing.expect_value(t, response.Peers[0].IP[0], byte(127))
	testing.expect_value(t, response.Peers[0].Port, u16(6881))

	invalid_response, invalid_error := Tracker_Parse_Announce_Response([]byte{'d', '8', ':', 'i', 'n', 't', 'e', 'r', 'v', 'a', 'l', 'i', '1', 'e', 'e'})
	Destroy_Tracker_Response(&invalid_response)
	testing.expect_value(t, invalid_error, Tracker_Error.Invalid_Response)
}
