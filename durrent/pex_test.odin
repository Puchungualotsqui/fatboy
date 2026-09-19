package durrent

import "core:testing"

@(test)
pex_handshake_and_compact_peers_test :: proc(t: ^testing.T) {
	handshake := PEX_Encode_Extension_Handshake()
	id, handshake_error := PEX_Parse_Extension_Handshake(handshake)
	delete(handshake)
	testing.expect_value(t, handshake_error, PEX_Error.None)
	testing.expect_value(t, id, byte(2))

	added: [2]PEX_Peer
	added[0].IP[0] = 127
	added[0].IP[3] = 1
	added[0].Port = 6881
	added[1].IPv6 = true
	added[1].IP[0] = 0x20
	added[1].IP[1] = 0x01
	added[1].IP[2] = 0x0d
	added[1].IP[3] = 0xb8
	added[1].IP[15] = 1
	added[1].Port = 6882
	dropped: [1]PEX_Peer
	dropped[0].IP[0] = 10
	dropped[0].Port = 6883
	payload := PEX_Encode_Message(added[:], dropped[:])
	message, parse_error := PEX_Parse_Message(payload)
	delete(payload)
	testing.expect_value(t, parse_error, PEX_Error.None)
	testing.expect_value(t, len(message.Added), 2)
	testing.expect_value(t, len(message.Dropped), 1)
	testing.expect(t, message.Added[1].IPv6)
	testing.expect_value(t, message.Added[1].IP[15], byte(1))
	testing.expect_value(t, message.Added[1].Port, u16(6882))
	Destroy_PEX_Message(&message)
}

@(test)
pex_ipv6_address_format_test :: proc(t: ^testing.T) {
	peer: PEX_Peer
	peer.IPv6 = true
	peer.IP[0] = 0x20
	peer.IP[1] = 0x01
	peer.IP[2] = 0x0d
	peer.IP[3] = 0xb8
	peer.IP[15] = 1
	peer.Port = 6881
	address := PEX_Peer_Address(peer)
	defer delete(address)
	testing.expect_value(t, address, "[2001:db8:0:0:0:0:0:1]:6881")
}
