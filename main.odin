package main

import "core:fmt"
import curl "vendor:curl"
import orui "orui"
import rl "vendor:raylib"


// ---------------------------------------------------------
// Execution Core
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

    if LoadSettings(&app) && EnsureRealDebridAccessToken(&app) {
        fmt.printf(
            "[BOOT] Existing settings found; download folder=%s\n",
            app.download_path,
        )

        app.screen = .Loading
        app.load_status =
            "Syncing with FitGirl API..."

        StartLoader(&app)
    } else {
        ClearRealDebridCredentials(&app)

        fmt.println(
            "[BOOT] Settings unavailable or Real-Debrid token expired. Launching setup screen.",
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
        // Authentication and background loader completion
        // -------------------------------------------------

        ProcessRealDebridAuth(&app)

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
    ShutdownRealDebridAuth(&app)
    DownloadManagerShutdown(&app.download_manager)

    fmt.println(
        "[SHUTDOWN] Download manager stopped",
    )

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
        "[SHUTDOWN] FitDeck shutdown complete",
    )

    fmt.println("========================================")
}
