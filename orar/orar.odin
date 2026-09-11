package orar

import "core:os"
import "core:strings"

// Format identifies the archive container selected by Open_Bytes.
Format :: enum {
	Unknown,
	RAR4,
	ZIP,
	TAR,
}

// Entry_Kind describes the logical kind of an archive entry.
Entry_Kind :: enum {
	File,
	Directory,
	Symlink,
	Other,
}

// Error is returned by the public Orar API.  The package deliberately keeps
// errors as a small, dependency-free enum so it can be used from applications
// that do not use Odin's optional error packages.
Error :: enum {
	None,
	End,
	Invalid_Archive,
	Truncated,
	Unsupported_Format,
	Unsupported_Feature,
	Encrypted,
	Checksum_Mismatch,
	Invalid_State,
	Invalid_Path,
	Limit_Exceeded,
	Out_Of_Memory,
}

// Entry is metadata for one archive member. Name and Raw_Name are owned by the
// Archive and remain valid until the next Destroy_Archive call.
Entry :: struct {
	Name:             string,
	Raw_Name:         string,
	Kind:             Entry_Kind,
	Size:             u64,
	Compressed_Size:  u64,
	Offset:           i64,
	Filetime:         i64,
	Method:           u16,
	Flags:            u16,
	CRC32:            u32,
	Data_Offset:      i64,
	Format_Index:     int,
}

// Archive owns its input bytes when created by Open_Bytes or Open_File.  An
// archive created by Open_Bytes_Borrowed only borrows the caller's bytes and
// must not outlive them.
Archive :: struct {
	Format:          Format,
	Data:            []byte,
	Owns_Data:       bool,
	Entries:         [dynamic]Entry,
	Comment:         string,
	Cursor:          int,
	Current:         int,
	Current_Offset:  u64,
	Current_Data:    []byte,
	Current_Loaded:  bool,
	At_EOF:          bool,
}

// Detect identifies an archive from its signature. It does not validate the
// complete archive.
Detect :: proc(data: []byte) -> Format {
	if len(data) >= 7 &&
		data[0] == 'R' && data[1] == 'a' && data[2] == 'r' && data[3] == '!' &&
		data[4] == 0x1a && data[5] == 0x07 {
		if data[6] == 0x00 {
			return .RAR4
		}
		return .Unknown
	}
	if len(data) >= 4 && data[0] == 0x50 && data[1] == 0x4b &&
		(data[2] == 0x03 || data[2] == 0x05 || data[2] == 0x07) &&
		(data[3] == 0x04 || data[3] == 0x06 || data[3] == 0x08) {
		return .ZIP
	}

	// TAR has no mandatory magic in its oldest form. The ustar marker is a
	// useful fast path; parse_tar also accepts valid checksum-only archives.
	if len(data) >= 265 && string(data[257:262]) == "ustar" {
		return .TAR
	}
	if len(data) >= 512 && tar_header_looks_valid(data[:512]) {
		return .TAR
	}
	return .Unknown
}

// Open_Bytes copies data before parsing. This is the safe default for callers
// that receive a temporary network buffer.
Open_Bytes :: proc(data: []byte) -> (Archive, Error) {
	copy_data, alloc_error := make([]byte, len(data), context.allocator)
	if alloc_error != nil {
		return Archive{}, .Out_Of_Memory
	}
	copy(copy_data, data)
	archive, err := open_owned_bytes(copy_data)
	return archive, err
}

// Open_Bytes_Borrowed avoids a copy. The caller must keep data alive until the
// archive has been destroyed.
Open_Bytes_Borrowed :: proc(data: []byte) -> (Archive, Error) {
	return open_borrowed_bytes(data)
}

// Open_File reads the complete file using Odin's cross-platform OS package;
// no platform archive or compression library is loaded.
Open_File :: proc(path: string) -> (Archive, Error) {
	data, read_error := os.read_entire_file_from_path(path, context.allocator)
	if read_error != nil {
		return Archive{}, .Invalid_Archive
	}
	archive, err := open_owned_bytes(data)
	return archive, err
}

open_owned_bytes :: proc(data: []byte) -> (Archive, Error) {
	archive := Archive{
		Data = data,
		Owns_Data = true,
		Cursor = -1,
		Current = -1,
	}
	if err := parse_archive(&archive); err != .None {
		Destroy_Archive(&archive)
		return Archive{}, err
	}
	return archive, .None
}

open_borrowed_bytes :: proc(data: []byte) -> (Archive, Error) {
	archive := Archive{
		Data = data,
		Owns_Data = false,
		Cursor = -1,
		Current = -1,
	}
	if err := parse_archive(&archive); err != .None {
		Destroy_Archive(&archive)
		return Archive{}, err
	}
	return archive, .None
}

// Destroy_Archive releases all allocations owned by archive. It is safe to
// call it on a zero Archive or more than once.
Destroy_Archive :: proc(archive: ^Archive) {
	if archive == nil {
		return
	}
	for entry in archive.Entries {
		delete(entry.Name)
		delete(entry.Raw_Name)
	}
	delete(archive.Entries)
	delete(archive.Comment)
	delete(archive.Current_Data)
	if archive.Owns_Data {
		delete(archive.Data)
	}
	archive^ = Archive{Cursor = -1, Current = -1}
}

// Close is an alias useful when Orar is used as a stream-style library.
Close :: proc(archive: ^Archive) {
	Destroy_Archive(archive)
}

// Next selects the next regular or special entry. Directories are retained in
// the metadata list; callers can skip them by checking Entry.Kind.
Next :: proc(archive: ^Archive) -> (Entry, Error) {
	if archive == nil {
		return Entry{}, .Invalid_State
	}
	archive.Current = -1
	delete(archive.Current_Data)
	archive.Current_Data = nil
	archive.Current_Loaded = false
	archive.Current_Offset = 0

	next := archive.Cursor + 1
	if next < 0 || next >= len(archive.Entries) {
		archive.At_EOF = true
		return Entry{}, .End
	}
	archive.Cursor = next
	archive.Current = next
	archive.At_EOF = false
	return archive.Entries[next], .None
}

// Parse_Entry is the unarr-style spelling of Next.
Parse_Entry :: proc(archive: ^Archive) -> (Entry, Error) {
	return Next(archive)
}

// Parse_Entry_At selects the entry whose source offset equals offset. Offset 0
// is treated as a restart request, matching unarr's ar_parse_entry_at.
Parse_Entry_At :: proc(archive: ^Archive, offset: i64) -> (Entry, Error) {
	if archive == nil {
		return Entry{}, .Invalid_State
	}
	if offset == 0 {
		archive.Cursor = -1
		return Next(archive)
	}
	for index := 0; index < len(archive.Entries); index += 1 {
		if archive.Entries[index].Offset == offset {
			archive.Cursor = index - 1
			return Next(archive)
		}
	}
	return Entry{}, .Invalid_Archive
}

Parse_Entry_For :: proc(archive: ^Archive, name: string) -> (Entry, Error) {
	if archive == nil {
		return Entry{}, .Invalid_State
	}
	for index := 0; index < len(archive.Entries); index += 1 {
		if archive.Entries[index].Name == name {
			archive.Cursor = index - 1
			return Next(archive)
		}
	}
	return Entry{}, .End
}

At_EOF :: proc(archive: ^Archive) -> bool {
	return archive == nil || archive.At_EOF
}

Entry_Name :: proc(archive: ^Archive) -> string {
	if archive == nil || archive.Current < 0 || archive.Current >= len(archive.Entries) {
		return ""
	}
	return archive.Entries[archive.Current].Name
}

Entry_Raw_Name :: proc(archive: ^Archive) -> string {
	if archive == nil || archive.Current < 0 || archive.Current >= len(archive.Entries) {
		return ""
	}
	return archive.Entries[archive.Current].Raw_Name
}

Entry_Offset :: proc(archive: ^Archive) -> i64 {
	if archive == nil || archive.Current < 0 || archive.Current >= len(archive.Entries) {
		return 0
	}
	return archive.Entries[archive.Current].Offset
}

Entry_Size :: proc(archive: ^Archive) -> u64 {
	if archive == nil || archive.Current < 0 || archive.Current >= len(archive.Entries) {
		return 0
	}
	return archive.Entries[archive.Current].Size
}

Entry_Filetime :: proc(archive: ^Archive) -> i64 {
	if archive == nil || archive.Current < 0 || archive.Current >= len(archive.Entries) {
		return 0
	}
	return archive.Entries[archive.Current].Filetime
}

// Read_Current reads the next part of the selected entry into dst. It supports
// repeated calls and returns .End only after all requested entry data has been
// consumed. A zero-length dst is always successful.
Read_Current :: proc(archive: ^Archive, dst: []byte) -> (int, Error) {
	if archive == nil || archive.Current < 0 || archive.Current >= len(archive.Entries) {
		return 0, .Invalid_State
	}
	if len(dst) == 0 {
		return 0, .None
	}
	if !archive.Current_Loaded {
		data, err := decode_entry(archive, archive.Current)
		if err != .None {
			return 0, err
		}
		archive.Current_Data = data
		archive.Current_Loaded = true
	}
	if archive.Current_Offset >= u64(len(archive.Current_Data)) {
		return 0, .End
	}
	remaining := u64(len(archive.Current_Data)) - archive.Current_Offset
	count := u64(len(dst))
	if count > remaining {
		count = remaining
	}
	copy(dst[:int(count)], archive.Current_Data[int(archive.Current_Offset):int(archive.Current_Offset+count)])
	archive.Current_Offset += count
	return int(count), .None
}

// Extract_Current returns an independent copy of the complete current entry.
Extract_Current :: proc(archive: ^Archive) -> ([]byte, Error) {
	if archive == nil || archive.Current < 0 || archive.Current >= len(archive.Entries) {
		return nil, .Invalid_State
	}
	if !archive.Current_Loaded {
		data, err := decode_entry(archive, archive.Current)
		if err != .None {
			return nil, err
		}
		archive.Current_Data = data
		archive.Current_Loaded = true
	}
	result, alloc_error := make([]byte, len(archive.Current_Data), context.allocator)
	if alloc_error != nil {
		return nil, .Out_Of_Memory
	}
	copy(result, archive.Current_Data)
	return result, .None
}

// Uncompress is a convenience wrapper for callers that already know the
// expected output size.
Uncompress :: proc(archive: ^Archive, buffer: []byte) -> (bool, Error) {
	if archive == nil || archive.Current < 0 || archive.Current >= len(archive.Entries) {
		return false, .Invalid_State
	}
	if u64(len(buffer)) > Entry_Size(archive) {
		return false, .Invalid_State
	}
	position := archive.Current_Offset
	count, err := Read_Current(archive, buffer)
	if err != .None && !(err == .End && count == len(buffer)) {
		return false, err
	}
	return count == len(buffer) && archive.Current_Offset >= position+u64(len(buffer)), .None
}

Get_Global_Comment :: proc(archive: ^Archive) -> string {
	if archive == nil {
		return ""
	}
	return archive.Comment
}

Format_Name :: proc(format: Format) -> string {
	switch format {
	case .RAR4:
		return "RAR4"
	case .ZIP:
		return "ZIP"
	case .TAR:
		return "TAR"
	case .Unknown:
		return "unknown"
	}
	return "unknown"
}

parse_archive :: proc(archive: ^Archive) -> Error {
	format := Detect(archive.Data)
	switch format {
	case .RAR4:
		err := parse_rar(archive)
		if err == .None {
			archive.Format = .RAR4
		}
		return err
	case .ZIP:
		err := parse_zip(archive)
		if err == .None {
			archive.Format = .ZIP
		}
		return err
	case .TAR:
		err := parse_tar(archive)
		if err == .None {
			archive.Format = .TAR
		}
		return err
	case .Unknown:
		return .Unsupported_Format
	}
	return .Unsupported_Format
}

// decode_entry is implemented by the format backends.
decode_entry :: proc(archive: ^Archive, index: int) -> ([]byte, Error) {
	switch archive.Format {
	case .RAR4:
		return decode_rar_entry(archive, index)
	case .ZIP:
		return decode_zip_entry(archive, index)
	case .TAR:
		return decode_tar_entry(archive, index)
	case .Unknown:
		return nil, .Unsupported_Format
	}
	return nil, .Unsupported_Format
}

// Little-endian readers shared by all formats.
read_u16le :: proc(data: []byte, offset: int) -> (u16, bool) {
	if offset < 0 || offset+2 > len(data) {
		return 0, false
	}
	return u16(data[offset]) | u16(data[offset+1])<<8, true
}

read_u32le :: proc(data: []byte, offset: int) -> (u32, bool) {
	if offset < 0 || offset+4 > len(data) {
		return 0, false
	}
	return u32(data[offset]) | u32(data[offset+1])<<8 | u32(data[offset+2])<<16 | u32(data[offset+3])<<24, true
}

read_u64le :: proc(data: []byte, offset: int) -> (u64, bool) {
	if offset < 0 || offset+8 > len(data) {
		return 0, false
	}
	low, low_ok := read_u32le(data, offset)
	high, high_ok := read_u32le(data, offset+4)
	return u64(low) | u64(high)<<32, low_ok && high_ok
}

read_u16be :: proc(data: []byte, offset: int) -> (u16, bool) {
	if offset < 0 || offset+2 > len(data) {
		return 0, false
	}
	return u16(data[offset])<<8 | u16(data[offset+1]), true
}

read_u32be :: proc(data: []byte, offset: int) -> (u32, bool) {
	if offset < 0 || offset+4 > len(data) {
		return 0, false
	}
	return u32(data[offset])<<24 | u32(data[offset+1])<<16 | u32(data[offset+2])<<8 | u32(data[offset+3]), true
}

valid_range :: proc(data: []byte, offset: int, size: u64) -> bool {
	if offset < 0 || offset > len(data) {
		return false
	}
	return size <= u64(len(data)-offset)
}

clone_text :: proc(value: string) -> (string, Error) {
	return strings.clone(value, context.allocator), .None
}

normalize_name :: proc(value: string) -> string {
	output: [dynamic]byte
	for index := 0; index < len(value); index += 1 {
		c := value[index]
		if c == '\\' {
			append(&output, byte('/'))
		} else {
			append(&output, c)
		}
	}
	result := strings.clone(string(output[:]), context.allocator)
	delete(output)
	return result
}

append_utf8 :: proc(output: ^[dynamic]byte, codepoint: u32) {
	if codepoint <= 0x7f {
		append(output, byte(codepoint))
	} else if codepoint <= 0x7ff {
		append(output, byte(0xc0|(codepoint>>6)))
		append(output, byte(0x80|(codepoint&0x3f)))
	} else if codepoint <= 0xffff && !(codepoint >= 0xd800 && codepoint <= 0xdfff) {
		append(output, byte(0xe0|(codepoint>>12)))
		append(output, byte(0x80|((codepoint>>6)&0x3f)))
		append(output, byte(0x80|(codepoint&0x3f)))
	} else if codepoint <= 0x10ffff {
		append(output, byte(0xf0|(codepoint>>18)))
		append(output, byte(0x80|((codepoint>>12)&0x3f)))
		append(output, byte(0x80|((codepoint>>6)&0x3f)))
		append(output, byte(0x80|(codepoint&0x3f)))
	} else {
		append_utf8(output, 0xfffd)
	}
}

utf8_is_valid :: proc(value: []byte) -> bool {
	index := 0
	for index < len(value) {
		first := value[index]
		if first < 0x80 {
			index += 1
			continue
		}
		needed: int
		codepoint: u32
		minimum: u32
		if first >= 0xc2 && first <= 0xdf {
			needed, codepoint, minimum = 1, u32(first&0x1f), 0x80
		} else if first >= 0xe0 && first <= 0xef {
			needed, codepoint, minimum = 2, u32(first&0x0f), 0x800
		} else if first >= 0xf0 && first <= 0xf4 {
			needed, codepoint, minimum = 3, u32(first&0x07), 0x10000
		} else {
			return false
		}
		if index+needed >= len(value) {
			return false
		}
		for step := 1; step <= needed; step += 1 {
			continuation := value[index+step]
			if continuation&0xc0 != 0x80 {
				return false
			}
			codepoint = (codepoint<<6) | u32(continuation&0x3f)
		}
		if codepoint < minimum || codepoint > 0x10ffff || (codepoint >= 0xd800 && codepoint <= 0xdfff) {
			return false
		}
		index += needed + 1
	}
	return true
}

// CP437 is the fallback encoding specified by ZIP and used by old RAR/TAR
// writers. The first 128 code points are ASCII and are handled directly.
cp437_extension: [128]u32 = {
	0x00c7, 0x00fc, 0x00e9, 0x00e2, 0x00e4, 0x00e0, 0x00e5, 0x00e7,
	0x00ea, 0x00eb, 0x00e8, 0x00ef, 0x00ee, 0x00ec, 0x00c4, 0x00c5,
	0x00c9, 0x00e6, 0x00c6, 0x00f4, 0x00f6, 0x00f2, 0x00fb, 0x00f9,
	0x00ff, 0x00d6, 0x00dc, 0x00a2, 0x00a3, 0x00a5, 0x20a7, 0x0192,
	0x00e1, 0x00ed, 0x00f3, 0x00fa, 0x00f1, 0x00d1, 0x00aa, 0x00ba,
	0x00bf, 0x2310, 0x00ac, 0x00bd, 0x00bc, 0x00a1, 0x00ab, 0x00bb,
	0x2591, 0x2592, 0x2593, 0x2502, 0x2524, 0x2561, 0x2562, 0x2556,
	0x2555, 0x2563, 0x2551, 0x2557, 0x255d, 0x255c, 0x255b, 0x2510,
	0x2514, 0x2534, 0x252c, 0x251c, 0x2500, 0x253c, 0x255e, 0x255f,
	0x255a, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550, 0x256c, 0x2567,
	0x2568, 0x2564, 0x2565, 0x2559, 0x2558, 0x2552, 0x2553, 0x256b,
	0x256a, 0x2518, 0x250c, 0x2588, 0x2584, 0x258c, 0x2590, 0x2580,
	0x03b1, 0x00df, 0x0393, 0x03c0, 0x03a3, 0x03c3, 0x00b5, 0x03c4,
	0x03a6, 0x0398, 0x03a9, 0x03b4, 0x221e, 0x03c6, 0x03b5, 0x2229,
	0x2261, 0x00b1, 0x2265, 0x2264, 0x2320, 0x2321, 0x00f7, 0x2248,
	0x00b0, 0x2219, 0x00b7, 0x221a, 0x207f, 0x00b2, 0x25a0, 0x00a0,
}

cp437_to_utf8 :: proc(value: []byte) -> string {
	output: [dynamic]byte
	for c in value {
		if c < 0x80 {
			append_utf8(&output, u32(c))
		} else {
			append_utf8(&output, cp437_extension[int(c-0x80)])
		}
	}
	result := strings.clone(string(output[:]), context.allocator)
	delete(output)
	return result
}

archive_name_from_bytes :: proc(value: []byte, utf8: bool) -> (string, string) {
	raw := strings.clone(string(value), context.allocator)
	if utf8 || utf8_is_valid(value) {
		return normalize_name(raw), raw
	}
	name := cp437_to_utf8(value)
	return normalize_name(name), raw
}

// DOS timestamps are represented by unarr's FILETIME-compatible unit: 100 ns
// ticks since 1601-01-01 UTC. This conversion is timezone-independent and is
// sufficient for archive metadata; invalid fields are clamped to zero.
dos_datetime_to_filetime :: proc(dos: u32) -> i64 {
	second := int((dos & 0x1f) * 2)
	minute := int((dos >> 5) & 0x3f)
	hour := int((dos >> 11) & 0x1f)
	day := int((dos >> 16) & 0x1f)
	month := int((dos >> 21) & 0x0f)
	year := int((dos >> 25) & 0x7f) + 1980
	if day == 0 || month == 0 || month > 12 {
		return 0
	}
	// Howard Hinnant's civil-date conversion, yielding days since 1970-01-01.
	y := year
	m := month
	d := day
	if m <= 2 {
		y -= 1
	}
	era := y / 400
	yoe := y - era*400
	month_adjusted := m + 9
		if m > 2 {
			month_adjusted = m - 3
		}
	doe := yoe*365 + yoe/4 - yoe/100 + (153*month_adjusted+2)/5 + d - 1
	days := era*146097 + doe - 719468
	seconds := i64(days*86400 + hour*3600 + minute*60 + second)
	return (seconds + 11644473600) * 10000000
}

tar_header_looks_valid :: proc(header: []byte) -> bool {
	return len(header) >= 512 && tar_validate_checksum(header[:512])
}

// CRC32 uses the same reflected polynomial as ZIP, RAR, and 7z. It is kept in
// Odin rather than delegated to zlib so the package has no external linkage.
crc32 :: proc(seed: u32, data: []byte) -> u32 {
	crc := seed ~ u32(0xffffffff)
	for value in data {
		crc = crc ~ u32(value)
		for bit := 0; bit < 8; bit += 1 {
			mask := u32(0) - (crc & 1)
			crc = (crc >> 1) ~ (u32(0xedb88320) & mask)
		}
	}
	return crc ~ u32(0xffffffff)
}

// Public aliases for users that want to validate an extracted member.
CRC32 :: proc(data: []byte) -> u32 {
	return crc32(0, data)
}
