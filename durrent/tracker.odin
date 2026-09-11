package durrent

Tracker_Peer :: struct {
	IP:   [4]byte,
	Port: u16,
}

Tracker_Event :: enum {
	None,
	Started,
	Completed,
	Stopped,
}

Tracker_Announce_Request :: struct {
	Info_Hash:  Torrent_Hash,
	Peer_ID:    [20]byte,
	Port:       u16,
	Uploaded:   u64,
	Downloaded: u64,
	Left:       u64,
	Compact:    bool,
	Event:      Tracker_Event,
}

Tracker_Announce_Response :: struct {
	Interval:       u64,
	Min_Interval:   u64,
	Has_Min_Interval: bool,
	Complete:       u64,
	Has_Complete:   bool,
	Incomplete:     u64,
	Has_Incomplete: bool,
	Peers:          [dynamic]Tracker_Peer,
	Failure_Reason: []byte,
	Warning_Message: []byte,
}

Tracker_Error :: enum {
	None,
	Invalid_Response,
	Invalid_Peer,
	Tracker_Failure,
	Out_Of_Memory,
}

Destroy_Tracker_Response :: proc(response: ^Tracker_Announce_Response) {
	if response == nil {
		return
	}
	delete(response.Peers)
	delete(response.Failure_Reason)
	delete(response.Warning_Message)
	response^ = Tracker_Announce_Response{}
}

Tracker_Event_Name :: proc(event: Tracker_Event) -> (string, bool) {
	switch event {
	case .Started:
		return "started", true
	case .Completed:
		return "completed", true
	case .Stopped:
		return "stopped", true
	case .None:
		return "", false
	}
	return "", false
}

// Tracker_Build_Announce_URL creates a BEP 3 query string. Info hashes and
// peer IDs are percent-encoded as raw bytes; the caller owns the returned URL.
Tracker_Build_Announce_URL :: proc(base_url: string, request: Tracker_Announce_Request) -> ([]byte, Tracker_Error) {
	output: [dynamic]byte
	append(&output, base_url)
	separator := byte('?')
	for c in base_url {
		if c == '?' {
			separator = '&'
			break
		}
	}
	append(&output, separator)
	tracker_append_string(&output, "info_hash=")
	info_hash := request.Info_Hash
	tracker_append_percent_encoded(&output, info_hash[:])
	tracker_append_string(&output, "&peer_id=")
	peer_id := request.Peer_ID
	tracker_append_percent_encoded(&output, peer_id[:])
	tracker_append_string(&output, "&port=")
	bencode_append_unsigned(&output, u64(request.Port))
	tracker_append_string(&output, "&uploaded=")
	bencode_append_unsigned(&output, request.Uploaded)
	tracker_append_string(&output, "&downloaded=")
	bencode_append_unsigned(&output, request.Downloaded)
	tracker_append_string(&output, "&left=")
	bencode_append_unsigned(&output, request.Left)
	tracker_append_string(&output, "&compact=")
	append(&output, byte('1') if request.Compact else byte('0'))
	if event_name, event_present := Tracker_Event_Name(request.Event); event_present {
		tracker_append_string(&output, "&event=")
		tracker_append_string(&output, event_name)
	}
	return output[:], .None
}

// A Tracker_Failure result still owns Failure_Reason; destroy the returned
// response for every return path, not only when the error is None.
Tracker_Parse_Announce_Response :: proc(data: []byte) -> (Tracker_Announce_Response, Tracker_Error) {
	root, bencode_error := Bencode_Decode_Default(data)
	if bencode_error != .None {
		return Tracker_Announce_Response{}, .Invalid_Response
	}
	defer Destroy_Bencode_Value(&root)

	failure := Bencode_Dictionary_Get(&root, "failure reason")
	if failure != nil {
		if failure.Kind != .String {
			return Tracker_Announce_Response{}, .Invalid_Response
		}
		result: Tracker_Announce_Response
		failure_copy, failure_ok := torrent_clone(failure.String)
		if !failure_ok {
			return Tracker_Announce_Response{}, .Out_Of_Memory
		}
		result.Failure_Reason = failure_copy
		return result, .Tracker_Failure
	}

	interval_value := Bencode_Dictionary_Get(&root, "interval")
	interval, interval_ok := tracker_non_negative_integer(interval_value)
	if !interval_ok {
		return Tracker_Announce_Response{}, .Invalid_Response
	}
	result: Tracker_Announce_Response
	result.Interval = interval

	min_interval_value := Bencode_Dictionary_Get(&root, "min interval")
	if min_interval_value != nil {
		parsed, parsed_ok := tracker_non_negative_integer(min_interval_value)
		if !parsed_ok {
			return result, .Invalid_Response
		}
		result.Min_Interval = parsed
		result.Has_Min_Interval = true
	}
	complete_value := Bencode_Dictionary_Get(&root, "complete")
	if complete_value != nil {
		parsed, parsed_ok := tracker_non_negative_integer(complete_value)
		if !parsed_ok {
			return result, .Invalid_Response
		}
		result.Complete = parsed
		result.Has_Complete = true
	}
	incomplete_value := Bencode_Dictionary_Get(&root, "incomplete")
	if incomplete_value != nil {
		parsed, parsed_ok := tracker_non_negative_integer(incomplete_value)
		if !parsed_ok {
			return result, .Invalid_Response
		}
		result.Incomplete = parsed
		result.Has_Incomplete = true
	}

	warning := Bencode_Dictionary_Get(&root, "warning message")
	if warning != nil {
		if warning.Kind != .String {
			return result, .Invalid_Response
		}
		warning_copy, warning_ok := torrent_clone(warning.String)
		if !warning_ok {
			Destroy_Tracker_Response(&result)
			return Tracker_Announce_Response{}, .Out_Of_Memory
		}
		result.Warning_Message = warning_copy
	}

	peers := Bencode_Dictionary_Get(&root, "peers")
	if peers == nil {
		Destroy_Tracker_Response(&result)
		return Tracker_Announce_Response{}, .Invalid_Response
	}
	switch peers.Kind {
	case .String:
		if len(peers.String) % 6 != 0 {
			Destroy_Tracker_Response(&result)
			return Tracker_Announce_Response{}, .Invalid_Peer
		}
		for position := 0; position < len(peers.String); position += 6 {
			port := u16(peers.String[position+4]) << 8 | u16(peers.String[position+5])
			append(&result.Peers, Tracker_Peer{
				IP = [4]byte{
					peers.String[position],
					peers.String[position+1],
					peers.String[position+2],
					peers.String[position+3],
				},
				Port = port,
			})
		}
	case .List:
		for i := 0; i < len(peers.List); i += 1 {
			peer_value := &peers.List[i]
			if peer_value.Kind != .Dictionary {
				Destroy_Tracker_Response(&result)
				return Tracker_Announce_Response{}, .Invalid_Peer
			}
			ip_value := Bencode_Dictionary_Get(peer_value, "ip")
			port_value := Bencode_Dictionary_Get(peer_value, "port")
			if ip_value == nil || ip_value.Kind != .String {
				Destroy_Tracker_Response(&result)
				return Tracker_Announce_Response{}, .Invalid_Peer
			}
			port, port_ok := tracker_non_negative_integer(port_value)
			if !port_ok || port > 65535 {
				Destroy_Tracker_Response(&result)
				return Tracker_Announce_Response{}, .Invalid_Peer
			}
			ip, ip_ok := tracker_parse_ipv4(ip_value.String)
			if !ip_ok {
				Destroy_Tracker_Response(&result)
				return Tracker_Announce_Response{}, .Invalid_Peer
			}
			append(&result.Peers, Tracker_Peer{IP = ip, Port = u16(port)})
		}
	case .Integer:
		Destroy_Tracker_Response(&result)
		return Tracker_Announce_Response{}, .Invalid_Response
	case .Dictionary:
		Destroy_Tracker_Response(&result)
		return Tracker_Announce_Response{}, .Invalid_Response
	case:
		Destroy_Tracker_Response(&result)
		return Tracker_Announce_Response{}, .Invalid_Response
	}

	return result, .None
}

tracker_append_string :: proc(output: ^[dynamic]byte, value: string) {
	append(output, value)
}

tracker_append_percent_encoded :: proc(output: ^[dynamic]byte, data: []byte) {
	hex := "0123456789ABCDEF"
	for c in data {
		if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~' {
			append(output, c)
		} else {
			append(output, '%')
			append(output, hex[int(c>>4)])
			append(output, hex[int(c&0x0f)])
		}
	}
}

tracker_non_negative_integer :: proc(value: ^Bencode_Value) -> (u64, bool) {
	if value == nil || value.Kind != .Integer || value.Integer < 0 {
		return 0, false
	}
	return u64(value.Integer), true
}

tracker_parse_ipv4 :: proc(value: []byte) -> ([4]byte, bool) {
	result: [4]byte
	part := 0
	position := 0
	for octet := 0; octet < 4; octet += 1 {
		if position >= len(value) {
			return [4]byte{}, false
		}
		digits := 0
		for position < len(value) && value[position] >= '0' && value[position] <= '9' {
			digit := byte(value[position] - '0')
			if part > 25 || (part == 25 && digit > 5) {
				return [4]byte{}, false
			}
			part = part*10 + int(digit)
			digits += 1
			position += 1
		}
		if digits == 0 || part > 255 {
			return [4]byte{}, false
		}
		result[octet] = byte(part)
		part = 0
		if octet < 3 {
			if position >= len(value) || value[position] != '.' {
				return [4]byte{}, false
			}
			position += 1
		}
	}
	return result, position == len(value)
}
