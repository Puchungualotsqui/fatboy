package main

import "core:c"
import "core:fmt"
import curl "vendor:curl"
import orui "orui"
import rl "vendor:raylib"


// ---------------------------------------------------------
// Embedded assets
// ---------------------------------------------------------

EMBEDDED_FONT_DATA :: #load("font.ttf", []u8)


// ---------------------------------------------------------
// Execution Core
// ---------------------------------------------------------

main :: proc() {
    fmt.println("========================================")
    fmt.println("--- Starting Fatboy ---")
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
    app.download_provider = .RealDebrid
    app.games = make([dynamic]GameRelease, 0, CATALOG_GAME_RESERVE)
    app.cover_cache_needs_enforcement = true

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
    rl.SetConfigFlags({
        .WINDOW_RESIZABLE,
        .WINDOW_HIGHDPI,
        .MSAA_4X_HINT,
    })

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

    fmt.printf(
        "[BOOT] Loading embedded font.ttf (%d bytes)...\n",
        len(EMBEDDED_FONT_DATA),
    )
    ctx.default_font = rl.GetFontDefault()

    font_data, font_alloc_err := make(
        []u8,
        len(EMBEDDED_FONT_DATA),
        context.allocator,
    )
    if font_alloc_err == nil {
        copy(font_data, EMBEDDED_FONT_DATA)
        customFont := rl.LoadFontFromMemory(
            ".ttf",
            rawptr(&font_data[0]),
            c.int(len(font_data)),
            36,
            nil,
            0,
        )
        delete(font_data)

        if customFont.texture.id != 0 {
            rl.SetTextureFilter(
                customFont.texture,
                .BILINEAR,
            )

            ctx.default_font = customFont

            fmt.printf(
                "[BOOT] Embedded font loaded, texture=%d\n",
                customFont.texture.id,
            )
        } else {
            fmt.println(
                "[BOOT] WARNING: embedded font load failed; using default font",
            )
        }
    } else {
        fmt.printf(
            "[BOOT] WARNING: embedded font allocation failed: %v\n",
            font_alloc_err,
        )
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

    settings_loaded := LoadSettings(&app)
    provider_ready := settings_loaded
    if settings_loaded && app.download_provider == .RealDebrid {
        provider_ready = EnsureRealDebridAccessToken(&app)
    }

    if provider_ready {
        fmt.printf(
            "[BOOT] Existing settings found; provider=%s download folder=%s\n",
            app.download_provider == .Durrent ? "durrent" : "real-debrid",
            app.download_path,
        )

        app.screen = .Loading
        app.load_status =
            "Syncing with FitGirl API..."
    } else {
        if app.download_provider == .RealDebrid {
            ClearRealDebridCredentials(&app)
        }

        fmt.println(
            "[BOOT] Settings unavailable or provider authentication failed. Launching setup screen.",
        )

        app.screen = .SetupKey
    }


    // -----------------------------------------------------
    // Download manager
    // -----------------------------------------------------

    fmt.println(
        "[BOOT] Starting download manager...",
    )

    if !DownloadManagerInit(&app.download_manager, &app) {
        fmt.println(
            "[BOOT] WARNING: download manager could not be started",
        )
        app.status_message = "Download manager unavailable."
    }

    if app.screen == .Loading {
        RestorePersistedDownloadGames(&app)
        if app.download_manager.worker != nil {
            ResumePersistedDownloadJobs(&app)
        }
        StartLoader(&app)
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

        // F11 and Alt+Enter provide a discoverable fullscreen toggle while
        // keeping the normal window resizable through the window manager.
        if rl.IsKeyPressed(.F11) ||
           (rl.IsKeyDown(.LEFT_ALT) && rl.IsKeyPressed(.ENTER)) {
            rl.ToggleFullscreen()
        }


        // -------------------------------------------------
        // Authentication and background loader completion
        // -------------------------------------------------

        if app.download_provider == .RealDebrid || app.auth_thread != nil {
            ProcessRealDebridAuth(&app)
        }

        if app.screen == .Loading || app.loader_thread != nil {
            ProcessFinishedLoader(&app)
        }

        if app.screen == .Library {
            ProcessCatalogSearchInput(&app)
            if app.catalog_filter_pending {
                app.catalog_filter_pending = false
                CatalogRebuildVisiblePage(&app)
                app.selected_game = -1
            }
            ProcessCoverLoader(&app)
            QueueVisibleCoverDownloads(&app)
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

        if app.screen == .Library {
            RenderCatalogSearchBar(&app, ctx.default_font)
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
    ShutdownRealDebridAuth(&app)
    DownloadManagerShutdown(&app.download_manager)

    fmt.println(
        "[SHUTDOWN] Download manager stopped",
    )

    ShutdownLoader(&app)

    fmt.println(
        "[SHUTDOWN] Background loader stopped",
    )

    ShutdownCoverLoader(&app)


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
    } else {
        delete(app.games)
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

    if len(app.filtered_game_indices) > 0 {
        delete(app.filtered_game_indices)
    }

    if len(app.search_query) > 0 {
        delete(app.search_query)
        app.search_query = ""
    }

    if len(app.rd_key) > 0 {
        fmt.println(
            "[SHUTDOWN] Releasing Real-Debrid access token memory",
        )

        delete(app.rd_key)
        app.rd_key = ""
    }

    if len(app.rd_refresh_token) > 0 {
        delete(app.rd_refresh_token)
        app.rd_refresh_token = ""
    }
    if len(app.rd_client_id) > 0 {
        delete(app.rd_client_id)
        app.rd_client_id = ""
    }
    if len(app.rd_client_secret) > 0 {
        delete(app.rd_client_secret)
        app.rd_client_secret = ""
    }

    if len(app.download_path) > 0 {
        fmt.println(
            "[SHUTDOWN] Releasing download path memory",
        )

        delete(app.download_path)
        app.download_path = ""
    }

    fmt.println(
        "[SHUTDOWN] Fatboy shutdown complete",
    )

    fmt.println("========================================")
}
