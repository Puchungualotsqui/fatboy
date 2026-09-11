package durrent

// Bencode is the compact data format used by .torrent files, trackers, and
// several BitTorrent extension messages. Byte strings are deliberately kept as
// []byte: the protocol does not require them to contain UTF-8 text.

Bencode_Kind :: enum {
	Integer,
	String,
	List,
	Dictionary,
}

Bencode_Entry :: struct {
	Key:   []byte,
	Value: Bencode_Value,
}

// Bencode_Value owns every slice reachable from it. The List and Dictionary
// fields are only meaningful for their corresponding Kind. Values are shallow
// copies in Odin, so callers should treat an owned value as move-only and call
// Destroy_Bencode_Value exactly once.
Bencode_Value :: struct {
	Kind:       Bencode_Kind,
	Integer:    i64,
	String:     []byte,
	List:       [dynamic]Bencode_Value,
	Dictionary: [dynamic]Bencode_Entry,
}

Bencode_Limits :: struct {
	Max_Depth:         int,
	Max_String_Bytes:  int,
	Max_Values:        int,
	Max_Total_Bytes:   int,
}

Bencode_Default_Limits :: proc() -> Bencode_Limits {
	return Bencode_Limits{
		Max_Depth = 64,
		Max_String_Bytes = 64 * 1024 * 1024,
		Max_Values = 1 * 1024 * 1024,
		Max_Total_Bytes = 128 * 1024 * 1024,
	}
}

Bencode_Error :: enum {
	None,
	Unexpected_End,
	Unexpected_Byte,
	Invalid_Integer,
	Invalid_String_Length,
	Leading_Zero,
	Negative_Zero,
	Duplicate_Dictionary_Key,
	Limit_Exceeded,
	Out_Of_Memory,
}

Bencode_Parser :: struct {
	Data:          []byte,
	Position:      int,
	Limits:        Bencode_Limits,
	Depth:         int,
	Value_Count:   int,
	String_Bytes:  int,
}

// Bencode_Decode parses exactly one bencoded value. The returned value owns
// cloned byte strings and must be released with Destroy_Bencode_Value.
Bencode_Decode :: proc(data: []byte, limits: Bencode_Limits) -> (Bencode_Value, Bencode_Error) {
	parser := Bencode_Parser{
		Data = data,
		Limits = limits,
	}

	value, err := bencode_parse_value(&parser, 0)
	if err != .None {
		return Bencode_Value{}, err
	}
	if parser.Position != len(data) {
		Destroy_Bencode_Value(&value)
		return Bencode_Value{}, .Unexpected_Byte
	}
	return value, .None
}

Bencode_Decode_Default :: proc(data: []byte) -> (Bencode_Value, Bencode_Error) {
	return Bencode_Decode(data, Bencode_Default_Limits())
}

Destroy_Bencode_Value :: proc(value: ^Bencode_Value) {
	if value == nil {
		return
	}

	switch value.Kind {
	case .Integer:
		{}
	case .String:
		if len(value.String) > 0 {
			delete(value.String)
		}
	case .List:
		for i := 0; i < len(value.List); i += 1 {
			Destroy_Bencode_Value(&value.List[i])
		}
		delete(value.List)
	case .Dictionary:
		for i := 0; i < len(value.Dictionary); i += 1 {
			entry := &value.Dictionary[i]
			if len(entry.Key) > 0 {
				delete(entry.Key)
			}
			Destroy_Bencode_Value(&entry.Value)
		}
		delete(value.Dictionary)
	}

	value^ = Bencode_Value{}
}

Bencode_Dictionary_Get :: proc(value: ^Bencode_Value, key: string) -> ^Bencode_Value {
	if value == nil || value.Kind != .Dictionary {
		return nil
	}
	key_bytes := transmute([]byte)key
	for i := 0; i < len(value.Dictionary); i += 1 {
		if bytes_equal(value.Dictionary[i].Key, key_bytes) {
			return &value.Dictionary[i].Value
		}
	}
	return nil
}

Bencode_As_Integer :: proc(value: ^Bencode_Value) -> (i64, bool) {
	if value == nil || value.Kind != .Integer {
		return 0, false
	}
	return value.Integer, true
}

Bencode_As_String :: proc(value: ^Bencode_Value) -> ([]byte, bool) {
	if value == nil || value.Kind != .String {
		return nil, false
	}
	return value.String, true
}

Bencode_As_List :: proc(value: ^Bencode_Value) -> ([dynamic]Bencode_Value, bool) {
	if value == nil || value.Kind != .List {
		return nil, false
	}
	return value.List, true
}

// Bencode_Encode preserves dictionary entry order. That is important for
// torrent info hashes: parsed info dictionaries must be re-encoded in the same
// order rather than sorted as a generic map would be.
Bencode_Encode :: proc(value: ^Bencode_Value) -> []byte {
	output: [dynamic]byte
	if value == nil {
		return nil
	}
	bencode_encode_value(&output, value)
	return output[:]
}

bencode_parse_value :: proc(parser: ^Bencode_Parser, depth: int) -> (Bencode_Value, Bencode_Error) {
	if parser == nil || parser.Position >= len(parser.Data) {
		return Bencode_Value{}, .Unexpected_End
	}
	if depth > parser.Limits.Max_Depth {
		return Bencode_Value{}, .Limit_Exceeded
	}
	if parser.Value_Count >= parser.Limits.Max_Values {
		return Bencode_Value{}, .Limit_Exceeded
	}
	parser.Value_Count += 1

	switch parser.Data[parser.Position] {
	case 'i':
		return bencode_parse_integer(parser)
	case 'l':
		return bencode_parse_list(parser, depth)
	case 'd':
		return bencode_parse_dictionary(parser, depth)
	case '0' ..= '9':
		text, err := bencode_parse_string(parser)
		if err != .None {
			return Bencode_Value{}, err
		}
		return Bencode_Value{Kind = .String, String = text}, .None
	}

	return Bencode_Value{}, .Unexpected_Byte
}

bencode_parse_integer :: proc(parser: ^Bencode_Parser) -> (Bencode_Value, Bencode_Error) {
	// i<optional minus><digits>e
	parser.Position += 1
	if parser.Position >= len(parser.Data) {
		return Bencode_Value{}, .Unexpected_End
	}

	negative := false
	if parser.Data[parser.Position] == '-' {
		negative = true
		parser.Position += 1
	}
	if parser.Position >= len(parser.Data) {
		return Bencode_Value{}, .Unexpected_End
	}
	if parser.Data[parser.Position] < '0' || parser.Data[parser.Position] > '9' {
		return Bencode_Value{}, .Invalid_Integer
	}

	if parser.Data[parser.Position] == '0' {
		parser.Position += 1
		if negative {
			if parser.Position < len(parser.Data) && parser.Data[parser.Position] == 'e' {
				return Bencode_Value{}, .Negative_Zero
			}
			return Bencode_Value{}, .Leading_Zero
		}
		if parser.Position < len(parser.Data) && parser.Data[parser.Position] != 'e' {
			return Bencode_Value{}, .Leading_Zero
		}
	} else {
		positive_limit :: u64(9223372036854775807)
		negative_limit :: u64(9223372036854775808)
		limit := positive_limit if !negative else negative_limit
		magnitude: u64 = 0

		for parser.Position < len(parser.Data) {
			c := parser.Data[parser.Position]
			if c == 'e' {
				break
			}
			if c < '0' || c > '9' {
				return Bencode_Value{}, .Unexpected_Byte
			}
			digit := u64(c - '0')
			if magnitude > (limit - digit) / 10 {
				return Bencode_Value{}, .Invalid_Integer
			}
			magnitude = magnitude * 10 + digit
			parser.Position += 1
		}

		if parser.Position >= len(parser.Data) {
			return Bencode_Value{}, .Unexpected_End
		}
		if parser.Data[parser.Position] != 'e' {
			return Bencode_Value{}, .Unexpected_Byte
		}

		parser.Position += 1
		if negative {
			if magnitude == negative_limit {
				return Bencode_Value{Kind = .Integer, Integer = -9223372036854775807 - 1}, .None
			}
			return Bencode_Value{Kind = .Integer, Integer = -i64(magnitude)}, .None
		}
		return Bencode_Value{Kind = .Integer, Integer = i64(magnitude)}, .None
	}

	if parser.Position >= len(parser.Data) {
		return Bencode_Value{}, .Unexpected_End
	}
	if parser.Data[parser.Position] != 'e' {
		return Bencode_Value{}, .Unexpected_Byte
	}
	parser.Position += 1
	return Bencode_Value{Kind = .Integer, Integer = 0}, .None
}

bencode_parse_string :: proc(parser: ^Bencode_Parser) -> ([]byte, Bencode_Error) {
	start := parser.Position
	for parser.Position < len(parser.Data) && parser.Data[parser.Position] >= '0' && parser.Data[parser.Position] <= '9' {
		parser.Position += 1
	}
	if parser.Position >= len(parser.Data) {
		return nil, .Unexpected_End
	}
	if parser.Data[parser.Position] != ':' {
		return nil, .Unexpected_Byte
	}
	if parser.Position == start {
		return nil, .Invalid_String_Length
	}
	if parser.Position-start > 1 && parser.Data[start] == '0' {
		return nil, .Leading_Zero
	}

	length: int = 0
	for i := start; i < parser.Position; i += 1 {
		digit := int(parser.Data[i] - '0')
		if length > (parser.Limits.Max_String_Bytes-digit) / 10 {
			return nil, .Limit_Exceeded
		}
		length = length * 10 + digit
	}
	if length > parser.Limits.Max_String_Bytes {
		return nil, .Limit_Exceeded
	}

	parser.Position += 1
	if length > len(parser.Data)-parser.Position {
		return nil, .Unexpected_End
	}
	if parser.String_Bytes > parser.Limits.Max_Total_Bytes-length {
		return nil, .Limit_Exceeded
	}
	parser.String_Bytes += length

	result, alloc_error := make([]byte, length, context.allocator)
	if alloc_error != nil {
		return nil, .Out_Of_Memory
	}
	copy(result, parser.Data[parser.Position:parser.Position+length])
	parser.Position += length
	return result, .None
}

bencode_parse_list :: proc(parser: ^Bencode_Parser, depth: int) -> (Bencode_Value, Bencode_Error) {
	parser.Position += 1
	items: [dynamic]Bencode_Value

	for {
		if parser.Position >= len(parser.Data) {
			bencode_destroy_values(&items)
			return Bencode_Value{}, .Unexpected_End
		}
		if parser.Data[parser.Position] == 'e' {
			parser.Position += 1
			return Bencode_Value{Kind = .List, List = items}, .None
		}
		item, err := bencode_parse_value(parser, depth+1)
		if err != .None {
			bencode_destroy_values(&items)
			return Bencode_Value{}, err
		}
		append(&items, item)
	}
}

bencode_parse_dictionary :: proc(parser: ^Bencode_Parser, depth: int) -> (Bencode_Value, Bencode_Error) {
	parser.Position += 1
	entries: [dynamic]Bencode_Entry

	for {
		if parser.Position >= len(parser.Data) {
			bencode_destroy_entries(&entries)
			return Bencode_Value{}, .Unexpected_End
		}
		if parser.Data[parser.Position] == 'e' {
			parser.Position += 1
			return Bencode_Value{Kind = .Dictionary, Dictionary = entries}, .None
		}
		if parser.Data[parser.Position] < '0' || parser.Data[parser.Position] > '9' {
			bencode_destroy_entries(&entries)
			return Bencode_Value{}, .Unexpected_Byte
		}

		key, key_err := bencode_parse_string(parser)
		if key_err != .None {
			bencode_destroy_entries(&entries)
			return Bencode_Value{}, key_err
		}
		for i := 0; i < len(entries); i += 1 {
			if bytes_equal(entries[i].Key, key) {
				delete(key)
				bencode_destroy_entries(&entries)
				return Bencode_Value{}, .Duplicate_Dictionary_Key
			}
		}

		value, value_err := bencode_parse_value(parser, depth+1)
		if value_err != .None {
			delete(key)
			bencode_destroy_entries(&entries)
			return Bencode_Value{}, value_err
		}
		append(&entries, Bencode_Entry{Key = key, Value = value})
	}
}

bencode_destroy_values :: proc(values: ^[dynamic]Bencode_Value) {
	if values == nil {
		return
	}
	for i := 0; i < len(values^); i += 1 {
		Destroy_Bencode_Value(&values^[i])
	}
	delete(values^)
}

bencode_destroy_entries :: proc(entries: ^[dynamic]Bencode_Entry) {
	if entries == nil {
		return
	}
	for i := 0; i < len(entries^); i += 1 {
		if len(entries^[i].Key) > 0 {
			delete(entries^[i].Key)
		}
		Destroy_Bencode_Value(&entries^[i].Value)
	}
	delete(entries^)
}

bencode_encode_value :: proc(output: ^[dynamic]byte, value: ^Bencode_Value) {
	switch value.Kind {
	case .Integer:
		append(output, 'i')
		bencode_append_integer(output, value.Integer)
		append(output, 'e')
	case .String:
		bencode_append_unsigned(output, u64(len(value.String)))
		append(output, ':')
		for b in value.String {
			append(output, b)
		}
	case .List:
		append(output, 'l')
		for i := 0; i < len(value.List); i += 1 {
			bencode_encode_value(output, &value.List[i])
		}
		append(output, 'e')
	case .Dictionary:
		append(output, 'd')
		for i := 0; i < len(value.Dictionary); i += 1 {
			entry := &value.Dictionary[i]
			bencode_append_unsigned(output, u64(len(entry.Key)))
			append(output, ':')
			for b in entry.Key {
				append(output, b)
			}
			bencode_encode_value(output, &entry.Value)
		}
		append(output, 'e')
	}
}

bencode_append_integer :: proc(output: ^[dynamic]byte, value: i64) {
	if value < 0 {
		append(output, '-')
		magnitude := u64(-(value + 1)) + 1
		bencode_append_unsigned(output, magnitude)
		return
	}
	bencode_append_unsigned(output, u64(value))
}

bencode_append_unsigned :: proc(output: ^[dynamic]byte, value: u64) {
	if value == 0 {
		append(output, '0')
		return
	}

	digits: [20]byte
	count := 0
	remaining := value
	for remaining > 0 {
		digits[count] = byte(remaining % 10) + '0'
		count += 1
		remaining /= 10
	}
	for count > 0 {
		count -= 1
		append(output, digits[count])
	}
}

bytes_equal :: proc(a, b: []byte) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i := 0; i < len(a); i += 1 {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
