package main

import "core:c/libc"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "base:runtime"

import curl "vendor:curl"


DownloadState :: enum {
    NotDownloaded,
    Queued,
    Resolving,
    Downloading,
    Completed,
    Cancelled,
    Failed,
}


DownloadEntry :: struct {
    game_index: int,
    info_hash:  string,

    rd_torrent_id: string,
    output_path:   string,
    part_path:     string,

    state:            DownloadState,
    progress:         f64,
    bytes_downloaded: i64,
    bytes_total:      i64,
    error_message:    string,

    cancel_requested: bool,
}


DownloadSnapshot :: struct {
    found:             bool,
    state:             DownloadState,
    progress:         f64,
    bytes_downloaded: i64,
    bytes_total:      i64,
}


DownloadManager :: struct {
    app: ^App,

    mutex: sync.Mutex,
    entries: [dynamic]DownloadEntry,

    worker:         ^thread.Thread,
    stop_requested: bool,
}


// ---------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------

DownloadManagerInit :: proc(manager: ^DownloadManager, app: ^App) -> bool {
    if manager == nil || app == nil {
        return false
    }

    manager.app = app
    manager.stop_requested = false

    worker := thread.create(download_manager_proc)
    if worker == nil {
        manager.app = nil
        return false
    }

    worker.data = manager
    manager.worker = worker
    thread.start(worker)
    return true
}


DownloadManagerShutdown :: proc(manager: ^DownloadManager) {
    if manager == nil {
        return
    }

    sync.mutex_lock(&manager.mutex)
    manager.stop_requested = true
    sync.mutex_unlock(&manager.mutex)

    if manager.worker != nil {
        thread.destroy(manager.worker)
        manager.worker = nil
    }

    sync.mutex_lock(&manager.mutex)
    for &entry in manager.entries {
        delete(entry.info_hash)
        delete(entry.rd_torrent_id)
        delete(entry.output_path)
        delete(entry.part_path)
        delete(entry.error_message)
    }
    delete(manager.entries)
    sync.mutex_unlock(&manager.mutex)

    manager.app = nil
}


// ---------------------------------------------------------
// Queue API
// ---------------------------------------------------------

DownloadQueueGame :: proc(manager: ^DownloadManager, game_index: int) -> bool {
    if manager == nil || manager.app == nil {
        return false
    }

    app := manager.app
    if game_index < 0 || game_index >= len(app.games) {
        return false
    }

    info_hash := download_info_hash(app.games[game_index].magnetLink)
    defer delete(info_hash)

    marker_path := download_marker_path(app.download_path, info_hash)
    defer delete(marker_path)

    sync.mutex_lock(&manager.mutex)
    defer sync.mutex_unlock(&manager.mutex)

    if manager.stop_requested {
        return false
    }

    if len(info_hash) > 0 && download_marker_valid(marker_path) {
        return false
    }

    for &entry in manager.entries {
        same_game := entry.game_index == game_index
        same_hash := len(info_hash) > 0 && entry.info_hash == info_hash

        if !same_game && !same_hash {
            continue
        }

        switch entry.state {
        case .Queued, .Resolving, .Downloading, .Completed:
            return false
        case .Cancelled, .Failed, .NotDownloaded:
            delete(entry.error_message)
            entry.error_message = ""
            entry.state = .Queued
            entry.progress = 0
            entry.bytes_downloaded = 0
            entry.bytes_total = 0
            entry.cancel_requested = false
            return true
        }
    }

    append(&manager.entries, DownloadEntry{
        game_index = game_index,
        info_hash = strings.clone(info_hash, context.allocator),
        state = .Queued,
    })
    return true
}


DownloadCancelGame :: proc(manager: ^DownloadManager, game_index: int) -> bool {
    if manager == nil {
        return false
    }

    sync.mutex_lock(&manager.mutex)
    defer sync.mutex_unlock(&manager.mutex)

    for &entry in manager.entries {
        if entry.game_index != game_index {
            continue
        }

        switch entry.state {
        case .Queued:
            entry.state = .Cancelled
            entry.cancel_requested = true
            return true
        case .Resolving, .Downloading:
            entry.cancel_requested = true
            return true
        case .NotDownloaded, .Completed, .Cancelled, .Failed:
            return false
        }
    }

    return false
}


DownloadSnapshotForGame :: proc(manager: ^DownloadManager, game_index: int) -> DownloadSnapshot {
    result := DownloadSnapshot{}
    if manager == nil || manager.app == nil {
        return result
    }

    info_hash := ""
    if game_index >= 0 && game_index < len(manager.app.games) {
        info_hash = download_info_hash(manager.app.games[game_index].magnetLink)
        defer delete(info_hash)
    }

    sync.mutex_lock(&manager.mutex)
    for entry in manager.entries {
        same_game := entry.game_index == game_index
        same_hash := len(info_hash) > 0 && entry.info_hash == info_hash
        if same_game || same_hash {
            result.found = true
            result.state = entry.state
            result.progress = entry.progress
            result.bytes_downloaded = entry.bytes_downloaded
            result.bytes_total = entry.bytes_total
            sync.mutex_unlock(&manager.mutex)
            return result
        }
    }
    sync.mutex_unlock(&manager.mutex)

    // Completion markers make the catalog state survive application restarts.
    if game_index >= 0 && game_index < len(manager.app.games) {
        marker_path := download_marker_path(manager.app.download_path, info_hash)
        defer delete(marker_path)

        if len(info_hash) > 0 && download_marker_valid(marker_path) {
            result.found = true
            result.state = .Completed
            result.progress = 1
        }
    }

    return result
}


DownloadManagerHasActiveWork :: proc(manager: ^DownloadManager) -> bool {
    if manager == nil {
        return false
    }

    sync.mutex_lock(&manager.mutex)
    defer sync.mutex_unlock(&manager.mutex)

    for entry in manager.entries {
        if entry.state == .Queued ||
           entry.state == .Resolving ||
           entry.state == .Downloading {
            return true
        }
    }
    return false
}


DownloadStateText :: proc(state: DownloadState) -> string {
    switch state {
    case .NotDownloaded: return "DOWNLOAD"
    case .Queued:        return "QUEUED"
    case .Resolving:     return "PREPARING"
    case .Downloading:   return "DOWNLOADING"
    case .Completed:     return "DOWNLOADED"
    case .Cancelled:     return "CANCELLED"
    case .Failed:        return "RETRY"
    }
    return "DOWNLOAD"
}


// ---------------------------------------------------------
// Worker
// ---------------------------------------------------------

download_manager_proc :: proc(t: ^thread.Thread) {
    if t == nil {
        return
    }

    manager := cast(^DownloadManager)t.data
    if manager == nil {
        return
    }

    for {
        next_index := -1

        sync.mutex_lock(&manager.mutex)
        if manager.stop_requested {
            sync.mutex_unlock(&manager.mutex)
            return
        }

        for entry, index in manager.entries {
            if entry.state == .Queued {
                next_index = index
                break
            }
        }
        sync.mutex_unlock(&manager.mutex)

        if next_index >= 0 {
            download_process_entry(manager, next_index)
        } else {
            time.sleep(250 * time.Millisecond)
        }
    }
}


download_process_entry :: proc(manager: ^DownloadManager, entry_index: int) {
    app := manager.app
    if app == nil {
        return
    }

    sync.mutex_lock(&manager.mutex)
    if entry_index < 0 || entry_index >= len(manager.entries) {
        sync.mutex_unlock(&manager.mutex)
        return
    }
    game_index := manager.entries[entry_index].game_index
    sync.mutex_unlock(&manager.mutex)

    if game_index < 0 || game_index >= len(app.games) {
        download_fail_entry(manager, entry_index, "Invalid game index.")
        return
    }

    if !EnsureRealDebridAccessToken(app) {
        download_fail_entry(manager, entry_index, "Real-Debrid authorization has expired. Reconnect the account.")
        return
    }

    source_magnet := app.games[game_index].magnetLink
    original_magnet_length := len(source_magnet)
    had_html_entities := strings.contains(source_magnet, "&amp;") ||
        strings.contains(source_magnet, "&#038;") ||
        strings.contains(source_magnet, "&#x26;")
    magnet := download_normalize_magnet(source_magnet)
    defer delete(magnet)
    fmt.printf(
        "[DOWNLOAD] Magnet prepared original_bytes=%d normalized_bytes=%d html_entities_normalized=%v spaces=%v\n",
        original_magnet_length,
        len(magnet),
        had_html_entities,
        strings.contains(magnet, " ") || strings.contains(magnet, "\t") ||
            strings.contains(magnet, "\r") || strings.contains(magnet, "\n"),
    )

    token := strings.clone(app.rd_key, context.allocator)
    defer delete(token)

    if len(token) == 0 || len(magnet) == 0 {
        download_fail_entry(manager, entry_index, "Real-Debrid key or magnet is missing.")
        return
    }

    if download_should_cancel(manager, entry_index) {
        download_cancel_entry(manager, entry_index, nil)
        return
    }

    download_set_state(manager, entry_index, .Resolving)

    if !EnsureDownloadDirectory(app.download_path) {
        download_fail_entry(manager, entry_index, "Download folder is not usable.")
        return
    }

    client := NewRealDebridClient(token)

    created, rd_err := RDAddMagnet(&client, magnet, "")
    if rd_err.message != "" {
        download_fail_entry_from_rd(manager, entry_index, &rd_err)
        return
    }

    download_set_torrent_id(manager, entry_index, created.id)
    torrent_id := strings.clone(created.id, context.allocator)
    DestroyRealDebridTorrentCreated(&created)

    if len(torrent_id) == 0 {
        delete(torrent_id)
        download_fail_entry(manager, entry_index, "Real-Debrid returned an empty torrent id.")
        return
    }
    defer delete(torrent_id)

    if download_should_cancel(manager, entry_index) {
        download_cancel_entry(manager, entry_index, &client)
        return
    }

    // A newly-added magnet may still be converting. Selecting files before
    // the API reports waiting_files_selection can produce a transient error.
    for {
        if download_should_cancel(manager, entry_index) {
            download_cancel_entry(manager, entry_index, &client)
            return
        }

        conversion_info, conversion_err := RDGetTorrentInfo(&client, torrent_id)
        if conversion_err.message != "" {
            download_fail_entry_from_rd(manager, entry_index, &conversion_err)
            download_delete_remote_torrent(&client, torrent_id)
            return
        }

        conversion_status := conversion_info.status
        selected_files := "all"
        if conversion_status == "waiting_files_selection" {
            fmt.printf(
                "[DOWNLOAD] Torrent awaiting file selection files=%d\n",
                len(conversion_info.files),
            )
            for file in conversion_info.files {
                fmt.printf(
                    "[DOWNLOAD] Torrent file id=%d bytes=%d selected=%d path=%s\n",
                    file.id,
                    file.bytes,
                    file.selected,
                    file.path,
                )
            }

            if len(conversion_info.files) > 0 {
                largest_file := 0
                for file, file_index in conversion_info.files {
                    if file.bytes > conversion_info.files[largest_file].bytes {
                        largest_file = file_index
                    }
                }
                selected_files = fmt.aprintf(
                    "%d",
                    conversion_info.files[largest_file].id,
                )
                fmt.printf(
                    "[DOWNLOAD] Selecting largest torrent file id=%d bytes=%d\n",
                    conversion_info.files[largest_file].id,
                    conversion_info.files[largest_file].bytes,
                )
            }
        }
        DestroyRealDebridTorrentInfo(&conversion_info)

        if conversion_status == "waiting_files_selection" {
            rd_err = RDSelectTorrentFiles(&client, torrent_id, selected_files)
            selection_rejected :=
                rd_err.http_status == 404 ||
                rd_err.api_code == 1 ||
                rd_err.api_code == 2
            if rd_err.message != "" && selected_files != "all" && selection_rejected {
                fmt.printf(
                    "[DOWNLOAD] Single-file selection rejected HTTP=%d API=%d; retrying with all files\n",
                    rd_err.http_status,
                    rd_err.api_code,
                )
                DestroyRealDebridError(&rd_err)
                rd_err = RDSelectTorrentFiles(&client, torrent_id, "all")
            }
            if selected_files != "all" {
                delete(selected_files)
            }
            if rd_err.message != "" {
                download_fail_entry_from_rd(manager, entry_index, &rd_err)
                download_delete_remote_torrent(&client, torrent_id)
                return
            }
            break
        }

        if conversion_status == "magnet_error" ||
           conversion_status == "error" ||
           conversion_status == "virus" ||
           conversion_status == "dead" {
            message := fmt.aprintf(
                "Real-Debrid torrent failed: %s",
                conversion_status,
            )
            download_fail_entry(manager, entry_index, message)
            delete(message)
            download_delete_remote_torrent(&client, torrent_id)
            return
        }

        // queued/downloading/downloaded means selection has already been
        // accepted, while magnet_conversion means we should keep polling.
        if conversion_status != "magnet_conversion" {
            break
        }

        time.sleep(2 * time.Second)
    }

    info: RealDebridTorrentInfo
    for {
        if download_should_cancel(manager, entry_index) {
            download_cancel_entry(manager, entry_index, &client)
            return
        }

        info, rd_err = RDGetTorrentInfo(&client, torrent_id)
        if rd_err.message != "" {
            download_fail_entry_from_rd(manager, entry_index, &rd_err)
            download_delete_remote_torrent(&client, torrent_id)
            return
        }

        download_set_torrent_progress(
            manager,
            entry_index,
            info.progress,
            info.bytes,
        )

        if info.status == "downloaded" {
            break
        }

        terminal_error :=
            info.status == "magnet_error" ||
            info.status == "error" ||
            info.status == "virus" ||
            info.status == "dead"

        if terminal_error {
            message := fmt.aprintf("Real-Debrid torrent failed: %s", info.status)
            download_fail_entry(manager, entry_index, message)
            delete(message)
            DestroyRealDebridTorrentInfo(&info)
            download_delete_remote_torrent(&client, torrent_id)
            return
        }

        DestroyRealDebridTorrentInfo(&info)
        time.sleep(2 * time.Second)
    }

    download_set_state(manager, entry_index, .Downloading)

    if len(info.links) == 0 {
        DestroyRealDebridTorrentInfo(&info)
        download_fail_entry(manager, entry_index, "Real-Debrid returned no downloadable files.")
        download_delete_remote_torrent(&client, torrent_id)
        return
    }

    // This first milestone deliberately downloads one selected file. The
    // queue can later be extended to process every selected file in order.
    direct, direct_err := RDUnrestrictLink(&client, info.links[0], "")
    DestroyRealDebridTorrentInfo(&info)
    if direct_err.message != "" {
        download_fail_entry_from_rd(manager, entry_index, &direct_err)
        download_delete_remote_torrent(&client, torrent_id)
        return
    }

    filename := download_safe_filename(direct.filename)
    filename_owned := true
    if len(filename) == 0 {
        delete(filename)
        filename = download_safe_filename(app.games[game_index].title)
    }
    if len(filename) == 0 {
        delete(filename)
        filename = "release.download"
        filename_owned = false
    }
    if filename_owned {
        defer delete(filename)
    }

    expected_size := direct.filesize
    output_path := fmt.aprintf("%s/%s", app.download_path, filename)
    part_path := fmt.aprintf("%s.part", output_path)
    info_hash := download_info_hash(magnet)
    defer delete(info_hash)
    marker_path := download_marker_path(app.download_path, info_hash)

    download_set_paths(manager, entry_index, output_path, part_path)
    download_set_progress(manager, entry_index, 0, 0, direct.filesize)

    download_url := strings.clone(direct.download, context.allocator)
    DestroyRealDebridUnrestrictedLink(&direct)

    if len(download_url) == 0 {
        delete(output_path)
        delete(part_path)
        delete(marker_path)
        delete(download_url)
        download_fail_entry(manager, entry_index, "Real-Debrid returned an empty download URL.")
        download_delete_remote_torrent(&client, torrent_id)
        return
    }

    completed, cancelled, transfer_error := download_file(
        manager,
        entry_index,
        download_url,
        part_path,
        direct.filesize,
    )
    delete(download_url)

    if cancelled {
        delete(output_path)
        delete(part_path)
        delete(marker_path)
        download_cancel_entry(manager, entry_index, &client)
        return
    }

    if !completed {
        delete(output_path)
        delete(part_path)
        delete(marker_path)
        download_fail_entry(manager, entry_index, transfer_error)
        download_delete_remote_torrent(&client, torrent_id)
        return
    }

    finalized, finalize_cancelled, finalize_error := download_finalize_file(
        manager,
        entry_index,
        part_path,
        output_path,
        marker_path,
        expected_size,
    )
    delete(output_path)
    delete(part_path)
    delete(marker_path)

    if finalize_cancelled {
        delete(finalize_error)
        download_cancel_entry(manager, entry_index, &client)
        return
    }

    if !finalized {
        download_fail_entry(manager, entry_index, finalize_error)
        delete(finalize_error)
        download_delete_remote_torrent(&client, torrent_id)
        return
    }

    delete(finalize_error)
    download_delete_remote_torrent(&client, torrent_id)
}


// ---------------------------------------------------------
// File transfer
// ---------------------------------------------------------

DownloadFileContext :: struct {
    manager:     ^DownloadManager,
    entry_index: int,
    file:        ^os.File,
}


download_file_write_callback :: proc "c" (
    ptr: rawptr,
    element_size, element_count: uint,
    user_data: rawptr,
) -> uint {
    context = runtime.default_context()

    actual_size := element_size * element_count
    if ptr == nil || user_data == nil || actual_size == 0 {
        return 0
    }

    transfer := cast(^DownloadFileContext)user_data
    if download_should_cancel(transfer.manager, transfer.entry_index) {
        return 0
    }

    data := mem.slice_ptr(cast(^byte)ptr, int(actual_size))
    written, write_err := os.write(transfer.file, data)
    if write_err != nil || written != len(data) {
        return 0
    }

    return actual_size
}


download_file_progress_callback :: proc "c" (
    user_data: rawptr,
    download_total: curl.off_t,
    download_now: curl.off_t,
    _: curl.off_t,
    _: curl.off_t,
) -> libc.int {
    context = runtime.default_context()

    if user_data == nil {
        return 0
    }

    transfer := cast(^DownloadFileContext)user_data
    if download_should_cancel(transfer.manager, transfer.entry_index) {
        return 1
    }

    download_set_progress(
        transfer.manager,
        transfer.entry_index,
        download_total > 0 ? f64(download_now) / f64(download_total) : 0,
        i64(download_now),
        i64(download_total),
    )
    return 0
}


download_file :: proc(
    manager: ^DownloadManager,
    entry_index: int,
    url, part_path: string,
    expected_size: i64,
) -> (completed, cancelled: bool, error_message: string) {
    file, file_err := os.create(part_path)
    if file_err != nil {
        return false, false, fmt.aprintf("Could not create download file: %v", file_err)
    }
    defer os.close(file)

    handle := curl.easy_init()
    if handle == nil {
        return false, false, "Could not initialize libcurl for file download."
    }
    defer curl.easy_cleanup(handle)

    download_url := strings.clone_to_cstring(url, context.allocator)
    defer delete(download_url)

    transfer := DownloadFileContext{
        manager = manager,
        entry_index = entry_index,
        file = file,
    }

    curl.easy_setopt(handle, .URL, download_url)
    curl.easy_setopt(handle, .FOLLOWLOCATION, 1)
    curl.easy_setopt(handle, .USERAGENT, REALDEBRID_USER_AGENT)
    // Do not impose a total transfer timeout on large games. A connect
    // timeout and low-speed timeout still let shutdown/cancellation recover
    // from stalled network connections.
    curl.easy_setopt(handle, .TIMEOUT, 0)
    curl.easy_setopt(handle, .CONNECTTIMEOUT, 30)
    curl.easy_setopt(handle, .LOW_SPEED_LIMIT, 1)
    curl.easy_setopt(handle, .LOW_SPEED_TIME, 60)
    curl.easy_setopt(handle, .NOPROGRESS, 0)
    curl.easy_setopt(handle, .XFERINFOFUNCTION, download_file_progress_callback)
    curl.easy_setopt(handle, .XFERINFODATA, &transfer)
    curl.easy_setopt(handle, .WRITEFUNCTION, download_file_write_callback)
    curl.easy_setopt(handle, .WRITEDATA, &transfer)

    if expected_size > 0 {
        download_set_progress(manager, entry_index, 0, 0, expected_size)
    }

    result := curl.easy_perform(handle)

    if download_should_cancel(manager, entry_index) {
        return false, true, ""
    }

    if result != .E_OK {
        return false, false, fmt.aprintf("File download failed: %v", result)
    }

    status: libc.long = 0
    curl.easy_getinfo(handle, .RESPONSE_CODE, &status)
    if status < 200 || status >= 300 {
        return false, false, fmt.aprintf("File download returned HTTP %d", status)
    }

    return true, false, ""
}


download_finalize_file :: proc(
    manager: ^DownloadManager,
    entry_index: int,
    part_path, output_path, marker_path: string,
    expected_size: i64,
) -> (finalized, cancelled: bool, error_message: string) {
    // Keep cancellation from racing the rename/marker pair. The UI cannot
    // set cancel_requested until this short critical section completes.
    sync.mutex_lock(&manager.mutex)
    defer sync.mutex_unlock(&manager.mutex)

    if entry_index < 0 || entry_index >= len(manager.entries) {
        return false, false, "Invalid download entry."
    }
    if manager.stop_requested || manager.entries[entry_index].cancel_requested {
        return false, true, ""
    }

    if os.exists(output_path) {
        return false, false, "Refusing to overwrite an existing downloaded file."
    }

    rename_err := os.rename(part_path, output_path)
    if rename_err != nil {
        return false, false, fmt.aprintf(
            "Could not finalize downloaded file: %v",
            rename_err,
        )
    }

    marker_bytes := transmute([]byte)output_path
    marker_err := os.write_entire_file(marker_path, marker_bytes)
    if marker_err != nil {
        os.remove(output_path)
        return false, false, fmt.aprintf(
            "Downloaded file, but completion marker failed: %v",
            marker_err,
        )
    }

    manager.entries[entry_index].progress = 1
    manager.entries[entry_index].bytes_downloaded = expected_size
    manager.entries[entry_index].bytes_total = expected_size
    manager.entries[entry_index].state = .Completed
    return true, false, ""
}


// ---------------------------------------------------------
// Worker state helpers
// ---------------------------------------------------------

download_should_cancel :: proc(manager: ^DownloadManager, entry_index: int) -> bool {
    if manager == nil {
        return true
    }

    sync.mutex_lock(&manager.mutex)
    defer sync.mutex_unlock(&manager.mutex)

    return manager.stop_requested ||
        entry_index < 0 ||
        entry_index >= len(manager.entries) ||
        manager.entries[entry_index].cancel_requested
}


download_set_state :: proc(manager: ^DownloadManager, entry_index: int, state: DownloadState) {
    sync.mutex_lock(&manager.mutex)
    defer sync.mutex_unlock(&manager.mutex)

    if entry_index >= 0 && entry_index < len(manager.entries) {
        manager.entries[entry_index].state = state
    }
}


download_set_torrent_id :: proc(manager: ^DownloadManager, entry_index: int, torrent_id: string) {
    sync.mutex_lock(&manager.mutex)
    defer sync.mutex_unlock(&manager.mutex)

    if entry_index < 0 || entry_index >= len(manager.entries) {
        return
    }

    delete(manager.entries[entry_index].rd_torrent_id)
    manager.entries[entry_index].rd_torrent_id = strings.clone(
        torrent_id,
        context.allocator,
    )
}


download_set_paths :: proc(manager: ^DownloadManager, entry_index: int, output_path, part_path: string) {
    sync.mutex_lock(&manager.mutex)
    defer sync.mutex_unlock(&manager.mutex)

    if entry_index < 0 || entry_index >= len(manager.entries) {
        return
    }

    delete(manager.entries[entry_index].output_path)
    delete(manager.entries[entry_index].part_path)
    manager.entries[entry_index].output_path = strings.clone(output_path, context.allocator)
    manager.entries[entry_index].part_path = strings.clone(part_path, context.allocator)
}


download_set_progress :: proc(manager: ^DownloadManager, entry_index: int, progress: f64, downloaded, total: i64) {
    sync.mutex_lock(&manager.mutex)
    defer sync.mutex_unlock(&manager.mutex)

    if entry_index < 0 || entry_index >= len(manager.entries) {
        return
    }

    manager.entries[entry_index].progress = clamp(progress, 0, 1)
    manager.entries[entry_index].bytes_downloaded = downloaded
    if total > 0 {
        manager.entries[entry_index].bytes_total = total
    }
}


download_set_torrent_progress :: proc(manager: ^DownloadManager, entry_index: int, progress: f64, total: i64) {
    sync.mutex_lock(&manager.mutex)
    defer sync.mutex_unlock(&manager.mutex)

    if entry_index < 0 || entry_index >= len(manager.entries) {
        return
    }

    manager.entries[entry_index].progress = clamp(progress, 0, 1)
    if total > 0 {
        manager.entries[entry_index].bytes_total = total
    }
}


download_fail_entry :: proc(manager: ^DownloadManager, entry_index: int, message: string) {
    sync.mutex_lock(&manager.mutex)
    defer sync.mutex_unlock(&manager.mutex)

    if entry_index < 0 || entry_index >= len(manager.entries) {
        return
    }

    delete(manager.entries[entry_index].error_message)
    manager.entries[entry_index].error_message = strings.clone(message, context.allocator)
    manager.entries[entry_index].state = .Failed
}


download_fail_entry_from_rd :: proc(manager: ^DownloadManager, entry_index: int, err: ^RealDebridError) {
    if err == nil {
        download_fail_entry(manager, entry_index, "Real-Debrid request failed.")
        return
    }

    message := err.message
    if len(message) == 0 {
        message = "Real-Debrid request failed."
    }
    download_fail_entry(manager, entry_index, message)
    DestroyRealDebridError(err)
}


download_cancel_entry :: proc(manager: ^DownloadManager, entry_index: int, client: ^RealDebridClient) {
    torrent_id := download_copy_torrent_id(manager, entry_index)
    defer delete(torrent_id)

    if client != nil && len(torrent_id) > 0 {
        download_delete_remote_torrent(client, torrent_id)
    }

    part_path := download_copy_part_path(manager, entry_index)
    defer delete(part_path)
    if len(part_path) > 0 && os.exists(part_path) {
        os.remove(part_path)
    }

    download_set_state(manager, entry_index, .Cancelled)
}


download_delete_remote_torrent :: proc(client: ^RealDebridClient, torrent_id: string) {
    if client == nil || len(torrent_id) == 0 {
        return
    }

    err := RDDeleteTorrent(client, torrent_id)
    if err.message != "" {
        fmt.printf(
            "[DOWNLOAD] WARNING: could not delete Real-Debrid torrent %s (HTTP %d, API %d): %s\n",
            torrent_id,
            err.http_status,
            err.api_code,
            err.message,
        )
    }
    DestroyRealDebridError(&err)
}


download_copy_torrent_id :: proc(manager: ^DownloadManager, entry_index: int) -> string {
    sync.mutex_lock(&manager.mutex)
    defer sync.mutex_unlock(&manager.mutex)

    if entry_index < 0 || entry_index >= len(manager.entries) {
        return ""
    }
    return strings.clone(manager.entries[entry_index].rd_torrent_id, context.allocator)
}


download_copy_part_path :: proc(manager: ^DownloadManager, entry_index: int) -> string {
    sync.mutex_lock(&manager.mutex)
    defer sync.mutex_unlock(&manager.mutex)

    if entry_index < 0 || entry_index >= len(manager.entries) {
        return ""
    }
    return strings.clone(manager.entries[entry_index].part_path, context.allocator)
}


// ---------------------------------------------------------
// Magnet normalization and local identity
// ---------------------------------------------------------

download_replace_owned :: proc(value, old, new: string) -> string {
    replacement, allocated := strings.replace_all(
        value,
        old,
        new,
        context.allocator,
    )
    if allocated {
        delete(value)
        return replacement
    }
    return value
}


download_normalize_magnet :: proc(value: string) -> string {
    result := strings.clone(value, context.allocator)
    result = download_replace_owned(result, "&amp;", "&")
    result = download_replace_owned(result, "&#038;", "&")
    result = download_replace_owned(result, "&#x26;", "&")
    result = download_replace_owned(result, "&quot;", "\"")
    return result
}


download_info_hash :: proc(magnet: string) -> string {
    lower := strings.to_lower(magnet, context.allocator)
    defer delete(lower)

    prefix := "magnet:?xt=urn:btih:"
    start := strings.index(lower, prefix)
    if start < 0 {
        return strings.clone(lower, context.allocator)
    }

    rest := lower[start + len(prefix):]
    end := strings.index_any(rest, "&\"' >\t\r\n")
    if end < 0 {
        end = len(rest)
    }

    return strings.clone(rest[:end], context.allocator)
}


download_marker_path :: proc(download_directory, info_hash: string) -> string {
    safe_hash := sanitize_filename(info_hash, context.allocator)
    defer delete(safe_hash)

    filename := fmt.aprintf(".fitdeck-%s.complete", safe_hash)
    defer delete(filename)

    path, join_err := filepath.join({download_directory, filename}, context.allocator)
    if join_err != nil {
        return fmt.aprintf("%s/%s", download_directory, filename)
    }
    return path
}


download_marker_valid :: proc(marker_path: string) -> bool {
    marker_data, read_err := os.read_entire_file_from_path(
        marker_path,
        context.allocator,
    )
    if read_err != nil {
        return false
    }
    defer delete(marker_data)

    if len(marker_data) == 0 {
        return false
    }

    return os.exists(string(marker_data[:]))
}


download_safe_filename :: proc(name: string) -> string {
    // Keep the extension, but discard path separators and traversal markers.
    base := name
    if slash := strings.last_index(base, "/"); slash >= 0 {
        base = base[slash + 1:]
    }
    if slash := strings.last_index(base, "\\"); slash >= 0 {
        base = base[slash + 1:]
    }

    builder: strings.Builder
    strings.builder_init(&builder, context.allocator)
    for r in base {
        if (r >= 'A' && r <= 'Z') ||
           (r >= 'a' && r <= 'z') ||
           (r >= '0' && r <= '9') ||
           r == '.' || r == '-' || r == '_' || r == ' ' {
            strings.write_rune(&builder, r)
        } else {
            strings.write_rune(&builder, '_')
        }
    }

    result := strings.to_string(builder)
    for len(result) > 0 && (result[0] == '.' || result[0] == ' ') {
        trimmed := strings.trim_left(result, ". ")
        if trimmed == result {
            break
        }
        old := result
        result = strings.clone(trimmed, context.allocator)
        delete(old)
    }
    return result
}
