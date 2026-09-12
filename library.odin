package main

import "core:fmt"
import orui "./orui"
import rl "vendor:raylib"


// ---------------------------------------------------------
// Library Screen
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
                    if DownloadManagerHasActiveWork(&app.download_manager) {
                        app.status_message =
                            "Finish or cancel active downloads before changing settings."
                    } else {
                        fmt.println(
                            "[UI] Opening settings screen",
                        )

                        app.screen = .SetupKey
                    }
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
                    download_snapshot := DownloadSnapshotForGame(
                        &app.download_manager,
                        index,
                    )

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

                            {
                                orui.container(
                                    orui.id(
                                        fmt.tprintf(
                                            "text_wrap_%d",
                                            index,
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
                                                index,
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
                                                index,
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
                                                index,
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
                                                index,
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
                                                index,
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
                                        index,
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
                                        fmt.tprintf("pause_download_%d", index),
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
                                    if DownloadPauseGame(&app.download_manager, index) {
                                        app.status_message = "Pause requested. Partial data will be preserved."
                                    }
                                }
                            }

                            if can_cancel {
                                if orui.button(
                                    orui.id(
                                        fmt.tprintf(
                                            "cancel_download_%d",
                                            index,
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
                                        index,
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
                                            index,
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
                                        index,
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
