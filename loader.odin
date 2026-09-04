package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:thread"
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


// ---------------------------------------------------------
// Poll Completed Loader - MAIN THREAD ONLY
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
