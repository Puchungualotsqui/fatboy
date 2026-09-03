package jpegpng

import "core:math"
import "core:os"
import "core:simd"
import "core:thread"
import "base:runtime"

// Error is returned by the conversion procedures.
Error :: enum {
    None,
    Invalid_Input,
    Decode_Failed,
    Unsupported_Image,
    Invalid_Dimensions,
    Allocation_Failed,
    Write_Failed,
}

// Options controls the amount of parallel work used by the decoder and PNG
// encoder. Workers <= 0 uses four workers. A value of one is useful for
// deterministic profiling and debugging.
Options :: struct {
    workers: int,
}

DEFAULT_OPTIONS :: Options{}

// Convert_File decodes input_path as a baseline or progressive JPEG and writes
// a PNG to output_path.
Convert_File :: proc(
    input_path: string,
    output_path: string,
    options := DEFAULT_OPTIONS,
    allocator := context.allocator,
) -> Error {
    input, read_err := os.read_entire_file(input_path, allocator)
    if read_err != nil {
        return .Invalid_Input
    }
    defer delete(input, allocator)

    output, err := Convert_Bytes(input, options, allocator)
    if err != .None {
        return err
    }
    defer delete(output, allocator)

    if write_err := os.write_entire_file(output_path, output); write_err != nil {
        return .Write_Failed
    }
    return .None
}

// Convert_Bytes converts a baseline or progressive JPEG byte slice to PNG
// bytes. The returned slice is owned by allocator and must be deleted by the
// caller. The input is never modified or retained.
Convert_Bytes :: proc(
    input: []byte,
    options := DEFAULT_OPTIONS,
    allocator := context.allocator,
) -> (output: []byte, err: Error) {
    if len(input) < 2 || input[0] != 0xff || input[1] != 0xd8 {
        return nil, .Invalid_Input
    }

    image, ok := decode_jpeg(input, allocator)
    if !ok || image == nil {
        return nil, .Decode_Failed
    }
    defer destroy_jpeg_image(image)

    if image.component_count != 1 && image.component_count != 3 {
        return nil, .Unsupported_Image
    }
    if !make_idct_planes(image, options, allocator) {
        return nil, .Allocation_Failed
    }
    return encode_png(image, options, allocator)
}

// -----------------------------------------------------------------------------
// JPEG decoder
// -----------------------------------------------------------------------------

JPEG_MAX_COMPONENTS :: 4
JPEG_MAX_TABLES :: 4
JPEG_BLOCK_COEFFICIENTS :: 64
JPEG_PI :: 3.14159265358979323846

ZIGZAG := [64]int{
    0, 1, 8, 16, 9, 2, 3, 10,
    17, 24, 32, 25, 18, 11, 4, 5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6, 7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
}

Huffman_Table :: struct {
    counts:  [17]u8,
    codes:   [17][256]u16,
    symbols: [17][256]byte,
    valid:   bool,
}

JPEG_Component :: struct {
    id: byte,
    h:  int,
    v:  int,
    tq: int,

    blocks_w: int,
    blocks_h: int,
    coefficients: []i16,
    pixels: []byte,
    pixel_width: int,
    dc_predictor: int,
}

JPEG_Image :: struct {
    width: int,
    height: int,
    max_h: int,
    max_v: int,
    progressive: bool,
    component_count: int,
    components: [JPEG_MAX_COMPONENTS]JPEG_Component,
    quantization: [JPEG_MAX_TABLES][64]u16,
    allocator: runtime.Allocator,
}

JPEG_Decoder :: struct {
    data: []byte,
    pos: int,
    pending_marker: byte,
    restart_interval: int,
    quantization_cache: [JPEG_MAX_TABLES][64]u16,
    quantization_cache_valid: [JPEG_MAX_TABLES]bool,
    dc_tables: [JPEG_MAX_TABLES]Huffman_Table,
    ac_tables: [JPEG_MAX_TABLES]Huffman_Table,
    image: ^JPEG_Image,
    allocator: runtime.Allocator,
}

Scan_Component :: struct {
    component: int,
    dc_table: int,
    ac_table: int,
}

JPEG_Scan :: struct {
    components: [JPEG_MAX_COMPONENTS]Scan_Component,
    component_count: int,
    spectral_start: int,
    spectral_end: int,
    successive_high: int,
    successive_low: int,
}

Bit_Reader :: struct {
    data: []byte,
    pos: int,
    buffer: u32,
    bits: int,
    marker: byte,
}

read_u8 :: proc(d: ^JPEG_Decoder) -> (value: byte, ok: bool) {
    if d.pos >= len(d.data) {
        return 0, false
    }
    value = d.data[d.pos]
    d.pos += 1
    return value, true
}

read_u16 :: proc(d: ^JPEG_Decoder) -> (value: int, ok: bool) {
    hi, ok_hi := read_u8(d)
    lo, ok_lo := read_u8(d)
    if !ok_hi || !ok_lo {
        return 0, false
    }
    return (int(hi) << 8) | int(lo), true
}

next_marker :: proc(d: ^JPEG_Decoder) -> (marker: byte, ok: bool) {
    if d.pending_marker != 0 {
        marker = d.pending_marker
        d.pending_marker = 0
        return marker, true
    }

    for d.pos < len(d.data) && d.data[d.pos] != 0xff {
        d.pos += 1
    }
    if d.pos >= len(d.data) {
        return 0, false
    }
    for d.pos < len(d.data) && d.data[d.pos] == 0xff {
        d.pos += 1
    }
    if d.pos >= len(d.data) {
        return 0, false
    }
    marker = d.data[d.pos]
    d.pos += 1
    if marker == 0 {
        return next_marker(d)
    }
    return marker, true
}

read_segment_end :: proc(d: ^JPEG_Decoder) -> (end: int, ok: bool) {
    length, length_ok := read_u16(d)
    if !length_ok || length < 2 || d.pos+length-2 > len(d.data) {
        return 0, false
    }
    return d.pos + length - 2, true
}


parse_dht :: proc(d: ^JPEG_Decoder) -> bool {
    end, ok := read_segment_end(d)
    if !ok {
        return false
    }
    for d.pos < end {
        info, info_ok := read_u8(d)
        if !info_ok {
            return false
        }
        table_class := int(info >> 4)
        table_index := int(info & 0x0f)
        if table_class > 1 || table_index >= JPEG_MAX_TABLES {
            return false
        }

        counts: [17]u8
        total := 0
        for length := 1; length <= 16; length += 1 {
            count, count_ok := read_u8(d)
            if !count_ok {
                return false
            }
            counts[length] = count
            total += int(count)
        }
        if total > 256 || d.pos+total > end {
            return false
        }

        table: ^Huffman_Table
        if table_class == 0 {
            table = &d.dc_tables[table_index]
        } else {
            table = &d.ac_tables[table_index]
        }
        table^ = {}
        table.counts = counts
        code := 0
        for length := 1; length <= 16; length += 1 {
            for index := 0; index < int(counts[length]); index += 1 {
                symbol, symbol_ok := read_u8(d)
                if !symbol_ok {
                    return false
                }
                table.codes[length][index] = u16(code)
                table.symbols[length][index] = symbol
                code += 1
            }
            code <<= 1
        }
        table.valid = true
    }
    return d.pos == end
}

parse_sof :: proc(d: ^JPEG_Decoder, marker: byte) -> bool {
    end, ok := read_segment_end(d)
    if !ok {
        return false
    }
    precision, precision_ok := read_u8(d)
    height, height_ok := read_u16(d)
    width, width_ok := read_u16(d)
    count, count_ok := read_u8(d)
    if !precision_ok || !height_ok || !width_ok || !count_ok || precision != 8 {
        return false
    }
    if width <= 0 || height <= 0 || count < 1 || count > JPEG_MAX_COMPONENTS {
        return false
    }
    if d.image != nil {
        return false
    }

    image := new(JPEG_Image, allocator=d.allocator)
    image.width = width
    image.height = height
    image.component_count = int(count)
    image.progressive = marker == 0xc2
    image.allocator = d.allocator
    for table_index := 0; table_index < JPEG_MAX_TABLES; table_index += 1 {
        if d.quantization_cache_valid[table_index] {
            image.quantization[table_index] = d.quantization_cache[table_index]
        }
    }

    max_h := 1
    max_v := 1
    for index := 0; index < int(count); index += 1 {
        id, id_ok := read_u8(d)
        sampling, sampling_ok := read_u8(d)
        tq, tq_ok := read_u8(d)
        if !id_ok || !sampling_ok || !tq_ok {
            free(image, allocator=d.allocator)
            return false
        }
        h := int(sampling >> 4)
        v := int(sampling & 0x0f)
        if h < 1 || h > 4 || v < 1 || v > 4 || int(tq) >= JPEG_MAX_TABLES {
            free(image, allocator=d.allocator)
            return false
        }
        image.components[index] = JPEG_Component{id=id, h=h, v=v, tq=int(tq)}
        if h > max_h {
            max_h = h
        }
        if v > max_v {
            max_v = v
        }
    }
    image.max_h = max_h
    image.max_v = max_v

    mcu_width := 8 * max_h
    mcu_height := 8 * max_v
    mcu_columns := (width + mcu_width - 1) / mcu_width
    mcu_rows := (height + mcu_height - 1) / mcu_height
    for index := 0; index < int(count); index += 1 {
        component := &image.components[index]
        component.blocks_w = mcu_columns * component.h
        component.blocks_h = mcu_rows * component.v
        coefficient_count := component.blocks_w * component.blocks_h * JPEG_BLOCK_COEFFICIENTS
        coefficients, alloc_err := make([]i16, coefficient_count, d.allocator)
        if alloc_err != nil {
            for cleanup := 0; cleanup < index; cleanup += 1 {
                delete(image.components[cleanup].coefficients, d.allocator)
            }
            free(image, allocator=d.allocator)
            return false
        }
        component.coefficients = coefficients
    }
    d.image = image
    return d.pos == end
}

parse_dri :: proc(d: ^JPEG_Decoder) -> bool {
    end, ok := read_segment_end(d)
    if !ok || d.pos+2 != end {
        return false
    }
    interval, interval_ok := read_u16(d)
    if !interval_ok {
        return false
    }
    d.restart_interval = interval
    return d.pos == end
}

find_component :: proc(image: ^JPEG_Image, id: byte) -> int {
    for index := 0; index < image.component_count; index += 1 {
        if image.components[index].id == id {
            return index
        }
    }
    return -1
}

parse_sos :: proc(d: ^JPEG_Decoder) -> bool {
    if d.image == nil {
        return false
    }
    end, ok := read_segment_end(d)
    if !ok {
        return false
    }
    count, count_ok := read_u8(d)
    if !count_ok || int(count) < 1 || int(count) > d.image.component_count {
        return false
    }

    scan: JPEG_Scan
    scan.component_count = int(count)
    for index := 0; index < int(count); index += 1 {
        id, id_ok := read_u8(d)
        tables, tables_ok := read_u8(d)
        component_index := find_component(d.image, id)
        dc_table := int(tables >> 4)
        ac_table := int(tables & 0x0f)
        if !id_ok || !tables_ok || component_index < 0 || dc_table >= JPEG_MAX_TABLES || ac_table >= JPEG_MAX_TABLES {
            return false
        }
        scan.components[index] = Scan_Component{
            component = component_index,
            dc_table = dc_table,
            ac_table = ac_table,
        }
    }
    spectral_start, ss_ok := read_u8(d)
    spectral_end, se_ok := read_u8(d)
    successive, successive_ok := read_u8(d)
    if !ss_ok || !se_ok || !successive_ok || d.pos != end {
        return false
    }
    scan.spectral_start = int(spectral_start)
    scan.spectral_end = int(spectral_end)
    scan.successive_high = int(successive >> 4)
    scan.successive_low = int(successive & 0x0f)

    if scan.spectral_start > scan.spectral_end || scan.spectral_end >= 64 || scan.successive_high > 13 || scan.successive_low > 13 {
        return false
    }
    if !d.image.progressive && (scan.spectral_start != 0 || scan.spectral_end != 63 || scan.successive_high != 0 || scan.successive_low != 0) {
        return false
    }
    if d.image.progressive && scan.successive_high != 0 && scan.successive_high != scan.successive_low+1 {
        return false
    }
    return decode_scan(d, scan)
}

entropy_byte :: proc(br: ^Bit_Reader) -> (value: byte, ok: bool) {
    if br.pos >= len(br.data) {
        return 0, false
    }
    value = br.data[br.pos]
    br.pos += 1
    if value != 0xff {
        return value, true
    }
    for br.pos < len(br.data) && br.data[br.pos] == 0xff {
        br.pos += 1
    }
    if br.pos >= len(br.data) {
        return 0, false
    }
    next := br.data[br.pos]
    br.pos += 1
    if next == 0 {
        return 0xff, true
    }
    br.marker = next
    return 0, false
}

get_bit :: proc(br: ^Bit_Reader) -> (value: int, ok: bool) {
    if br.bits == 0 {
        next, byte_ok := entropy_byte(br)
        if !byte_ok {
            return 0, false
        }
        br.buffer = u32(next)
        br.bits = 8
    }
    br.bits -= 1
    return int((br.buffer >> u32(br.bits)) & 1), true
}

get_bits :: proc(br: ^Bit_Reader, count: int) -> (value: int, ok: bool) {
    value = 0
    for index := 0; index < count; index += 1 {
        bit, bit_ok := get_bit(br)
        if !bit_ok {
            return 0, false
        }
        value = (value << 1) | bit
    }
    return value, true
}

bit_align :: proc(br: ^Bit_Reader) {
    br.bits = 0
    br.buffer = 0
}

read_restart_marker :: proc(br: ^Bit_Reader) -> (marker: byte, ok: bool) {
    for br.pos < len(br.data) && br.data[br.pos] == 0xff {
        br.pos += 1
    }
    if br.pos >= len(br.data) {
        return 0, false
    }
    marker = br.data[br.pos]
    br.pos += 1
    return marker, marker >= 0xd0 && marker <= 0xd7
}

huffman_decode :: proc(br: ^Bit_Reader, table: ^Huffman_Table) -> (symbol: int, ok: bool) {
    if table == nil || !table.valid {
        return 0, false
    }
    code := 0
    for length := 1; length <= 16; length += 1 {
        bit, bit_ok := get_bit(br)
        if !bit_ok {
            return 0, false
        }
        code = (code << 1) | bit
        for index := 0; index < int(table.counts[length]); index += 1 {
            if int(table.codes[length][index]) == code {
                return int(table.symbols[length][index]), true
            }
        }
    }
    return 0, false
}

receive_extend :: proc(br: ^Bit_Reader, size: int) -> (value: int, ok: bool) {
    if size == 0 {
        return 0, true
    }
    bits, bits_ok := get_bits(br, size)
    if !bits_ok {
        return 0, false
    }
    if bits < (1 << u32(size - 1)) {
        return bits - ((1 << u32(size)) - 1), true
    }
    return bits, true
}

refine_existing_coefficient :: proc(br: ^Bit_Reader, coefficient: ^i16, bit_position: int) -> bool {
    bit, ok := get_bit(br)
    if !ok || bit == 0 {
        return ok
    }
    amount := 1 << u32(bit_position)
    value := int(coefficient^)
    if value < 0 {
        value -= amount
    } else {
        value += amount
    }
    coefficient^ = i16(value)
    return true
}

decode_block :: proc(
    d: ^JPEG_Decoder,
    br: ^Bit_Reader,
    scan: JPEG_Scan,
    scan_component: Scan_Component,
    block_index: int,
    eob_run: ^int,
) -> bool {
    component := &d.image.components[scan_component.component]
    start := block_index * JPEG_BLOCK_COEFFICIENTS
    block := component.coefficients[start:start+JPEG_BLOCK_COEFFICIENTS]
    dc_table := &d.dc_tables[scan_component.dc_table]
    ac_table := &d.ac_tables[scan_component.ac_table]

    ss := scan.spectral_start
    se := scan.spectral_end
    ah := scan.successive_high
    al := scan.successive_low
    progressive := d.image.progressive

    if !progressive {
        if ss != 0 || se != 63 || ah != 0 || al != 0 {
            return false
        }
        category, category_ok := huffman_decode(br, dc_table)
        if !category_ok || category > 11 {
            return false
        }
        difference, difference_ok := receive_extend(br, category)
        if !difference_ok {
            return false
        }
        component.dc_predictor += difference
        block[0] = i16(component.dc_predictor)

        k := 1
        for k <= 63 {
            value, value_ok := huffman_decode(br, ac_table)
            if !value_ok {
                return false
            }
            run := value >> 4
            size := value & 0x0f
            if size == 0 {
                if run == 15 {
                    k += 16
                    continue
                }
                break
            }
            if size > 10 {
                return false
            }
            k += run
            if k > 63 {
                return false
            }
            coefficient, coefficient_ok := receive_extend(br, size)
            if !coefficient_ok {
                return false
            }
            block[ZIGZAG[k]] = i16(coefficient)
            k += 1
        }
        return true
    }

    if ss == 0 {
        if ah != 0 {
            if bit, bit_ok := get_bit(br); !bit_ok {
                return false
            } else if bit != 0 {
                amount := 1 << u32(al)
                if block[0] < 0 {
                    block[0] -= i16(amount)
                } else {
                    block[0] += i16(amount)
                }
            }
            return true
        }
        category, category_ok := huffman_decode(br, dc_table)
        if !category_ok || category > 11 {
            return false
        }
        difference, difference_ok := receive_extend(br, category)
        if !difference_ok {
            return false
        }
        component.dc_predictor += difference
        block[0] = i16(component.dc_predictor << u32(al))
        return true
    }

    if ah == 0 {
        k := ss
        if eob_run^ > 0 {
            eob_run^ -= 1
            return true
        }
        for k <= se {
            value, value_ok := huffman_decode(br, ac_table)
            if !value_ok {
                return false
            }
            run := value >> 4
            size := value & 0x0f
            if size == 0 {
                if run == 15 {
                    k += 16
                    continue
                }
                extra, extra_ok := get_bits(br, run)
                if !extra_ok {
                    return false
                }
                eob_run^ = (1 << u32(run)) + extra - 1
                break
            }
            k += run
            if k > se {
                return false
            }
            coefficient, coefficient_ok := receive_extend(br, size)
            if !coefficient_ok {
                return false
            }
            block[ZIGZAG[k]] = i16(coefficient << u32(al))
            k += 1
        }
        return true
    }

    // AC successive approximation. The Huffman symbol is decoded first, even
    // when the current coefficient is already non-zero. Existing coefficients
    // consume refinement bits while the symbol's zero run is advanced.
    p1: int = 1 << u32(al)
    m1: int = -p1
    k := ss
    if eob_run^ > 0 {
        for k <= se {
            index := ZIGZAG[k]
            if block[index] != 0 && !refine_existing_coefficient(br, &block[index], al) {
                return false
            }
            k += 1
        }
        eob_run^ -= 1
        return true
    }

    for k <= se {
        value, value_ok := huffman_decode(br, ac_table)
        if !value_ok {
            return false
        }
        run := value >> 4
        size := value & 0x0f
        new_coefficient: int = 0
        if size == 0 {
            if run < 15 {
                extra, extra_ok := get_bits(br, run)
                if !extra_ok {
                    return false
                }
                eob_run^ = (1 << u32(run)) + extra - 1
                run = 64
            }
        } else {
            if size != 1 {
                return false
            }
            sign_bit, sign_ok := get_bit(br)
            if !sign_ok {
                return false
            }
            new_coefficient = p1
            if sign_bit == 0 {
                new_coefficient = m1
            }
        }

        for k <= se {
            index := ZIGZAG[k]
            k += 1
            if block[index] != 0 {
                if !refine_existing_coefficient(br, &block[index], al) {
                    return false
                }
            } else if run == 0 {
                if size != 0 {
                    block[index] = i16(new_coefficient)
                }
                break
            } else {
                run -= 1
            }
        }
    }
    return true
}

reset_predictors :: proc(image: ^JPEG_Image) {
    for index := 0; index < image.component_count; index += 1 {
        image.components[index].dc_predictor = 0
    }
}

decode_scan :: proc(d: ^JPEG_Decoder, scan: JPEG_Scan) -> bool {
    if scan.component_count == 0 {
        return false
    }
    br := Bit_Reader{data=d.data, pos=d.pos}
    eob_run := 0
    interleaved := scan.component_count > 1
    total_units := 0

    if interleaved {
        mcu_width := 8 * d.image.max_h
        mcu_height := 8 * d.image.max_v
        mcu_columns := (d.image.width + mcu_width - 1) / mcu_width
        mcu_rows := (d.image.height + mcu_height - 1) / mcu_height
        total_units = mcu_columns * mcu_rows
        for mcu_y := 0; mcu_y < mcu_rows; mcu_y += 1 {
            for mcu_x := 0; mcu_x < mcu_columns; mcu_x += 1 {
                for scan_index := 0; scan_index < scan.component_count; scan_index += 1 {
                    selected := scan.components[scan_index]
                    component := &d.image.components[selected.component]
                    for by := 0; by < component.v; by += 1 {
                        for bx := 0; bx < component.h; bx += 1 {
                            block_x := mcu_x * component.h + bx
                            block_y := mcu_y * component.v + by
                            block_index := block_y * component.blocks_w + block_x
                            if !decode_block(d, &br, scan, selected, block_index, &eob_run) {
                                return false
                            }
                        }
                    }
                }
                unit_index := mcu_y*mcu_columns + mcu_x + 1
                if d.restart_interval > 0 && unit_index < total_units && unit_index % d.restart_interval == 0 {
                    bit_align(&br)
                    marker, marker_ok := read_restart_marker(&br)
                    if !marker_ok {
                        return false
                    }
                    reset_predictors(d.image)
                    eob_run = 0
                    _ = marker
                }
            }
        }
    } else {
        selected := scan.components[0]
        component := &d.image.components[selected.component]
        total_units = component.blocks_w * component.blocks_h
        unit_index := 0
        for block_y := 0; block_y < component.blocks_h; block_y += 1 {
            for block_x := 0; block_x < component.blocks_w; block_x += 1 {
                block_index := block_y * component.blocks_w + block_x
                if !decode_block(d, &br, scan, selected, block_index, &eob_run) {
                    return false
                }
                unit_index += 1
                if d.restart_interval > 0 && unit_index < total_units && unit_index % d.restart_interval == 0 {
                    bit_align(&br)
                    marker, marker_ok := read_restart_marker(&br)
                    if !marker_ok {
                        return false
                    }
                    reset_predictors(d.image)
                    eob_run = 0
                    _ = marker
                }
            }
        }
    }

    bit_align(&br)
    d.pos = br.pos
    if br.marker != 0 {
        d.pending_marker = br.marker
    }
    return true
}

decode_jpeg :: proc(data: []byte, allocator: runtime.Allocator) -> (image: ^JPEG_Image, ok: bool) {
    d := JPEG_Decoder{data=data, allocator=allocator}
    soi_hi, soi_hi_ok := read_u8(&d)
    soi_lo, soi_lo_ok := read_u8(&d)
    if !soi_hi_ok || !soi_lo_ok || soi_hi != 0xff || soi_lo != 0xd8 {
        return nil, false
    }

    saw_eoi := false
    for {
        marker, marker_ok := next_marker(&d)
        if !marker_ok {
            break
        }
        switch marker {
        case 0xd9:
            saw_eoi = true
        case 0xdb:
            if d.image == nil {
                // Quantization tables are allowed before SOF, so parse into a
                // small temporary decoder table is not necessary: JPEG files
                // conventionally place DQT before SOF, but we handle both by
                // delaying only the table values in this local storage.
                // The image is created at SOF; this branch is handled below by
                // the decoder's pending quantization cache.
            }
            if !parse_dqt_for_decoder(&d) {
                return nil, false
            }
        case 0xc0, 0xc1, 0xc2:
            if !parse_sof(&d, marker) {
                return nil, false
            }
        case 0xc4:
            if !parse_dht(&d) {
                return nil, false
            }
        case 0xdd:
            if !parse_dri(&d) {
                return nil, false
            }
        case 0xda:
            if !parse_sos(&d) {
                return nil, false
            }
        case 0xe0 ..= 0xef, 0xfe:
            end, segment_ok := read_segment_end(&d)
            if !segment_ok {
                return nil, false
            }
            d.pos = end
        case 0xd0 ..= 0xd7, 0x01:
            return nil, false
        case:
            // TEM and restart markers are handled only inside entropy-coded
            // scans. Arithmetic-coded frames and other SOF variants are not
            // part of this 8-bit Huffman decoder.
            if marker >= 0xc0 && marker <= 0xcf {
                return nil, false
            }
            end, segment_ok := read_segment_end(&d)
            if !segment_ok {
                return nil, false
            }
            d.pos = end
        }
        if saw_eoi {
            break
        }
    }
    if !saw_eoi || d.image == nil {
        if d.image != nil {
            destroy_jpeg_image(d.image)
        }
        return nil, false
    }
    // Tables parsed before SOF are copied by parse_dqt_for_decoder once the
    // image exists; dimensions and coefficient storage are now complete.
    return d.image, true
}

// DQT is commonly before SOF. Keep tables in the decoder itself while parsing,
// then copy them into the image whenever the frame becomes available.
parse_dqt_for_decoder :: proc(d: ^JPEG_Decoder) -> bool {
    end, ok := read_segment_end(d)
    if !ok {
        return false
    }
    // Keep a decoder-side copy because DQT is commonly emitted before SOF.
    // Once SOF has been parsed, also update the image's active table.
    for d.pos < end {
        info, info_ok := read_u8(d)
        if !info_ok {
            return false
        }
        precision := int(info >> 4)
        table_index := int(info & 0x0f)
        if precision != 0 || table_index >= JPEG_MAX_TABLES || d.pos+64 > end {
            return false
        }
        values: [64]u16
        for i := 0; i < 64; i += 1 {
            value, value_ok := read_u8(d)
            if !value_ok {
                return false
            }
            values[ZIGZAG[i]] = u16(value)
        }
        if d.image != nil {
            d.image.quantization[table_index] = values
        }

        d.quantization_cache[table_index] = values
        d.quantization_cache_valid[table_index] = true
    }
    return d.pos == end
}

make_idct_planes :: proc(image: ^JPEG_Image, options: Options, allocator: runtime.Allocator) -> bool {
    total_blocks := 0
    for component_index := 0; component_index < image.component_count; component_index += 1 {
        component := &image.components[component_index]
        component.pixel_width = component.blocks_w * 8
        pixel_count := component.pixel_width * component.blocks_h * 8
        pixels, alloc_err := make([]byte, pixel_count, allocator)
        if alloc_err != nil {
            return false
        }
        component.pixels = pixels
        total_blocks += component.blocks_w * component.blocks_h
    }

    tasks, tasks_err := make([]IDCT_Task, total_blocks, allocator)
    if tasks_err != nil {
        return false
    }
    defer delete(tasks, allocator)

    worker_count := options.workers
    if worker_count <= 0 {
        worker_count = 4
    }
    if worker_count < 1 {
        worker_count = 1
    }
    if worker_count > total_blocks {
        worker_count = total_blocks
    }

    pool: thread.Pool
    thread.pool_init(&pool, allocator, worker_count)
    thread.pool_start(&pool)
    task_index := 0
    for component_index := 0; component_index < image.component_count; component_index += 1 {
        component := &image.components[component_index]
        for block_index := 0; block_index < component.blocks_w*component.blocks_h; block_index += 1 {
            tasks[task_index] = IDCT_Task{
                coefficients = component.coefficients[block_index*64:block_index*64+64],
                quantization = image.quantization[component.tq],
                pixels = component.pixels,
                pixel_width = component.pixel_width,
                block_x = (block_index % component.blocks_w) * 8,
                block_y = (block_index / component.blocks_w) * 8,
            }
            thread.pool_add_task(&pool, allocator, idct_block, &tasks[task_index], task_index)
            task_index += 1
        }
    }
    thread.pool_finish(&pool)
    thread.pool_destroy(&pool)
    return true
}

IDCT_Task :: struct {
    coefficients: []i16,
    quantization: [64]u16,
    pixels: []byte,
    pixel_width: int,
    block_x: int,
    block_y: int,
}

idct_block :: proc(task: thread.Task) {
    work := cast(^IDCT_Task)task.data
    if work == nil {
        return
    }
    for y := 0; y < 8; y += 1 {
        for x := 0; x < 8; x += 1 {
            sum: f64 = 0
            for v := 0; v < 8; v += 1 {
                cv: f64 = 1
                if v == 0 {
                    cv = 0.7071067811865476
                }
                y_angle := f64((2*y+1)*v) * JPEG_PI / 16.0
                for u := 0; u < 8; u += 1 {
                    cu: f64 = 1
                    if u == 0 {
                        cu = 0.7071067811865476
                    }
                    x_angle := f64((2*x+1)*u) * JPEG_PI / 16.0
                    coefficient := f64(work.coefficients[v*8+u]) * f64(work.quantization[v*8+u])
                    sum += cu * cv * coefficient * math.cos(x_angle) * math.cos(y_angle)
                }
            }
            sample := int(math.round(sum / 4.0 + 128.0))
            if sample < 0 {
                sample = 0
            } else if sample > 255 {
                sample = 255
            }
            destination := (work.block_y+y)*work.pixel_width + work.block_x + x
            work.pixels[destination] = byte(sample)
        }
    }
}

encode_png :: proc(image: ^JPEG_Image, options: Options, allocator: runtime.Allocator) -> (output: []byte, err: Error) {
    filtered_size := image.width * 3 + 1
    filtered, alloc_err := make([]byte, image.height*filtered_size, allocator)
    if alloc_err != nil {
        return nil, .Allocation_Failed
    }
    defer delete(filtered, allocator)

    tasks, tasks_err := make([]Color_Row_Task, image.height, allocator)
    if tasks_err != nil {
        return nil, .Allocation_Failed
    }
    defer delete(tasks, allocator)

    worker_count := options.workers
    if worker_count <= 0 {
        worker_count = 4
    }
    if worker_count < 1 {
        worker_count = 1
    }
    if worker_count > image.height {
        worker_count = image.height
    }

    pool: thread.Pool
    thread.pool_init(&pool, allocator, worker_count)
    thread.pool_start(&pool)
    for y := 0; y < image.height; y += 1 {
        start := y * filtered_size
        tasks[y] = Color_Row_Task{
            image = image,
            destination = filtered[start:start+filtered_size],
            width = image.width,
            row = y,
        }
        thread.pool_add_task(&pool, allocator, convert_color_row, &tasks[y], y)
    }
    thread.pool_finish(&pool)
    thread.pool_destroy(&pool)
    return make_png(filtered, image.width, image.height, 3, allocator)
}

Color_Row_Task :: struct {
    image:       ^JPEG_Image,
    destination: []byte,
    width:       int,
    row:         int,
}

sample_component :: proc(component: ^JPEG_Component, x, y, max_h, max_v: int) -> byte {
    sample_x := (x * component.h) / max_h
    sample_y := (y * component.v) / max_v
    if sample_x >= component.pixel_width {
        sample_x = component.pixel_width - 1
    }
    pixel_height := len(component.pixels) / component.pixel_width
    if sample_y >= pixel_height {
        sample_y = pixel_height - 1
    }
    return component.pixels[sample_y*component.pixel_width+sample_x]
}

clamp_byte :: proc(value: int) -> byte {
    if value < 0 {
        return 0
    }
    if value > 255 {
        return 255
    }
    return byte(value)
}

convert_color_row :: proc(task: thread.Task) {
    work := cast(^Color_Row_Task)task.data
    if work == nil {
        return
    }
    image := work.image
    destination := work.destination
    destination[0] = 0
    gray_index := find_component(image, image.components[0].id)
    cb_index := find_component(image, 2)
    cr_index := find_component(image, 3)
    // Component identifiers are normally 1, 2, 3. If an encoder uses other
    // identifiers, use frame order for the chroma components.
    if image.component_count == 3 && (cb_index < 0 || cr_index < 0) {
        cb_index = 1
        cr_index = 2
        gray_index = 0
    }

    if image.component_count == 1 {
        for x := 0; x < work.width; x += 1 {
            value := int(sample_component(&image.components[gray_index], x, work.row, image.max_h, image.max_v))
            destination[x*3+1] = byte(value)
            destination[x*3+2] = byte(value)
            destination[x*3+3] = byte(value)
        }
    } else {
        red_scale := simd.f64x4{1.40200, 1.40200, 1.40200, 1.40200}
        green_cb_scale := simd.f64x4{0.34414, 0.34414, 0.34414, 0.34414}
        green_cr_scale := simd.f64x4{0.71414, 0.71414, 0.71414, 0.71414}
        blue_scale := simd.f64x4{1.77200, 1.77200, 1.77200, 1.77200}
        x := 0
        for x+4 <= work.width {
            y_values: [4]f64
            cb_values: [4]f64
            cr_values: [4]f64
            for lane := 0; lane < 4; lane += 1 {
                pixel_x := x + lane
                y_values[lane] = f64(sample_component(&image.components[gray_index], pixel_x, work.row, image.max_h, image.max_v))
                cb_values[lane] = f64(sample_component(&image.components[cb_index], pixel_x, work.row, image.max_h, image.max_v)) - 128.0
                cr_values[lane] = f64(sample_component(&image.components[cr_index], pixel_x, work.row, image.max_h, image.max_v)) - 128.0
            }
            y_vector: simd.f64x4 = simd.from_array(y_values)
            cb_vector: simd.f64x4 = simd.from_array(cb_values)
            cr_vector: simd.f64x4 = simd.from_array(cr_values)
            red_vector := simd.add(y_vector, simd.mul(cr_vector, red_scale))
            green_vector := simd.sub(y_vector, simd.add(simd.mul(cb_vector, green_cb_scale), simd.mul(cr_vector, green_cr_scale)))
            blue_vector := simd.add(y_vector, simd.mul(cb_vector, blue_scale))
            red_values: [4]f64 = simd.to_array(simd.nearest(red_vector))
            green_values: [4]f64 = simd.to_array(simd.nearest(green_vector))
            blue_values: [4]f64 = simd.to_array(simd.nearest(blue_vector))
            for lane := 0; lane < 4; lane += 1 {
                pixel_x := x + lane
                destination[pixel_x*3+1] = clamp_byte(int(red_values[lane]))
                destination[pixel_x*3+2] = clamp_byte(int(green_values[lane]))
                destination[pixel_x*3+3] = clamp_byte(int(blue_values[lane]))
            }
            x += 4
        }
        for x < work.width {
            y_value := int(sample_component(&image.components[gray_index], x, work.row, image.max_h, image.max_v))
            cb := int(sample_component(&image.components[cb_index], x, work.row, image.max_h, image.max_v)) - 128
            cr := int(sample_component(&image.components[cr_index], x, work.row, image.max_h, image.max_v)) - 128
            destination[x*3+1] = clamp_byte(int(math.round(f64(y_value) + 1.40200*f64(cr))))
            destination[x*3+2] = clamp_byte(int(math.round(f64(y_value) - 0.34414*f64(cb) - 0.71414*f64(cr))))
            destination[x*3+3] = clamp_byte(int(math.round(f64(y_value) + 1.77200*f64(cb))))
            x += 1
        }
    }

    // SIMD vector loads/stores provide a fast final pass over the tightly
    // packed RGB row. The first byte is the PNG filter byte and is skipped.
    pixels := destination[1:]
    vector_count := len(pixels) / 16
    for vector_index := 0; vector_index < vector_count; vector_index += 1 {
        offset := vector_index * 16
        value := simd.from_slice(simd.u8x16, pixels[offset:offset+16])
        simd.masked_store(
            rawptr(&pixels[offset]),
            value,
            simd.u8x16{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
        )
    }
}

destroy_jpeg_image :: proc(image: ^JPEG_Image) {
    if image == nil {
        return
    }
    for index := 0; index < image.component_count; index += 1 {
        delete(image.components[index].coefficients, image.allocator)
        delete(image.components[index].pixels, image.allocator)
    }
    free(image, allocator=image.allocator)
}

// -----------------------------------------------------------------------------
// PNG writer
// -----------------------------------------------------------------------------

make_png :: proc(
    scanlines: []byte,
    width: int,
    height: int,
    channels: int,
    allocator: runtime.Allocator,
) -> (result: []byte, err: Error) {
    color_type: byte
    if channels == 3 {
        color_type = 2
    } else if channels == 4 {
        color_type = 6
    } else {
        return nil, .Unsupported_Image
    }

    // Stored DEFLATE blocks are simple, portable, and keep the expensive JPEG
    // decode/IDCT and row conversion stages parallel. The result is a valid
    // PNG; it can be replaced with a parallel deflater without changing the
    // package API.
    zlib_size := 2 + len(scanlines) + ((len(scanlines) + 65534) / 65535) * 5 + 4
    allocated, alloc_err := make([]byte, 8+25+12+zlib_size+12, allocator)
    if alloc_err != nil {
        return nil, .Allocation_Failed
    }
    result = allocated

    at := 0
    append_bytes(result, &at, []byte{0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a})

    ihdr: [13]byte
    put_u32(ihdr[:], 0, u32(width))
    put_u32(ihdr[:], 4, u32(height))
    ihdr[8] = 8
    ihdr[9] = color_type
    ihdr[10] = 0
    ihdr[11] = 0
    ihdr[12] = 0
    write_chunk(result, &at, "IHDR", ihdr[:])

    idat_start := at
    put_u32(result, at, 0)
    at += 4
    result[at+0] = 'I'
    result[at+1] = 'D'
    result[at+2] = 'A'
    result[at+3] = 'T'
    at += 4
    zlib_start := at
    result[at] = 0x78
    result[at+1] = 0x01
    at += 2

    adler_a: u32 = 1
    adler_b: u32 = 0
    input_at := 0
    remaining := len(scanlines)
    for remaining > 0 {
        block_size := remaining
        if block_size > 65535 {
            block_size = 65535
        }
        if remaining == block_size {
            result[at] = 1
        } else {
            result[at] = 0
        }
        at += 1
        // Stored DEFLATE block lengths are little-endian, unlike PNG
        // chunk fields and the JPEG fields written elsewhere in this file.
        put_u16_le(result, at, u16(block_size))
        put_u16_le(result, at+2, ~u16(block_size))
        at += 4
        for i := 0; i < block_size; i += 1 {
            value := scanlines[input_at+i]
            result[at] = value
            at += 1
            adler_a = (adler_a + u32(value)) % 65521
            adler_b = (adler_b + adler_a) % 65521
        }
        input_at += block_size
        remaining -= block_size
    }
    put_u32(result, at, (adler_b << 16) | adler_a)
    at += 4

    idat_length := at - zlib_start
    put_u32(result, idat_start, u32(idat_length))
    put_u32(result, at, crc32(result[idat_start+4:at]))
    at += 4

    write_chunk(result, &at, "IEND", nil)
    return result[:at], .None
}

append_bytes :: proc(dst: []byte, at: ^int, src: []byte) {
    for value in src {
        dst[at^] = value
        at^ += 1
    }
}

write_chunk :: proc(dst: []byte, at: ^int, kind: string, data: []byte) {
    put_u32(dst, at^, u32(len(data)))
    at^ += 4
    for i := 0; i < 4; i += 1 {
        dst[at^+i] = kind[i]
    }
    at^ += 4
    append_bytes(dst, at, data)
    put_u32(dst, at^, crc32(dst[at^-len(data)-4:at^]))
    at^ += 4
}

put_u16 :: proc(dst: []byte, at: int, value: u16) {
    dst[at+0] = byte(value >> 8)
    dst[at+1] = byte(value)
}

put_u16_le :: proc(dst: []byte, at: int, value: u16) {
    dst[at+0] = byte(value)
    dst[at+1] = byte(value >> 8)
}

put_u32 :: proc(dst: []byte, at: int, value: u32) {
    dst[at+0] = byte(value >> 24)
    dst[at+1] = byte(value >> 16)
    dst[at+2] = byte(value >> 8)
    dst[at+3] = byte(value)
}

crc32 :: proc(data: []byte) -> u32 {
    crc: u32 = 0xffff_ffff
    for value in data {
        crc = crc ~ u32(value)
        for bit := 0; bit < 8; bit += 1 {
            mask := u32(0) - (crc & 1)
            crc = (crc >> 1) ~ (0xedb8_8320 & mask)
        }
    }
    return ~crc
}
