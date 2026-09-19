package main

import "core:fmt"
import "core:strings"
import orui "./orui"
import rl "vendor:raylib"


CatalogSearchBounds :: proc() -> rl.Rectangle {
    screen_width := rl.GetScreenWidth()
    x := f32(screen_width / 2 - 170)

    if x < 260 {
        x = 260
    }

    if x + 340 > f32(screen_width - 32) {
        x = f32(screen_width - 372)
    }

    if x < 12 {
        x = 12
    }

    return rl.Rectangle{
        x = x,
        y = 23,
        width = 340,
        height = 34,
    }
}


RebuildFilteredGameIndices :: proc(app: ^App) {
    if app == nil {
        return
    }

    // The catalog is now server-paged. A search starts a new page-1 request
    // instead of pretending that the currently cached pages are complete.
    CatalogResetPages(app)
    app.search_pending = false
    if len(app.search_query) > 0 {
        app.load_status = "Searching catalog..."
    } else {
        app.load_status = "Loading catalog page..."
    }
    StartCatalogPageLoader(app, 1, app.search_query)
}


search_query_append_rune :: proc(app: ^App, value: rune) {
    if app == nil {
        return
    }

    old_query := app.search_query

    builder: strings.Builder
    strings.builder_init(&builder, context.allocator)
    strings.write_string(&builder, old_query)
    strings.write_rune(&builder, value)

    app.search_query = strings.to_string(builder)

    if len(old_query) > 0 {
        delete(old_query)
    }
}


search_query_remove_last_rune :: proc(app: ^App) {
    if app == nil || len(app.search_query) == 0 {
        return
    }

    old_query := app.search_query
    end := len(old_query) - 1

    // Move over UTF-8 continuation bytes so backspace removes one rune.
    for end > 0 && (old_query[end] & 0xc0) == 0x80 {
        end -= 1
    }

    app.search_query = strings.clone(
        old_query[:end],
        context.allocator,
    )
    delete(old_query)
}


RequestCatalogPage :: proc(app: ^App, api_page: int) {
    if app == nil || api_page <= 0 {
        return
    }

    if CatalogShowCachedPage(app, api_page, app.search_query) {
        app.status_message = "READY"
        return
    }

    if app.loader_thread != nil {
        return
    }

    // Prevent the page integration from growing app.games while cover tasks
    // still hold pointers into its current backing array.
    ShutdownCoverLoader(app)
    CatalogClearVisiblePage(app)
    app.selected_game = -1
    app.load_status = "Loading catalog page..."
    app.status_message = "Loading page..."
    StartCatalogPageLoader(app, api_page, app.search_query)
}


ProcessCatalogSearchInput :: proc(app: ^App) {
    if app == nil || app.screen != .Library {
        return
    }

    bounds := CatalogSearchBounds()
    mouse := rl.GetMousePosition()

    if rl.IsMouseButtonPressed(.LEFT) {
        app.search_focused = rl.CheckCollisionPointRec(mouse, bounds)
    }

    if !app.search_focused {
        return
    }

    text_changed := false

    for {
        codepoint := rl.GetCharPressed()
        if codepoint == 0 {
            break
        }

        if codepoint >= 32 && codepoint != 127 {
            search_query_append_rune(app, rune(codepoint))
            text_changed = true
        }
    }

    if rl.IsKeyPressed(.BACKSPACE) {
        search_query_remove_last_rune(app)
        text_changed = true
    }

    if text_changed {
        app.search_pending = true
        app.search_changed_at = rl.GetTime()
    }

    if rl.IsKeyPressed(.ESCAPE) {
        app.search_focused = false
        app.search_pending = false
    }

    // Enter submits immediately, but normal typing is submitted after a
    // short quiet period. This avoids one HTTP request per keystroke while
    // keeping the field responsive without requiring Enter.
    submit_search :=
        rl.IsKeyPressed(.ENTER) ||
        rl.IsKeyPressed(.KP_ENTER)
    debounce_elapsed :=
        app.search_pending &&
        rl.GetTime() - app.search_changed_at >= SEARCH_DEBOUNCE_SECONDS

    if submit_search || debounce_elapsed {
        RebuildFilteredGameIndices(app)
    }
}


RenderCatalogSearchBar :: proc(app: ^App, font: rl.Font) {
    if app == nil {
        return
    }

    bounds := CatalogSearchBounds()
    background := HEADER_BACKGROUND
    border := BORDER_COLOR
    text_color := TEXT_PRIMARY
    display_text := app.search_query

    if app.search_focused {
        border = ACCENT_COLOR
    }

    if len(display_text) == 0 {
        if app.search_focused {
            display_text = "Search as you type..."
        } else {
            display_text = "Search games..."
        }
        text_color = TEXT_MUTED
    }

    rl.DrawRectangleRec(bounds, background)
    rl.DrawRectangleLinesEx(bounds, 1, border)
    display_cstr := strings.clone_to_cstring(
        display_text,
        context.temp_allocator,
    )

    rl.DrawTextEx(
        font,
        display_cstr,
        rl.Vector2{bounds.x + 12, bounds.y + 7},
        16,
        0,
        text_color,
    )

    if app.search_focused && len(app.search_query) > 0 {
        query_cstr := strings.clone_to_cstring(
            app.search_query,
            context.temp_allocator,
        )
        text_size := rl.MeasureTextEx(
            font,
            query_cstr,
            16,
            0,
        )

        if int(rl.GetTime() * 2) % 2 == 0 {
            rl.DrawRectangle(
                i32(bounds.x + 12 + text_size.x),
                i32(bounds.y) + 8,
                1,
                18,
                TEXT_PRIMARY,
            )
        }
    }
}


// ---------------------------------------------------------
// Library Screen
// ---------------------------------------------------------

RenderLibraryScreen :: proc(
    app: ^App,
    theme: orui.Theme,
) {
    filtered_count := len(app.filtered_game_indices)
    page_start := 0
    page_end := filtered_count
    catalog_count_label := fmt.tprintf(
        "%d Games on Page %d",
        filtered_count,
        app.catalog_page + 1,
    )
    if app.show_installed_only {
        catalog_count_label = fmt.tprintf(
            "%d Installed / In-progress on Page %d",
            filtered_count,
            app.catalog_page + 1,
        )
    }

    if app.loader_thread != nil {
        catalog_count_label = "Loading catalog..."
    }

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
                    "Fatboy",
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
                    catalog_count_label,
                    {
                        font_size = 14,
                        color = TEXT_PRIMARY,
                    },
                )

                if orui.button(
                    orui.id("btn_settings"),
                    "⚙ Settings",
                    {
                        width = orui.fixed(110),
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
                    // Settings can be opened while a download is active so
                    // users can inspect configuration or adjust safe options.
                    // Save & Launch retains the active-work guard before any
                    // download path or credentials are committed.
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

                if orui.checkbox(
                    orui.id("installed_filter"),
                    "Installed / in-progress",
                    &app.show_installed_only,
                    {
                        width = orui.fixed(220),
                        height = orui.fixed(30),
                    },
                ) {
                    app.catalog_filter_pending = true
                }
            }

            if app.loader_thread != nil {
                spinner := "|"
                spinner_phase := int(rl.GetTime() * 8) % 4
                if spinner_phase == 1 {
                    spinner = "/"
                } else if spinner_phase == 2 {
                    spinner = "-"
                } else if spinner_phase == 3 {
                    spinner = "\\"
                }

                orui.label(
                    orui.id("catalog_loading"),
                    fmt.tprintf(
                        "Loading releases %s",
                        spinner,
                    ),
                    {
                        font_size = 16,
                        color = ACCENT_COLOR,
                    },
                )
            } else if filtered_count > 0 {
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
                        item_count = page_end - page_start,
                        item_extent = RELEASE_ROW_EXTENT,
                        overscan = 2,
                    },
                )

                for row_index := list.first;
                    row_index < list.last;
                    row_index += 1 {

                    filtered_index := page_start + row_index
                    game_index := app.filtered_game_indices[filtered_index]
                    game := app.games[game_index]
                    download_snapshot := DownloadSnapshotForGame(
                        &app.download_manager,
                        game_index,
                    )

                    rowId := orui.virtual_list_item_id(
                        list.id,
                        row_index,
                    )

                    isFocused :=
                        game_index == app.selected_game ||
                        orui.focused(rowId) ||
                        orui.active(rowId)

                    isHovered := orui.hovered(rowId)

                    rowBg := ROW_BACKGROUND

                    if isFocused {
                        rowBg = ROW_FOCUS_BACKGROUND
                    } else if isHovered {
                        rowBg = ROW_HOVER_BACKGROUND
                    } else if download_snapshot.found &&
                              download_snapshot.state == .Installed {
                        rowBg = rl.Color{34, 50, 40, 255}
                    }

                    rowBorder := isFocused ? ACCENT_COLOR : BORDER_COLOR
                    titleColor := isFocused ? rl.WHITE : TEXT_PRIMARY
                    badgeTextColor := isFocused ? rl.WHITE : STATUS_OK
                    if download_snapshot.found &&
                       download_snapshot.state == .Failed {
                        badgeTextColor = STATUS_ERR
                    } else if download_snapshot.found &&
                              download_snapshot.state != .Installed {
                        badgeTextColor = ACCENT_COLOR
                    }

                    badgeText := DownloadStateText(download_snapshot.state)
                    if download_snapshot.state == .Downloading ||
                       download_snapshot.state == .Extracting {
                        badgeText = fmt.tprintf(
                            "%s %d%%",
                            DownloadStateText(download_snapshot.state),
                            int(download_snapshot.progress * 100),
                        )
                    }

                    {
                        orui.container(
                            orui.id(rowId),
                            orui.virtual_list_item_config(
                                list,
                                row_index,
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
                                        game_index,
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
                                            game_index,
                                        ),
                                    ),
                                    &app.games[game_index].coverTex,
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
                                                game_index,
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

                            {
                                orui.container(
                                    orui.id(
                                        fmt.tprintf(
                                            "text_wrap_%d",
                                            game_index,
                                        ),
                                    ),
                                    {
                                        layout = .Flex,
                                        direction = .TopToBottom,
                                        height = orui.fit(),
                                        gap = 4,
                                    },
                                )

                                orui.label(
                                    orui.id(
                                        fmt.tprintf(
                                            "title_%d",
                                            game_index,
                                        ),
                                    ),
                                    game.title,
                                    {
                                        font_size = 18,
                                        color = titleColor,
                                        disabled = .True,
                                    },
                                )

                                if download_snapshot.found &&
                                   (download_snapshot.state == .Downloading ||
                                    download_snapshot.state == .Extracting) {
                                    fallback_message := "Extracting archive..."
                                    if download_snapshot.state == .Downloading {
                                        fallback_message = "Downloading game archive..."
                                    }
                                    phase_message := fallback_message
                                    if len(download_snapshot.status_message) > 0 {
                                        phase_message = download_snapshot.status_message
                                    }
                                    progress_color := TEXT_MUTED
                                    if download_snapshot.state == .Downloading {
                                        progress_color = STATUS_OK
                                    }
                                    progress_label := fmt.tprintf(
                                        "%s  %d%%  %d/%d MiB",
                                        phase_message,
                                        int(download_snapshot.progress * 100),
                                        download_snapshot.bytes_downloaded / (1024 * 1024),
                                        download_snapshot.bytes_total / (1024 * 1024),
                                    )
                                    orui.label(
                                        orui.id(
                                            fmt.tprintf(
                                                "progress_%d",
                                                game_index,
                                            ),
                                        ),
                                        progress_label,
                                        {
                                            font_size = 12,
                                            color = progress_color,
                                            disabled = .True,
                                        },
                                    )
                                } else if download_snapshot.found &&
                                          download_snapshot.state == .Resolving {
                                    resolving_message := download_snapshot.status_message
                                    if len(resolving_message) == 0 {
                                        resolving_message = "Preparing Real-Debrid torrent..."
                                    }
                                    orui.label(
                                        orui.id(
                                            fmt.tprintf(
                                                "progress_%d",
                                                game_index,
                                            ),
                                        ),
                                        resolving_message,
                                        {
                                            font_size = 12,
                                            color = TEXT_MUTED,
                                            disabled = .True,
                                        },
                                    )
                                } else if download_snapshot.found &&
                                          download_snapshot.state == .Installing {
                                    orui.label(
                                        orui.id(
                                            fmt.tprintf(
                                                "progress_%d",
                                                game_index,
                                            ),
                                        ),
                                        "Installing through GE-Proton8-25...",
                                        {
                                            font_size = 12,
                                            color = STATUS_OK,
                                            disabled = .True,
                                        },
                                    )
                                } else if download_snapshot.found &&
                                          download_snapshot.state == .Extracted {
                                    extracted_message := download_snapshot.status_message
                                    if len(extracted_message) == 0 {
                                        extracted_message = "Archive extracted; installer not run."
                                    }
                                    orui.label(
                                        orui.id(
                                            fmt.tprintf(
                                                "progress_%d",
                                                game_index,
                                            ),
                                        ),
                                        extracted_message,
                                        {
                                            font_size = 12,
                                            color = ACCENT_COLOR,
                                            disabled = .True,
                                        },
                                    )
                                } else if download_snapshot.found &&
                                          download_snapshot.state == .Failed {
                                    failure_message := download_snapshot.error_message
                                    if len(failure_message) == 0 {
                                        failure_message = "Installation failed; retry."
                                    }
                                    orui.label(
                                        orui.id(
                                            fmt.tprintf(
                                                "progress_%d",
                                                game_index,
                                            ),
                                        ),
                                        failure_message,
                                        {
                                            font_size = 12,
                                            color = STATUS_ERR,
                                            disabled = .True,
                                        },
                                    )
                                }
                            }
                        }

                        {
                            orui.container(
                                orui.id(
                                    fmt.tprintf(
                                        "download_actions_%d",
                                        game_index,
                                    ),
                                ),
                                {
                                    layout = .Flex,
                                    direction = .LeftToRight,
                                    width = orui.fit(),
                                    height = orui.fit(),
                                    align_cross = .Center,
                                    gap = 8,
                                },
                            )

                            {
                                orui.container(
                                    orui.id(
                                        fmt.tprintf(
                                            "badge_%d",
                                            game_index,
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
                                            game_index,
                                        ),
                                    ),
                                    badgeText,
                                    {
                                        font_size = 11,
                                        color = badgeTextColor,
                                        disabled = .True,
                                    },
                                )
                            }

                            can_pause :=
                                download_snapshot.found &&
                                (download_snapshot.state == .Resolving ||
                                 download_snapshot.state == .Downloading ||
                                 download_snapshot.state == .Extracting ||
                                 download_snapshot.state == .Installing)
                            can_cancel :=
                                download_snapshot.found &&
                                (download_snapshot.state == .Queued ||
                                 download_snapshot.state == .Resolving ||
                                 download_snapshot.state == .Downloading ||
                                 download_snapshot.state == .Extracting ||
                                 download_snapshot.state == .Installing)
                            can_queue :=
                                !download_snapshot.found ||
                                download_snapshot.state == .Cancelled ||
                                download_snapshot.state == .Paused ||
                                download_snapshot.state == .Failed ||
                                download_snapshot.state == .Extracted

                            if can_pause {
                                if orui.button(
                                    orui.id(
                                        fmt.tprintf("pause_download_%d", game_index),
                                    ),
                                    "Pause",
                                    {
                                        width = orui.fixed(72),
                                        height = orui.fixed(28),
                                        background_color = ROW_HOVER_BACKGROUND,
                                        color = TEXT_PRIMARY,
                                        corner_radius = orui.corner(5),
                                    },
                                ) {
                                    if DownloadPauseGame(&app.download_manager, game_index) {
                                        app.status_message = "Pause requested. Partial data will be preserved."
                                    }
                                }
                            }

                            if can_cancel {
                                if orui.button(
                                    orui.id(
                                        fmt.tprintf(
                                            "cancel_download_%d",
                                            game_index,
                                        ),
                                    ),
                                    "Cancel",
                                    {
                                        width = orui.fixed(72),
                                        height = orui.fixed(28),
                                        background_color = ROW_HOVER_BACKGROUND,
                                        color = TEXT_PRIMARY,
                                        corner_radius = orui.corner(5),
                                    },
                                ) {
                                    if DownloadCancelGame(
                                        &app.download_manager,
                                        game_index,
                                    ) {
                                        app.status_message =
                                            "Download cancellation requested."
                                    }
                                }
                            } else if can_queue {
                                queue_label := download_snapshot.state == .Paused ? "Resume" :
                                    download_snapshot.state == .Extracted ? "Install" : "Download"
                                if orui.button(
                                    orui.id(
                                        fmt.tprintf(
                                            "queue_download_%d",
                                            game_index,
                                        ),
                                    ),
                                    queue_label,
                                    {
                                        width = orui.fixed(84),
                                        height = orui.fixed(28),
                                        background_color = ACCENT_COLOR,
                                        color = APP_BACKGROUND,
                                        corner_radius = orui.corner(5),
                                    },
                                ) {
                                    if DownloadQueueGame(
                                        &app.download_manager,
                                        game_index,
                                    ) {
                                        app.status_message =
                                            "Download queued."
                                    } else {
                                        app.status_message =
                                            "Download already queued or completed."
                                    }
                                }
                            }
                        }
                    }

                    if orui.clicked(rowId) ||
                       orui.activated(rowId) {

                        app.selected_game = game_index

                        app.status_message =
                            "Handing off to Real-Debrid API..."

                        // Magnet is intentionally not printed here.
                        // It can be very long and isn't needed for
                        // crash diagnostics.
                        fmt.printf(
                            "[UI] Selected game index=%d title=%s magnet_length=%d\n",
                            game_index,
                            game.title,
                            len(game.magnetLink),
                        )
                    }
                }

                orui.end_virtual_list()

                orui.scrollbar(
                    orui.id("releases"),
                    {
                        position = {.Absolute, {-5, 0}},
                        placement = orui.placement(.Right, .Right),
                        width = orui.fixed(theme.metrics.scrollbar_width),
                        height = orui.grow(),
                        margin = orui.margin(2, 18),
                        background_color = HEADER_BACKGROUND,
                        corner_radius = orui.corner(4),
                    },
                    {
                        direction = .TopToBottom,
                        width = orui.percent(1),
                        background_color = ACCENT_COLOR,
                        corner_radius = orui.corner(4),
                    },
                )
            } else {
                empty_message := fmt.tprintf(
                    "No games match \"%s\"",
                    app.search_query,
                )
                if app.show_installed_only {
                    empty_message = fmt.tprintf(
                        "No installed or in-progress games match \"%s\"",
                        app.search_query,
                    )
                }
                orui.label(
                    orui.id("catalog_empty"),
                    empty_message,
                    {
                        font_size = 14,
                        color = TEXT_MUTED,
                    },
                )
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

                {
                    orui.container(
                        orui.id("catalog_pagination"),
                        {
                            layout = .Flex,
                            direction = .LeftToRight,
                            width = orui.fit(),
                            height = orui.fit(),
                            align_cross = .Center,
                            gap = 8,
                        },
                    )

                    if orui.button(
                        orui.id("catalog_previous"),
                        "Previous",
                        {
                            width = orui.fixed(78),
                            height = orui.fixed(28),
                            color = TEXT_PRIMARY,
                            background_color = ROW_BACKGROUND,
                            corner_radius = orui.corner(5),
                        },
                    ) {
                        if app.catalog_page > 0 {
                            RequestCatalogPage(
                                app,
                                app.catalog_page,
                            )
                        }
                    }

                    page_label := fmt.tprintf(
                        "Page %d  (%d games)",
                        app.catalog_page + 1,
                        filtered_count,
                    )

                    orui.label(
                        orui.id("catalog_page_label"),
                        page_label,
                        {
                            font_size = 11,
                            color = TEXT_MUTED,
                        },
                    )

                    if orui.button(
                        orui.id("catalog_next"),
                        "Next",
                        {
                            width = orui.fixed(78),
                            height = orui.fixed(28),
                            color = TEXT_PRIMARY,
                            background_color = ROW_BACKGROUND,
                            corner_radius = orui.corner(5),
                        },
                    ) {
                        if app.catalog_has_next {
                            RequestCatalogPage(
                                app,
                                app.catalog_page + 2,
                            )
                        }
                    }
                }

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
