package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:thread"
import "core:time"
import "base:runtime"
import orui "orui"
import rl "vendor:raylib"


// ---------------------------------------------------------
// Loader Control - MAIN THREAD ONLY
// ---------------------------------------------------------

StartLoader :: proc(app: ^App) {
    if app == nil {
        fmt.println("[MAIN] ERROR: StartLoader app=nil")
        return
    }

    StartCatalogPageLoader(
        app,
        1,
        app.search_query,
    )
}


StartCatalogPageLoader :: proc(app: ^App, api_page: int, query: string) {
    if app == nil {
        return
    }

    // A new search supersedes an older page request. Joining the old worker
    // here prevents partial query text from being dropped silently.
    ShutdownCoverLoader(app)
    if app.loader_thread != nil {
        ShutdownLoader(app)
    }

    fmt.printf(
        "[MAIN] Loading catalog page %d search=%q\n",
        api_page,
        query,
    )

    data := new(LoaderData)
    data.api_page = api_page
    data.query = strings.clone(query, context.allocator)

    t := thread.create(loader_proc)

    if t == nil {
        fmt.println("[MAIN] ERROR: thread.create returned nil")

        delete(data.query)
        free(data)

        app.load_status = "Error: Could not create catalog loader thread."
        return
    }

    t.data = data
    app.loader_data = data
    app.loader_thread = t

    if len(query) > 0 {
        app.load_status = "Searching catalog..."
    } else {
        app.load_status = "Loading catalog page..."
    }

    thread.start(t)
}


// ---------------------------------------------------------
// GPU Texture Loading - MAIN THREAD ONLY
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

        // Let raylib decode the image itself.
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

        // CPU-side decoded image is no longer needed after
        // LoadTextureFromImage().
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


CatalogVisibleIndices :: proc(app: ^App) -> []int {
    if app == nil || len(app.filtered_game_indices) == 0 {
        return nil
    }

    // filtered_game_indices is the already-loaded API page. It is not a
    // slice of the complete catalog, so no second UI-page offset applies.
    return app.filtered_game_indices[:]
}


COVER_CACHE_LIMIT :: 100


IsCoverCacheFile :: proc(name: string) -> bool {
    return strings.ends_with(name, ".png") ||
        strings.ends_with(name, ".jpg")
}


TouchCoverCacheFile :: proc(path: string) {
    if len(path) == 0 || !os.exists(path) {
        return
    }

    now := time.now()
    _ = os.chtimes(path, now, now)
}


CoverCacheFileProtected :: proc(
    app: ^App,
    relative_path, full_path: string,
) -> bool {
    if app == nil {
        return false
    }

    for game, game_index in app.games {
        if game.coverPath != relative_path &&
           game.coverPath != full_path {
            continue
        }

        if game.cover_loading {
            return true
        }

        for visible_index in CatalogVisibleIndices(app) {
            if visible_index == game_index {
                return true
            }
        }

        snapshot := DownloadSnapshotForGame(
            &app.download_manager,
            game_index,
        )
        if snapshot.found && snapshot.state == .Installed {
            return true
        }

        return false
    }

    return false
}


EnforceCoverCacheLimit :: proc(app: ^App) {
    if app == nil || !os.exists("covers") {
        return
    }

    files, read_err := os.read_all_directory_by_path(
        "covers",
        context.allocator,
    )
    if read_err != nil {
        return
    }
    defer os.file_info_slice_delete(files, context.allocator)

    evictable_count := 0
    for file in files {
        if !os.is_file(file.fullpath) || !IsCoverCacheFile(file.name) {
            continue
        }

        relative_path := fmt.aprintf(
            "covers/%s",
            file.name,
        )
        protected := CoverCacheFileProtected(
            app,
            relative_path,
            file.fullpath,
        )
        delete(relative_path)

        if !protected {
            evictable_count += 1
        }
    }

    for evictable_count > COVER_CACHE_LIMIT {
        oldest_index := -1
        oldest_nano: i64

        for file, file_index in files {
            if !os.is_file(file.fullpath) || !IsCoverCacheFile(file.name) {
                continue
            }

            relative_path := fmt.aprintf(
                "covers/%s",
                file.name,
            )
            protected := CoverCacheFileProtected(
                app,
                relative_path,
                file.fullpath,
            )
            delete(relative_path)

            if protected {
                continue
            }

            modified_nano := time.time_to_unix_nano(
                file.modification_time,
            )
            if oldest_index < 0 || modified_nano < oldest_nano {
                oldest_index = file_index
                oldest_nano = modified_nano
            }
        }

        if oldest_index < 0 {
            break
        }

        remove_err := os.remove(files[oldest_index].fullpath)
        if remove_err != nil {
            fmt.printf(
                "[CACHE] WARNING: could not evict cover %s: %v\n",
                files[oldest_index].name,
                remove_err,
            )
            break
        }

        fmt.printf(
            "[CACHE] Evicted least-recently-used cover %s\n",
            files[oldest_index].name,
        )
        evictable_count -= 1
    }

    app.cover_cache_needs_enforcement = false
}


LoadGameTextureAtIndex :: proc(app: ^App, game_index: int) {
    if app == nil ||
       game_index < 0 ||
       game_index >= len(app.games) {
        return
    }

    game := &app.games[game_index]

    if game.coverTex.id != 0 {
        now_seconds := rl.GetTime()
        if now_seconds - game.cover_last_touched >= 5 {
            TouchCoverCacheFile(game.coverPath)
            game.cover_last_touched = now_seconds
        }
        game.cover_attempted = true
        return
    }

    if len(game.coverPath) == 0 || !os.exists(game.coverPath) {
        return
    }

    path_cstr := strings.clone_to_cstring(
        game.coverPath,
        context.temp_allocator,
    )

    img := rl.LoadImage(path_cstr)

    if img.data == nil || img.width <= 0 || img.height <= 0 {
        remove_err := os.remove(game.coverPath)
        if remove_err != nil {
            fmt.printf(
                "[TEXTURE] WARNING: could not remove invalid cover %s: %v\n",
                game.coverPath,
                remove_err,
            )
        }

        game.cover_attempted = true
        return
    }

    game.coverTex = rl.LoadTextureFromImage(img)
    rl.UnloadImage(img)

    if game.coverTex.id != 0 {
        rl.SetTextureFilter(game.coverTex, .BILINEAR)
        TouchCoverCacheFile(game.coverPath)
        game.cover_last_touched = rl.GetTime()
    }

    game.cover_attempted = true
}


LoadVisibleGameTextures :: proc(app: ^App) {
    for game_index in CatalogVisibleIndices(app) {
        LoadGameTextureAtIndex(app, game_index)
    }
}


cover_loader_proc :: proc(t: ^thread.Thread) {
    context = runtime.default_context()

    if t == nil {
        return
    }

    data := cast(^CoverLoaderData)t.data
    if data == nil {
        return
    }

    pool: thread.Pool
    thread.pool_init(&pool, context.allocator, 8)
    thread.pool_start(&pool)

    for index := 0; index < len(data.tasks); index += 1 {
        thread.pool_add_task(
            &pool,
            context.allocator,
            download_worker,
            &data.tasks[index],
            index,
        )
    }

    thread.pool_finish(&pool)
    thread.pool_destroy(&pool)
}


ProcessCoverLoader :: proc(app: ^App) {
    if app == nil || app.cover_thread == nil {
        return
    }

    if !thread.is_done(app.cover_thread) {
        return
    }

    data := app.cover_data
    thread.destroy(app.cover_thread)
    app.cover_thread = nil
    app.cover_data = nil

    // The worker only writes image files. GPU texture creation must happen
    // on the main thread, so load only files for the current visible page.
    for &game in app.games {
        if game.cover_loading {
            game.cover_loading = false
            game.cover_attempted = true
        }
    }

    if data != nil {
        delete(data.tasks)
        free(data)
    }

    LoadVisibleGameTextures(app)
    app.cover_cache_needs_enforcement = true
    EnforceCoverCacheLimit(app)
}


QueueVisibleCoverDownloads :: proc(app: ^App) {
    if app == nil ||
       app.cover_thread != nil ||
       app.loader_thread != nil {
        return
    }

    // Existing cache files can be uploaded immediately without starting a
    // network worker.
    LoadVisibleGameTextures(app)
    if app.cover_cache_needs_enforcement {
        EnforceCoverCacheLimit(app)
    }

    data := new(CoverLoaderData)

    for game_index in CatalogVisibleIndices(app) {
        game := &app.games[game_index]

        if game.coverTex.id != 0 ||
           game.cover_loading ||
           game.cover_attempted {
            continue
        }

        if len(game.coverUrl) == 0 {
            game.cover_attempted = true
            continue
        }

        if len(game.coverPath) == 0 {
            game.cover_attempted = true
            continue
        }

        game.cover_loading = true
        append(&data.tasks, DownloadTask{game_ptr = game})
    }

    if len(data.tasks) == 0 {
        delete(data.tasks)
        free(data)
        return
    }

    t := thread.create(cover_loader_proc)
    if t == nil {
        for task in data.tasks {
            if task.game_ptr != nil {
                task.game_ptr.cover_loading = false
                task.game_ptr.cover_attempted = true
            }
        }

        delete(data.tasks)
        free(data)
        return
    }

    t.data = data
    app.cover_data = data
    app.cover_thread = t
    thread.start(t)
}


ShutdownCoverLoader :: proc(app: ^App) {
    if app == nil || app.cover_thread == nil {
        return
    }

    data := app.cover_data
    thread.destroy(app.cover_thread)
    app.cover_thread = nil
    app.cover_data = nil

    if data != nil {
        delete(data.tasks)
        free(data)
    }
}


CatalogPageCacheIndex :: proc(app: ^App, api_page: int, query: string) -> int {
    if app == nil {
        return -1
    }

    for page, page_index in app.catalog_pages {
        if page.api_page == api_page && page.query == query {
            return page_index
        }
    }

    return -1
}


CatalogClearVisiblePage :: proc(app: ^App) {
    if app == nil {
        return
    }

    if len(app.filtered_game_indices) > 0 {
        delete(app.filtered_game_indices)
    }

    app.filtered_game_indices = make([dynamic]int)
}


CatalogShowCachedPage :: proc(app: ^App, api_page: int, query: string) -> bool {
    if app == nil {
        return false
    }

    cache_index := CatalogPageCacheIndex(app, api_page, query)
    if cache_index < 0 {
        return false
    }

    CatalogClearVisiblePage(app)

    for game_index in app.catalog_pages[cache_index].game_indices {
        append(&app.filtered_game_indices, game_index)
    }

    app.catalog_page = api_page - 1
    app.catalog_has_next = app.catalog_pages[cache_index].has_next
    app.selected_game = -1
    return true
}


CatalogResetPages :: proc(app: ^App) {
    if app == nil {
        return
    }

    for &page in app.catalog_pages {
        if len(page.query) > 0 {
            delete(page.query)
        }
        if len(page.game_indices) > 0 {
            delete(page.game_indices)
        }
    }

    if len(app.catalog_pages) > 0 {
        delete(app.catalog_pages)
    }

    app.catalog_pages = make([dynamic]CatalogPageCache)
    CatalogClearVisiblePage(app)
    app.catalog_page = 0
    app.catalog_has_next = false
    app.selected_game = -1
}


FindCachedGameIndex :: proc(app: ^App, magnet_link: string) -> int {
    if app == nil || len(magnet_link) == 0 {
        return -1
    }

    for game, game_index in app.games {
        if game.magnetLink == magnet_link {
            return game_index
        }
    }

    return -1
}


CatalogAppendLoadedPage :: proc(
    app: ^App,
    loader_data: ^LoaderData,
) -> bool {
    if app == nil || loader_data == nil {
        return false
    }

    cache := CatalogPageCache{
        query = strings.clone(loader_data.query, context.allocator),
        api_page = loader_data.api_page,
        has_next = loader_data.raw_post_count >= CATALOG_API_PAGE_SIZE,
    }

    for game_index := 0; game_index < len(loader_data.games); game_index += 1 {
        existing_index := FindCachedGameIndex(
            app,
            loader_data.games[game_index].magnetLink,
        )

        if existing_index >= 0 {
            DestroyGame(&loader_data.games[game_index])
            append(&cache.game_indices, existing_index)
            continue
        }

        new_index := len(app.games)
        append(&app.games, loader_data.games[game_index])
        loader_data.games[game_index] = {}
        append(&cache.game_indices, new_index)
    }

    append(&app.catalog_pages, cache)
    cache_index := len(app.catalog_pages) - 1

    CatalogClearVisiblePage(app)
    for game_index in app.catalog_pages[cache_index].game_indices {
        append(&app.filtered_game_indices, game_index)
    }

    app.catalog_page = loader_data.api_page - 1
    app.catalog_has_next = app.catalog_pages[cache_index].has_next
    app.selected_game = -1
    return true
}


// ---------------------------------------------------------
// Poll Completed Loader - MAIN THREAD ONLY
// ---------------------------------------------------------

ProcessFinishedLoader :: proc(app: ^App) {
    if app == nil || app.loader_thread == nil {
        return
    }

    if !thread.is_done(app.loader_thread) {
        return
    }

    loader_data := app.loader_data
    thread.destroy(app.loader_thread)
    app.loader_thread = nil
    app.loader_data = nil

    if loader_data == nil {
        app.load_status = "Error: Loader returned invalid state."
        return
    }

    // A user can type another search term while a request is in flight. Do
    // not show stale results; discard them and request the current query.
    if loader_data.query != app.search_query {
        if len(loader_data.games) > 0 {
            DestroyGames(loader_data.games)
        }
        delete(loader_data.query)
        free(loader_data)
        StartCatalogPageLoader(app, 1, app.search_query)
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
        delete(loader_data.query)

        if len(loader_data.error_message) > 0 {
            app.load_status = loader_data.error_message
        } else {
            app.load_status = "Error loading catalog."
        }
        free(loader_data)
        return
    }

    // Stop the cover worker before app.games can grow. Cover tasks retain
    // pointers to existing records, and appending may move its backing array.
    ShutdownCoverLoader(app)

    requested_page := loader_data.api_page
    loaded_count := len(loader_data.games)

    if loaded_count > 0 {
        CatalogAppendLoadedPage(app, loader_data)
        app.load_status = "Catalog ready"
        app.status_message = "READY"
        app.screen = .Library
    } else {
        // A raw API page can contain only digest/non-release posts. Keep the
        // API page position and use the raw count to decide whether Next can
        // continue past this filtered page.
        CatalogClearVisiblePage(app)
        app.catalog_page = requested_page - 1
        app.catalog_has_next =
            loader_data.raw_post_count >= CATALOG_API_PAGE_SIZE
        app.load_status = "No releases on that page."
        app.status_message = "No releases found on that page."
    }

    fmt.printf(
        "[MAIN] Catalog page %d integrated: %d games\n",
        requested_page,
        loaded_count,
    )

    delete(loader_data.games)
    delete(loader_data.query)
    free(loader_data)
}


// ---------------------------------------------------------
// Shutdown Loader Safely
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

    fmt.println("[SHUTDOWN] Loader thread stopped")

    if loader_data != nil {
        if len(loader_data.games) > 0 {
            DestroyGames(loader_data.games)
        }
        if len(loader_data.query) > 0 {
            delete(loader_data.query)
        }

        free(loader_data)
    }
}


// ---------------------------------------------------------
// Loading Screen
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
