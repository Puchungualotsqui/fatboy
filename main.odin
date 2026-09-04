package main

import "core:fmt"
import "core:strings"
import "core:encoding/json"
import endian "core:encoding/endian"
import "core:mem"
import "core:thread"
import "core:os"
import "base:runtime"

import curl "vendor:curl"
import jpegpng "jpegpng"
import orui "orui"
import tinyfd "tinyfiledialogs"
import rl "vendor:raylib"


WINDOW_WIDTH  :: 1280
WINDOW_HEIGHT :: 800
WINDOW_TITLE  :: "FitDeck"

FITGIRL_API_URL :: "https://fitgirl-repacks.site/wp-json/wp/v2/posts?per_page=30"

SETTINGS_FILE    :: "settings.bin"
SETTINGS_VERSION :: u32(1)

RELEASE_ROW_HEIGHT :: 96
RELEASE_ROW_EXTENT :: 106


// ---------------------------------------------------------
// Palette
// ---------------------------------------------------------

APP_BACKGROUND        :: rl.Color{24, 24, 24, 255}
HEADER_BACKGROUND     :: rl.Color{32, 32, 32, 255}
LIST_BACKGROUND       :: rl.Color{24, 24, 24, 255}
ROW_BACKGROUND        :: rl.Color{38, 38, 38, 255}
ROW_HOVER_BACKGROUND  :: rl.Color{48, 48, 48, 255}
ROW_FOCUS_BACKGROUND  :: rl.Color{75, 75, 75, 255}
ACCENT_COLOR          :: rl.Color{180, 180, 180, 255}
TEXT_PRIMARY          :: rl.Color{225, 225, 225, 255}
TEXT_MUTED            :: rl.Color{140, 140, 140, 255}
BORDER_COLOR          :: rl.Color{55, 55, 55, 255}
STATUS_OK             :: rl.Color{120, 175, 135, 255}
STATUS_ERR            :: rl.Color{175, 120, 120, 255}


// ---------------------------------------------------------
// 1. App State & Data Structures
// ---------------------------------------------------------

AppScreen :: enum {
    SetupKey,
    Loading,
    Library,
}


GameRelease :: struct {
    title:      string,
    magnetLink: string,
    coverUrl:   string,
    coverPath:  string,
    coverTex:   rl.Texture2D,
}


DownloadTask :: struct {
    game_ptr: ^GameRelease,
}


// IMPORTANT:
// LoaderData is exclusively owned by the loader thread until the
// loader thread finishes. The main thread only reads it after
// thread.is_done() + thread.destroy(), avoiding App data races.
LoaderData :: struct {
    games:         [dynamic]GameRelease,
    success:       bool,
    error_message: string,
}


App :: struct {
    screen:               AppScreen,
    rd_key:               string,
    rd_key_input: strings.Builder,
    download_path: string,

    load_status: string,
    games:       [dynamic]GameRelease,

    loader_thread: ^thread.Thread,
    loader_data:   ^LoaderData,

    selected_game:  int,
    status_message: string,
}


// ---------------------------------------------------------
// 2. Utility / Lifetime Functions
// ---------------------------------------------------------

sanitize_filename :: proc(
    name: string,
    alloc := context.allocator,
) -> string {
    b: strings.Builder
    strings.builder_init(&b, alloc)

    for r in name {
        if (r >= 'A' && r <= 'Z') ||
           (r >= 'a' && r <= 'z') ||
           (r >= '0' && r <= '9') {
            strings.write_rune(&b, r)
        } else if r == ' ' || r == '-' {
            strings.write_rune(&b, '_')
        }
    }

    // Ownership of the builder's backing buffer is intentionally
    // transferred to the returned string.
    return strings.to_string(b)
}


DestroyGame :: proc(game: ^GameRelease) {
    if game == nil {
        return
    }

    if game.coverTex.id != 0 {
        rl.UnloadTexture(game.coverTex)
        game.coverTex = {}
    }

    if len(game.title) > 0 {
        delete(game.title)
        game.title = ""
    }

    if len(game.magnetLink) > 0 {
        delete(game.magnetLink)
        game.magnetLink = ""
    }

    if len(game.coverUrl) > 0 {
        delete(game.coverUrl)
        game.coverUrl = ""
    }

    if len(game.coverPath) > 0 {
        delete(game.coverPath)
        game.coverPath = ""
    }
}


DestroyGames :: proc(games: [dynamic]GameRelease) {
    for &game in games {
        DestroyGame(&game)
    }

    delete(games)
}


// ---------------------------------------------------------
// Settings
// ---------------------------------------------------------

// The settings file is deliberately a small, explicit binary format:
//
//   bytes 0..3   magic (FDS1)
//   bytes 4..7   little-endian format version
//   bytes 8..11  little-endian API key byte length
//   bytes 12..15 little-endian download path byte length
//   remaining    API key followed by download path
//
// Length-prefixed strings keep the format unambiguous and leave room for
// future versions without relying on Odin's in-memory struct layout.
EnsureDownloadDirectory :: proc(path: string) -> bool {
    if len(path) == 0 {
        return false
    }

    if !os.exists(path) {
        mkdir_err := os.make_directory_all(path)
        if mkdir_err != nil {
            fmt.printf(
                "[SETTINGS] ERROR: failed creating download folder: %v\n",
                mkdir_err,
            )
            return false
        }
    }

    return os.is_directory(path)
}


SaveSettings :: proc(app: ^App) -> bool {
    if app == nil || len(app.rd_key) == 0 || len(app.download_path) == 0 {
        return false
    }

    settings_size := 16 + len(app.rd_key) + len(app.download_path)
    settings_data, alloc_err := make(
        []byte,
        settings_size,
        context.allocator,
    )

    if alloc_err != nil {
        fmt.printf(
            "[SETTINGS] ERROR: could not allocate settings buffer: %v\n",
            alloc_err,
        )
        return false
    }
    defer delete(settings_data)

    settings_data[0] = 'F'
    settings_data[1] = 'D'
    settings_data[2] = 'S'
    settings_data[3] = '1'

    endian.put_u32(
        settings_data[4:8],
        .Little,
        SETTINGS_VERSION,
    )
    endian.put_u32(
        settings_data[8:12],
        .Little,
        u32(len(app.rd_key)),
    )
    endian.put_u32(
        settings_data[12:16],
        .Little,
        u32(len(app.download_path)),
    )

    offset := 16
    copy(
        settings_data[offset:offset+len(app.rd_key)],
        transmute([]byte)app.rd_key,
    )
    offset += len(app.rd_key)
    copy(
        settings_data[offset:offset+len(app.download_path)],
        transmute([]byte)app.download_path,
    )

    write_err := os.write_entire_file(
        SETTINGS_FILE,
        settings_data,
    )

    if write_err != nil {
        fmt.printf(
            "[SETTINGS] ERROR: failed writing %s: %v\n",
            SETTINGS_FILE,
            write_err,
        )
        return false
    }

    fmt.printf(
        "[SETTINGS] Saved version %d to %s\n",
        SETTINGS_VERSION,
        SETTINGS_FILE,
    )
    return true
}


LoadSettings :: proc(app: ^App) -> bool {
    if app == nil {
        return false
    }

    settings_data, read_err := os.read_entire_file_from_path(
        SETTINGS_FILE,
        context.allocator,
    )

    if read_err != nil {
        return false
    }
    defer delete(settings_data)

    if len(settings_data) < 16 {
        fmt.printf(
            "[SETTINGS] Ignoring truncated %s\n",
            SETTINGS_FILE,
        )
        return false
    }

    if string(settings_data[0:4]) != "FDS1" {
        fmt.printf(
            "[SETTINGS] Ignoring %s with an invalid header\n",
            SETTINGS_FILE,
        )
        return false
    }

    version, version_ok := endian.get_u32(
        settings_data[4:8],
        .Little,
    )
    if !version_ok || version != SETTINGS_VERSION {
        fmt.printf(
            "[SETTINGS] Unsupported settings version %d (expected %d)\n",
            version,
            SETTINGS_VERSION,
        )
        return false
    }

    key_len_u32, key_len_ok := endian.get_u32(
        settings_data[8:12],
        .Little,
    )
    path_len_u32, path_len_ok := endian.get_u32(
        settings_data[12:16],
        .Little,
    )

    payload_len := len(settings_data) - 16
    if !key_len_ok || !path_len_ok ||
       u64(key_len_u32) + u64(path_len_u32) > u64(payload_len) {
        fmt.printf(
            "[SETTINGS] Ignoring %s with invalid string lengths\n",
            SETTINGS_FILE,
        )
        return false
    }

    key_len := int(key_len_u32)
    path_len := int(path_len_u32)
    key_start := 16
    path_start := key_start + key_len

    loaded_key := strings.clone(
        string(settings_data[key_start:path_start]),
        context.allocator,
    )
    loaded_path := strings.clone(
        string(settings_data[path_start:path_start+path_len]),
        context.allocator,
    )

    if len(loaded_key) == 0 || len(loaded_path) == 0 {
        delete(loaded_key)
        delete(loaded_path)
        fmt.printf(
            "[SETTINGS] Ignoring %s with missing required values\n",
            SETTINGS_FILE,
        )
        return false
    }

    if !EnsureDownloadDirectory(loaded_path) {
        delete(loaded_key)
        delete(loaded_path)
        fmt.printf(
            "[SETTINGS] Ignoring %s with unusable download folder\n",
            SETTINGS_FILE,
        )
        return false
    }

    if len(app.rd_key) > 0 {
        delete(app.rd_key)
    }
    if len(app.download_path) > 0 {
        delete(app.download_path)
    }

    app.rd_key = loaded_key
    app.download_path = loaded_path

    fmt.printf(
        "[SETTINGS] Loaded version %d from %s\n",
        version,
        SETTINGS_FILE,
    )
    return true
}


// ---------------------------------------------------------
// 3. CURL Callback
// ---------------------------------------------------------

CurlWriteCallback :: proc "c" (
    ptr: rawptr,
    elementSize, elementCount: uint,
    userData: rawptr,
) -> uint {
    // curl invokes this callback from whichever thread owns the
    // easy handle, so establish a valid Odin context here.
    context = runtime.default_context()

    actualSize := elementSize * elementCount

    if ptr == nil || userData == nil || actualSize == 0 {
        return 0
    }

    builder := cast(^strings.Builder)userData

    data := mem.slice_ptr(
        cast(^byte)ptr,
        int(actualSize),
    )

    strings.write_bytes(builder, data)

    return actualSize
}


// ---------------------------------------------------------
// 4. HTTP Catalog
// ---------------------------------------------------------

FetchLiveCatalog :: proc() -> string {
    builder: strings.Builder
    strings.builder_init(&builder, context.allocator)
    defer strings.builder_destroy(&builder)

    fmt.printf(
        "[HTTP] Catalog URL: %s\n",
        FITGIRL_API_URL,
    )

    fmt.println("[HTTP] curl.easy_init()...")

    handle := curl.easy_init()

    if handle == nil {
        fmt.println("[HTTP] ERROR: curl.easy_init returned nil")
        return ""
    }

    defer curl.easy_cleanup(handle)

    cstrUrl := strings.clone_to_cstring(
        FITGIRL_API_URL,
        context.allocator,
    )
    defer delete(cstrUrl)

    curl.easy_setopt(handle, .URL, cstrUrl)
    curl.easy_setopt(handle, .FOLLOWLOCATION, 1)
    curl.easy_setopt(
        handle,
        .USERAGENT,
        "Mozilla/5.0 (X11; Linux x86_64) FitDeck/1.0",
    )
    curl.easy_setopt(handle, .TIMEOUT, 20)
    curl.easy_setopt(handle, .ACCEPT_ENCODING, "")
    curl.easy_setopt(handle, .WRITEFUNCTION, CurlWriteCallback)
    curl.easy_setopt(handle, .WRITEDATA, &builder)

    fmt.println("[HTTP] Performing catalog request...")

    result := curl.easy_perform(handle)

    fmt.printf(
        "[HTTP] Catalog result=%v bytes=%d\n",
        result,
        len(builder.buf),
    )

    if result != .E_OK {
        fmt.printf(
            "[HTTP] ERROR: Catalog request failed: %v\n",
            result,
        )
        return ""
    }

    if len(builder.buf) == 0 {
        fmt.println("[HTTP] ERROR: Catalog response was empty")
        return ""
    }

    // Detect obvious HTML error/challenge pages before giving the
    // response to the JSON parser.
    check_len := min(len(builder.buf), 256)
    response_head := string(builder.buf[:check_len])

    if strings.contains(response_head, "<!DOCTYPE") ||
       strings.contains(response_head, "<html") ||
       strings.contains(response_head, "<HTML") {
        fmt.println(
            "[HTTP] ERROR: Catalog endpoint returned HTML instead of JSON",
        )
        return ""
    }

    fmt.println("[HTTP] Catalog download completed successfully")

    return strings.clone(
        strings.to_string(builder),
        context.allocator,
    )
}


// ---------------------------------------------------------
// 5. HTML Extraction
// ---------------------------------------------------------

ExtractMagnet :: proc(html: string) -> string {
    prefix := "magnet:?xt=urn:btih:"

    index := strings.index(html, prefix)

    if index == -1 {
        return ""
    }

    rest := html[index:]

    endIndex := strings.index_any(
        rest,
        "\"'> \t\r\n",
    )

    if endIndex == -1 {
        return rest
    }

    return rest[:endIndex]
}


ExtractImageURL :: proc(html: string) -> string {
    img_idx := strings.index(html, "<img")

    if img_idx == -1 {
        return ""
    }

    rest := html[img_idx:]

    src_prefix := "src=\""

    src_idx := strings.index(
        rest,
        src_prefix,
    )

    if src_idx == -1 {
        return ""
    }

    start_idx := src_idx + len(src_prefix)

    end_idx := strings.index(
        rest[start_idx:],
        "\"",
    )

    if end_idx == -1 {
        return ""
    }

    return rest[start_idx:start_idx + end_idx]
}


// ---------------------------------------------------------
// 6. JSON Parser
// ---------------------------------------------------------

ParseGames :: proc(data: []byte) -> [dynamic]GameRelease {
    games := make([dynamic]GameRelease)

    fmt.printf(
        "[PARSE] Enter ParseGames, bytes=%d\n",
        len(data),
    )

    if len(data) == 0 {
        fmt.println("[PARSE] ERROR: Empty JSON buffer")
        return games
    }

    fmt.println("[PARSE] Validating JSON...")

    valid := json.is_valid(data)

    fmt.printf(
        "[PARSE] json.is_valid=%v\n",
        valid,
    )

    if !valid {
        fmt.println(
            "[PARSE] ERROR: Server response is not valid JSON",
        )
        return games
    }

    fmt.println("[PARSE] Calling json.parse...")

    value, err := json.parse(data)

    if err != .None {
        fmt.printf(
            "[PARSE] ERROR: json.parse failed: %v\n",
            err,
        )
        return games
    }

    fmt.println("[PARSE] json.parse succeeded")

    defer json.destroy_value(value)

    rootArray, ok := value.(json.Array)

    if !ok {
        fmt.println(
            "[PARSE] ERROR: Root JSON value is not an array",
        )
        return games
    }

    fmt.printf(
        "[PARSE] Root contains %d posts\n",
        len(rootArray),
    )

    for item, index in rootArray {
        fmt.printf(
            "[PARSE] ---- post %d/%d ----\n",
            index + 1,
            len(rootArray),
        )

        post, is_obj := item.(json.Object)

        if !is_obj {
            fmt.printf(
                "[PARSE] post %d: not an object, skipping\n",
                index,
            )
            continue
        }


        // -------------------------------------------------
        // Title
        // -------------------------------------------------

        titleVal, has_title := post["title"]

        if !has_title {
            fmt.printf(
                "[PARSE] post %d: missing title\n",
                index,
            )
            continue
        }

        titleObj, is_title_obj := titleVal.(json.Object)

        if !is_title_obj {
            fmt.printf(
                "[PARSE] post %d: title isn't an object\n",
                index,
            )
            continue
        }

        renderedTitleVal, has_rt := titleObj["rendered"]

        if !has_rt {
            fmt.printf(
                "[PARSE] post %d: title.rendered missing\n",
                index,
            )
            continue
        }

        titleString, is_title_str := renderedTitleVal.(json.String)

        if !is_title_str {
            fmt.printf(
                "[PARSE] post %d: title.rendered isn't a string\n",
                index,
            )
            continue
        }

        raw_title := string(titleString)

        fmt.printf(
            "[PARSE] post %d: title bytes=%d\n",
            index,
            len(raw_title),
        )


        // -------------------------------------------------
        // Content
        // -------------------------------------------------

        contentVal, has_content := post["content"]

        if !has_content {
            fmt.printf(
                "[PARSE] post %d: missing content\n",
                index,
            )
            continue
        }

        contentObj, is_content_obj := contentVal.(json.Object)

        if !is_content_obj {
            fmt.printf(
                "[PARSE] post %d: content isn't an object\n",
                index,
            )
            continue
        }

        renderedContentVal, has_rc := contentObj["rendered"]

        if !has_rc {
            fmt.printf(
                "[PARSE] post %d: content.rendered missing\n",
                index,
            )
            continue
        }

        contentString, is_content_str :=
            renderedContentVal.(json.String)

        if !is_content_str {
            fmt.printf(
                "[PARSE] post %d: content.rendered isn't a string\n",
                index,
            )
            continue
        }


        // -------------------------------------------------
        // TITLE OWNERSHIP FIX
        //
        // strings.replace_all may return the original string
        // when no allocation was necessary.
        //
        // Start with our own clone and only free the previous
        // string when replace_all explicitly allocated a new one.
        // -------------------------------------------------

        cleanTitle := strings.clone(
            raw_title,
            context.allocator,
        )

        tmp1, allocated1 := strings.replace_all(
            cleanTitle,
            "&#8211;",
            "-",
            context.allocator,
        )

        if allocated1 {
            delete(cleanTitle)
            cleanTitle = tmp1
        }

        tmp2, allocated2 := strings.replace_all(
            cleanTitle,
            "&#8217;",
            "'",
            context.allocator,
        )

        if allocated2 {
            delete(cleanTitle)
            cleanTitle = tmp2
        }

        tmp3, allocated3 := strings.replace_all(
            cleanTitle,
            "&#038;",
            "&",
            context.allocator,
        )

        if allocated3 {
            delete(cleanTitle)
            cleanTitle = tmp3
        }

        tmp4, allocated4 := strings.replace_all(
            cleanTitle,
            "&amp;",
            "&",
            context.allocator,
        )

        if allocated4 {
            delete(cleanTitle)
            cleanTitle = tmp4
        }

        fmt.printf(
            "[PARSE] post %d: normalized title OK\n",
            index,
        )


        // -------------------------------------------------
        // Extract links
        // -------------------------------------------------

        htmlContent := string(contentString)

        magnetLink := ExtractMagnet(htmlContent)
        coverUrl := ExtractImageURL(htmlContent)

        fmt.printf(
            "[PARSE] post %d: magnet=%v cover=%v content_bytes=%d\n",
            index,
            len(magnetLink) > 0,
            len(coverUrl) > 0,
            len(htmlContent),
        )

        if len(magnetLink) == 0 {
            fmt.printf(
                "[PARSE] post %d: no magnet, skipping\n",
                index,
            )

            delete(cleanTitle)
            continue
        }


        // -------------------------------------------------
        // Filter non-game catalog posts
        // -------------------------------------------------

        lowerTitle := strings.to_lower(
            cleanTitle,
            context.allocator,
        )

        excluded :=
            strings.contains(
                lowerTitle,
                "upcoming repacks",
            ) ||
            strings.contains(
                lowerTitle,
                "updates digest",
            )

        delete(lowerTitle)

        if excluded {
            fmt.printf(
                "[PARSE] post %d: excluded catalog post\n",
                index,
            )

            delete(cleanTitle)
            continue
        }


        // -------------------------------------------------
        // Build cover cache path
        // -------------------------------------------------

        fmt.printf(
            "[PARSE] post %d: sanitizing filename\n",
            index,
        )

        safeName := sanitize_filename(
            cleanTitle,
            context.allocator,
        )

        // All rendered covers use PNG as the canonical cache format.
        // JPEG downloads and legacy JPEG cache files are converted before
        // raylib sees them.
        if len(safeName) == 0 {
            safeName = fmt.aprintf(
                "release_%d",
                index,
            )
        }

        coverPath := fmt.aprintf(
            "covers/%s.png",
            safeName,
        )

        if len(safeName) > 0 {
            delete(safeName)
        }

        fmt.printf(
            "[PARSE] post %d: cover path=%s\n",
            index,
            coverPath,
        )


        // -------------------------------------------------
        // Clone everything that currently points into the
        // JSON parser's owned memory.
        // -------------------------------------------------

        fmt.printf(
            "[PARSE] post %d: cloning magnet\n",
            index,
        )

        ownedMagnet := strings.clone(
            magnetLink,
            context.allocator,
        )

        fmt.printf(
            "[PARSE] post %d: cloning cover URL\n",
            index,
        )

        ownedCover := strings.clone(
            coverUrl,
            context.allocator,
        )

        fmt.printf(
            "[PARSE] post %d: appending game\n",
            index,
        )

        append(
            &games,
            GameRelease{
                title      = cleanTitle,
                magnetLink = ownedMagnet,
                coverUrl   = ownedCover,
                coverPath  = coverPath,
            },
        )

        fmt.printf(
            "[PARSE] post %d: appended successfully; games=%d\n",
            index,
            len(games),
        )
    }

    fmt.printf(
        "[PARSE] Complete: %d valid games\n",
        len(games),
    )

    return games
}


// ---------------------------------------------------------
// 7. Cover Download Worker
// ---------------------------------------------------------

download_worker :: proc(task: thread.Task) {
    index := task.user_index

    fmt.printf(
        "[COVER %d] Worker started\n",
        index,
    )

    t_data := cast(^DownloadTask)task.data

    if t_data == nil {
        fmt.printf(
            "[COVER %d] ERROR: task.data=nil\n",
            index,
        )
        return
    }

    if t_data.game_ptr == nil {
        fmt.printf(
            "[COVER %d] ERROR: game_ptr=nil\n",
            index,
        )
        return
    }

    game := t_data.game_ptr

    fmt.printf(
        "[COVER %d] Title: %s\n",
        index,
        game.title,
    )

    fmt.printf(
        "[COVER %d] Path: %s\n",
        index,
        game.coverPath,
    )

    if len(game.coverPath) == 0 {
        fmt.printf(
            "[COVER %d] ERROR: empty cover path\n",
            index,
        )
        return
    }

    if os.exists(game.coverPath) {
        fmt.printf(
            "[COVER %d] PNG cache hit; skipping download\n",
            index,
        )
        return
    }

    // Migrate covers cached by the previous JPEG-based implementation.
    // Keep the legacy file until conversion succeeds so a failed conversion
    // can be retried on the next run.
    legacyCoverPath := ""
    if len(game.coverPath) >= len(".png") {
        legacyCoverPath = fmt.aprintf(
            "%s.jpg",
            game.coverPath[:len(game.coverPath)-len(".png")],
        )
        defer delete(legacyCoverPath)
    }

    if len(legacyCoverPath) > 0 && os.exists(legacyCoverPath) {
        fmt.printf(
            "[COVER %d] Legacy JPEG cache hit; converting to %s\n",
            index,
            game.coverPath,
        )

        conversion_err := jpegpng.Convert_File(
            legacyCoverPath,
            game.coverPath,
        )

        if conversion_err != .None {
            fmt.printf(
                "[COVER %d] ERROR: cached JPEG conversion failed: %v\n",
                index,
                conversion_err,
            )
            return
        }

        remove_err := os.remove(legacyCoverPath)
        if remove_err != nil {
            fmt.printf(
                "[COVER %d] WARNING: could not remove legacy JPEG cache: %v\n",
                index,
                remove_err,
            )
        } else {
            fmt.printf(
                "[COVER %d] Legacy JPEG cache removed\n",
                index,
            )
        }
        return
    }

    if len(game.coverUrl) == 0 {
        fmt.printf(
            "[COVER %d] No cover URL; skipping\n",
            index,
        )
        return
    }

    url_lower := strings.to_lower(
        game.coverUrl,
        context.allocator,
    )
    defer delete(url_lower)

    if strings.contains(url_lower, ".webp") {
        fmt.printf(
            "[COVER %d] WEBP skipped\n",
            index,
        )
        return
    }

    if strings.contains(url_lower, ".avif") {
        fmt.printf(
            "[COVER %d] AVIF skipped\n",
            index,
        )
        return
    }

    builder: strings.Builder
    strings.builder_init(
        &builder,
        context.allocator,
    )
    defer strings.builder_destroy(&builder)

    fmt.printf(
        "[COVER %d] curl.easy_init()...\n",
        index,
    )

    handle := curl.easy_init()

    if handle == nil {
        fmt.printf(
            "[COVER %d] ERROR: curl.easy_init returned nil\n",
            index,
        )
        return
    }

    defer curl.easy_cleanup(handle)

    cstrUrl := strings.clone_to_cstring(
        game.coverUrl,
        context.allocator,
    )
    defer delete(cstrUrl)

    curl.easy_setopt(handle, .URL, cstrUrl)
    curl.easy_setopt(handle, .FOLLOWLOCATION, 1)
    curl.easy_setopt(
        handle,
        .REFERER,
        "https://fitgirl-repacks.site/",
    )
    curl.easy_setopt(
        handle,
        .USERAGENT,
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) FitDeck/1.0",
    )
    curl.easy_setopt(handle, .TIMEOUT, 15)
    curl.easy_setopt(handle, .ACCEPT_ENCODING, "")
    curl.easy_setopt(handle, .WRITEFUNCTION, CurlWriteCallback)
    curl.easy_setopt(handle, .WRITEDATA, &builder)

    fmt.printf(
        "[COVER %d] Performing HTTP request...\n",
        index,
    )

    result := curl.easy_perform(handle)

    fmt.printf(
        "[COVER %d] HTTP result=%v bytes=%d\n",
        index,
        result,
        len(builder.buf),
    )

    if result != .E_OK {
        fmt.printf(
            "[COVER %d] ERROR: curl request failed: %v\n",
            index,
            result,
        )
        return
    }

    if len(builder.buf) <= 10 {
        fmt.printf(
            "[COVER %d] ERROR: response too small\n",
            index,
        )
        return
    }

    header_len := min(
        len(builder.buf),
        256,
    )

    header := string(
        builder.buf[:header_len],
    )

    if strings.contains(header, "<!DOCTYPE") ||
       strings.contains(header, "<html") ||
       strings.contains(header, "<HTML") {
        fmt.printf(
            "[COVER %d] ERROR: received HTML instead of image\n",
            index,
        )
        return
    }

    // The API normally returns JPEG bytes even when the URL has a .png
    // suffix. Convert those bytes before putting them in the canonical PNG
    // cache. Preserve an actual PNG response as-is.
    png_data: []byte
    is_jpeg :=
        len(builder.buf) >= 2 &&
        builder.buf[0] == 0xff &&
        builder.buf[1] == 0xd8

    if is_jpeg {
        converted, conversion_err := jpegpng.Convert_Bytes(
            builder.buf[:],
        )

        if conversion_err != .None {
            fmt.printf(
                "[COVER %d] ERROR: downloaded JPEG conversion failed: %v\n",
                index,
                conversion_err,
            )
            return
        }

        png_data = converted
    } else {
        is_png :=
            len(builder.buf) >= 8 &&
            builder.buf[0] == 0x89 &&
            builder.buf[1] == 0x50 &&
            builder.buf[2] == 0x4e &&
            builder.buf[3] == 0x47 &&
            builder.buf[4] == 0x0d &&
            builder.buf[5] == 0x0a &&
            builder.buf[6] == 0x1a &&
            builder.buf[7] == 0x0a

        if !is_png {
            fmt.printf(
                "[COVER %d] ERROR: response is neither JPEG nor PNG\n",
                index,
            )
            return
        }

        png_data, alloc_err := make(
            []byte,
            len(builder.buf),
            context.allocator,
        )

        if alloc_err != nil {
            fmt.printf(
                "[COVER %d] ERROR: PNG response allocation failed: %v\n",
                index,
                alloc_err,
            )
            return
        }

        copy(png_data, builder.buf[:])
    }

    defer delete(png_data, context.allocator)

    fmt.printf(
        "[COVER %d] Writing converted PNG (%d bytes) to %s\n",
        index,
        len(png_data),
        game.coverPath,
    )

    write_err := os.write_entire_file(
        game.coverPath,
        png_data,
    )

    if write_err != nil {
        fmt.printf(
            "[COVER %d] ERROR: file write failed: %v\n",
            index,
            write_err,
        )
        return
    }

    fmt.printf(
        "[COVER %d] Download and PNG conversion completed\n",
        index,
    )
}


// ---------------------------------------------------------
// 8. Background Loader
// ---------------------------------------------------------

loader_proc :: proc(t: ^thread.Thread) {
    fmt.println("[LOADER] Thread entered loader_proc")

    if t == nil {
        fmt.println("[LOADER] FATAL: thread pointer is nil")
        return
    }

    data := cast(^LoaderData)t.data

    if data == nil {
        fmt.println("[LOADER] FATAL: LoaderData pointer is nil")
        return
    }

    data.success = false
    data.error_message = ""

    fmt.println("[LOADER] Syncing with FitGirl API...")

    json_data := FetchLiveCatalog()

    if len(json_data) == 0 {
        data.error_message = "Error: Could not reach catalog."

        fmt.println(
            "[LOADER] ERROR: Failed to fetch catalog JSON.",
        )

        return
    }

    fmt.printf(
        "[LOADER] Received %d JSON bytes\n",
        len(json_data),
    )

    fmt.println(
        "[LOADER] Parsing JSON data safely...",
    )

    games := ParseGames(
        transmute([]byte)json_data,
    )

    fmt.printf(
        "[LOADER] ParseGames returned %d games\n",
        len(games),
    )

    fmt.println(
        "[LOADER] Releasing raw JSON buffer...",
    )

    delete(json_data)

    fmt.println(
        "[LOADER] Raw JSON buffer released",
    )

    if len(games) == 0 {
        data.games = games
        data.error_message = "No valid releases found."

        fmt.println(
            "[LOADER] ERROR: parser returned zero games",
        )

        return
    }

    fmt.printf(
        "[LOADER] Parsed %d valid games\n",
        len(games),
    )


    // -----------------------------------------------------
    // Cover directory
    // -----------------------------------------------------

    if !os.exists("covers") {
        fmt.println(
            "[LOADER] Creating covers directory...",
        )

        mkdir_err := os.make_directory("covers")

        if mkdir_err != nil {
            fmt.printf(
                "[LOADER] WARNING: covers directory creation failed: %v\n",
                mkdir_err,
            )
        } else {
            fmt.println(
                "[LOADER] Covers directory created",
            )
        }
    } else {
        fmt.println(
            "[LOADER] Covers directory already exists",
        )
    }


    // -----------------------------------------------------
    // Cover pool
    // -----------------------------------------------------

    fmt.println(
        "[LOADER] Initializing cover thread pool...",
    )

    pool: thread.Pool

    thread.pool_init(
        &pool,
        context.allocator,
        8,
    )

    fmt.println(
        "[LOADER] Starting cover thread pool...",
    )

    thread.pool_start(&pool)

    tasks := make(
        []DownloadTask,
        len(games),
    )

    queued := 0

    fmt.println(
        "[LOADER] Queueing cover jobs...",
    )

    for i in 0..<len(games) {
        if len(games[i].coverUrl) == 0 {
            fmt.printf(
                "[LOADER] Cover %d: no URL, not queued\n",
                i,
            )
            continue
        }

        tasks[i].game_ptr = &games[i]

        thread.pool_add_task(
            &pool,
            context.allocator,
            download_worker,
            &tasks[i],
            i,
        )

        queued += 1
    }

    fmt.printf(
        "[LOADER] Queued %d cover jobs\n",
        queued,
    )

    fmt.println(
        "[LOADER] Waiting for cover workers...",
    )

    thread.pool_finish(&pool)

    fmt.println(
        "[LOADER] All cover workers finished",
    )

    fmt.println(
        "[LOADER] Destroying cover thread pool...",
    )

    thread.pool_destroy(&pool)

    fmt.println(
        "[LOADER] Cover thread pool destroyed",
    )

    delete(tasks)

    fmt.println(
        "[LOADER] Cover task array released",
    )


    // -----------------------------------------------------
    // Hand result to main thread.
    //
    // Main will not access LoaderData until this thread has
    // completely finished.
    // -----------------------------------------------------

    data.games = games
    data.success = true

    fmt.printf(
        "[LOADER] SUCCESS: %d games ready for main thread\n",
        len(data.games),
    )

    fmt.println("[LOADER] Thread exiting normally")
}


// ---------------------------------------------------------
// 9. Loader Control - MAIN THREAD ONLY
// ---------------------------------------------------------

StartLoader :: proc(app: ^App) {
    if app == nil {
        fmt.println("[MAIN] ERROR: StartLoader app=nil")
        return
    }

    if app.loader_thread != nil {
        fmt.println("[MAIN] WARNING: loader already running")
        return
    }

    fmt.println("[MAIN] Allocating LoaderData...")

    data := new(LoaderData)

    fmt.println("[MAIN] Creating loader thread...")

    t := thread.create(loader_proc)

    if t == nil {
        fmt.println("[MAIN] ERROR: thread.create returned nil")

        free(data)

        app.load_status = "Error: Could not create loader thread."
        return
    }

    t.data = data

    app.loader_data = data
    app.loader_thread = t

    app.load_status = "Syncing with FitGirl API..."

    fmt.println("[MAIN] Starting loader thread...")

    thread.start(t)

    fmt.println("[MAIN] Loader thread started")
}


// ---------------------------------------------------------
// 10. GPU Texture Loading - MAIN THREAD ONLY
// ---------------------------------------------------------

LoadGameTextures :: proc(app: ^App) {
    fmt.printf(
        "[TEXTURE] Beginning GPU texture load for %d games\n",
        len(app.games),
    )

    for &game, index in app.games {
        fmt.printf(
            "[TEXTURE %d] Checking: %s\n",
            index,
            game.coverPath,
        )

        if len(game.coverPath) == 0 {
            fmt.printf(
                "[TEXTURE %d] Empty path; skipping\n",
                index,
            )
            continue
        }

        if !os.exists(game.coverPath) {
            fmt.printf(
                "[TEXTURE %d] File does not exist\n",
                index,
            )
            continue
        }

        //
        // Let raylib decode the image itself.
        //
        path_cstr := strings.clone_to_cstring(
            game.coverPath,
            context.temp_allocator,
        )

        fmt.printf(
            "[TEXTURE %d] Calling raylib LoadImage...\n",
            index,
        )

        img := rl.LoadImage(path_cstr)

        fmt.printf(
            "[TEXTURE %d] LoadImage result: data=%v width=%d height=%d format=%v\n",
            index,
            img.data != nil,
            img.width,
            img.height,
            img.format,
        )

        if img.data == nil ||
           img.width <= 0 ||
           img.height <= 0 {

            fmt.printf(
                "[TEXTURE %d] ERROR: raylib could not decode %s\n",
                index,
                game.coverPath,
            )

            // Do not leave a corrupt/unsupported PNG in the cache. The
            // loader will download and convert it again on the next launch.
            remove_err := os.remove(game.coverPath)
            if remove_err != nil {
                fmt.printf(
                    "[TEXTURE %d] WARNING: could not remove invalid cache: %v\n",
                    index,
                    remove_err,
                )
            } else {
                fmt.printf(
                    "[TEXTURE %d] Invalid PNG cache removed; retrying next launch\n",
                    index,
                )
            }

            continue
        }

        fmt.printf(
            "[TEXTURE %d] Raylib decoded %dx%d\n",
            index,
            img.width,
            img.height,
        )

        fmt.printf(
            "[TEXTURE %d] Uploading image to GPU...\n",
            index,
        )

        game.coverTex = rl.LoadTextureFromImage(
            img,
        )

        //
        // CPU-side decoded image is no longer needed after
        // LoadTextureFromImage().
        //
        rl.UnloadImage(img)

        if game.coverTex.id == 0 {
            fmt.printf(
                "[TEXTURE %d] ERROR: GPU texture creation failed\n",
                index,
            )
            continue
        }

        rl.SetTextureFilter(
            game.coverTex,
            .BILINEAR,
        )

        fmt.printf(
            "[TEXTURE %d] SUCCESS: texture=%d\n",
            index,
            game.coverTex.id,
        )
    }

    fmt.println(
        "[TEXTURE] GPU texture loading complete",
    )
}


// ---------------------------------------------------------
// 11. Poll Completed Loader - MAIN THREAD ONLY
// ---------------------------------------------------------

ProcessFinishedLoader :: proc(app: ^App) {
    if app == nil {
        return
    }

    if app.loader_thread == nil {
        return
    }

    if !thread.is_done(app.loader_thread) {
        return
    }

    fmt.println(
        "[MAIN] Loader reports completion",
    )

    // Save the result pointer first because thread.destroy()
    // frees the Thread object itself.
    loader_data := app.loader_data

    fmt.println(
        "[MAIN] Destroying/joining completed loader thread...",
    )

    thread.destroy(app.loader_thread)

    app.loader_thread = nil
    app.loader_data = nil

    fmt.println(
        "[MAIN] Loader thread destroyed safely",
    )

    if loader_data == nil {
        fmt.println(
            "[MAIN] ERROR: loader completed without LoaderData",
        )

        app.load_status =
            "Error: Loader returned invalid state."

        return
    }

    if !loader_data.success {
        fmt.printf(
            "[MAIN] Loader failed: %s\n",
            loader_data.error_message,
        )

        if len(loader_data.games) > 0 {
            DestroyGames(loader_data.games)
        }

        if len(loader_data.error_message) > 0 {
            app.load_status = loader_data.error_message
        } else {
            app.load_status = "Error loading catalog."
        }

        free(loader_data)
        return
    }

    fmt.printf(
        "[MAIN] Taking ownership of %d games\n",
        len(loader_data.games),
    )

    app.games = loader_data.games

    // Free only the LoaderData struct. app.games now owns the
    // dynamic array and all GameRelease allocations.
    free(loader_data)

    app.load_status = "Loading cover textures..."

    LoadGameTextures(app)

    app.screen = .Library
    app.status_message = "READY"

    fmt.println(
        "[MAIN] Library ready",
    )
}


// ---------------------------------------------------------
// 12. Shutdown Loader Safely
// ---------------------------------------------------------

ShutdownLoader :: proc(app: ^App) {
    if app == nil {
        return
    }

    if app.loader_thread == nil {
        return
    }

    fmt.println(
        "[SHUTDOWN] Loader is still running; waiting for it...",
    )

    loader_data := app.loader_data

    // destroy() waits for the worker to complete and releases
    // the Thread object.
    thread.destroy(app.loader_thread)

    app.loader_thread = nil
    app.loader_data = nil

    fmt.println(
        "[SHUTDOWN] Loader thread stopped",
    )

    if loader_data != nil {
        if len(loader_data.games) > 0 {
            DestroyGames(loader_data.games)
        }

        free(loader_data)
    }
}


// ---------------------------------------------------------
// 13. UI - Setup
// ---------------------------------------------------------

RenderSetupScreen :: proc(
    app: ^App,
    theme: orui.Theme,
) {
    {
        orui.container(
            orui.id("setup_root"),
            {
                layout = .Flex,
                direction = .TopToBottom,
                width = orui.grow(),
                height = orui.grow(),
                align_main = .Center,
                align_cross = .Center,
                background_color = APP_BACKGROUND,
            },
        )

        {
            orui.container(
                orui.id("setup_panel"),
                {
                    layout = .Flex,
                    direction = .TopToBottom,
                    width = orui.fixed(560),
                    height = orui.fit(),

                    padding = orui.Edges{
                        top = 32,
                        right = 32,
                        bottom = 32,
                        left = 32,
                    },

                    gap = 16,
                    background_color = ROW_BACKGROUND,
                    border = orui.border(1),
                    border_color = BORDER_COLOR,
                    corner_radius = orui.corner(8),
                },
            )

            orui.label(
                orui.id("setup_title"),
                "FitDeck Configuration",
                {
                    font_size = 24,
                    color = TEXT_PRIMARY,
                },
            )

            orui.label(
                orui.id("setup_desc"),
                "Provide your API token and choose the default folder for downloaded games. You only need to do this once.",
                {
                    font_size = 14,
                    color = TEXT_MUTED,
                    overflow = .Wrap,
                },
            )

            orui.label(
                orui.id("api_key_label"),
                "Real-Debrid API token",
                {
                    font_size = 12,
                    color = TEXT_MUTED,
                },
            )

            {
                orui.container(
                    orui.id("input_row"),
                    {
                        layout = .Flex,
                        direction = .LeftToRight,
                        width = orui.grow(),
                        height = orui.fixed(42),
                        gap = 8,
                    },
                )

                orui.text_input(
                    orui.id("rd_key_input"),
                    &app.rd_key_input,
                    {
                        width = orui.grow(),
                        height = orui.grow(),

                        padding = orui.Edges{
                            top = 0,
                            right = 12,
                            bottom = 0,
                            left = 12,
                        },

                        background_color = LIST_BACKGROUND,
                        border = orui.border(1),
                        border_color = BORDER_COLOR,
                        corner_radius = orui.corner(6),
                        color = rl.WHITE,
                        font_size = 20,
                        placeholder = "Paste API Token Here...",
                    },
                )

                if orui.button(
                    orui.id("btn_paste"),
                    "Paste",
                    {
                        width = orui.fixed(80),
                        height = orui.grow(),
                        background_color = ROW_HOVER_BACKGROUND,
                        color = TEXT_PRIMARY,
                        corner_radius = orui.corner(6),
                    },
                ) {
                    cb := rl.GetClipboardText()

                    if cb != nil {
                        strings.builder_reset(
                            &app.rd_key_input,
                        )

                        strings.write_string(
                            &app.rd_key_input,
                            string(cb),
                        )

                        // Never log the actual API token.
                        fmt.printf(
                            "[UI] Pasted API key, length=%d\n",
                            len(app.rd_key_input.buf),
                        )
                    }
                }
            }

            orui.label(
                orui.id("download_path_label"),
                "Default game download folder",
                {
                    font_size = 12,
                    color = TEXT_MUTED,
                },
            )

            {
                orui.container(
                    orui.id("download_path_row"),
                    {
                        layout = .Flex,
                        direction = .LeftToRight,
                        width = orui.grow(),
                        height = orui.fixed(42),
                        gap = 8,
                    },
                )

                download_path_display := app.download_path
                if len(download_path_display) == 0 {
                    download_path_display = "No folder selected"
                }

                orui.label(
                    orui.id("download_path_value"),
                    download_path_display,
                    {
                        width = orui.grow(),
                        height = orui.grow(),
                        padding = orui.Edges{
                            top = 0,
                            right = 12,
                            bottom = 0,
                            left = 12,
                        },
                        background_color = LIST_BACKGROUND,
                        border = orui.border(1),
                        border_color = BORDER_COLOR,
                        corner_radius = orui.corner(6),
                        color = TEXT_PRIMARY,
                        font_size = 14,
                        overflow = .Wrap,
                    },
                )

                if orui.button(
                    orui.id("btn_choose_download_path"),
                    "Choose Folder",
                    {
                        width = orui.fixed(132),
                        height = orui.grow(),
                        background_color = ROW_HOVER_BACKGROUND,
                        color = TEXT_PRIMARY,
                        corner_radius = orui.corner(6),
                    },
                ) {
                    dialog_default_path := ""
                    if os.is_directory(app.download_path) {
                        dialog_default_path = app.download_path
                    }

                    dialog_default_cstr := strings.clone_to_cstring(
                        dialog_default_path,
                        context.temp_allocator,
                    )
                    selected_path_cstr := tinyfd.selectFolderDialog(
                        "Select default game download folder",
                        dialog_default_cstr,
                    )

                    if selected_path_cstr != nil {
                        selected_path := strings.clone(
                            string(selected_path_cstr),
                            context.allocator,
                        )

                        if len(selected_path) > 0 {
                            if len(app.download_path) > 0 {
                                delete(app.download_path)
                            }
                            app.download_path = selected_path
                            app.status_message =
                                "Download folder selected."
                        } else {
                            delete(selected_path)
                        }
                    }
                }
            }

            key_text := strings.to_string(app.rd_key_input)
            download_path_text := strings.trim_space(app.download_path)
            key_ready := len(strings.trim_space(key_text)) > 0
            path_ready := len(download_path_text) > 0

            if !key_ready || !path_ready {
                orui.label(
                    orui.id("setup_warn"),
                    "API key and download folder are required to continue.",
                    {
                        font_size = 12,
                        color = STATUS_ERR,
                    },
                )
            } else {
                if orui.button(
                    orui.id("btn_save"),
                    "Save & Launch",
                    {
                        width = orui.grow(),
                        height = orui.fixed(44),
                        background_color = ACCENT_COLOR,
                        color = APP_BACKGROUND,
                        corner_radius = orui.corner(6),
                    },
                ) {
                    key_text = strings.trim_space(key_text)
                    download_path_text = strings.trim_space(download_path_text)

                    if len(key_text) == 0 || len(download_path_text) == 0 {
                        app.status_message =
                            "API key and download folder are required."
                        return
                    }

                    if !EnsureDownloadDirectory(download_path_text) {
                        app.status_message =
                            "Warning: Download path is not a usable folder."
                        return
                    }

                    normalized_download_path := strings.clone(
                        download_path_text,
                        context.allocator,
                    )

                    if len(app.rd_key) > 0 {
                        delete(app.rd_key)
                    }
                    if len(app.download_path) > 0 {
                        delete(app.download_path)
                    }

                    app.rd_key = strings.clone(
                        key_text,
                        context.allocator,
                    )
                    app.download_path = normalized_download_path

                    if !SaveSettings(app) {
                        app.status_message =
                            "Warning: Settings could not be saved."
                        return
                    }

                    fmt.println(
                        "[UI] Settings saved to disk",
                    )

                    if len(app.games) > 0 {
                        fmt.println(
                            "[UI] Existing library present; returning to library",
                        )

                        app.screen = .Library
                    } else {
                        fmt.println(
                            "[UI] Starting loader after API key setup",
                        )

                        app.screen = .Loading
                        StartLoader(app)
                    }
                }
            }
        }
    }
}


// ---------------------------------------------------------
// 14. UI - Loading
// ---------------------------------------------------------

RenderLoadingScreen :: proc(
    app: ^App,
    theme: orui.Theme,
) {
    {
        orui.container(
            orui.id("load_root"),
            {
                layout = .Flex,
                direction = .TopToBottom,
                width = orui.grow(),
                height = orui.grow(),
                align_main = .Center,
                align_cross = .Center,
                background_color = APP_BACKGROUND,
                gap = 16,
            },
        )

        orui.label(
            orui.id("load_title"),
            "Booting Library",
            {
                font_size = 24,
                color = TEXT_PRIMARY,
            },
        )

        orui.label(
            orui.id("load_status"),
            app.load_status,
            {
                font_size = 14,
                color = ACCENT_COLOR,
            },
        )
    }
}


// ---------------------------------------------------------
// 15. UI - Library
// ---------------------------------------------------------

RenderLibraryScreen :: proc(
    app: ^App,
    theme: orui.Theme,
) {
    {
        orui.container(
            orui.id("app"),
            {
                layout = .Flex,
                direction = .TopToBottom,
                width = orui.grow(),
                height = orui.grow(),
                background_color = APP_BACKGROUND,
            },
        )

        // -------------------------------------------------
        // Top nav
        // -------------------------------------------------

        {
            orui.container(
                orui.id("top_nav"),
                {
                    layout = .Flex,
                    direction = .LeftToRight,
                    width = orui.grow(),
                    height = orui.fixed(80),

                    align_cross = .Center,
                    align_main = .SpaceBetween,

                    padding = orui.Edges{
                        top = 0,
                        right = 32,
                        bottom = 0,
                        left = 32,
                    },

                    background_color = HEADER_BACKGROUND,

                    border = orui.Edges{
                        top = 0,
                        right = 0,
                        bottom = 1,
                        left = 0,
                    },

                    border_color = BORDER_COLOR,
                },
            )

            {
                orui.container(
                    orui.id("brand_wrap"),
                    {
                        layout = .Flex,
                        direction = .TopToBottom,
                        width = orui.fit(),
                        height = orui.fit(),
                    },
                )

                orui.label(
                    orui.id("title"),
                    "FitDeck",
                    {
                        font_size = 28,
                        color = TEXT_PRIMARY,
                    },
                )

                orui.label(
                    orui.id("subtitle"),
                    "Real-Debrid Library Integration",
                    {
                        font_size = 13,
                        color = ACCENT_COLOR,
                    },
                )
            }

            {
                orui.container(
                    orui.id("status_wrap"),
                    {
                        layout = .Flex,
                        direction = .TopToBottom,
                        width = orui.fit(),
                        height = orui.fit(),
                        align_cross = .End,
                        gap = 4,
                    },
                )

                orui.label(
                    orui.id("catalog count"),
                    fmt.tprintf(
                        "%d Games Found",
                        len(app.games),
                    ),
                    {
                        font_size = 14,
                        color = TEXT_PRIMARY,
                    },
                )

                if orui.button(
                    orui.id("btn_settings"),
                    "⚙ Settings",
                    {
                        height = orui.fixed(24),

                        padding = orui.Edges{
                            top = 0,
                            right = 8,
                            bottom = 0,
                            left = 8,
                        },

                        color = TEXT_MUTED,
                    },
                ) {
                    fmt.println(
                        "[UI] Opening settings screen",
                    )

                    app.screen = .SetupKey
                }
            }
        }


        // -------------------------------------------------
        // Main content
        // -------------------------------------------------

        {
            orui.container(
                orui.id("main_content"),
                {
                    layout = .Flex,
                    direction = .TopToBottom,
                    width = orui.grow(),
                    height = orui.grow(),

                    padding = orui.Edges{
                        top = 24,
                        right = 32,
                        bottom = 24,
                        left = 32,
                    },

                    gap = 12,
                },
            )

            {
                orui.container(
                    orui.id("release heading"),
                    {
                        layout = .Flex,
                        direction = .LeftToRight,
                        width = orui.grow(),
                        height = orui.fit(),
                        align_cross = .Center,
                        align_main = .SpaceBetween,

                        padding = orui.Edges{
                            top = 0,
                            right = 4,
                            bottom = 8,
                            left = 4,
                        },
                    },
                )

                orui.label(
                    orui.id("release heading title"),
                    "AVAILABLE RELEASES",
                    {
                        font_size = 14,
                        color = TEXT_MUTED,
                        letter_spacing = 1,
                    },
                )
            }

            if len(app.games) > 0 {
                list := orui.begin_virtual_list(
                    orui.id("releases"),
                    {
                        width = orui.grow(),
                        height = orui.grow(),
                        scroll = orui.scroll(.Vertical),
                        clip = {.Self, {}},
                        background_color = LIST_BACKGROUND,
                    },
                    {
                        direction = .Vertical,
                        item_count = len(app.games),
                        item_extent = RELEASE_ROW_EXTENT,
                        overscan = 2,
                    },
                )

                for index := list.first;
                    index < list.last;
                    index += 1 {

                    game := app.games[index]

                    rowId := orui.virtual_list_item_id(
                        list.id,
                        index,
                    )

                    isFocused :=
                        index == app.selected_game ||
                        orui.focused(rowId) ||
                        orui.active(rowId)

                    isHovered := orui.hovered(rowId)

                    rowBg := ROW_BACKGROUND

                    if isFocused {
                        rowBg = ROW_FOCUS_BACKGROUND
                    } else if isHovered {
                        rowBg = ROW_HOVER_BACKGROUND
                    }

                    rowBorder := isFocused ? ACCENT_COLOR : BORDER_COLOR
                    titleColor := isFocused ? rl.WHITE : TEXT_PRIMARY
                    badgeTextColor := isFocused ? rl.WHITE : STATUS_OK

                    {
                        orui.container(
                            orui.id(rowId),
                            orui.virtual_list_item_config(
                                list,
                                index,
                                {
                                    layout = .Flex,
                                    direction = .LeftToRight,
                                    width = orui.percent(1),
                                    height = orui.fixed(
                                        RELEASE_ROW_HEIGHT,
                                    ),

                                    padding = orui.Edges{
                                        top = 0,
                                        right = 20,
                                        bottom = 0,
                                        left = 12,
                                    },

                                    align_cross = .Center,
                                    align_main = .SpaceBetween,
                                    background_color = rowBg,
                                    border = orui.border(1),
                                    border_color = rowBorder,
                                    corner_radius = orui.corner(6),
                                    focusable = true,
                                    block = .True,
                                    cursor = .Pointing_Hand,
                                },
                            ),
                        )

                        {
                            orui.container(
                                orui.id(
                                    fmt.tprintf(
                                        "info_wrap_%d",
                                        index,
                                    ),
                                ),
                                {
                                    layout = .Flex,
                                    direction = .LeftToRight,
                                    height = orui.grow(),
                                    align_cross = .Center,
                                    gap = 16,
                                },
                            )

                            if game.coverTex.id != 0 {
                                orui.image(
                                    orui.id(
                                        fmt.tprintf(
                                            "cover_%d",
                                            index,
                                        ),
                                    ),
                                    &app.games[index].coverTex,
                                    {
                                        width = orui.fixed(56),
                                        height = orui.fixed(76),
                                        texture_fit = .Cover,
                                        corner_radius = orui.corner(4),
                                        border = orui.border(1),
                                        border_color = BORDER_COLOR,
                                    },
                                )
                            } else {
                                {
                                    orui.container(
                                        orui.id(
                                            fmt.tprintf(
                                                "cover_ph_%d",
                                                index,
                                            ),
                                        ),
                                        {
                                            width = orui.fixed(56),
                                            height = orui.fixed(76),
                                            background_color = HEADER_BACKGROUND,
                                            corner_radius = orui.corner(4),
                                        },
                                    )
                                }
                            }

                            orui.label(
                                orui.id(
                                    fmt.tprintf(
                                        "title_%d",
                                        index,
                                    ),
                                ),
                                game.title,
                                {
                                    font_size = 18,
                                    color = titleColor,
                                    disabled = .True,
                                },
                            )
                        }

                        {
                            orui.container(
                                orui.id(
                                    fmt.tprintf(
                                        "badge_%d",
                                        index,
                                    ),
                                ),
                                {
                                    layout = .Flex,
                                    direction = .LeftToRight,
                                    width = orui.fixed(120),
                                    height = orui.fixed(26),
                                    align_main = .Center,
                                    align_cross = .Center,
                                    background_color = rl.Color{
                                        0,
                                        0,
                                        0,
                                        40,
                                    },
                                    corner_radius = orui.corner(13),
                                },
                            )

                            orui.label(
                                orui.id(
                                    fmt.tprintf(
                                        "badgetext_%d",
                                        index,
                                    ),
                                ),
                                "MAGNET READY",
                                {
                                    font_size = 11,
                                    color = badgeTextColor,
                                    disabled = .True,
                                },
                            )
                        }
                    }

                    if orui.clicked(rowId) ||
                       orui.activated(rowId) {

                        app.selected_game = index

                        app.status_message =
                            "Handing off to Real-Debrid API..."

                        // Magnet is intentionally not printed here.
                        // It can be very long and isn't needed for
                        // crash diagnostics.
                        fmt.printf(
                            "[UI] Selected game index=%d title=%s magnet_length=%d\n",
                            index,
                            game.title,
                            len(game.magnetLink),
                        )
                    }
                }

                orui.end_virtual_list()
            }


            // -------------------------------------------------
            // Footer
            // -------------------------------------------------

            {
                orui.container(
                    orui.id("footer"),
                    {
                        layout = .Flex,
                        direction = .LeftToRight,
                        width = orui.grow(),
                        height = orui.fit(),
                        align_cross = .Center,
                        align_main = .SpaceBetween,

                        padding = orui.Edges{
                            top = 12,
                            right = 0,
                            bottom = 0,
                            left = 0,
                        },
                    },
                )

                orui.label(
                    orui.id("footer source"),
                    "SOURCE: FITGIRL-REPACKS.SITE",
                    {
                        font_size = 11,
                        color = TEXT_MUTED,
                    },
                )

                orui.label(
                    orui.id("footer msg"),
                    app.status_message,
                    {
                        font_size = 11,
                        color = ACCENT_COLOR,
                    },
                )
            }
        }
    }
}


// ---------------------------------------------------------
// 16. Execution Core
// ---------------------------------------------------------

main :: proc() {
    fmt.println("========================================")
    fmt.println("--- Starting FitDeck ---")
    fmt.println("========================================")


    // -----------------------------------------------------
    // libcurl global lifetime
    //
    // Initialize ONCE before any worker threads can touch
    // libcurl. Cleanup happens after all loader workers have
    // been joined during shutdown.
    // -----------------------------------------------------

    fmt.println(
        "[BOOT] Initializing global libcurl state...",
    )

    curl_init_result :=
        curl.global_init(curl.GLOBAL_DEFAULT)

    if curl_init_result != .E_OK {
        fmt.printf(
            "[BOOT] FATAL: curl.global_init failed: %v\n",
            curl_init_result,
        )

        return
    }

    defer curl.global_cleanup()

    fmt.println(
        "[BOOT] libcurl initialized successfully",
    )


    // -----------------------------------------------------
    // App
    // -----------------------------------------------------

    app: App

    strings.builder_init(
        &app.rd_key_input,
    )
    defer strings.builder_destroy(
        &app.rd_key_input,
    )

    app.status_message = "READY"
    app.load_status = "Initializing..."
    app.selected_game = 0


    // -----------------------------------------------------
    // Raylib
    // -----------------------------------------------------

    fmt.println(
        "[BOOT] Initializing raylib window...",
    )

    rl.SetTraceLogLevel(.FATAL)
    rl.SetConfigFlags({.MSAA_4X_HINT})

    rl.InitWindow(
        WINDOW_WIDTH,
        WINDOW_HEIGHT,
        WINDOW_TITLE,
    )

    defer rl.CloseWindow()

    rl.SetTargetFPS(60)

    fmt.println(
        "[BOOT] raylib window initialized",
    )


    // -----------------------------------------------------
    // ORUI
    // -----------------------------------------------------

    fmt.println(
        "[BOOT] Initializing ORUI...",
    )

    ctx := new(orui.Context)
    defer free(ctx)

    orui.init(ctx)
    defer orui.destroy(ctx)

    orui.set_input_trace(
        ctx,
        false,
    )

    fmt.println(
        "[BOOT] ORUI initialized",
    )


    // -----------------------------------------------------
    // Font
    // -----------------------------------------------------

    if rl.FileExists("font.ttf") {
        fmt.println(
            "[BOOT] Loading custom font.ttf...",
        )

        customFont := rl.LoadFontEx(
            "font.ttf",
            36,
            nil,
            0,
        )

        if customFont.texture.id != 0 {
            rl.SetTextureFilter(
                customFont.texture,
                .BILINEAR,
            )

            ctx.default_font = customFont

            fmt.printf(
                "[BOOT] Custom font loaded, texture=%d\n",
                customFont.texture.id,
            )
        } else {
            fmt.println(
                "[BOOT] WARNING: custom font load failed; using default font",
            )

            ctx.default_font =
                rl.GetFontDefault()
        }
    } else {
        fmt.println(
            "[BOOT] font.ttf not found; using default font",
        )

        ctx.default_font =
            rl.GetFontDefault()
    }


    // -----------------------------------------------------
    // Theme
    // -----------------------------------------------------

    theme := orui.default_theme()

    theme.button_background =
        ROW_BACKGROUND

    theme.button_hover =
        ROW_HOVER_BACKGROUND

    theme.button_focused =
        ROW_FOCUS_BACKGROUND

    theme.selected =
        ROW_FOCUS_BACKGROUND

    theme.focus_border =
        rl.BLANK

    theme.border =
        BORDER_COLOR

    theme.text =
        TEXT_PRIMARY

    orui.set_theme(
        ctx,
        theme,
    )


    // -----------------------------------------------------
    // Settings
    //
    // Loader starts only after curl, raylib and ORUI have
    // all been initialized. A missing or incompatible settings
    // file deliberately returns to setup so new settings can
    // be collected before the first catalog sync.
    // -----------------------------------------------------

    fmt.printf(
        "[BOOT] Checking %s (version %d)...\n",
        SETTINGS_FILE,
        SETTINGS_VERSION,
    )

    if LoadSettings(&app) {
        strings.write_string(
            &app.rd_key_input,
            app.rd_key,
        )
        fmt.printf(
            "[BOOT] Existing settings found; download folder=%s\n",
            app.download_path,
        )

        app.screen = .Loading
        app.load_status =
            "Syncing with FitGirl API..."

        StartLoader(&app)
    } else {
        if len(app.download_path) > 0 {
            delete(app.download_path)
            app.download_path = ""
        }

        fmt.println(
            "[BOOT] Settings unavailable. Launching setup screen.",
        )

        app.screen = .SetupKey
    }


    // -----------------------------------------------------
    // Main Loop
    // -----------------------------------------------------

    fmt.println(
        "[MAIN] Entering render loop",
    )

    frame_number: u64 = 0

    for !rl.WindowShouldClose() {
        frame_number += 1


        // -------------------------------------------------
        // Background loader completion
        // -------------------------------------------------

        if app.screen == .Loading {
            ProcessFinishedLoader(&app)
        }


        // -------------------------------------------------
        // Drawing
        // -------------------------------------------------

        rl.BeginDrawing()
        rl.ClearBackground(
            APP_BACKGROUND,
        )

        input :=
            orui.input_from_raylib()

        orui.begin_responsive_with_input(
            ctx,
            rl.GetScreenWidth(),
            rl.GetScreenHeight(),
            input,
        )

        switch app.screen {
        case .SetupKey:
            RenderSetupScreen(
                &app,
                theme,
            )

        case .Loading:
            RenderLoadingScreen(
                &app,
                theme,
            )

        case .Library:
            RenderLibraryScreen(
                &app,
                theme,
            )
        }

        renderCommands :=
            orui.end()

        for command in renderCommands {
            orui.render_command(
                command,
            )
        }

        rl.EndDrawing()

        // All temp strings generated by fmt.tprintf,
        // clone_to_cstring, etc. are no longer needed after
        // the frame has rendered.
        free_all(
            context.temp_allocator,
        )
    }


    // -----------------------------------------------------
    // Shutdown
    // -----------------------------------------------------

    fmt.printf(
        "[SHUTDOWN] Window requested close after %d frames\n",
        frame_number,
    )

    // Most important shutdown rule:
    // finish every curl-using worker BEFORE curl.global_cleanup().
    ShutdownLoader(&app)

    fmt.println(
        "[SHUTDOWN] Background loader stopped",
    )


    // -----------------------------------------------------
    // Release game-owned CPU/GPU resources while raylib is
    // still alive.
    // -----------------------------------------------------

    if len(app.games) > 0 {
        fmt.printf(
            "[SHUTDOWN] Releasing %d games\n",
            len(app.games),
        )

        DestroyGames(app.games)

        fmt.println(
            "[SHUTDOWN] Game resources released",
        )
    }

    if len(app.rd_key) > 0 {
        fmt.println(
            "[SHUTDOWN] Releasing API key memory",
        )

        delete(app.rd_key)
        app.rd_key = ""
    }

    if len(app.download_path) > 0 {
        fmt.println(
            "[SHUTDOWN] Releasing download path memory",
        )

        delete(app.download_path)
        app.download_path = ""
    }

    fmt.println(
        "[SHUTDOWN] FitDeck shutdown complete",
    )

    fmt.println("========================================")
}
