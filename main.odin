package main

import "core:fmt"
import "core:strings"
import "core:encoding/json"
import "core:mem"
import "core:thread"
import "core:os"
import "base:runtime"
import curl "vendor:curl"
import orui "orui"
import rl "vendor:raylib"

WINDOW_WIDTH :: 1280
WINDOW_HEIGHT :: 800
WINDOW_TITLE :: "FitDeck"
FITGIRL_API_URL :: "https://fitgirl-repacks.site/wp-json/wp/v2/posts?per_page=30"

RELEASE_ROW_HEIGHT :: 96
RELEASE_ROW_EXTENT :: 106

// --- Sober / Professional Monochrome Palette ---
APP_BACKGROUND       :: rl.Color{24, 24, 24, 255}
HEADER_BACKGROUND    :: rl.Color{32, 32, 32, 255}
LIST_BACKGROUND      :: rl.Color{24, 24, 24, 255}
ROW_BACKGROUND       :: rl.Color{38, 38, 38, 255}
ROW_HOVER_BACKGROUND :: rl.Color{48, 48, 48, 255}
ROW_FOCUS_BACKGROUND :: rl.Color{75, 75, 75, 255}
ACCENT_COLOR         :: rl.Color{180, 180, 180, 255}
TEXT_PRIMARY         :: rl.Color{225, 225, 225, 255}
TEXT_MUTED           :: rl.Color{140, 140, 140, 255}
BORDER_COLOR         :: rl.Color{55, 55, 55, 255}
STATUS_OK            :: rl.Color{120, 175, 135, 255}
STATUS_ERR           :: rl.Color{175, 120, 120, 255}

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

App :: struct {
    screen:         AppScreen,
    rd_key:         string,
    rd_key_input:   strings.Builder,

    // Background Loading State
    load_status:    string,
    load_done:      bool,
    games:          [dynamic]GameRelease,

    // Library State
    selected_game:  int,
    status_message: string,
}

DownloadTask :: struct {
    game_ptr: ^GameRelease,
}

LoaderData :: struct {
    app: ^App,
}

sanitize_filename :: proc(name: string, alloc := context.allocator) -> string {
    b: strings.Builder
    strings.builder_init(&b, alloc)
    for r in name {
        if (r >= 'A' && r <= 'Z') || (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
            strings.write_rune(&b, r)
        } else if r == ' ' || r == '-' {
            strings.write_rune(&b, '_')
        }
    }
    return strings.to_string(b)
}

// ---------------------------------------------------------
// 2. Thread Workers (No Temp Allocators to prevent leaks)
// ---------------------------------------------------------

download_worker :: proc(task: thread.Task) {
    t_data := cast(^DownloadTask)task.data
    game := t_data.game_ptr

    if os.exists(game.coverPath) do return

    url_lower := strings.to_lower(game.coverUrl, context.allocator)
    defer delete(url_lower)

    if !strings.contains(url_lower, ".webp") && !strings.contains(url_lower, ".avif") {
        builder: strings.Builder
        strings.builder_init(&builder, context.allocator)
        defer strings.builder_destroy(&builder)

        handle := curl.easy_init()
        if handle != nil {
            cstrUrl := strings.clone_to_cstring(game.coverUrl, context.allocator)
            defer delete(cstrUrl)

            curl.easy_setopt(handle, .URL, cstrUrl)
            curl.easy_setopt(handle, .FOLLOWLOCATION, 1)
            curl.easy_setopt(handle, .REFERER, "https://fitgirl-repacks.site/")
            curl.easy_setopt(handle, .USERAGENT, "Mozilla/5.0 (Windows NT 10.0; Win64; x64)")
            curl.easy_setopt(handle, .TIMEOUT, 10)
            curl.easy_setopt(handle, .WRITEFUNCTION, CurlWriteCallback)
            curl.easy_setopt(handle, .WRITEDATA, &builder)

            if curl.easy_perform(handle) == .E_OK {
                if len(builder.buf) > 10 {
                    header := string(builder.buf[:10])
                    if !strings.contains(header, "<!DOCTYPE") && !strings.contains(header, "<html") {
                        _ = os.write_entire_file(game.coverPath, builder.buf[:])
                    }
                }
            }
            curl.easy_cleanup(handle)
        }
    }
}

loader_proc :: proc(t: ^thread.Thread) {
    data := cast(^LoaderData)t.data
    app := data.app

    app.load_status = "Syncing with FitGirl API..."

    json_data := FetchLiveCatalog()
    if len(json_data) == 0 {
        app.load_status = "Error: Could not reach catalog."
        return
    }

    games := ParseGames(transmute([]byte)json_data)
    delete(json_data)

    app.load_status = "Caching Library Assets..."

    if !os.exists("covers") {
        os.make_directory("covers")
    }

    pool: thread.Pool
    thread.pool_init(&pool, context.allocator, 8)
    thread.pool_start(&pool)

    tasks := make([]DownloadTask, len(games))
    for i in 0..<len(games) {
        if len(games[i].coverUrl) > 0 {
            tasks[i].game_ptr = &games[i]
            thread.pool_add_task(&pool, context.allocator, download_worker, &tasks[i], i)
        }
    }

    thread.pool_finish(&pool)
    thread.pool_destroy(&pool)
    delete(tasks)

    app.games = games
    app.load_status = "Finalizing..."
    app.load_done = true
}

// ---------------------------------------------------------
// 3. Base API Functions
// ---------------------------------------------------------

CurlWriteCallback :: proc "c" (ptr: rawptr, elementSize, elementCount: uint, userData: rawptr) -> uint {
    context = runtime.default_context()
    actualSize := elementSize * elementCount
    builder := cast(^strings.Builder)userData
    data := mem.slice_ptr(cast(^byte)ptr, int(actualSize))
    strings.write_bytes(builder, data)
    return actualSize
}

FetchLiveCatalog :: proc() -> string {
    builder: strings.Builder
    strings.builder_init(&builder, context.allocator)
    defer strings.builder_destroy(&builder)

    curl.global_init(curl.GLOBAL_DEFAULT)
    defer curl.global_cleanup()

    handle := curl.easy_init()
    if handle == nil do return ""
    defer curl.easy_cleanup(handle)

    cstrUrl := strings.clone_to_cstring(FITGIRL_API_URL, context.allocator)
    defer delete(cstrUrl)

    curl.easy_setopt(handle, .URL, cstrUrl)
    curl.easy_setopt(handle, .FOLLOWLOCATION, 1)
    curl.easy_setopt(handle, .USERAGENT, "Mozilla/5.0 (X11; Linux x86_64)")
    curl.easy_setopt(handle, .WRITEFUNCTION, CurlWriteCallback)
    curl.easy_setopt(handle, .WRITEDATA, &builder)

    _ = curl.easy_perform(handle)
    return strings.clone(strings.to_string(builder), context.allocator)
}

ExtractMagnet :: proc(html: string) -> string {
    prefix := "magnet:?xt=urn:btih:"
    index := strings.index(html, prefix)
    if index == -1 do return ""

    rest := html[index:]
    endIndex := strings.index_any(rest, "\"'> \t")
    if endIndex == -1 do return rest

    return rest[:endIndex]
}

ExtractImageURL :: proc(html: string) -> string {
    img_idx := strings.index(html, "<img")
    if img_idx == -1 do return ""
    rest := html[img_idx:]

    src_prefix := "src=\""
    src_idx := strings.index(rest, src_prefix)
    if src_idx == -1 do return ""

    start_idx := src_idx + len(src_prefix)
    end_idx := strings.index(rest[start_idx:], "\"")
    if end_idx == -1 do return ""

    return rest[start_idx : start_idx+end_idx]
}

ParseGames :: proc(data: []byte) -> [dynamic]GameRelease {
    games := make([dynamic]GameRelease)
    value, err := json.parse(data)
    if err != .None do return games
    defer json.destroy_value(value)

    rootArray, ok := value.(json.Array)
    if !ok do return games

    for item in rootArray {
        post, _ := item.(json.Object)
        titleObject, _ := post["title"].(json.Object)
        titleString, _ := titleObject["rendered"].(json.String)
        contentObject, _ := post["content"].(json.Object)
        contentString, _ := contentObject["rendered"].(json.String)

        clean1, _ := strings.replace_all(string(titleString), "&#8211;", "-", context.allocator)
        cleanTitle, _ := strings.replace_all(clean1, "&#8217;", "'", context.allocator)
        delete(clean1)

        htmlContent := string(contentString)
        magnetLink := ExtractMagnet(htmlContent)
        coverUrl := ExtractImageURL(htmlContent)

        if len(magnetLink) == 0 {
            delete(cleanTitle)
            continue
        }

        lowerTitle := strings.to_lower(cleanTitle, context.allocator)
        if strings.contains(lowerTitle, "upcoming repacks") || strings.contains(lowerTitle, "updates digest") {
            delete(cleanTitle)
            delete(lowerTitle)
            continue
        }
        delete(lowerTitle)

        safeName := sanitize_filename(cleanTitle, context.allocator)
        ext := ".jpg"

        urlLower := strings.to_lower(coverUrl, context.allocator)
        if strings.contains(urlLower, ".png") do ext = ".png"
        delete(urlLower)

        coverPath := fmt.tprintf("covers/%s%s", safeName, ext)

        append(&games, GameRelease{
            title      = strings.clone(cleanTitle),
            magnetLink = strings.clone(magnetLink),
            coverUrl   = strings.clone(coverUrl),
            coverPath  = strings.clone(coverPath),
        })
        delete(cleanTitle)
        delete(safeName)
    }
    return games
}

// ---------------------------------------------------------
// 4. UI Screens
// ---------------------------------------------------------

RenderSetupScreen :: proc(app: ^App, theme: orui.Theme) {
    {orui.container(orui.id("setup_root"), {
        layout = .Flex, direction = .TopToBottom, width = orui.grow(), height = orui.grow(),
        align_main = .Center, align_cross = .Center, background_color = APP_BACKGROUND,
    })
        {orui.container(orui.id("setup_panel"), {
            layout = .Flex, direction = .TopToBottom, width = orui.fixed(460), height = orui.fit(),
            padding = orui.padding(32), gap = 16, background_color = ROW_BACKGROUND,
            border = orui.border(1), border_color = BORDER_COLOR, corner_radius = orui.corner(8),
        })
            orui.label(orui.id("setup_title"), "Real-Debrid Configuration", { font_size = 24, color = TEXT_PRIMARY })
            orui.label(orui.id("setup_desc"), "Please provide your API token to unrestrict FitGirl downloads automatically.", {
                font_size = 14, color = TEXT_MUTED, overflow = .Wrap
            })

            orui.text_input(orui.id("rd_key_input"), &app.rd_key_input, {
                width = orui.grow(), height = orui.fixed(42),
                padding = orui.padding(12, 0), background_color = APP_BACKGROUND,
                border = orui.border(1), border_color = BORDER_COLOR, corner_radius = orui.corner(6),
                placeholder = "API Token...",
            })

            if len(app.rd_key_input.buf) == 0 {
                orui.label(orui.id("setup_warn"), "API Key is required to continue.", { font_size = 12, color = STATUS_ERR })
            } else {
                if orui.button(orui.id("btn_save"), "Save & Continue", {
                    width = orui.grow(), height = orui.fixed(44),
                    background_color = ACCENT_COLOR, color = APP_BACKGROUND, corner_radius = orui.corner(6),
                }) {
                    app.rd_key = strings.clone(strings.to_string(app.rd_key_input))
                    _ = os.write_entire_file("rd_key.txt", app.rd_key_input.buf[:])

                    // Route to Loading state
                    app.screen = .Loading

                    // Spawn loader thread
                    t_data := new(LoaderData)
                    t_data.app = app
                    t := thread.create(loader_proc)
                    t.data = t_data
                    thread.start(t)
                }
            }
        }
    }
}

RenderLoadingScreen :: proc(app: ^App, theme: orui.Theme) {
    {orui.container(orui.id("load_root"), {
        layout = .Flex, direction = .TopToBottom, width = orui.grow(), height = orui.grow(),
        align_main = .Center, align_cross = .Center, background_color = APP_BACKGROUND, gap = 16,
    })
        orui.label(orui.id("load_title"), "Booting Library", { font_size = 24, color = TEXT_PRIMARY })
        orui.label(orui.id("load_status"), app.load_status, { font_size = 14, color = ACCENT_COLOR })
    }
}

RenderLibraryScreen :: proc(app: ^App, theme: orui.Theme) {
    {orui.container(orui.id("app"), {
        layout = .Flex, direction = .TopToBottom, width = orui.grow(), height = orui.grow(),
        background_color = APP_BACKGROUND,
    })
        {orui.container(orui.id("top_nav"), {
            layout = .Flex, direction = .LeftToRight, width = orui.grow(), height = orui.fixed(80),
            align_cross = .Center, align_main = .SpaceBetween, padding = orui.Edges{top = 0, right = 32, bottom = 0, left = 32},
            background_color = HEADER_BACKGROUND, border = orui.Edges{top = 0, right = 0, bottom = 1, left = 0}, border_color = BORDER_COLOR,
        })
            {orui.container(orui.id("brand_wrap"), { layout = .Flex, direction = .TopToBottom, width = orui.fit(), height = orui.fit() })
                orui.label(orui.id("title"), "FitDeck", { font_size = 28, color = TEXT_PRIMARY })
                orui.label(orui.id("subtitle"), "Real-Debrid Library Integration", { font_size = 13, color = ACCENT_COLOR })
            }
            {orui.container(orui.id("status_wrap"), { layout = .Flex, direction = .TopToBottom, width = orui.fit(), height = orui.fit(), align_cross = .End, gap = 4 })
                orui.label(orui.id("catalog count"), fmt.tprintf("%d Games Found", len(app.games)), { font_size = 14, color = TEXT_PRIMARY })
                if orui.button(orui.id("btn_settings"), "Reset API Key", { height = orui.fixed(24), padding = orui.padding(8, 0) }) {
                    app.screen = .SetupKey
                }
            }
        }

        {orui.container(orui.id("main_content"), {
            layout = .Flex, direction = .TopToBottom, width = orui.grow(), height = orui.grow(),
            padding = orui.Edges{top = 24, right = 32, bottom = 24, left = 32}, gap = 12,
        })
            {orui.container(orui.id("release heading"), {
                layout = .Flex, direction = .LeftToRight, width = orui.grow(), height = orui.fit(),
                align_cross = .Center, align_main = .SpaceBetween, padding = orui.Edges{top = 0, right = 4, bottom = 8, left = 4},
            })
                orui.label(orui.id("release heading title"), "AVAILABLE RELEASES", { font_size = 14, color = TEXT_MUTED, letter_spacing = 1 })
            }

            if len(app.games) > 0 {
                list := orui.begin_virtual_list(orui.id("releases"), {
                    width = orui.grow(), height = orui.grow(), scroll = orui.scroll(.Vertical),
                    clip = {.Self, {}}, background_color = LIST_BACKGROUND,
                }, {
                    direction = .Vertical, item_count = len(app.games), item_extent = RELEASE_ROW_EXTENT, overscan = 2,
                })

                for index := list.first; index < list.last; index += 1 {
                    game := app.games[index]
                    rowId := orui.virtual_list_item_id(list.id, index)

                    isFocused := index == app.selected_game || orui.focused(rowId) || orui.active(rowId)
                    isHovered := orui.hovered(rowId)

                    rowBg := ROW_BACKGROUND
                    if isFocused do rowBg = ROW_FOCUS_BACKGROUND
                    else if isHovered do rowBg = ROW_HOVER_BACKGROUND

                    rowBorder := isFocused ? ACCENT_COLOR : BORDER_COLOR
                    titleColor := isFocused ? rl.WHITE : TEXT_PRIMARY
                    badgeTextColor := isFocused ? rl.WHITE : STATUS_OK

                    {orui.container(orui.id(rowId), orui.virtual_list_item_config(list, index, {
                        layout = .Flex, direction = .LeftToRight, width = orui.percent(1), height = orui.fixed(RELEASE_ROW_HEIGHT),
                        padding = orui.Edges{top = 0, right = 20, bottom = 0, left = 12},
                        align_cross = .Center, align_main = .SpaceBetween,
                        background_color = rowBg, border = orui.border(1), border_color = rowBorder, corner_radius = orui.corner(6),
                        focusable = true, block = .True, cursor = .Pointing_Hand,
                    }))

                        {orui.container(orui.id(fmt.tprintf("info_wrap_%d", index)), {
                            layout = .Flex, direction = .LeftToRight, height = orui.grow(), align_cross = .Center, gap = 16,
                        })
                            if game.coverTex.id != 0 {
                                orui.image(orui.id(fmt.tprintf("cover_%d", index)), &app.games[index].coverTex, {
                                    width = orui.fixed(56), height = orui.fixed(76),
                                    texture_fit = .Cover, corner_radius = orui.corner(4), border = orui.border(1), border_color = BORDER_COLOR,
                                })
                            } else {
                                {orui.container(orui.id(fmt.tprintf("cover_ph_%d", index)), {
                                    width = orui.fixed(56), height = orui.fixed(76),
                                    background_color = HEADER_BACKGROUND, corner_radius = orui.corner(4),
                                })}
                            }

                            orui.label(orui.id(fmt.tprintf("title_%d", index)), game.title, { font_size = 18, color = titleColor, disabled = .True })
                        }

                        {orui.container(orui.id(fmt.tprintf("badge_%d", index)), {
                            layout = .Flex, direction = .LeftToRight, width = orui.fixed(120), height = orui.fixed(26),
                            align_main = .Center, align_cross = .Center, background_color = rl.Color{0, 0, 0, 40}, corner_radius = orui.corner(13),
                        })
                            orui.label(orui.id(fmt.tprintf("badgetext_%d", index)), "MAGNET READY", { font_size = 11, color = badgeTextColor, disabled = .True })
                        }
                    }

                    if orui.clicked(rowId) || orui.activated(rowId) {
                        app.selected_game = index
                        app.status_message = "Handing off to Real-Debrid API..."
                        // TODO: Fire Real Debrid Pipeline here!
                    }
                }
                orui.end_virtual_list()
            }
            {orui.container(orui.id("footer"), {
                layout = .Flex, direction = .LeftToRight, width = orui.grow(), height = orui.fit(),
                align_cross = .Center, align_main = .SpaceBetween, padding = orui.Edges{top = 12, right = 0, bottom = 0, left = 0},
            })
                orui.label(orui.id("footer source"), "SOURCE: FITGIRL-REPACKS.SITE", { font_size = 11, color = TEXT_MUTED })
                orui.label(orui.id("footer msg"), app.status_message, { font_size = 11, color = ACCENT_COLOR })
            }
        }
    }
}

// ---------------------------------------------------------
// 5. Execution Core
// ---------------------------------------------------------

main :: proc() {
    app: App
    strings.builder_init(&app.rd_key_input)
    defer strings.builder_destroy(&app.rd_key_input)
    app.status_message = "READY"

    // Check if key exists
    data, err := os.read_entire_file_from_path("rd_key.txt", context.allocator)
    if err == nil {
        app.rd_key = strings.clone(string(data))
        strings.write_string(&app.rd_key_input, app.rd_key)
        delete(data)

        // Start Loader
        app.screen = .Loading
        t_data := new(LoaderData)
        t_data.app = &app
        t := thread.create(loader_proc)
        t.data = t_data
        thread.start(t)
    } else {
        app.screen = .SetupKey
    }

    // --- GUI Init ---
    rl.SetTraceLogLevel(.FATAL) // KILL TERMINAL SPAM!
    rl.SetConfigFlags({.MSAA_4X_HINT})
    rl.InitWindow(WINDOW_WIDTH, WINDOW_HEIGHT, WINDOW_TITLE)
    defer rl.CloseWindow()
    rl.SetTargetFPS(60)

    ctx := new(orui.Context)
    defer free(ctx)
    orui.init(ctx)
    defer orui.destroy(ctx)
    orui.set_input_trace(ctx, false)

    if rl.FileExists("font.ttf") {
        customFont := rl.LoadFontEx("font.ttf", 36, nil, 0)
        rl.SetTextureFilter(customFont.texture, .BILINEAR)
        ctx.default_font = customFont
    } else {
        ctx.default_font = rl.GetFontDefault()
    }

    theme := orui.default_theme()
    theme.button_background = ROW_BACKGROUND
    theme.button_hover = ROW_HOVER_BACKGROUND
    theme.button_focused = ROW_FOCUS_BACKGROUND
    theme.selected = ROW_FOCUS_BACKGROUND
    theme.focus_border = rl.BLANK
    theme.border = BORDER_COLOR
    theme.text = TEXT_PRIMARY
    orui.set_theme(ctx, theme)

    for !rl.WindowShouldClose() {
        // Safe context checking - when the thread finishes, we convert the disk caches to GPU textures
        if app.screen == .Loading && app.load_done {
            for &game in app.games {
                if os.exists(game.coverPath) {
                    path_cstr := strings.clone_to_cstring(game.coverPath, context.temp_allocator)
                    game.coverTex = rl.LoadTexture(path_cstr)
                    if game.coverTex.id != 0 {
                        rl.SetTextureFilter(game.coverTex, .BILINEAR)
                    }
                }
            }
            app.screen = .Library
            app.load_done = false
        }

        rl.BeginDrawing()
        rl.ClearBackground(APP_BACKGROUND)

        input := orui.input_from_raylib()
        orui.begin_responsive_with_input(ctx, rl.GetScreenWidth(), rl.GetScreenHeight(), input)

        switch app.screen {
        case .SetupKey: RenderSetupScreen(&app, theme)
        case .Loading:  RenderLoadingScreen(&app, theme)
        case .Library:  RenderLibraryScreen(&app, theme)
        }

        renderCommands := orui.end()
        for command in renderCommands {
            orui.render_command(command)
        }

        rl.EndDrawing()
        free_all(context.temp_allocator)
    }
}
