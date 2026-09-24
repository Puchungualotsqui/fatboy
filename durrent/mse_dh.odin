package durrent

// MSE uses the historical 768-bit MODP group, encoded as exactly 96 bytes.
// This deliberately fixed-size representation avoids a general-purpose bigint
// dependency in the torrent hot path.
MSE_DH_Word_Count :: 12
MSE_DH_Public_Length :: 96
MSE_DH_Private_Length :: 20

MSE_DH_Number :: struct {
	// Little-endian 64-bit words.
	Words: [MSE_DH_Word_Count]u64,
}

MSE_DH_Prime :: MSE_DH_Number{Words = {
	0xffffffffffffffff,
	0xf44c42e9a63a3620,
	0xe485b576625e7ec6,
	0x4fe1356d6d51c245,
	0x302b0a6df25f1437,
	0xef9519b3cd3a431b,
	0x514a08798e3404dd,
	0x020bbea63b139b22,
	0x29024e088a67cc74,
	0xc4c6628b80dc1cd1,
	0xc90fdaa22168c234,
	0xffffffffffffffff,
}}

MSE_DH_Public :: proc(private: [MSE_DH_Private_Length]byte) -> [MSE_DH_Public_Length]byte {
	base: MSE_DH_Number
	base.Words[0] = 2
	return MSE_DH_Encode(mse_dh_pow(base, private))
}

MSE_DH_Shared :: proc(private: [MSE_DH_Private_Length]byte, remote_public: [MSE_DH_Public_Length]byte) -> ([MSE_DH_Public_Length]byte, bool) {
	remote, valid := MSE_DH_Decode(remote_public)
	if !valid {
		return [MSE_DH_Public_Length]byte{}, false
	}
	return MSE_DH_Encode(mse_dh_pow(remote, private)), true
}

MSE_DH_Encode :: proc(value: MSE_DH_Number) -> [MSE_DH_Public_Length]byte {
	result: [MSE_DH_Public_Length]byte
	for word_index := 0; word_index < MSE_DH_Word_Count; word_index += 1 {
		word := value.Words[MSE_DH_Word_Count-1-word_index]
		for byte_index := 0; byte_index < 8; byte_index += 1 {
			shift := u64(56 - byte_index*8)
			result[word_index*8+byte_index] = byte(word >> shift)
		}
	}
	return result
}

MSE_DH_Decode :: proc(encoded: [MSE_DH_Public_Length]byte) -> (MSE_DH_Number, bool) {
	result: MSE_DH_Number
	for word_index := 0; word_index < MSE_DH_Word_Count; word_index += 1 {
		word: u64
		for byte_index := 0; byte_index < 8; byte_index += 1 {
			word = (word << 8) | u64(encoded[word_index*8+byte_index])
		}
		result.Words[MSE_DH_Word_Count-1-word_index] = word
	}
	return result, !mse_dh_zero(result) && mse_dh_compare(result, MSE_DH_Prime) < 0
}

mse_dh_pow :: proc(base: MSE_DH_Number, exponent: [MSE_DH_Private_Length]byte) -> MSE_DH_Number {
	result: MSE_DH_Number
	result.Words[0] = 1
	for value in exponent {
		for bit := 7; bit >= 0; bit -= 1 {
			result = mse_dh_multiply(result, result)
			if value&(byte(1)<<u8(bit)) != 0 {
				result = mse_dh_multiply(result, base)
			}
		}
	}
	return result
}

// Double-and-add is deliberately simple and bounded: multiplication performs
// exactly 768 modular additions. It is only used while establishing a peer
// connection, not while transferring pieces.
mse_dh_multiply :: proc(a, b: MSE_DH_Number) -> MSE_DH_Number {
	result: MSE_DH_Number
	for word_index := MSE_DH_Word_Count - 1; word_index >= 0; word_index -= 1 {
		word := b.Words[word_index]
		for bit := 63; bit >= 0; bit -= 1 {
			result = mse_dh_add_mod(result, result)
			if word&(u64(1)<<u8(bit)) != 0 {
				result = mse_dh_add_mod(result, a)
			}
		}
	}
	return result
}

mse_dh_add_mod :: proc(a, b: MSE_DH_Number) -> MSE_DH_Number {
	result: MSE_DH_Number
	carry := false
	for index := 0; index < MSE_DH_Word_Count; index += 1 {
		first := a.Words[index] + b.Words[index]
		first_carry := first < a.Words[index]
		second := first + u64(1 if carry else 0)
		second_carry := carry && second == 0
		result.Words[index] = second
		carry = first_carry || second_carry
	}
	if carry || mse_dh_compare(result, MSE_DH_Prime) >= 0 {
		return mse_dh_subtract(result, MSE_DH_Prime)
	}
	return result
}

mse_dh_subtract :: proc(a, b: MSE_DH_Number) -> MSE_DH_Number {
	result: MSE_DH_Number
	borrow := false
	for index := 0; index < MSE_DH_Word_Count; index += 1 {
		subtrahend := b.Words[index] + u64(1 if borrow else 0)
		overflow := borrow && subtrahend == 0
		result.Words[index] = a.Words[index] - subtrahend
		borrow = overflow || a.Words[index] < subtrahend
	}
	return result
}

mse_dh_compare :: proc(a, b: MSE_DH_Number) -> int {
	for index := MSE_DH_Word_Count - 1; index >= 0; index -= 1 {
		if a.Words[index] < b.Words[index] {
			return -1
		}
		if a.Words[index] > b.Words[index] {
			return 1
		}
	}
	return 0
}

mse_dh_zero :: proc(value: MSE_DH_Number) -> bool {
	for word in value.Words {
		if word != 0 {
			return false
		}
	}
	return true
}
