package main

import "core:fmt"
import "core:os"
import "core:strings"
import endian "core:encoding/endian"
import orui "./orui"
import tinyfd "tinyfiledialogs"
import rl "vendor:raylib"


SETTINGS_FILE           :: "settings.bin"
SETTINGS_VERSION        :: u32(3)
SETTINGS_V2_HEADER_SIZE  :: 36
SETTINGS_HEADER_SIZE    :: 40
SETTINGS_RAM_LIMIT_FLAG :: u32(1)

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
    if app == nil ||
       len(app.rd_key) == 0 ||
       len(app.rd_refresh_token) == 0 ||
       len(app.rd_client_id) == 0 ||
       len(app.rd_client_secret) == 0 ||
       len(app.download_path) == 0 {
        return false
    }

    settings_size := SETTINGS_HEADER_SIZE +
        len(app.rd_key) +
        len(app.download_path) +
        len(app.rd_refresh_token) +
        len(app.rd_client_id) +
        len(app.rd_client_secret)

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

    endian.put_u32(settings_data[4:8], .Little, SETTINGS_VERSION)
    endian.put_u32(settings_data[8:12], .Little, u32(len(app.rd_key)))
    endian.put_u32(settings_data[12:16], .Little, u32(len(app.download_path)))
    endian.put_u32(settings_data[16:20], .Little, u32(len(app.rd_refresh_token)))
    endian.put_u32(settings_data[20:24], .Little, u32(len(app.rd_client_id)))
    endian.put_u32(settings_data[24:28], .Little, u32(len(app.rd_client_secret)))
    endian.put_u64(settings_data[28:36], .Little, u64(app.rd_token_expires_at))
    settings_flags: u32 = 0
    if app.use_ram_limit {
        settings_flags |= SETTINGS_RAM_LIMIT_FLAG
    }
    endian.put_u32(settings_data[36:40], .Little, settings_flags)

    offset := SETTINGS_HEADER_SIZE
    copy(settings_data[offset:offset+len(app.rd_key)], transmute([]byte)app.rd_key)
    offset += len(app.rd_key)
    copy(settings_data[offset:offset+len(app.download_path)], transmute([]byte)app.download_path)
    offset += len(app.download_path)
    copy(settings_data[offset:offset+len(app.rd_refresh_token)], transmute([]byte)app.rd_refresh_token)
    offset += len(app.rd_refresh_token)
    copy(settings_data[offset:offset+len(app.rd_client_id)], transmute([]byte)app.rd_client_id)
    offset += len(app.rd_client_id)
    copy(settings_data[offset:offset+len(app.rd_client_secret)], transmute([]byte)app.rd_client_secret)

    write_err := os.write_entire_file(SETTINGS_FILE, settings_data)
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
        fmt.printf("[SETTINGS] Ignoring truncated %s\n", SETTINGS_FILE)
        return false
    }

    if string(settings_data[0:4]) != "FDS1" {
        fmt.printf("[SETTINGS] Ignoring %s with an invalid header\n", SETTINGS_FILE)
        return false
    }

    version, version_ok := endian.get_u32(settings_data[4:8], .Little)
    if !version_ok {
        return false
    }
    if version == 1 {
        legacy_key_len_u32, key_ok := endian.get_u32(settings_data[8:12], .Little)
        legacy_path_len_u32, path_ok := endian.get_u32(settings_data[12:16], .Little)
        legacy_payload_len := len(settings_data) - 16
        legacy_total_len := u64(legacy_key_len_u32) + u64(legacy_path_len_u32)

        if key_ok && path_ok && legacy_total_len <= u64(legacy_payload_len) {
            legacy_path_start := 16 + int(legacy_key_len_u32)
            legacy_path_len := int(legacy_path_len_u32)
            legacy_path := strings.clone(
                string(settings_data[legacy_path_start:legacy_path_start+legacy_path_len]),
                context.allocator,
            )

            if len(legacy_path) > 0 && EnsureDownloadDirectory(legacy_path) {
                delete(app.download_path)
                app.download_path = legacy_path
            } else {
                delete(legacy_path)
            }
        }

        fmt.println(
            "[SETTINGS] Legacy API-key settings found; reconnect Real-Debrid",
        )
        return false
    }
    settings_header_size := SETTINGS_HEADER_SIZE
    if version == 1 {
        // Version 1 is handled above because it used a different payload.
        return false
    }
    if version == 2 {
        settings_header_size = SETTINGS_V2_HEADER_SIZE
    } else if version != SETTINGS_VERSION {
        fmt.printf(
            "[SETTINGS] Unsupported settings version %d (expected %d)\n",
            version,
            SETTINGS_VERSION,
        )
        return false
    }
    if len(settings_data) < settings_header_size {
        fmt.printf("[SETTINGS] Ignoring truncated %s\n", SETTINGS_FILE)
        return false
    }

    use_ram_limit := false
    if version >= 3 {
        settings_flags, flags_ok := endian.get_u32(settings_data[36:40], .Little)
        if !flags_ok {
            fmt.printf("[SETTINGS] Ignoring %s with invalid option flags\n", SETTINGS_FILE)
            return false
        }
        use_ram_limit = (settings_flags & SETTINGS_RAM_LIMIT_FLAG) != 0
    }

    access_len_u32, access_ok := endian.get_u32(settings_data[8:12], .Little)
    path_len_u32, path_ok := endian.get_u32(settings_data[12:16], .Little)
    refresh_len_u32, refresh_ok := endian.get_u32(settings_data[16:20], .Little)
    client_id_len_u32, client_id_ok := endian.get_u32(settings_data[20:24], .Little)
    client_secret_len_u32, client_secret_ok := endian.get_u32(settings_data[24:28], .Little)
    expires_u64, expires_ok := endian.get_u64(settings_data[28:36], .Little)

    payload_len := len(settings_data) - settings_header_size
    total_len := u64(access_len_u32) +
        u64(path_len_u32) +
        u64(refresh_len_u32) +
        u64(client_id_len_u32) +
        u64(client_secret_len_u32)

    if !access_ok || !path_ok || !refresh_ok ||
       !client_id_ok || !client_secret_ok || !expires_ok ||
       total_len > u64(payload_len) {
        fmt.printf(
            "[SETTINGS] Ignoring %s with invalid credential lengths\n",
            SETTINGS_FILE,
        )
        return false
    }

    access_len := int(access_len_u32)
    path_len := int(path_len_u32)
    refresh_len := int(refresh_len_u32)
    client_id_len := int(client_id_len_u32)
    client_secret_len := int(client_secret_len_u32)

    offset := settings_header_size
    access_start := offset
    offset += access_len
    path_start := offset
    offset += path_len
    refresh_start := offset
    offset += refresh_len
    client_id_start := offset
    offset += client_id_len
    client_secret_start := offset

    loaded_access := strings.clone(string(settings_data[access_start:access_start+access_len]), context.allocator)
    loaded_path := strings.clone(string(settings_data[path_start:path_start+path_len]), context.allocator)
    loaded_refresh := strings.clone(string(settings_data[refresh_start:refresh_start+refresh_len]), context.allocator)
    loaded_client_id := strings.clone(string(settings_data[client_id_start:client_id_start+client_id_len]), context.allocator)
    loaded_client_secret := strings.clone(string(settings_data[client_secret_start:client_secret_start+client_secret_len]), context.allocator)

    if len(loaded_access) == 0 || len(loaded_path) == 0 ||
       len(loaded_refresh) == 0 || len(loaded_client_id) == 0 ||
       len(loaded_client_secret) == 0 {
        delete(loaded_access)
        delete(loaded_path)
        delete(loaded_refresh)
        delete(loaded_client_id)
        delete(loaded_client_secret)
        fmt.printf("[SETTINGS] Ignoring %s with missing OAuth values\n", SETTINGS_FILE)
        return false
    }

    if !EnsureDownloadDirectory(loaded_path) {
        delete(loaded_access)
        delete(loaded_path)
        delete(loaded_refresh)
        delete(loaded_client_id)
        delete(loaded_client_secret)
        fmt.printf("[SETTINGS] Ignoring %s with unusable download folder\n", SETTINGS_FILE)
        return false
    }

    delete(app.rd_key)
    delete(app.download_path)
    delete(app.rd_refresh_token)
    delete(app.rd_client_id)
    delete(app.rd_client_secret)

    app.rd_key = loaded_access
    app.download_path = loaded_path
    app.rd_refresh_token = loaded_refresh
    app.rd_client_id = loaded_client_id
    app.rd_client_secret = loaded_client_secret
    app.rd_token_expires_at = i64(expires_u64)
    app.use_ram_limit = use_ram_limit

    fmt.printf("[SETTINGS] Loaded version %d from %s\n", version, SETTINGS_FILE)
    return true
}


// ---------------------------------------------------------
// Setup Screen
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
                "Fatboy Configuration",
                {
                    font_size = 24,
                    color = TEXT_PRIMARY,
                },
            )

            orui.label(
                orui.id("setup_desc"),
                "Connect your Real-Debrid account and choose the default folder for downloaded games. You only need to do this once.",
                {
                    font_size = 14,
                    color = TEXT_MUTED,
                    overflow = .Wrap,
                },
            )

            orui.label(
                orui.id("api_key_label"),
                "Real-Debrid account",
                {
                    font_size = 12,
                    color = TEXT_MUTED,
                },
            )

            {
                orui.container(
                    orui.id("rd_connection_panel"),
                    {
                        layout = .Flex,
                        direction = .TopToBottom,
                        width = orui.grow(),
                        height = orui.fit(),
                        gap = 8,
                        padding = orui.Edges{
                            top = 12,
                            right = 12,
                            bottom = 12,
                            left = 12,
                        },
                        background_color = LIST_BACKGROUND,
                        border = orui.border(1),
                        border_color = BORDER_COLOR,
                        corner_radius = orui.corner(6),
                    },
                )

                auth_snapshot, auth_active := RealDebridAuthSnapshotForApp(app)
                if auth_active {
                    orui.label(
                        orui.id("rd_auth_status"),
                        auth_snapshot.status,
                        {
                            font_size = 13,
                            color = ACCENT_COLOR,
                            overflow = .Wrap,
                        },
                    )

                    if len(auth_snapshot.user_code) > 0 {
                        orui.label(
                            orui.id("rd_auth_code"),
                            fmt.tprintf(
                                "Code: %s",
                                auth_snapshot.user_code,
                            ),
                            {
                                font_size = 22,
                                color = TEXT_PRIMARY,
                            },
                        )

                        if orui.button(
                            orui.id("btn_copy_rd_code"),
                            "Copy code",
                            {
                                width = orui.fixed(110),
                                height = orui.fixed(30),
                                background_color = ROW_HOVER_BACKGROUND,
                                color = TEXT_PRIMARY,
                                corner_radius = orui.corner(5),
                            },
                        ) {
                            code_cstr := strings.clone_to_cstring(
                                auth_snapshot.user_code,
                                context.temp_allocator,
                            )
                            rl.SetClipboardText(code_cstr)
                            app.status_message =
                                "Real-Debrid code copied to clipboard."
                            fmt.println("[AUTH] Device code copied to clipboard")
                        }

                        orui.label(
                            orui.id("rd_auth_url"),
                            auth_snapshot.verification_url,
                            {
                                font_size = 12,
                                color = TEXT_MUTED,
                                overflow = .Wrap,
                            },
                        )
                    }

                    if orui.button(
                        orui.id("btn_cancel_rd_auth"),
                        "Cancel",
                        {
                            width = orui.fixed(100),
                            height = orui.fixed(30),
                            background_color = ROW_HOVER_BACKGROUND,
                            color = TEXT_PRIMARY,
                            corner_radius = orui.corner(5),
                        },
                    ) {
                        CancelRealDebridAuth(app)
                    }
                } else {
                    connected :=
                        len(app.rd_key) > 0 &&
                        len(app.rd_refresh_token) > 0 &&
                        len(app.rd_client_id) > 0 &&
                        len(app.rd_client_secret) > 0

                    connection_text := "Not connected"
                    if connected {
                        connection_text = "Connected to Real-Debrid"
                    }

                    orui.label(
                        orui.id("rd_connection_status"),
                        connection_text,
                        {
                            font_size = 13,
                            color = connected ? STATUS_OK : STATUS_ERR,
                        },
                    )

                    if orui.button(
                        orui.id("btn_connect_rd"),
                        connected ? "Reconnect Real-Debrid" : "Connect Real-Debrid",
                        {
                            width = orui.grow(),
                            height = orui.fixed(36),
                            background_color = ACCENT_COLOR,
                            color = APP_BACKGROUND,
                            corner_radius = orui.corner(5),
                        },
                    ) {
                        if !StartRealDebridAuth(app) {
                            app.status_message =
                                "Could not start Real-Debrid connection."
                        }
                    }
                }
                DestroyRealDebridAuthSnapshot(&auth_snapshot)
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

            orui.label(
                orui.id("ram_limit_label"),
                "FitGirl installer memory limit",
                {
                    font_size = 12,
                    color = TEXT_MUTED,
                },
            )

            ram_limit_button_text := "Enable 2 GB RAM limit (/RAM=2)"
            if app.use_ram_limit {
                ram_limit_button_text = "Disable 2 GB RAM limit (/RAM=2)"
            }
            if orui.button(
                orui.id("btn_ram_limit"),
                ram_limit_button_text,
                {
                    width = orui.grow(),
                    height = orui.fixed(36),
                    background_color = app.use_ram_limit ? ACCENT_COLOR : ROW_HOVER_BACKGROUND,
                    color = app.use_ram_limit ? APP_BACKGROUND : TEXT_PRIMARY,
                    corner_radius = orui.corner(5),
                },
            ) {
                app.use_ram_limit = !app.use_ram_limit
                if app.use_ram_limit {
                    app.status_message = "FitGirl installers will use the 2 GB RAM limit."
                } else {
                    app.status_message = "FitGirl installers will use their default RAM limit."
                }
            }
            orui.label(
                orui.id("ram_limit_help"),
                "Some FitGirl installers need /RAM=2 on systems with limited memory. This applies when the next installer starts.",
                {
                    font_size = 12,
                    color = TEXT_MUTED,
                    overflow = .Wrap,
                },
            )

            download_path_text := strings.trim_space(app.download_path)
            auth_ready :=
                len(app.rd_key) > 0 &&
                len(app.rd_refresh_token) > 0 &&
                len(app.rd_client_id) > 0 &&
                len(app.rd_client_secret) > 0
            path_ready := len(download_path_text) > 0

            if !auth_ready || !path_ready {
                orui.label(
                    orui.id("setup_warn"),
                    "Connect Real-Debrid and choose a download folder to continue.",
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
                    if DownloadManagerHasActiveWork(&app.download_manager) {
                        app.status_message =
                            "Finish or cancel active downloads before changing settings."
                        return
                    }

                    download_path_text = strings.trim_space(download_path_text)

                    if !auth_ready || len(download_path_text) == 0 {
                        app.status_message =
                            "Connect Real-Debrid and choose a download folder."
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

                    if len(app.download_path) > 0 {
                        delete(app.download_path)
                    }
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
                            "[UI] Starting loader after Real-Debrid connection",
                        )

                        app.screen = .Loading
                        StartLoader(app)
                    }
                }
            }
        }
    }
}
