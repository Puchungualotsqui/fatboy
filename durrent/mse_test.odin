package durrent

import "core:testing"

@(test)
mse_rc4_known_vector_and_fragmentation_test :: proc(t: ^testing.T) {
	key := []byte{'K', 'e', 'y'}
	expected := []byte{0xeb, 0x9f, 0x77, 0x81, 0xb7, 0x34, 0xca, 0x72, 0xa7, 0x19, 0x4a, 0x28, 0x67, 0xb6, 0x42, 0x95}
	cipher: MSE_RC4
	testing.expect(t, MSE_RC4_Init(&cipher, key))
	actual := []byte{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
	MSE_RC4_Apply(&cipher, actual)
	testing.expect(t, bytes_equal(actual, expected))

	plain := []byte{'f', 'r', 'a', 'g', 'm', 'e', 'n', 't', 'e', 'd', ' ', 'm', 's', 'e'}
	encrypted: [14]byte
	copy(encrypted[:], plain)
	encryptor: MSE_RC4
	decryptor: MSE_RC4
	testing.expect(t, MSE_RC4_Init(&encryptor, key))
	testing.expect(t, MSE_RC4_Init(&decryptor, key))
	MSE_RC4_Apply(&encryptor, encrypted[:5])
	MSE_RC4_Apply(&encryptor, encrypted[5:])
	MSE_RC4_Apply(&decryptor, encrypted[:3])
	MSE_RC4_Apply(&decryptor, encrypted[3:])
	testing.expect(t, bytes_equal(encrypted[:], plain))
}

@(test)
mse_directional_keys_and_rc4_drop_test :: proc(t: ^testing.T) {
	info_hash := Torrent_Hash{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19}
	shared: [96]byte
	for index := 0; index < len(shared); index += 1 {
		shared[index] = byte(index)
	}

	initiator_send, initiator_receive: MSE_RC4
	responder_send, responder_receive: MSE_RC4
	testing.expect(t, MSE_RC4_Directional_Init(&initiator_send, &initiator_receive, .Preferred, true, shared[:], info_hash))
	testing.expect(t, MSE_RC4_Directional_Init(&responder_send, &responder_receive, .Preferred, false, shared[:], info_hash))

	outbound := []byte{'e', 'n', 'c', 'r', 'y', 'p', 't', 'e', 'd'}
	MSE_RC4_Apply(&initiator_send, outbound)
	MSE_RC4_Apply(&responder_receive, outbound)
	testing.expect(t, bytes_equal(outbound, []byte{'e', 'n', 'c', 'r', 'y', 'p', 't', 'e', 'd'}))

	inbound := []byte{'r', 'e', 's', 'p', 'o', 'n', 's', 'e'}
	MSE_RC4_Apply(&responder_send, inbound)
	MSE_RC4_Apply(&initiator_receive, inbound)
	testing.expect(t, bytes_equal(inbound, []byte{'r', 'e', 's', 'p', 'o', 'n', 's', 'e'}))

	disabled_send, disabled_receive: MSE_RC4
	testing.expect(t, !MSE_RC4_Directional_Init(&disabled_send, &disabled_receive, .Disabled, true, shared[:], info_hash))
}

@(test)
mse_protocol_hashes_test :: proc(t: ^testing.T) {
	info_hash := Torrent_Hash{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19}
	shared := []byte{'s', 'h', 'a', 'r', 'e', 'd'}
	request := MSE_Request_Hash(shared)
	request_again := MSE_Request_Hash(shared)
	info_request := MSE_Info_Hash_Request(info_hash)
	key_a := MSE_Key_A(shared, info_hash)
	key_b := MSE_Key_B(shared, info_hash)
	testing.expect(t, bytes_equal(request[:], request_again[:]))
	testing.expect(t, !bytes_equal(request[:], info_request[:]))
	testing.expect(t, !bytes_equal(key_a[:], key_b[:]))
}
