package durrent

peer_session_local_handshake :: proc(session: ^Peer_Session) -> [Handshake_Length]byte {
	handshake := Wire_Handshake{Info_Hash = session.Expected_Info_Hash, Peer_ID = session.Local_Peer_ID}
	handshake.Reserved[5] = 0x10
	return Wire_Handshake_Serialize(handshake)
}

peer_session_begin_plain_locked :: proc(session: ^Peer_Session) -> Peer_Error {
	encoded := peer_session_local_handshake(session)
	append(&session.Outgoing, ..encoded[:])
	session.State = .Handshaking
	return .None
}

peer_session_begin_outbound_locked :: proc(session: ^Peer_Session) -> Peer_Error {
	if session.MSE_Policy == .Disabled {
		return peer_session_begin_plain_locked(session)
	}
	private, random_ok := MSE_DH_Private_Generate()
	if !random_ok {
		return peer_session_fail_locked(session, .Protocol)
	}
	initial := peer_session_local_handshake(session)
	if MSE_Handshake_Initiator_Init(&session.MSE, session.MSE_Policy, session.Expected_Info_Hash, private, nil, initial[:]) != .None {
		return peer_session_fail_locked(session, .Protocol)
	}
	session.MSE_Negotiating = true
	session.MSE_Inbound = false
	session.State = .Handshaking
	peer_session_mse_drain_outgoing_locked(session)
	return .None
}

peer_session_begin_inbound_locked :: proc(session: ^Peer_Session) -> Peer_Error {
	session.State = .Handshaking
	if session.MSE_Policy == .Disabled {
		return peer_session_begin_plain_locked(session)
	}
	// Preferred waits for the first peer bytes so it can accept an ordinary PWP
	// handshake. Required starts the responder immediately and rejects PWP.
	session.MSE_Inbound = true
	if session.MSE_Policy == .Required {
		return peer_session_mse_start_responder_locked(session)
	}
	return .None
}

peer_session_mse_start_responder_locked :: proc(session: ^Peer_Session) -> Peer_Error {
	private, random_ok := MSE_DH_Private_Generate()
	if !random_ok || MSE_Handshake_Responder_Init(&session.MSE, session.MSE_Policy, session.Expected_Info_Hash, private, nil) != .None {
		return peer_session_fail_locked(session, .Protocol)
	}
	session.MSE_Negotiating = true
	return .None
}

peer_session_mse_drain_outgoing_locked :: proc(session: ^Peer_Session) {
	outgoing := MSE_Handshake_Take_Outgoing(&session.MSE)
	defer delete(outgoing)
	append(&session.Outgoing, ..outgoing[:])
}

peer_session_mse_finish_locked :: proc(session: ^Peer_Session) -> Peer_Error {
	if !MSE_Handshake_Complete(&session.MSE) {
		return .None
	}
	session.MSE_Negotiating = false
	session.MSE_Active = session.MSE.Encryption == MSE_Encryption_RC4
	if session.MSE_Inbound {
		encoded := peer_session_local_handshake(session)
		if MSE_Handshake_Queue_Payload(&session.MSE, encoded[:]) != .None {
			return peer_session_fail_locked(session, .Protocol)
		}
		peer_session_mse_drain_outgoing_locked(session)
	}
	payload := MSE_Handshake_Take_Payload(&session.MSE)
	defer delete(payload)
	if len(payload) > 0 {
		append(&session.Receive_Buffer, ..payload[:])
	}
	return peer_session_process_locked(session)
}
