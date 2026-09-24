package durrent

import "core:crypto/hash"

// MSE/PE is negotiated before the ordinary BitTorrent handshake. Keep the
// crypto primitives independent from sockets so the eventual streaming state
// machine can be exercised deterministically.
MSE_Policy :: enum {
	Disabled,
	Preferred,
	Required,
}

MSE_Encryption_Plaintext :: u32(1)
MSE_Encryption_RC4 :: u32(2)
MSE_Verification_Constant :: [8]byte{}

MSE_RC4 :: struct {
	S: [256]byte,
	I: byte,
	J: byte,
}

MSE_RC4_Init :: proc(cipher: ^MSE_RC4, key: []byte) -> bool {
	if cipher == nil || len(key) == 0 || len(key) > 256 {
		return false
	}
	cipher^ = MSE_RC4{}
	for index := 0; index < 256; index += 1 {
		cipher.S[index] = byte(index)
	}
	j := 0
	for index := 0; index < 256; index += 1 {
		j = (j + int(cipher.S[index]) + int(key[index%len(key)])) & 0xff
		cipher.S[index], cipher.S[j] = cipher.S[j], cipher.S[index]
	}
	return true
}

// MSE requires discarding the first 1,024 RC4 output bytes after key setup.
MSE_RC4_Drop :: proc(cipher: ^MSE_RC4, count: int) {
	if cipher == nil || count <= 0 {
		return
	}
	for index := 0; index < count; index += 1 {
		_ = mse_rc4_next(cipher)
	}
}

// Applies the RC4 keystream in place. It is intentionally safe for fragmented
// socket reads and writes: callers apply it exactly once to each new byte.
MSE_RC4_Apply :: proc(cipher: ^MSE_RC4, data: []byte) {
	if cipher == nil {
		return
	}
	for index := 0; index < len(data); index += 1 {
		data[index] = data[index] ~ mse_rc4_next(cipher)
	}
}

mse_rc4_next :: proc(cipher: ^MSE_RC4) -> byte {
	cipher.I += 1
	cipher.J += cipher.S[cipher.I]
	cipher.S[cipher.I], cipher.S[cipher.J] = cipher.S[cipher.J], cipher.S[cipher.I]
	return cipher.S[byte(int(cipher.S[cipher.I])+int(cipher.S[cipher.J]))]
}

// The MSE SHA-1 labels are part of the interoperable Azureus/Vuze protocol.
MSE_Request_Hash :: proc(shared_secret: []byte) -> [20]byte {
	return mse_sha1("req1", shared_secret, nil)
}

MSE_Info_Hash_Request :: proc(info_hash: Torrent_Hash) -> [20]byte {
	hash_copy := info_hash
	return mse_sha1("req2", hash_copy[:], nil)
}

MSE_Key_A :: proc(shared_secret: []byte, info_hash: Torrent_Hash) -> [20]byte {
	hash_copy := info_hash
	return mse_sha1("keyA", shared_secret, hash_copy[:])
}

MSE_Key_B :: proc(shared_secret: []byte, info_hash: Torrent_Hash) -> [20]byte {
	hash_copy := info_hash
	return mse_sha1("keyB", shared_secret, hash_copy[:])
}

// Configures the directional ciphers after Diffie-Hellman has produced the
// shared secret. The initiator sends with keyA and receives with keyB; the
// responder uses the inverse direction.
MSE_RC4_Directional_Init :: proc(
	send_cipher, receive_cipher: ^MSE_RC4,
	policy: MSE_Policy,
	initiator: bool,
	shared_secret: []byte,
	info_hash: Torrent_Hash,
) -> bool {
	if send_cipher == nil || receive_cipher == nil || policy == .Disabled || len(shared_secret) == 0 {
		return false
	}
	key_a := MSE_Key_A(shared_secret, info_hash)
	key_b := MSE_Key_B(shared_secret, info_hash)
	send_key := key_a[:] if initiator else key_b[:]
	receive_key := key_b[:] if initiator else key_a[:]
	if !MSE_RC4_Init(send_cipher, send_key) || !MSE_RC4_Init(receive_cipher, receive_key) {
		return false
	}
	MSE_RC4_Drop(send_cipher, 1024)
	MSE_RC4_Drop(receive_cipher, 1024)
	return true
}

mse_sha1 :: proc(label: string, first, second: []byte) -> [20]byte {
	input: [dynamic]byte
	defer delete(input)
	append(&input, ..transmute([]byte)label)
	append(&input, ..first)
	append(&input, ..second)
	result: [20]byte
	hash.hash_bytes_to_buffer(hash.Algorithm.Insecure_SHA1, input[:], result[:])
	return result
}
