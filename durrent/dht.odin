package durrent

import endian "core:encoding/endian"
import "core:crypto/hash"
import "core:net"
import "core:os"
import "core:sync"
import "core:time"

DHT_Node_ID :: [20]byte

DHT_Endpoint :: struct {
	IP:   [16]byte,
	Port: u16,
	IPv6: bool,
}

DHT_Node :: struct {
	ID:         DHT_Node_ID,
	Endpoint:   DHT_Endpoint,
	Last_Seen:  time.Time,
}

DHT_Query :: enum {
	None,
	Get_Peers,
	Announce_Peer,
}

DHT_Message_Kind :: enum {
	Unknown,
	Query,
	Response,
	Error,
}

DHT_Message :: struct {
	Kind:          DHT_Message_Kind,
	Query:         DHT_Query,
	Transaction:   []byte,
	Sender:        DHT_Node_ID,
	Info_Hash:     Torrent_Hash,
	Has_Info_Hash: bool,
	Nodes:         [dynamic]DHT_Node,
	Peers:         [dynamic]DHT_Endpoint,
	Token:         []byte,
	Port:          u16,
	Implied_Port:  bool,
	Error_Code:    i64,
	Error_Message: []byte,
}

DHT_Error :: enum {
	None,
	Invalid_DHT,
	Private_Torrent,
	Invalid_Message,
	Invalid_Node,
	Invalid_Token,
	Resolve,
	Socket,
	Send,
	Receive,
	Timeout,
	Transaction_Mismatch,
	Tracker_Error,
	Out_Of_Memory,
	Persistence,
}

Destroy_DHT_Message :: proc(message: ^DHT_Message) {
	if message == nil {
		return
	}
	delete(message.Transaction)
	delete(message.Nodes)
	delete(message.Peers)
	delete(message.Token)
	delete(message.Error_Message)
	message^ = DHT_Message{}
}

DHT_Encode_Get_Peers :: proc(transaction: []byte, node_id: DHT_Node_ID, info_hash: Torrent_Hash) -> []byte {
	output: [dynamic]byte
	id := node_id
	hash_value := info_hash
	append(&output, "d1:ad2:id20:")
	append(&output, ..id[:])
	append(&output, "9:info_hash20:")
	append(&output, ..hash_value[:])
	append(&output, "e1:q9:get_peers1:t")
	dht_append_bytes(&output, transaction)
	append(&output, "1:y1:qe")
	return output[:]
}

DHT_Encode_Announce_Peer :: proc(
	transaction: []byte,
	node_id: DHT_Node_ID,
	info_hash: Torrent_Hash,
	token: []byte,
	port: u16,
) -> []byte {
	output: [dynamic]byte
	id := node_id
	hash_value := info_hash
	append(&output, 'd', '1', ':', 'a', 'd', '2', ':', 'i', 'd', '2', '0', ':')
	append(&output, ..id[:])
	append(&output, "9:info_hash20:")
	append(&output, ..hash_value[:])
	append(&output, "4:porti")
	dht_append_unsigned(&output, u32(port))
	append(&output, 'e')
	append(&output, "5:token")
	dht_append_bytes(&output, token)
	append(&output, "e1:q13:announce_peer1:t")
	dht_append_bytes(&output, transaction)
	append(&output, "1:y1:qe")
	return output[:]
}

DHT_Parse_Message :: proc(data: []byte) -> (DHT_Message, DHT_Error) {
	root, decode_error := Bencode_Decode_Default(data)
	if decode_error != .None || root.Kind != .Dictionary {
		return DHT_Message{}, .Invalid_Message
	}
	defer Destroy_Bencode_Value(&root)
	transaction_value := Bencode_Dictionary_Get(&root, "t")
	transaction, transaction_ok := Bencode_As_String(transaction_value)
	if !transaction_ok || len(transaction) == 0 || len(transaction) > 32 {
		return DHT_Message{}, .Invalid_Message
	}
	result: DHT_Message
	transaction_copy, transaction_copy_ok := torrent_clone(transaction)
	if !transaction_copy_ok {
		return DHT_Message{}, .Out_Of_Memory
	}
	result.Transaction = transaction_copy
	type_value, type_ok := Bencode_As_String(Bencode_Dictionary_Get(&root, "y"))
	if !type_ok || len(type_value) != 1 {
		Destroy_DHT_Message(&result)
		return DHT_Message{}, .Invalid_Message
	}
	switch type_value[0] {
	case 'q':
		result.Kind = .Query
		error := dht_parse_query(&result, &root)
		if error != .None {
			Destroy_DHT_Message(&result)
			return DHT_Message{}, error
		}
	case 'r':
		result.Kind = .Response
		error := dht_parse_response(&result, &root)
		if error != .None {
			Destroy_DHT_Message(&result)
			return DHT_Message{}, error
		}
	case 'e':
		result.Kind = .Error
		error := dht_parse_error(&result, &root)
		if error != .None {
			Destroy_DHT_Message(&result)
			return DHT_Message{}, error
		}
	case:
		Destroy_DHT_Message(&result)
		return DHT_Message{}, .Invalid_Message
	}
	return result, .None
}

DHT_Routing_Bucket :: struct {
	Nodes: [dynamic]DHT_Node,
}

DHT_Routing_Table :: struct {
	Mutex:       sync.Mutex,
	Local_ID:    DHT_Node_ID,
	Buckets:     [dynamic]DHT_Routing_Bucket,
	Bucket_Size: u32,
	Expiry:      time.Duration,
}

DHT_Routing_Init :: proc(table: ^DHT_Routing_Table, local_id: DHT_Node_ID) -> DHT_Error {
	if table == nil {
		return .Invalid_DHT
	}
	DHT_Routing_Destroy(table)
	buckets, alloc_error := make([dynamic]DHT_Routing_Bucket, 160, context.allocator)
	if alloc_error != nil {
		return .Out_Of_Memory
	}
	table.Local_ID = local_id
	table.Buckets = buckets
	table.Bucket_Size = 8
	table.Expiry = 15 * time.Minute
	return .None
}

DHT_Routing_Destroy :: proc(table: ^DHT_Routing_Table) {
	if table == nil {
		return
	}
	sync.mutex_lock(&table.Mutex)
	for &bucket in table.Buckets {
		delete(bucket.Nodes)
	}
	delete(table.Buckets)
	table.Buckets = nil
	table.Bucket_Size = 0
	sync.mutex_unlock(&table.Mutex)
}

DHT_Routing_Add_Node :: proc(table: ^DHT_Routing_Table, node: DHT_Node) -> DHT_Error {
	if table == nil || len(table.Buckets) != 160 || node.ID == table.Local_ID || node.Endpoint.Port == 0 {
		return .Invalid_Node
	}
	bucket_index := dht_bucket_index(table.Local_ID, node.ID)
	now := time.now()
	if bucket_index < 0 {
		return .Invalid_Node
	}
	sync.mutex_lock(&table.Mutex)
	defer sync.mutex_unlock(&table.Mutex)
	bucket := &table.Buckets[bucket_index]
	for &existing in bucket.Nodes {
		if existing.ID == node.ID {
			existing.Endpoint = node.Endpoint
			existing.Last_Seen = now
			return .None
		}
	}
	if len(bucket.Nodes) >= int(table.Bucket_Size) {
		oldest := 0
		for index := 1; index < len(bucket.Nodes); index += 1 {
			if time.diff(bucket.Nodes[index].Last_Seen, bucket.Nodes[oldest].Last_Seen) < 0 {
				oldest = index
			}
		}
		copy(bucket.Nodes[oldest:], bucket.Nodes[oldest+1:])
		resize(&bucket.Nodes, len(bucket.Nodes)-1)
	}
	stored := node
	stored.Last_Seen = time.now()
	append(&bucket.Nodes, stored)
	return .None
}

DHT_Routing_Expire :: proc(table: ^DHT_Routing_Table) -> u32 {
	if table == nil {
		return 0
	}
	now := time.now()
	sync.mutex_lock(&table.Mutex)
	defer sync.mutex_unlock(&table.Mutex)
	removed: u32
	for &bucket in table.Buckets {
		index := 0
		for index < len(bucket.Nodes) {
			if time.diff(bucket.Nodes[index].Last_Seen, now) < table.Expiry {
				index += 1
				continue
			}
			copy(bucket.Nodes[index:], bucket.Nodes[index+1:])
			resize(&bucket.Nodes, len(bucket.Nodes)-1)
			removed += 1
		}
	}
	return removed
}

DHT_Routing_Closest :: proc(table: ^DHT_Routing_Table, target: DHT_Node_ID, limit := 8) -> [dynamic]DHT_Node {
	result: [dynamic]DHT_Node
	if table == nil || limit <= 0 {
		return result
	}
	sync.mutex_lock(&table.Mutex)
	defer sync.mutex_unlock(&table.Mutex)
	for bucket in table.Buckets {
		for node in bucket.Nodes {
			append(&result, node)
		}
	}
	for i := 0; i < len(result); i += 1 {
		best := i
		for j := i + 1; j < len(result); j += 1 {
			if dht_id_less(result[j].ID, result[best].ID, target) {
				best = j
			}
		}
		if best != i {
			temp := result[i]
			result[i] = result[best]
			result[best] = temp
		}
	}
	if len(result) > limit {
		resize(&result, limit)
	}
	return result
}

DHT_Routing_Save :: proc(table: ^DHT_Routing_Table, path: string) -> DHT_Error {
	if table == nil || len(path) == 0 {
		return .Persistence
	}
	sync.mutex_lock(&table.Mutex)
	data: [dynamic]byte
	append(&data, "DHTR1")
	append(&data, ..table.Local_ID[:])
	count: u32
	for bucket in table.Buckets {
		count += u32(len(bucket.Nodes))
	}
	buffer: [4]byte
	endian.put_u32(buffer[:], .Big, count)
	append(&data, ..buffer[:])
	for bucket in table.Buckets {
		for node in bucket.Nodes {
			id := node.ID
			ip := node.Endpoint.IP
			append(&data, ..id[:])
			append(&data, byte(1) if node.Endpoint.IPv6 else byte(0))
			append(&data, ..ip[:])
			endian.put_u16(buffer[:2], .Big, node.Endpoint.Port)
			append(&data, ..buffer[:2])
		}
	}
	sync.mutex_unlock(&table.Mutex)
	write_error := os.write_entire_file(path, data[:])
	delete(data)
	return .None if write_error == nil else .Persistence
}

DHT_Routing_Load :: proc(table: ^DHT_Routing_Table, path: string) -> DHT_Error {
	if table == nil || len(path) == 0 {
		return .Persistence
	}
	data, read_error := os.read_entire_file_from_path(path, context.allocator)
	if read_error != nil {
		return .Persistence
	}
	defer delete(data)
	if len(data) < 29 || !bytes_equal(data[:5], []byte{'D', 'H', 'T', 'R', '1'}) {
		return .Persistence
	}
	count, count_ok := endian.get_u32(data[25:29], .Big)
	if !count_ok || u64(count)*39 > u64(len(data)-29) {
		return .Persistence
	}
	position := 29
	for i: u32 = 0; i < count; i += 1 {
		if position+39 > len(data) {
			return .Persistence
		}
		node: DHT_Node
		copy(node.ID[:], data[position:position+20])
		node.Endpoint.IPv6 = data[position+20] != 0
		copy(node.Endpoint.IP[:], data[position+21:position+37])
		node.Endpoint.Port, _ = endian.get_u16(data[position+37:position+39], .Big)
		if DHT_Routing_Add_Node(table, node) != .None {
			return .Invalid_Node
		}
		position += 39
	}
	return .None
}
