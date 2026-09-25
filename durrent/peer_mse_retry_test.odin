package durrent

import "core:testing"

peer_mse_retry_test_prepare :: proc(session: ^Peer_Session, policy: MSE_Policy) {
	peer_id: [20]byte
	peer_id[0] = '-'
	Peer_Session_Init(session, peer_test_hash, peer_id, 4, 4, 16)
	Peer_Session_Set_MSE_Policy(session, policy)
	private: [MSE_DH_Private_Length]byte
	private[0] = 1
	_ = MSE_Handshake_Initiator_Init(&session.MSE, policy, peer_test_hash, private, nil, nil)
	session.MSE_Negotiating = true
	session.MSE_Inbound = false
	session.State = .Handshaking
}

@(test)
peer_mse_preferred_early_failure_retries_once_as_plaintext_test :: proc(t: ^testing.T) {
	session: Peer_Session
	defer Destroy_Peer_Session(&session)
	peer_mse_retry_test_prepare(&session, .Preferred)
	testing.expect(t, Peer_Session_Can_Retry_Plaintext(&session))
	testing.expect_value(t, Peer_Session_Reset_For_Plaintext_Retry(&session), Peer_Error.None)
	testing.expect_value(t, session.State, Peer_State.New)
	testing.expect_value(t, session.MSE_Policy, MSE_Policy.Disabled)
	testing.expect(t, session.MSE_Plaintext_Retry_Used)
	testing.expect(t, !Peer_Session_Can_Retry_Plaintext(&session))

	// The fresh attempt is normal plaintext PWP and can complete successfully.
	testing.expect_value(t, Peer_Session_Begin(&session), Peer_Error.None)
	outgoing, output_error := Peer_Session_Take_Output(&session)
	testing.expect_value(t, output_error, Peer_Error.None)
	testing.expect_value(t, len(outgoing), Handshake_Length)
	delete(outgoing)
	remote := peer_test_remote_handshake()
	testing.expect_value(t, Peer_Session_Feed(&session, remote[:]), Peer_Error.None)
	testing.expect_value(t, session.State, Peer_State.Ready)
	testing.expect_value(t, Peer_Session_Reset_For_Plaintext_Retry(&session), Peer_Error.Invalid_State)
}

@(test)
peer_mse_required_never_downgrades_and_preferred_retries_incomplete_negotiation_test :: proc(t: ^testing.T) {
	required: Peer_Session
	defer Destroy_Peer_Session(&required)
	peer_mse_retry_test_prepare(&required, .Required)
	testing.expect(t, !Peer_Session_Can_Retry_Plaintext(&required))
	testing.expect_value(t, Peer_Session_Reset_For_Plaintext_Retry(&required), Peer_Error.Invalid_State)

	incomplete: Peer_Session
	defer Destroy_Peer_Session(&incomplete)
	peer_mse_retry_test_prepare(&incomplete, .Preferred)
	// Protocol failures can occur after receiving Yb but before a usable MSE
	// session exists. Preferred retries plaintext once on a fresh connection.
	incomplete.MSE.State = .Await_Response
	testing.expect(t, Peer_Session_Can_Retry_Plaintext(&incomplete))
	testing.expect_value(t, Peer_Session_Reset_For_Plaintext_Retry(&incomplete), Peer_Error.None)

	negotiated: Peer_Session
	defer Destroy_Peer_Session(&negotiated)
	peer_mse_retry_test_prepare(&negotiated, .Preferred)
	negotiated.MSE.State = .Complete
	negotiated.MSE_Negotiating = false
	negotiated.MSE_Active = true
	testing.expect(t, !Peer_Session_Can_Retry_Plaintext(&negotiated))
	testing.expect_value(t, Peer_Session_Reset_For_Plaintext_Retry(&negotiated), Peer_Error.Invalid_State)
}
