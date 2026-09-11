package durrent

import "core:crypto/hash"

Block_Size :: u32(16 * 1024)

Bitfield :: struct {
	Bytes:       []byte,
	Piece_Count: u32,
}

Piece_Error :: enum {
	None,
	Invalid_Length,
	Invalid_Block,
	Out_Of_Memory,
}

Bitfield_Init :: proc(piece_count: u32) -> (Bitfield, Piece_Error) {
	byte_count := int((u64(piece_count) + 7) / 8)
	bytes, alloc_error := make([]byte, byte_count, context.allocator)
	if alloc_error != nil {
		return Bitfield{}, .Out_Of_Memory
	}
	return Bitfield{Bytes = bytes, Piece_Count = piece_count}, .None
}

Bitfield_From_Raw :: proc(raw: []byte, piece_count: u32) -> (Bitfield, Piece_Error) {
	expected := int((u64(piece_count) + 7) / 8)
	if len(raw) != expected {
		return Bitfield{}, .Invalid_Length
	}
	result, alloc_error := make([]byte, expected, context.allocator)
	if alloc_error != nil {
		return Bitfield{}, .Out_Of_Memory
	}
	copy(result, raw)
	return Bitfield{Bytes = result, Piece_Count = piece_count}, .None
}

Destroy_Bitfield :: proc(bitfield: ^Bitfield) {
	if bitfield == nil {
		return
	}
	delete(bitfield.Bytes)
	bitfield^ = Bitfield{}
}

Bitfield_Has_Piece :: proc(bitfield: ^Bitfield, index: u32) -> bool {
	if bitfield == nil || index >= bitfield.Piece_Count {
		return false
	}
	byte_index := int(index / 8)
	bit_index := u8(7 - index%8)
	return (bitfield.Bytes[byte_index] & (byte(1) << bit_index)) != 0
}

Bitfield_Set_Piece :: proc(bitfield: ^Bitfield, index: u32) {
	if bitfield == nil || index >= bitfield.Piece_Count {
		return
	}
	byte_index := int(index / 8)
	bit_index := u8(7 - index%8)
	bitfield.Bytes[byte_index] |= byte(1) << bit_index
}

Bitfield_Clear_Piece :: proc(bitfield: ^Bitfield, index: u32) {
	if bitfield == nil || index >= bitfield.Piece_Count {
		return
	}
	byte_index := int(index / 8)
	bit_index := u8(7 - index%8)
	bitfield.Bytes[byte_index] &= ~(byte(1) << bit_index)
}

Bitfield_Count :: proc(bitfield: ^Bitfield) -> u32 {
	if bitfield == nil {
		return 0
	}
	count: u32 = 0
	for index: u32 = 0; index < bitfield.Piece_Count; index += 1 {
		if Bitfield_Has_Piece(bitfield, index) {
			count += 1
		}
	}
	return count
}

Bitfield_Is_Complete :: proc(bitfield: ^Bitfield) -> bool {
	return bitfield != nil && Bitfield_Count(bitfield) == bitfield.Piece_Count
}

Piece_Progress :: struct {
	Index:        u32,
	Piece_Length: u32,
	Block_Count:  u32,
	Received:     []byte,
	Requested:    []byte,
	Data:         []byte,
}

Piece_Progress_Init :: proc(index, piece_length: u32) -> (Piece_Progress, Piece_Error) {
	if piece_length == 0 {
		return Piece_Progress{}, .Invalid_Length
	}
	block_count := u32((u64(piece_length) + u64(Block_Size) - 1) / u64(Block_Size))
	bitmap_length := int((u64(block_count) + 7) / 8)

	received, received_error := make([]byte, bitmap_length, context.allocator)
	if received_error != nil {
		return Piece_Progress{}, .Out_Of_Memory
	}
	requested, requested_error := make([]byte, bitmap_length, context.allocator)
	if requested_error != nil {
		delete(received)
		return Piece_Progress{}, .Out_Of_Memory
	}
	data, data_error := make([]byte, int(piece_length), context.allocator)
	if data_error != nil {
		delete(received)
		delete(requested)
		return Piece_Progress{}, .Out_Of_Memory
	}
	return Piece_Progress{
		Index = index,
		Piece_Length = piece_length,
		Block_Count = block_count,
		Received = received,
		Requested = requested,
		Data = data,
	}, .None
}

Destroy_Piece_Progress :: proc(progress: ^Piece_Progress) {
	if progress == nil {
		return
	}
	delete(progress.Received)
	delete(progress.Requested)
	delete(progress.Data)
	progress^ = Piece_Progress{}
}

Piece_Progress_Add_Block :: proc(progress: ^Piece_Progress, begin: u32, block: []byte) -> (bool, Piece_Error) {
	if progress == nil || begin >= progress.Piece_Length || begin % Block_Size != 0 {
		return false, .Invalid_Block
	}
	block_index := begin / Block_Size
	if block_index >= progress.Block_Count {
		return false, .Invalid_Block
	}
	expected_length := progress.Piece_Length - begin
	if expected_length > Block_Size {
		expected_length = Block_Size
	}
	if len(block) != int(expected_length) {
		return false, .Invalid_Block
	}

	copy(progress.Data[int(begin):int(begin+expected_length)], block)
	piece_bitmap_set(progress.Received, block_index)
	piece_bitmap_clear(progress.Requested, block_index)
	return Piece_Progress_Is_Complete(progress), .None
}

Piece_Progress_Has_Block :: proc(progress: ^Piece_Progress, block_index: u32) -> bool {
	return progress != nil && block_index < progress.Block_Count && piece_bitmap_has(progress.Received, block_index)
}

Piece_Progress_Is_Complete :: proc(progress: ^Piece_Progress) -> bool {
	if progress == nil {
		return false
	}
	for block_index: u32 = 0; block_index < progress.Block_Count; block_index += 1 {
		if !Piece_Progress_Has_Block(progress, block_index) {
			return false
		}
	}
	return true
}

Piece_Progress_Next_Missing_Block :: proc(progress: ^Piece_Progress) -> (u32, bool) {
	if progress == nil {
		return 0, false
	}
	for block_index: u32 = 0; block_index < progress.Block_Count; block_index += 1 {
		if !Piece_Progress_Has_Block(progress, block_index) {
			return block_index, true
		}
	}
	return 0, false
}

Piece_Progress_Is_Requested :: proc(progress: ^Piece_Progress, block_index: u32) -> bool {
	return progress != nil && block_index < progress.Block_Count && piece_bitmap_has(progress.Requested, block_index)
}

Piece_Progress_Mark_Requested :: proc(progress: ^Piece_Progress, block_index: u32) {
	if progress == nil || block_index >= progress.Block_Count {
		return
	}
	piece_bitmap_set(progress.Requested, block_index)
}

Piece_Progress_Clear_Requested :: proc(progress: ^Piece_Progress, block_index: u32) {
	if progress == nil || block_index >= progress.Block_Count {
		return
	}
	piece_bitmap_clear(progress.Requested, block_index)
}

Piece_Progress_Next_Unrequested_Block :: proc(progress: ^Piece_Progress) -> (u32, bool) {
	if progress == nil {
		return 0, false
	}
	for block_index: u32 = 0; block_index < progress.Block_Count; block_index += 1 {
		if !Piece_Progress_Has_Block(progress, block_index) && !Piece_Progress_Is_Requested(progress, block_index) {
			return block_index, true
		}
	}
	return 0, false
}

Piece_Block_Spec :: struct {
	Begin:  u32,
	Length: u32,
}

Piece_Progress_Block_Spec :: proc(progress: ^Piece_Progress, block_index: u32) -> (Piece_Block_Spec, bool) {
	if progress == nil || block_index >= progress.Block_Count {
		return Piece_Block_Spec{}, false
	}
	begin := block_index * Block_Size
	length := progress.Piece_Length - begin
	if length > Block_Size {
		length = Block_Size
	}
	return Piece_Block_Spec{Begin = begin, Length = length}, true
}

Piece_Progress_Reset :: proc(progress: ^Piece_Progress) {
	if progress == nil {
		return
	}
	for i := 0; i < len(progress.Received); i += 1 {
		progress.Received[i] = 0
	}
	for i := 0; i < len(progress.Requested); i += 1 {
		progress.Requested[i] = 0
	}
	for i := 0; i < len(progress.Data); i += 1 {
		progress.Data[i] = 0
	}
}

Verify_Piece :: proc(data: []byte, expected: ^Torrent_Hash) -> bool {
	if expected == nil {
		return false
	}
	actual: Torrent_Hash
	hash.hash_bytes_to_buffer(hash.Algorithm.Insecure_SHA1, data, actual[:])
	return bytes_equal(actual[:], expected[:])
}

Torrent_Piece_Hash :: proc(pieces: [dynamic]Torrent_Hash, index: u32) -> (Torrent_Hash, bool) {
	if index >= u32(len(pieces)) {
		return Torrent_Hash{}, false
	}
	return pieces[int(index)], true
}

Piece_Length :: proc(index: u32, piece_length, total_length: u64) -> u32 {
	if piece_length == 0 || u64(index) > u64_max / piece_length {
		return 0
	}
	start := u64(index) * piece_length
	if start >= total_length {
		return 0
	}
	remaining := total_length - start
	if remaining > piece_length {
		remaining = piece_length
	}
	if remaining > u64(0xffffffff) {
		return 0
	}
	return u32(remaining)
}

Piece_Count :: proc(total_length, piece_length: u64) -> (u32, bool) {
	if piece_length == 0 {
		return 0, false
	}
	count := total_length / piece_length
	if total_length % piece_length != 0 {
		count += 1
	}
	if count > u64(0xffffffff) {
		return 0, false
	}
	return u32(count), true
}

Torrent_Total_Length :: proc(files: [dynamic]Torrent_File) -> (u64, bool) {
	total: u64 = 0
	for file in files {
		if total > u64_max-file.Length {
			return 0, false
		}
		total += file.Length
	}
	return total, true
}

piece_bitmap_has :: proc(bitmap: []byte, index: u32) -> bool {
	byte_index := int(index / 8)
	if byte_index < 0 || byte_index >= len(bitmap) {
		return false
	}
	bit_index := u8(7 - index%8)
	return (bitmap[byte_index] & (byte(1) << bit_index)) != 0
}

piece_bitmap_set :: proc(bitmap: []byte, index: u32) {
	byte_index := int(index / 8)
	if byte_index < 0 || byte_index >= len(bitmap) {
		return
	}
	bit_index := u8(7 - index%8)
	bitmap[byte_index] |= byte(1) << bit_index
}

piece_bitmap_clear :: proc(bitmap: []byte, index: u32) {
	byte_index := int(index / 8)
	if byte_index < 0 || byte_index >= len(bitmap) {
		return
	}
	bit_index := u8(7 - index%8)
	bitmap[byte_index] &= ~(byte(1) << bit_index)
}
