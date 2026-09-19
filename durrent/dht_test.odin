package durrent

import endian "core:encoding/endian"

import "core:os"
import "core:path/filepath"

import "core:testing"
import "core:time"

dht_test_id :: proc(first: byte) -> DHT_Node_ID {
	result: DHT_Node_ID
	result[0] = first
	return result
}

@(test)
dht_krpc_query_and_response_test :: proc(t: ^testing.T) {
	node_id := dht_test_id(1)
	info_hash := Torrent_Hash{}
	info_hash[0] = 0xaa
	transaction := []byte{'a', 'b'}
	query := DHT_Encode_Get_Peers(transaction, node_id, info_hash)
	message, parse_error := DHT_Parse_Message(query)
	delete(query)
	testing.expect_value(t, parse_error, DHT_Error.None)
	testing.expect_value(t, message.Kind, DHT_Message_Kind.Query)
	testing.expect_value(t, message.Query, DHT_Query.Get_Peers)
	testing.expect(t, message.Sender == node_id && message.Info_Hash == info_hash)
	Destroy_DHT_Message(&message)

	token := []byte{'t', 'o', 'k'}
	announce := DHT_Encode_Announce_Peer(transaction, node_id, info_hash, token, 6881)

	message, parse_error = DHT_Parse_Message(announce)
	delete(announce)
	testing.expect_value(t, parse_error, DHT_Error.None)
	testing.expect_value(t, message.Query, DHT_Query.Announce_Peer)
	testing.expect_value(t, message.Port, u16(6881))
	Destroy_DHT_Message(&message)

	response: [dynamic]byte
	append(&response, "d1:rd2:id20:")
	append(&response, ..node_id[:])
	append(&response, "5:token3:tok6:valuesl6:")
	append(&response, byte(127), byte(0), byte(0), byte(1))
	port: [2]byte
	endian.put_u16(port[:], .Big, 6881)
	append(&response, ..port[:])
	append(&response, "ee1:t2:ab1:y1:re")

	message, parse_error = DHT_Parse_Message(response[:])
	delete(response)
	testing.expect_value(t, parse_error, DHT_Error.None)
	testing.expect_value(t, message.Kind, DHT_Message_Kind.Response)
	testing.expect_value(t, len(message.Peers), 1)
	testing.expect_value(t, message.Peers[0].Port, u16(6881))
	testing.expect(t, bytes_equal(message.Token, []byte{'t', 'o', 'k'}))
	Destroy_DHT_Message(&message)
}

@(test)
dht_routing_token_and_persistence_test :: proc(t: ^testing.T) {
	local_id := dht_test_id(0)
	node: DHT_Node
	node.ID = dht_test_id(1)
	node.Endpoint.IP[0] = 127
	node.Endpoint.IP[3] = 1
	node.Endpoint.Port = 6881
	table: DHT_Routing_Table
	defer DHT_Routing_Destroy(&table)
	testing.expect_value(t, DHT_Routing_Init(&table, local_id), DHT_Error.None)
	testing.expect_value(t, DHT_Routing_Add_Node(&table, node), DHT_Error.None)
	closest := DHT_Routing_Closest(&table, node.ID, 1)
	testing.expect_value(t, len(closest), 1)
	delete(closest)

	secret: [20]byte
	secret[0] = 3
	token := DHT_Token_Make(secret, node.Endpoint)
	testing.expect(t, DHT_Token_Validate(secret, [20]byte{}, node.Endpoint, token[:]))
	testing.expect(t, !DHT_Token_Validate([20]byte{}, [20]byte{}, node.Endpoint, token[:]))

	base, base_error := os.make_directory_temp("", "durrent-dht-*", context.allocator)
	testing.expect_value(t, base_error, nil)
	defer os.remove_all(base)
	defer delete(base)
	path, path_error := filepath.join({base, "routing.bin"}, context.allocator)
	testing.expect_value(t, path_error, nil)
	defer delete(path)
	testing.expect_value(t, DHT_Routing_Save(&table, path), DHT_Error.None)
	loaded: DHT_Routing_Table
	defer DHT_Routing_Destroy(&loaded)
	testing.expect_value(t, DHT_Routing_Init(&loaded, local_id), DHT_Error.None)
	testing.expect_value(t, DHT_Routing_Load(&loaded, path), DHT_Error.None)
	closest = DHT_Routing_Closest(&loaded, node.ID, 1)
	testing.expect_value(t, len(closest), 1)
	delete(closest)

	for &bucket in loaded.Buckets {
		if len(bucket.Nodes) > 0 {
			bucket.Nodes[0].Last_Seen = time.time_add(time.now(), -20*time.Minute)
			break
		}
	}
	testing.expect_value(t, DHT_Routing_Expire(&loaded), u32(1))
}

@(test)
dht_private_torrent_gate_test :: proc(t: ^testing.T) {
	private_torrent: Torrent
	private_torrent.Private = true
	client: DHT_Client
	testing.expect_value(t, DHT_Client_Init(&client, &private_torrent, dht_test_id(2), 0), DHT_Error.Private_Torrent)
	testing.expect(t, !Torrent_Allows_DHT(&private_torrent))
	testing.expect(t, !Torrent_Allows_Peer_Exchange(&private_torrent))

	data: [dynamic]byte
	append(&data, "d4:infod6:lengthi1e4:name1:x12:piece lengthi1e6:pieces20:")
	for i := 0; i < 20; i += 1 {
		append(&data, byte(0))
	}
	append(&data, "7:privatei1eee")
	torrent, parse_error := Parse_Torrent(data[:])
	delete(data)
	testing.expect_value(t, parse_error, Torrent_Error.None)
	testing.expect(t, torrent.Private && torrent.Has_Private)
	Destroy_Torrent(&torrent)
}
