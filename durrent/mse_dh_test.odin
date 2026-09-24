package durrent

import "core:testing"

@(test)
mse_dh_public_shared_secret_test :: proc(t: ^testing.T) {
	alice_private: [MSE_DH_Private_Length]byte
	bob_private: [MSE_DH_Private_Length]byte
	for index := 0; index < MSE_DH_Private_Length; index += 1 {
		alice_private[index] = byte(index + 1)
		bob_private[index] = byte(0xa0 + index)
	}
	alice_public := MSE_DH_Public(alice_private)
	bob_public := MSE_DH_Public(bob_private)
	alice_shared, alice_ok := MSE_DH_Shared(alice_private, bob_public)
	bob_shared, bob_ok := MSE_DH_Shared(bob_private, alice_public)
	testing.expect(t, alice_ok)
	testing.expect(t, bob_ok)
	testing.expect(t, bytes_equal(alice_shared[:], bob_shared[:]))
	zero: [MSE_DH_Public_Length]byte
	testing.expect(t, !bytes_equal(alice_shared[:], zero[:]))
}

@(test)
mse_dh_rejects_zero_and_prime_test :: proc(t: ^testing.T) {
	zero: [MSE_DH_Public_Length]byte
	_, zero_ok := MSE_DH_Decode(zero)
	testing.expect(t, !zero_ok)
	prime := MSE_DH_Encode(MSE_DH_Prime)
	_, prime_ok := MSE_DH_Decode(prime)
	testing.expect(t, !prime_ok)
}
