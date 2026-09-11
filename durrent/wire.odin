package durrent

import endian "core:encoding/endian"

BitTorrent_Protocol_String :: "BitTorrent protocol"
Handshake_Length :: 68
Wire_Max_Message_Length :: u32(2 * 1024 * 1024)

Wire_Error :: enum {
	None,
	Incomplete,
	Invalid_Protocol,
	Invalid_Length,
	Unknown_Message_ID,
	Message_Too_Large,
	Out_Of_Memory,
}

Wire_Handshake :: struct {
	Reserved:  [8]byte,
	Info_Hash: Torrent_Hash,
	Peer_ID:   [20]byte,
}

Wire_Handshake_Serialize :: proc(handshake: Wire_Handshake) -> [Handshake_Length]byte {
	result: [Handshake_Length]byte
	result[0] = 19
	protocol := BitTorrent_Protocol_String
	copy(result[1:20], transmute([]byte)protocol)
	for i := 0; i < 8; i += 1 {
		result[20+i] = handshake.Reserved[i]
	}
	for i := 0; i < 20; i += 1 {
		result[28+i] = handshake.Info_Hash[i]
		result[48+i] = handshake.Peer_ID[i]
	}
	return result
}

Wire_Handshake_Parse :: proc(data: []byte) -> (Wire_Handshake, Wire_Error) {
	if len(data) < Handshake_Length {
		return Wire_Handshake{}, .Incomplete
	}
	if data[0] != 19 {
		return Wire_Handshake{}, .Invalid_Protocol
	}
	protocol := BitTorrent_Protocol_String
	if !bytes_equal(data[1:20], transmute([]byte)protocol) {
		return Wire_Handshake{}, .Invalid_Protocol
	}
	result: Wire_Handshake
	copy(result.Reserved[:], data[20:28])
	copy(result.Info_Hash[:], data[28:48])
	copy(result.Peer_ID[:], data[48:68])
	return result, .None
}

Wire_Message_ID :: enum u8 {
	Choke = 0,
	Unchoke = 1,
	Interested = 2,
	Not_Interested = 3,
	Have = 4,
	Bitfield = 5,
	Request = 6,
	Piece = 7,
	Cancel = 8,
	Port = 9,
	Extended = 20,
}

Wire_Message_Kind :: enum {
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

// Payload borrows the caller's receive buffer. It is the bitfield bytes for a
// Bitfield message, the block bytes for Piece, and the extension-id-plus-data
// bytes for Extended. Copy it before retaining the view beyond that buffer.
Wire_Message_View :: struct {
	Kind:    Wire_Message_Kind,
	Index:   u32,
	Begin:   u32,
	Length:  u32,
	Port:    u16,
	Payload: []byte,
}

Wire_Message_Parse_Result :: struct {
	Message:  Wire_Message_View,
	Consumed: int,
}

Wire_Message_Parse :: proc(data: []byte) -> (Wire_Message_Parse_Result, Wire_Error) {
	if len(data) < 4 {
		return Wire_Message_Parse_Result{}, .Incomplete
	}
	length, length_ok := endian.get_u32(data[:4], .Big)
	if !length_ok {
		return Wire_Message_Parse_Result{}, .Incomplete
	}
	if length == 0 {
		return Wire_Message_Parse_Result{
			Message = Wire_Message_View{Kind = .Keep_Alive},
			Consumed = 4,
		}, .None
	}
	if length > Wire_Max_Message_Length {
		return Wire_Message_Parse_Result{}, .Message_Too_Large
	}
	if length < 1 {
		return Wire_Message_Parse_Result{}, .Invalid_Length
	}
	total := 4 + int(length)
	if len(data) < total {
		return Wire_Message_Parse_Result{}, .Incomplete
	}

	message_id := data[4]
	payload := data[5:total]
	message: Wire_Message_View
	switch message_id {
	case byte(Wire_Message_ID.Choke):
		if len(payload) != 0 {
			return Wire_Message_Parse_Result{}, .Invalid_Length
		}
		message.Kind = .Choke
	case byte(Wire_Message_ID.Unchoke):
		if len(payload) != 0 {
			return Wire_Message_Parse_Result{}, .Invalid_Length
		}
		message.Kind = .Unchoke
	case byte(Wire_Message_ID.Interested):
		if len(payload) != 0 {
			return Wire_Message_Parse_Result{}, .Invalid_Length
		}
		message.Kind = .Interested
	case byte(Wire_Message_ID.Not_Interested):
		if len(payload) != 0 {
			return Wire_Message_Parse_Result{}, .Invalid_Length
		}
		message.Kind = .Not_Interested
	case byte(Wire_Message_ID.Have):
		if len(payload) != 4 {
			return Wire_Message_Parse_Result{}, .Invalid_Length
		}
		index, index_ok := endian.get_u32(payload[:4], .Big)
		if !index_ok {
			return Wire_Message_Parse_Result{}, .Invalid_Length
		}
		message.Kind = .Have
		message.Index = index
	case byte(Wire_Message_ID.Bitfield):
		message.Kind = .Bitfield
		message.Payload = payload
	case byte(Wire_Message_ID.Request):
		if len(payload) != 12 {
			return Wire_Message_Parse_Result{}, .Invalid_Length
		}
		request, request_ok := wire_parse_block_request(payload)
		if !request_ok || !wire_block_length_valid(request.Length) {
			return Wire_Message_Parse_Result{}, .Invalid_Length
		}
		message.Kind = .Request
		message.Index = request.Index
		message.Begin = request.Begin
		message.Length = request.Length
	case byte(Wire_Message_ID.Piece):
		if len(payload) < 8 || len(payload)-8 == 0 || len(payload)-8 > int(Block_Size) {
			return Wire_Message_Parse_Result{}, .Invalid_Length
		}
		index, index_ok := endian.get_u32(payload[:4], .Big)
		begin, begin_ok := endian.get_u32(payload[4:8], .Big)
		if !index_ok || !begin_ok {
			return Wire_Message_Parse_Result{}, .Invalid_Length
		}
		message.Kind = .Piece
		message.Index = index
		message.Begin = begin
		message.Payload = payload[8:]
	case byte(Wire_Message_ID.Cancel):
		if len(payload) != 12 {
			return Wire_Message_Parse_Result{}, .Invalid_Length
		}
		request, request_ok := wire_parse_block_request(payload)
		if !request_ok || !wire_block_length_valid(request.Length) {
			return Wire_Message_Parse_Result{}, .Invalid_Length
		}
		message.Kind = .Cancel
		message.Index = request.Index
		message.Begin = request.Begin
		message.Length = request.Length
	case byte(Wire_Message_ID.Port):
		if len(payload) != 2 {
			return Wire_Message_Parse_Result{}, .Invalid_Length
		}
		port, port_ok := endian.get_u16(payload[:2], .Big)
		if !port_ok {
			return Wire_Message_Parse_Result{}, .Invalid_Length
		}
		message.Kind = .Port
		message.Port = port
	case byte(Wire_Message_ID.Extended):
		if len(payload) < 1 {
			return Wire_Message_Parse_Result{}, .Invalid_Length
		}
		message.Kind = .Extended
		message.Payload = payload
	case:
		return Wire_Message_Parse_Result{}, .Unknown_Message_ID
	}

	return Wire_Message_Parse_Result{Message = message, Consumed = total}, .None
}

Wire_Message_Encode :: proc(message: Wire_Message_View) -> ([]byte, Wire_Error) {
	switch message.Kind {
	case .Request, .Cancel:
		if !wire_block_length_valid(message.Length) {
			return nil, .Invalid_Length
		}
	case .Piece:
		if len(message.Payload) == 0 || len(message.Payload) > int(Block_Size) {
			return nil, .Invalid_Length
		}
	case .Extended:
		if len(message.Payload) == 0 {
			return nil, .Invalid_Length
		}
	case .Keep_Alive, .Choke, .Unchoke, .Interested, .Not_Interested, .Have, .Bitfield, .Port:
		{}
	}

	frame_length: int
	switch message.Kind {
	case .Keep_Alive:
		frame_length = 4
	case .Choke, .Unchoke, .Interested, .Not_Interested:
		frame_length = 5
	case .Have:
		frame_length = 9
	case .Bitfield:
		frame_length = 5 + len(message.Payload)
	case .Request, .Cancel:
		frame_length = 17
	case .Piece:
		frame_length = 13 + len(message.Payload)
	case .Port:
		frame_length = 7
	case .Extended:
		frame_length = 5 + len(message.Payload)
	}

	if frame_length < 4 || frame_length-4 > int(Wire_Max_Message_Length) {
		return nil, .Message_Too_Large
	}
	result, alloc_error := make([]byte, frame_length, context.allocator)
	if alloc_error != nil {
		return nil, .Out_Of_Memory
	}
	if !endian.put_u32(result[:4], .Big, u32(frame_length-4)) {
		delete(result)
		return nil, .Invalid_Length
	}
	if message.Kind == .Keep_Alive {
		return result, .None
	}

	message_id: byte
	switch message.Kind {
	case .Choke:
		message_id = byte(Wire_Message_ID.Choke)
	case .Unchoke:
		message_id = byte(Wire_Message_ID.Unchoke)
	case .Interested:
		message_id = byte(Wire_Message_ID.Interested)
	case .Not_Interested:
		message_id = byte(Wire_Message_ID.Not_Interested)
	case .Have:
		message_id = byte(Wire_Message_ID.Have)
	case .Bitfield:
		message_id = byte(Wire_Message_ID.Bitfield)
	case .Request:
		message_id = byte(Wire_Message_ID.Request)
	case .Piece:
		message_id = byte(Wire_Message_ID.Piece)
	case .Cancel:
		message_id = byte(Wire_Message_ID.Cancel)
	case .Port:
		message_id = byte(Wire_Message_ID.Port)
	case .Extended:
		message_id = byte(Wire_Message_ID.Extended)
	case .Keep_Alive:
		message_id = 0
	}
	result[4] = message_id

	switch message.Kind {
	case .Have:
		endian.put_u32(result[5:9], .Big, message.Index)
	case .Bitfield:
		copy(result[5:], message.Payload)
	case .Request, .Cancel:
		wire_write_block_request(result[5:17], message.Index, message.Begin, message.Length)
	case .Piece:
		endian.put_u32(result[5:9], .Big, message.Index)
		endian.put_u32(result[9:13], .Big, message.Begin)
		copy(result[13:], message.Payload)
	case .Port:
		endian.put_u16(result[5:7], .Big, message.Port)
	case .Extended:
		copy(result[5:], message.Payload)
	case .Choke, .Unchoke, .Interested, .Not_Interested, .Keep_Alive:
		{}
	}
	return result, .None
}

Wire_Block_Request :: struct {
	Index:  u32,
	Begin:  u32,
	Length: u32,
}

wire_parse_block_request :: proc(data: []byte) -> (Wire_Block_Request, bool) {
	if len(data) != 12 {
		return Wire_Block_Request{}, false
	}
	index, index_ok := endian.get_u32(data[0:4], .Big)
	begin, begin_ok := endian.get_u32(data[4:8], .Big)
	length, length_ok := endian.get_u32(data[8:12], .Big)
	if !index_ok || !begin_ok || !length_ok {
		return Wire_Block_Request{}, false
	}
	return Wire_Block_Request{Index = index, Begin = begin, Length = length}, true
}

wire_block_length_valid :: proc(length: u32) -> bool {
	return length > 0 && length <= Block_Size
}

wire_write_block_request :: proc(data: []byte, index, begin, length: u32) {
	if len(data) < 12 {
		return
	}
	endian.put_u32(data[0:4], .Big, index)
	endian.put_u32(data[4:8], .Big, begin)
	endian.put_u32(data[8:12], .Big, length)
}
