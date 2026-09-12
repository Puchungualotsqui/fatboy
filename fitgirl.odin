package main

import "core:fmt"
import "core:strings"
import "core:encoding/json"
import "core:mem"
import "core:os"
import "core:thread"
import "base:runtime"

import curl "vendor:curl"
import jpegpng "jpegpng"


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


FITGIRL_API_URL :: "https://fitgirl-repacks.site/wp-json/wp/v2/posts?per_page=30"

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
        "Mozilla/5.0 FitDeck/1.0",
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
