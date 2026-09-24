package durrent

import endian "core:encoding/endian"

// MSE_Request_Hash_3 is the protocol hash used to hide req2 on the wire.
// The initiator sends HASH(req2, SKEY) xor HASH(req3, S).
MSE_Request_Hash_3 :: proc(shared_secret: []byte) -> [20]byte {
	return mse_sha1("req3", shared_secret, nil)
}

MSE_Request_Hash_2_Masked :: proc(shared_secret: []byte, info_hash: Torrent_Hash) -> [20]byte {
	result := MSE_Info_Hash_Request(info_hash)
	mask := MSE_Request_Hash_3(shared_secret)
	for index := 0; index < len(result); index += 1 {
		result[index] = result[index] ~ mask[index]
	}
	return result
}

MSE_Handshake_Role :: enum {
	Initiator,
	Responder,
}

MSE_Handshake_State :: enum {
	New,
	Await_DH_Public,
	Await_Request_Hash,
	Await_Request_Body,
	Await_Request_Crypto,
	Await_Response,
	Complete,
	Failed,
}

MSE_Handshake_Error :: enum {
	None,
	Invalid_Argument,
	Invalid_State,
	Invalid_Private_Key,
	Invalid_DH_Public,
	Bad_Request_Hash,
	Bad_Verification_Constant,
	Bad_Crypto_Selection,
	Bad_Pad,
	Bad_Initial_Payload,
}

// MSE_Handshake_Engine owns every byte it queues. After Feed, callers drain
// Outgoing and Payload with the Take functions and must delete those returned
// dynamic arrays when finished. It is deliberately socket-agnostic.
MSE_Handshake_Engine :: struct {
	Role:       MSE_Handshake_Role,
	Policy:     MSE_Policy,
	State:      MSE_Handshake_State,
	Error:      MSE_Handshake_Error,
	Info_Hash:  Torrent_Hash,
	Private:    [MSE_DH_Private_Length]byte,
	Public:     [MSE_DH_Public_Length]byte,
	Shared:     [MSE_DH_Public_Length]byte,
	Provide:    u32,
	Encryption: u32,

	Send:    MSE_RC4,
	Receive: MSE_RC4,

	// Incoming is raw except for its first Decrypted bytes. Keeping this count
	// prevents a plaintext payload coalesced after the encrypted negotiation
	// frame from being accidentally RC4-decoded.
	Incoming:  [dynamic]byte,
	Decrypted: int,
	Outgoing:  [dynamic]byte,
	Payload:   [dynamic]byte,

	Pad:        [dynamic]byte,
	Initial_IA: [dynamic]byte,
}

MSE_Handshake_Destroy :: proc(engine: ^MSE_Handshake_Engine) {
	if engine == nil {
		return
	}
	delete(engine.Incoming)
	delete(engine.Outgoing)
	delete(engine.Payload)
	delete(engine.Pad)
	delete(engine.Initial_IA)
	engine^ = MSE_Handshake_Engine{}
}

// MSE_Handshake_Initiator_Init starts an MSE connection and queues Ya. private
// is an explicit input so callers can source it from a CSPRNG in production and
// deterministic tests can supply a fixed value. initial_ia is included in the
// encrypted Req3 frame, normally the ordinary BitTorrent handshake.
MSE_Handshake_Initiator_Init :: proc(
	engine: ^MSE_Handshake_Engine,
	policy: MSE_Policy,
	info_hash: Torrent_Hash,
	private: [MSE_DH_Private_Length]byte,
	pad, initial_ia: []byte,
) -> MSE_Handshake_Error {
	if !mse_engine_init_common(engine, .Initiator, policy, info_hash, private, pad, initial_ia) {
		return engine.Error
	}
	if policy == .Disabled {
		mse_engine_emit_plain(engine, initial_ia)
		return .None
	}
	append(&engine.Outgoing, ..engine.Public[:])
	return .None
}

// MSE_Handshake_Responder_Init prepares an inbound MSE connection. pad becomes
// PadD in the encrypted response. A Disabled responder is a plaintext pass-through.
MSE_Handshake_Responder_Init :: proc(
	engine: ^MSE_Handshake_Engine,
	policy: MSE_Policy,
	info_hash: Torrent_Hash,
	private: [MSE_DH_Private_Length]byte,
	pad: []byte,
) -> MSE_Handshake_Error {
	if !mse_engine_init_common(engine, .Responder, policy, info_hash, private, pad, nil) {
		return engine.Error
	}
	return .None
}

MSE_Handshake_Complete :: proc(engine: ^MSE_Handshake_Engine) -> bool {
	return engine != nil && engine.State == .Complete
}

MSE_Handshake_Take_Outgoing :: proc(engine: ^MSE_Handshake_Engine) -> [dynamic]byte {
	if engine == nil {
		return [dynamic]byte{}
	}
	result := engine.Outgoing
	engine.Outgoing = [dynamic]byte{}
	return result
}

MSE_Handshake_Take_Payload :: proc(engine: ^MSE_Handshake_Engine) -> [dynamic]byte {
	if engine == nil {
		return [dynamic]byte{}
	}
	result := engine.Payload
	engine.Payload = [dynamic]byte{}
	return result
}

// MSE_Handshake_Queue_Payload queues normal post-handshake bytes. It is valid
// only after negotiation, so an initiator's first BitTorrent handshake belongs
// in initial_ia instead.
MSE_Handshake_Queue_Payload :: proc(engine: ^MSE_Handshake_Engine, data: []byte) -> MSE_Handshake_Error {
	if engine == nil {
		return .Invalid_Argument
	}
	if engine.State != .Complete {
		return .Invalid_State
	}
	if engine.Encryption == MSE_Encryption_RC4 {
		mse_engine_emit_encrypted(engine, data)
	} else {
		mse_engine_emit_plain(engine, data)
	}
	return .None
}

// MSE_Handshake_Feed accepts arbitrary socket-read fragments. It queues any
// bytes that must be written and any decrypted IA or ordinary payload.
MSE_Handshake_Feed :: proc(engine: ^MSE_Handshake_Engine, data: []byte) -> MSE_Handshake_Error {
	if engine == nil {
		return .Invalid_Argument
	}
	if engine.State == .Failed {
		return engine.Error
	}
	if len(data) > 0 {
		append(&engine.Incoming, ..data)
	}

	for engine.State != .Failed {
		progress := false
		switch engine.State {
		case .Complete:
			mse_engine_deliver_payload(engine)
			return .None
		case .Await_DH_Public:
			if len(engine.Incoming) < MSE_DH_Public_Length {
				return .None
			}
			remote: [MSE_DH_Public_Length]byte
			copy(remote[:], engine.Incoming[:MSE_DH_Public_Length])
			mse_engine_consume(engine, MSE_DH_Public_Length)
			shared, valid := MSE_DH_Shared(engine.Private, remote)
			if !valid {
				return mse_engine_fail(engine, .Invalid_DH_Public)
			}
			engine.Shared = shared
			if !MSE_RC4_Directional_Init(&engine.Send, &engine.Receive, engine.Policy, engine.Role == .Initiator, engine.Shared[:], engine.Info_Hash) {
				return mse_engine_fail(engine, .Invalid_Argument)
			}
			if engine.Role == .Initiator {
				mse_engine_emit_initiator_request(engine)
				engine.State = .Await_Response
			} else {
				append(&engine.Outgoing, ..engine.Public[:])
				engine.State = .Await_Request_Hash
			}
			progress = true
		case .Await_Request_Hash:
			// MSE permits up to 512 opaque PadA bytes before req1. Search only
			// that bounded window, which also bounds malicious buffering.
			expected := MSE_Request_Hash(engine.Shared[:])
			found := -1
			limit := min(len(engine.Incoming)-20, 512)
			for index := 0; index <= limit; index += 1 {
				if bytes_equal(engine.Incoming[index:index+20], expected[:]) {
					found = index
					break
				}
			}
			if found >= 0 {
				mse_engine_consume(engine, found+20)
				engine.State = .Await_Request_Body
				progress = true
			} else if len(engine.Incoming) >= 532 {
				return mse_engine_fail(engine, .Bad_Request_Hash)
			} else {
				return .None
			}
		case .Await_Request_Body:
			if len(engine.Incoming) < 20 {
				return .None
			}
			expected := MSE_Request_Hash_2_Masked(engine.Shared[:], engine.Info_Hash)
			if !bytes_equal(engine.Incoming[:20], expected[:]) {
				return mse_engine_fail(engine, .Bad_Request_Hash)
			}
			mse_engine_consume(engine, 20)
			engine.State = .Await_Request_Crypto
			progress = true
		case .Await_Request_Crypto:
			if !mse_engine_parse_request_body(engine) {
				if engine.State == .Failed {
					return engine.Error
				}
				return .None
			}
			progress = true
		case .Await_Response:
			if !mse_engine_parse_response(engine) {
				if engine.State == .Failed {
					return engine.Error
				}
				return .None
			}
			progress = true
		case .New, .Failed:
			return mse_engine_fail(engine, .Invalid_State)
		}
		if !progress {
			return .None
		}
	}
	return engine.Error
}

mse_engine_init_common :: proc(
	engine: ^MSE_Handshake_Engine,
	role: MSE_Handshake_Role,
	policy: MSE_Policy,
	info_hash: Torrent_Hash,
	private: [MSE_DH_Private_Length]byte,
	pad, initial_ia: []byte,
) -> bool {
	if engine == nil {
		return false
	}
	MSE_Handshake_Destroy(engine)
	if len(pad) > 512 {
		engine.Error = .Bad_Pad
		engine.State = .Failed
		return false
	}
	if len(initial_ia) > 65535 {
		engine.Error = .Bad_Initial_Payload
		engine.State = .Failed
		return false
	}
	engine.Role = role
	engine.Policy = policy
	engine.Info_Hash = info_hash
	append(&engine.Pad, ..pad)
	append(&engine.Initial_IA, ..initial_ia)
	if policy == .Disabled {
		engine.Encryption = MSE_Encryption_Plaintext
		engine.State = .Complete
		return true
	}
	private_nonzero := false
	for value in private {
		private_nonzero = private_nonzero || value != 0
	}
	if !private_nonzero {
		engine.Error = .Invalid_Private_Key
		engine.State = .Failed
		return false
	}
	engine.Private = private
	engine.Public = MSE_DH_Public(private)
	engine.Provide = MSE_Encryption_RC4
	if policy == .Preferred {
		engine.Provide |= MSE_Encryption_Plaintext
	}
	engine.State = .Await_DH_Public
	return true
}

mse_engine_emit_initiator_request :: proc(engine: ^MSE_Handshake_Engine) {
	request := MSE_Request_Hash(engine.Shared[:])
	masked := MSE_Request_Hash_2_Masked(engine.Shared[:], engine.Info_Hash)
	plain: [dynamic]byte
	defer delete(plain)
	append(&plain, ..request[:])
	append(&plain, ..masked[:])
	vc := MSE_Verification_Constant
	append(&plain, ..vc[:])
	mse_engine_append_u32(&plain, engine.Provide)
	mse_engine_append_u16(&plain, u16(len(engine.Pad)))
	append(&plain, ..engine.Pad[:])
	mse_engine_append_u16(&plain, u16(len(engine.Initial_IA)))
	append(&plain, ..engine.Initial_IA[:])
	// req1 and req2 xor req3 are intentionally cleartext. Only the Req3 body
	// starting at crypto_provide is RC4 encrypted.
	append(&engine.Outgoing, ..plain[:40])
	mse_engine_emit_encrypted(engine, plain[40:])
}

mse_engine_parse_request_body :: proc(engine: ^MSE_Handshake_Engine) -> bool {
	if !mse_engine_decrypt_to(engine, 14) {
		return false
	}
	if !mse_engine_is_vc(engine.Incoming[:8]) {
		mse_engine_fail(engine, .Bad_Verification_Constant)
		return false
	}
	provide, provide_ok := endian.get_u32(engine.Incoming[8:12], .Big)
	if !provide_ok || !mse_engine_valid_provide(provide) {
		mse_engine_fail(engine, .Bad_Crypto_Selection)
		return false
	}
	selection, selection_ok := mse_engine_select_crypto(engine.Policy, provide)
	if !selection_ok {
		mse_engine_fail(engine, .Bad_Crypto_Selection)
		return false
	}
	pad_length, pad_ok := endian.get_u16(engine.Incoming[12:14], .Big)
	if !pad_ok || pad_length > 512 {
		mse_engine_fail(engine, .Bad_Pad)
		return false
	}
	prefix_length := 14 + int(pad_length) + 2
	if !mse_engine_decrypt_to(engine, prefix_length) {
		return false
	}
	ia_length, ia_ok := endian.get_u16(engine.Incoming[14+int(pad_length):prefix_length], .Big)
	if !ia_ok {
		mse_engine_fail(engine, .Bad_Initial_Payload)
		return false
	}
	total_length := prefix_length + int(ia_length)
	if !mse_engine_decrypt_to(engine, total_length) {
		return false
	}
	append(&engine.Payload, ..engine.Incoming[prefix_length:total_length])
	mse_engine_consume(engine, total_length)
	engine.Encryption = selection
	mse_engine_emit_responder_response(engine)
	engine.State = .Complete
	return true
}

mse_engine_parse_response :: proc(engine: ^MSE_Handshake_Engine) -> bool {
	if !mse_engine_decrypt_to(engine, 14) {
		return false
	}
	if !mse_engine_is_vc(engine.Incoming[:8]) {
		mse_engine_fail(engine, .Bad_Verification_Constant)
		return false
	}
	selection, selection_ok := endian.get_u32(engine.Incoming[8:12], .Big)
	if !selection_ok || (selection != MSE_Encryption_Plaintext && selection != MSE_Encryption_RC4) || engine.Provide&selection == 0 || (engine.Policy == .Required && selection != MSE_Encryption_RC4) {
		mse_engine_fail(engine, .Bad_Crypto_Selection)
		return false
	}
	pad_length, pad_ok := endian.get_u16(engine.Incoming[12:14], .Big)
	if !pad_ok || pad_length > 512 {
		mse_engine_fail(engine, .Bad_Pad)
		return false
	}
	total_length := 14 + int(pad_length)
	if !mse_engine_decrypt_to(engine, total_length) {
		return false
	}
	mse_engine_consume(engine, total_length)
	engine.Encryption = selection
	engine.State = .Complete
	return true
}

mse_engine_emit_responder_response :: proc(engine: ^MSE_Handshake_Engine) {
	plain: [dynamic]byte
	defer delete(plain)
	vc := MSE_Verification_Constant
	append(&plain, ..vc[:])
	mse_engine_append_u32(&plain, engine.Encryption)
	mse_engine_append_u16(&plain, u16(len(engine.Pad)))
	append(&plain, ..engine.Pad[:])
	mse_engine_emit_encrypted(engine, plain[:])
}

mse_engine_select_crypto :: proc(policy: MSE_Policy, provide: u32) -> (u32, bool) {
	if !mse_engine_valid_provide(provide) || policy == .Disabled {
		return 0, false
	}
	if provide&MSE_Encryption_RC4 != 0 {
		return MSE_Encryption_RC4, true
	}
	if policy == .Preferred && provide&MSE_Encryption_Plaintext != 0 {
		return MSE_Encryption_Plaintext, true
	}
	return 0, false
}

mse_engine_valid_provide :: proc(provide: u32) -> bool {
	known := MSE_Encryption_Plaintext | MSE_Encryption_RC4
	return provide != 0 && provide&~known == 0
}

mse_engine_decrypt_to :: proc(engine: ^MSE_Handshake_Engine, length: int) -> bool {
	if length > len(engine.Incoming) {
		return false
	}
	if length > engine.Decrypted {
		MSE_RC4_Apply(&engine.Receive, engine.Incoming[engine.Decrypted:length])
		engine.Decrypted = length
	}
	return true
}

mse_engine_consume :: proc(engine: ^MSE_Handshake_Engine, count: int) {
	if count <= 0 {
		return
	}
	remaining := len(engine.Incoming) - count
	if remaining > 0 {
		copy(engine.Incoming[:remaining], engine.Incoming[count:])
	}
	resize(&engine.Incoming, remaining)
	engine.Decrypted = max(0, engine.Decrypted-count)
}

mse_engine_deliver_payload :: proc(engine: ^MSE_Handshake_Engine) {
	if len(engine.Incoming) == 0 {
		return
	}
	if engine.Encryption == MSE_Encryption_RC4 {
		MSE_RC4_Apply(&engine.Receive, engine.Incoming[:])
	}
	append(&engine.Payload, ..engine.Incoming[:])
	resize(&engine.Incoming, 0)
	engine.Decrypted = 0
}

mse_engine_emit_plain :: proc(engine: ^MSE_Handshake_Engine, data: []byte) {
	append(&engine.Outgoing, ..data)
}

mse_engine_emit_encrypted :: proc(engine: ^MSE_Handshake_Engine, data: []byte) {
	start := len(engine.Outgoing)
	append(&engine.Outgoing, ..data)
	MSE_RC4_Apply(&engine.Send, engine.Outgoing[start:])
}

mse_engine_append_u16 :: proc(output: ^[dynamic]byte, value: u16) {
	encoded: [2]byte
	endian.put_u16(encoded[:], .Big, value)
	append(output, ..encoded[:])
}

mse_engine_append_u32 :: proc(output: ^[dynamic]byte, value: u32) {
	encoded: [4]byte
	endian.put_u32(encoded[:], .Big, value)
	append(output, ..encoded[:])
}

mse_engine_is_vc :: proc(data: []byte) -> bool {
	vc := MSE_Verification_Constant
	return len(data) == len(vc) && bytes_equal(data, vc[:])
}

mse_engine_fail :: proc(engine: ^MSE_Handshake_Engine, error: MSE_Handshake_Error) -> MSE_Handshake_Error {
	engine.Error = error
	engine.State = .Failed
	return error
}
