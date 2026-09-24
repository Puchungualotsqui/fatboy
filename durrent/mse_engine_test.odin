package durrent

import "core:testing"

mse_engine_test_info_hash :: proc() -> Torrent_Hash {
	result: Torrent_Hash
	for index := 0; index < len(result); index += 1 {
		result[index] = byte(index + 1)
	}
	return result
}

mse_engine_test_private :: proc(first: byte) -> [MSE_DH_Private_Length]byte {
	result: [MSE_DH_Private_Length]byte
	for index := 0; index < len(result); index += 1 {
		result[index] = first + byte(index)
	}
	return result
}

// Deliver in deliberately uneven chunks to exercise every streaming boundary.
mse_engine_test_deliver :: proc(t: ^testing.T, sender, receiver: ^MSE_Handshake_Engine) {
	outgoing := MSE_Handshake_Take_Outgoing(sender)
	defer delete(outgoing)
	chunks := []int{1, 7, 2, 19, 3, 31}
	position := 0
	chunk_index := 0
	for position < len(outgoing) {
		amount := min(chunks[chunk_index%len(chunks)], len(outgoing)-position)
		error := MSE_Handshake_Feed(receiver, outgoing[position:position+amount])
		testing.expect_value(t, error, MSE_Handshake_Error.None)
		position += amount
		chunk_index += 1
	}
}

mse_engine_test_start :: proc(t: ^testing.T, initiator, responder: ^MSE_Handshake_Engine) {
	info_hash := mse_engine_test_info_hash()
	initiator_private := mse_engine_test_private(1)
	responder_private := mse_engine_test_private(0x61)
	testing.expect_value(t, MSE_Handshake_Initiator_Init(initiator, .Preferred, info_hash, initiator_private, []byte{'c', 'p'}, []byte{'i', 'n', 'i', 't', 'i', 'a', 'l'}), MSE_Handshake_Error.None)
	testing.expect_value(t, MSE_Handshake_Responder_Init(responder, .Preferred, info_hash, responder_private, []byte{'d', 'p'}), MSE_Handshake_Error.None)
}

@(test)
mse_req3_mask_test :: proc(t: ^testing.T) {
	info_hash := mse_engine_test_info_hash()
	shared: [MSE_DH_Public_Length]byte
	for index := 0; index < len(shared); index += 1 {
		shared[index] = byte(index + 3)
	}
	req2 := MSE_Info_Hash_Request(info_hash)
	req3 := MSE_Request_Hash_3(shared[:])
	masked := MSE_Request_Hash_2_Masked(shared[:], info_hash)
	for index := 0; index < len(masked); index += 1 {
		masked[index] = masked[index] ~ req3[index]
	}
	testing.expect(t, bytes_equal(masked[:], req2[:]))
}

@(test)
mse_engine_fragmented_rc4_handshake_and_payload_test :: proc(t: ^testing.T) {
	initiator, responder: MSE_Handshake_Engine
	defer MSE_Handshake_Destroy(&initiator)
	defer MSE_Handshake_Destroy(&responder)
	mse_engine_test_start(t, &initiator, &responder)

	mse_engine_test_deliver(t, &initiator, &responder) // Ya
	mse_engine_test_deliver(t, &responder, &initiator) // Yb
	mse_engine_test_deliver(t, &initiator, &responder) // req1, req2 xor req3, encrypted C
	mse_engine_test_deliver(t, &responder, &initiator) // encrypted D

	testing.expect(t, MSE_Handshake_Complete(&initiator))
	testing.expect(t, MSE_Handshake_Complete(&responder))
	testing.expect_value(t, initiator.Encryption, MSE_Encryption_RC4)
	testing.expect_value(t, responder.Encryption, MSE_Encryption_RC4)
	ia := MSE_Handshake_Take_Payload(&responder)
	defer delete(ia)
	testing.expect(t, bytes_equal(ia[:], []byte{'i', 'n', 'i', 't', 'i', 'a', 'l'}))

	testing.expect_value(t, MSE_Handshake_Queue_Payload(&initiator, []byte{'p', 'a', 'y', 'l', 'o', 'a', 'd'}), MSE_Handshake_Error.None)
	mse_engine_test_deliver(t, &initiator, &responder)
	payload := MSE_Handshake_Take_Payload(&responder)
	defer delete(payload)
	testing.expect(t, bytes_equal(payload[:], []byte{'p', 'a', 'y', 'l', 'o', 'a', 'd'}))

	testing.expect_value(t, MSE_Handshake_Queue_Payload(&responder, []byte{'o', 'k'}), MSE_Handshake_Error.None)
	mse_engine_test_deliver(t, &responder, &initiator)
	response := MSE_Handshake_Take_Payload(&initiator)
	defer delete(response)
	testing.expect(t, bytes_equal(response[:], []byte{'o', 'k'}))
}

@(test)
mse_engine_rejects_bad_request_hash_test :: proc(t: ^testing.T) {
	initiator, responder: MSE_Handshake_Engine
	defer MSE_Handshake_Destroy(&initiator)
	defer MSE_Handshake_Destroy(&responder)
	mse_engine_test_start(t, &initiator, &responder)
	mse_engine_test_deliver(t, &initiator, &responder)
	mse_engine_test_deliver(t, &responder, &initiator)

	request := MSE_Handshake_Take_Outgoing(&initiator)
	defer delete(request)
	request[0] = request[0] ~ 1
	padding: [512]byte
	append(&request, ..padding[:])
	testing.expect_value(t, MSE_Handshake_Feed(&responder, request[:]), MSE_Handshake_Error.Bad_Request_Hash)
}

@(test)
mse_engine_rejects_bad_vc_and_crypto_selection_test :: proc(t: ^testing.T) {
	initiator, responder: MSE_Handshake_Engine
	defer MSE_Handshake_Destroy(&initiator)
	defer MSE_Handshake_Destroy(&responder)
	mse_engine_test_start(t, &initiator, &responder)
	mse_engine_test_deliver(t, &initiator, &responder)
	mse_engine_test_deliver(t, &responder, &initiator)
	mse_engine_test_deliver(t, &initiator, &responder)
	response := MSE_Handshake_Take_Outgoing(&responder)
	response[0] = response[0] ~ 1
	testing.expect_value(t, MSE_Handshake_Feed(&initiator, response[:]), MSE_Handshake_Error.Bad_Verification_Constant)
	delete(response)

	MSE_Handshake_Destroy(&initiator)
	MSE_Handshake_Destroy(&responder)
	mse_engine_test_start(t, &initiator, &responder)
	mse_engine_test_deliver(t, &initiator, &responder)
	mse_engine_test_deliver(t, &responder, &initiator)
	mse_engine_test_deliver(t, &initiator, &responder)
	response = MSE_Handshake_Take_Outgoing(&responder)
	defer delete(response)
	response[11] = response[11] ~ 1 // RC4 (2) becomes invalid bit-set selection (3).
	testing.expect_value(t, MSE_Handshake_Feed(&initiator, response[:]), MSE_Handshake_Error.Bad_Crypto_Selection)
}

@(test)
mse_engine_rejects_received_oversized_pad_test :: proc(t: ^testing.T) {
	initiator, responder: MSE_Handshake_Engine
	defer MSE_Handshake_Destroy(&initiator)
	defer MSE_Handshake_Destroy(&responder)
	mse_engine_test_start(t, &initiator, &responder)
	mse_engine_test_deliver(t, &initiator, &responder)
	mse_engine_test_deliver(t, &responder, &initiator)
	request := MSE_Handshake_Take_Outgoing(&initiator)
	defer delete(request)
	// PadC begins at byte 40 (after req1 and req2 xor req3); its encoded
	// length is initially 2 and is changed to 513 without desynchronizing RC4.
	request[52] = request[52] ~ 2
	request[53] = request[53] ~ 3
	testing.expect_value(t, MSE_Handshake_Feed(&responder, request[:]), MSE_Handshake_Error.Bad_Pad)
}

@(test)
mse_engine_rejects_oversized_pad_and_supports_disabled_test :: proc(t: ^testing.T) {
	info_hash := mse_engine_test_info_hash()
	private := mse_engine_test_private(1)
	oversized: [513]byte
	engine: MSE_Handshake_Engine
	defer MSE_Handshake_Destroy(&engine)
	testing.expect_value(t, MSE_Handshake_Initiator_Init(&engine, .Preferred, info_hash, private, oversized[:], nil), MSE_Handshake_Error.Bad_Pad)

	initiator, responder: MSE_Handshake_Engine
	defer MSE_Handshake_Destroy(&initiator)
	defer MSE_Handshake_Destroy(&responder)
	testing.expect_value(t, MSE_Handshake_Initiator_Init(&initiator, .Disabled, info_hash, private, nil, []byte{'p', 'l', 'a', 'i', 'n'}), MSE_Handshake_Error.None)
	testing.expect_value(t, MSE_Handshake_Responder_Init(&responder, .Disabled, info_hash, mse_engine_test_private(0x61), nil), MSE_Handshake_Error.None)
	mse_engine_test_deliver(t, &initiator, &responder)
	plain := MSE_Handshake_Take_Payload(&responder)
	defer delete(plain)
	testing.expect(t, bytes_equal(plain[:], []byte{'p', 'l', 'a', 'i', 'n'}))
}
