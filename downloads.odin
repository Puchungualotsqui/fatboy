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
    Extracting,
    Installing,
    Completed,
    Cancelled,
    Paused,
    Failed,
}


DownloadEntry :: struct {
    game_index: int,
    info_hash:  string,

    rd_torrent_id: string,
    output_path:   string,
    part_path:     string,
    archive_path:  string,

    state:            DownloadState,
    progress:         f64,
    bytes_downloaded: i64,
    bytes_total:      i64,
    error_message:    string,

    cancel_requested: bool,
    pause_requested:  bool,
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
        delete(entry.archive_path)
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
        case .Queued, .Resolving, .Downloading, .Extracting, .Installing, .Completed:
            return false
        case .Cancelled, .Paused, .Failed, .NotDownloaded:
            delete(entry.error_message)
            entry.error_message = ""
            entry.state = .Queued
            entry.progress = 0
            entry.bytes_downloaded = 0
            entry.bytes_total = 0
            entry.cancel_requested = false
            entry.pause_requested = false
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
        case .Resolving, .Downloading, .Extracting, .Installing:
            entry.cancel_requested = true
            entry.pause_requested = false
            return true
        case .NotDownloaded, .Completed, .Cancelled, .Paused, .Failed:
            return false
        }
    }

    return false
}


DownloadPauseGame :: proc(manager: ^DownloadManager, game_index: int) -> bool {
    if manager == nil {
        return false
    }

    sync.mutex_lock(&manager.mutex)
    defer sync.mutex_unlock(&manager.mutex)
    for &entry in manager.entries {
        if entry.game_index != game_index {
            continue
        }
        if entry.state == .Resolving ||
           entry.state == .Downloading ||
           entry.state == .Extracting ||
           entry.state == .Installing {
            entry.pause_requested = true
            entry.cancel_requested = false
            return true
        }
    }
    return false
}


download_should_pause :: proc(manager: ^DownloadManager, entry_index: int) -> bool {
    if manager == nil {
        return false
    }
    sync.mutex_lock(&manager.mutex)
    defer sync.mutex_unlock(&manager.mutex)
    if entry_index < 0 || entry_index >= len(manager.entries) {
        return false
    }
    return manager.entries[entry_index].pause_requested
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

    phase, manifest_archive, manifest_torrent := download_read_manifest_for_game(manager, game_index)
    defer delete(phase)
    defer delete(manifest_archive)
    defer delete(manifest_torrent)
    if len(phase) > 0 && phase != "completed" {
        result.found = true
        result.state = .Paused
        return result
    }

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


DownloadOutputPathForGame :: proc(manager: ^DownloadManager, game_index: int) -> string {
    if manager == nil {
        return ""
    }

    sync.mutex_lock(&manager.mutex)
    for entry in manager.entries {
        if entry.game_index == game_index {
            if len(entry.archive_path) > 0 {
                result := strings.clone(entry.archive_path, context.allocator)
                sync.mutex_unlock(&manager.mutex)
                return result
            }
            if len(entry.output_path) > 0 {
                result := strings.clone(entry.output_path, context.allocator)
                sync.mutex_unlock(&manager.mutex)
                return result
            }
        }
    }
    sync.mutex_unlock(&manager.mutex)

    app := manager.app
    if app == nil || game_index < 0 || game_index >= len(app.games) {
        return ""
    }

    info_hash := download_info_hash(app.games[game_index].magnetLink)
    defer delete(info_hash)
    marker_path := download_marker_path(app.download_path, info_hash)
    defer delete(marker_path)
    marker_data, read_err := os.read_entire_file_from_path(
        marker_path,
        context.allocator,
    )
    if read_err != nil || len(marker_data) == 0 {
        delete(marker_data)
        return ""
    }
    result := strings.clone(string(marker_data[:]), context.allocator)
    delete(marker_data)
    return result
}


DownloadFileNameForGame :: proc(manager: ^DownloadManager, game_index: int) -> string {
    path := DownloadOutputPathForGame(manager, game_index)
    defer delete(path)
    if len(path) == 0 {
        return ""
    }

    name := path
    if slash := strings.last_index(name, "/"); slash >= 0 {
        name = name[slash+1:]
    }
    if slash := strings.last_index(name, "\\"); slash >= 0 {
        name = name[slash+1:]
    }
    return strings.clone(name, context.temp_allocator)
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
           entry.state == .Downloading ||
           entry.state == .Extracting ||
           entry.state == .Installing {
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
    case .Extracting:    return "EXTRACTING"
    case .Installing:    return "INSTALLING"
    case .Completed:     return "DOWNLOADED"
    case .Cancelled:     return "CANCELLED"
    case .Paused:        return "RESUME"
    case .Failed:        return "RETRY"
    }
    return "DOWNLOAD"
}


// ---------------------------------------------------------
// Worker
// ---------------------------------------------------------

download_manager_proc :: proc(t: ^thread.Thread) {
    // Worker threads do not inherit a valid Odin context. Initialize it
    // before building strings or making Real-Debrid requests.
    context = runtime.default_context()

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


download_resume_archive_entry :: proc(
    manager: ^DownloadManager,
    entry_index: int,
    archive_path, torrent_id, phase: string,
    client: ^RealDebridClient,
) {
    if !os.exists(archive_path) {
        download_fail_entry(manager, entry_index, "Saved archive is missing; download it again.")
        return
    }

    if phase == "installing" {
        download_set_state(manager, entry_index, .Paused)
        download_write_manifest(manager, entry_index, "paused", "Installer may still be running; it was not relaunched.")
        return
    }

    if phase != "installing" {
        download_set_state(manager, entry_index, .Extracting)
        download_write_manifest(manager, entry_index, "extracting", "")
        extracted, extraction_message := ExtractDownloadArchiveAndWait(
            manager,
            entry_index,
            archive_path,
        )
        if !extracted {
            if download_should_pause(manager, entry_index) {
                download_pause_entry(manager, entry_index, nil)
            } else if download_should_cancel(manager, entry_index) {
                download_cancel_entry(manager, entry_index, nil)
            } else {
                download_fail_entry(manager, entry_index, extraction_message)
            }
            delete(extraction_message)
            return
        }
        delete(extraction_message)
    }

    download_set_state(manager, entry_index, .Installing)
    download_write_manifest(manager, entry_index, "installing", "")
    launched, install_message := LaunchDownloadInstaller(
        manager,
        entry_index,
        archive_path,
    )
    if !launched {
        if download_should_pause(manager, entry_index) {
            download_pause_entry(manager, entry_index, client)
        } else if download_should_cancel(manager, entry_index) {
            download_cancel_entry(manager, entry_index, client)
        } else {
            download_fail_entry(manager, entry_index, install_message)
        }
        delete(install_message)
        return
    }
    delete(install_message)

    sync.mutex_lock(&manager.mutex)
    resume_info_hash := strings.clone(manager.entries[entry_index].info_hash, context.allocator)
    resume_directory := strings.clone(manager.app.download_path, context.allocator)
    sync.mutex_unlock(&manager.mutex)
    defer delete(resume_info_hash)
    defer delete(resume_directory)
    marker_path := download_marker_path(resume_directory, resume_info_hash)
    marked, marker_error := download_mark_entry_complete(
        manager,
        entry_index,
        marker_path,
        archive_path,
        0,
    )
    delete(marker_path)
    if !marked {
        download_fail_entry(manager, entry_index, marker_error)
        delete(marker_error)
        return
    }
    delete(marker_error)
    if client != nil && len(torrent_id) > 0 {
        download_delete_remote_torrent(client, torrent_id)
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

    resume_phase, resume_archive, resume_torrent := download_read_manifest_for_game(manager, game_index)
    defer delete(resume_phase)
    defer delete(resume_archive)
    defer delete(resume_torrent)
    if (resume_phase == "archive_ready" ||
        resume_phase == "extracting" ||
        resume_phase == "installing") &&
       len(resume_archive) > 0 && os.exists(resume_archive) {
        client := NewRealDebridClient(token)
        if len(resume_torrent) > 0 {
            download_set_torrent_id(manager, entry_index, resume_torrent)
        }
        download_resume_archive_entry(
            manager,
            entry_index,
            resume_archive,
            resume_torrent,
            resume_phase,
            &client,
        )
        return
    }

    if download_should_cancel(manager, entry_index) {
        download_cancel_entry(manager, entry_index, nil)
        return
    }

    download_set_state(manager, entry_index, .Resolving)
    download_write_manifest(manager, entry_index, "resolving", "")

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
    download_write_manifest(manager, entry_index, "remote_downloading", "")

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

            fmt.println("[DOWNLOAD] Selecting all torrent files")
        }
        DestroyRealDebridTorrentInfo(&conversion_info)

        if conversion_status == "waiting_files_selection" {
            rd_err = RDSelectTorrentFiles(&client, torrent_id, selected_files)
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
    poll_count := 0
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
        poll_count += 1
        if poll_count == 1 || poll_count % 5 == 0 || info.status == "downloaded" {
            fmt.printf(
                "[DOWNLOAD] Torrent status=%s progress=%.1f%% bytes=%d\n",
                info.status,
                info.progress,
                info.bytes,
            )
        }

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

    info_hash := download_info_hash(magnet)
    defer delete(info_hash)
    marker_path := download_marker_path(app.download_path, info_hash)
    defer delete(marker_path)

    total_bytes := info.bytes
    completed_bytes: i64 = 0
    first_output_path := ""

    for link, link_index in info.links {
        if download_should_cancel(manager, entry_index) {
            DestroyRealDebridTorrentInfo(&info)
            delete(first_output_path)
            download_cancel_entry(manager, entry_index, &client)
            return
        }

        fmt.printf(
            "[DOWNLOAD] Preparing file %d/%d\n",
            link_index + 1,
            len(info.links),
        )
        direct, direct_err := RDUnrestrictLink(&client, link, "")
        if direct_err.message != "" {
            DestroyRealDebridUnrestrictedLink(&direct)
            DestroyRealDebridTorrentInfo(&info)
            delete(first_output_path)
            download_fail_entry_from_rd(manager, entry_index, &direct_err)
            download_delete_remote_torrent(&client, torrent_id)
            return
        }

        filename := download_safe_filename(direct.filename)
        if len(filename) == 0 {
            delete(filename)
            filename = fmt.aprintf("release-file-%d.download", link_index + 1)
        }
        output_path := fmt.aprintf("%s/%s", app.download_path, filename)
        part_path := fmt.aprintf("%s.part", output_path)
        if len(first_output_path) == 0 {
            first_output_path = strings.clone(output_path, context.allocator)
            download_set_archive_path(manager, entry_index, output_path)
        }

        expected_size := direct.filesize
        download_set_paths(manager, entry_index, output_path, part_path)
        download_write_manifest(manager, entry_index, "local_downloading", "")
        download_set_progress(
            manager,
            entry_index,
            total_bytes > 0 ? f64(completed_bytes) / f64(total_bytes) : 0,
            completed_bytes,
            total_bytes,
        )

        download_url := strings.clone(direct.download, context.allocator)
        DestroyRealDebridUnrestrictedLink(&direct)

        if len(download_url) == 0 {
            delete(filename)
            delete(output_path)
            delete(part_path)
            delete(download_url)
            DestroyRealDebridTorrentInfo(&info)
            delete(first_output_path)
            download_fail_entry(manager, entry_index, "Real-Debrid returned an empty download URL.")
            download_delete_remote_torrent(&client, torrent_id)
            return
        }

        fmt.printf(
            "[DOWNLOAD] Downloading file %d/%d name=%s bytes=%d\n",
            link_index + 1,
            len(info.links),
            filename,
            expected_size,
        )
        completed, cancelled, transfer_error := download_file(
            manager,
            entry_index,
            download_url,
            part_path,
            filename,
            expected_size,
        )
        delete(download_url)

        if cancelled {
            delete(filename)
            delete(output_path)
            delete(part_path)
            DestroyRealDebridTorrentInfo(&info)
            delete(first_output_path)
            if download_should_pause(manager, entry_index) {
                download_pause_entry(manager, entry_index, &client)
            } else {
                download_cancel_entry(manager, entry_index, &client)
            }
            return
        }

        if !completed {
            delete(filename)
            delete(output_path)
            delete(part_path)
            DestroyRealDebridTorrentInfo(&info)
            delete(first_output_path)
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
            false,
        )
        delete(filename)
        delete(output_path)
        delete(part_path)

        if finalize_cancelled {
            delete(finalize_error)
            DestroyRealDebridTorrentInfo(&info)
            delete(first_output_path)
            download_cancel_entry(manager, entry_index, &client)
            return
        }

        if !finalized {
            DestroyRealDebridTorrentInfo(&info)
            delete(first_output_path)
            download_fail_entry(manager, entry_index, finalize_error)
            delete(finalize_error)
            download_delete_remote_torrent(&client, torrent_id)
            return
        }
        delete(finalize_error)

        completed_bytes += expected_size
        download_set_progress(
            manager,
            entry_index,
            total_bytes > 0 ? f64(completed_bytes) / f64(total_bytes) : 0,
            completed_bytes,
            total_bytes,
        )
    }

    DestroyRealDebridTorrentInfo(&info)
    if len(first_output_path) == 0 {
        download_fail_entry(manager, entry_index, "Real-Debrid returned no file paths.")
        download_delete_remote_torrent(&client, torrent_id)
        return
    }

    if DownloadPathIsArchive(first_output_path) {
        download_write_manifest(manager, entry_index, "archive_ready", "")
        download_set_state(manager, entry_index, .Extracting)
        download_write_manifest(manager, entry_index, "extracting", "")
        extracted, extraction_message := ExtractDownloadArchiveAndWait(
            manager,
            entry_index,
            first_output_path,
        )
        if !extracted {
            if download_should_pause(manager, entry_index) {
                download_pause_entry(manager, entry_index, &client)
            } else if download_should_cancel(manager, entry_index) {
                download_cancel_entry(manager, entry_index, &client)
            } else {
                download_fail_entry(manager, entry_index, extraction_message)
                download_delete_remote_torrent(&client, torrent_id)
            }
            delete(extraction_message)
            delete(first_output_path)
            return
        }
        delete(extraction_message)

        download_set_state(manager, entry_index, .Installing)
        download_write_manifest(manager, entry_index, "installing", "")
        launched, install_message := LaunchDownloadInstaller(
            manager,
            entry_index,
            first_output_path,
        )
        if !launched {
            if download_should_pause(manager, entry_index) {
                download_pause_entry(manager, entry_index, &client)
            } else if download_should_cancel(manager, entry_index) {
                download_cancel_entry(manager, entry_index, &client)
            } else {
                download_fail_entry(manager, entry_index, install_message)
                download_delete_remote_torrent(&client, torrent_id)
            }
            delete(install_message)
            delete(first_output_path)
            return
        }
        fmt.printf("[DOWNLOAD] Installer launched for %s\n", first_output_path)
        delete(install_message)
    }

    marked, marker_error := download_mark_entry_complete(
        manager,
        entry_index,
        marker_path,
        first_output_path,
        completed_bytes,
    )
    if marked {
        download_write_manifest(manager, entry_index, "completed", "")
    }
    delete(first_output_path)
    if !marked {
        download_fail_entry(manager, entry_index, marker_error)
        delete(marker_error)
        download_delete_remote_torrent(&client, torrent_id)
        return
    }
    delete(marker_error)
    download_delete_remote_torrent(&client, torrent_id)
}


// ---------------------------------------------------------
// File transfer
// ---------------------------------------------------------

DownloadFileContext :: struct {
    manager:              ^DownloadManager,
    entry_index:          int,
    file:                 ^os.File,
    file_name:            string,
    expected_size:        i64,
    resume_offset:        i64,
    last_logged_percent:  int,
    progress_overflow:    bool,
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
    if download_should_cancel(transfer.manager, transfer.entry_index) ||
       download_should_pause(transfer.manager, transfer.entry_index) {
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
    if download_should_cancel(transfer.manager, transfer.entry_index) ||
       download_should_pause(transfer.manager, transfer.entry_index) {
        return 1
    }

    // libcurl reports the size of the current HTTP response here. For a
    // resumed request that is the remaining range, not the complete file.
    // Prefer the API's file size so the progress denominator stays stable.
    total := transfer.expected_size
    if total <= 0 {
        total = transfer.resume_offset + i64(download_total)
    }
    now := transfer.resume_offset + i64(download_now)

    // A server that ignores Range: will make now exceed the expected file
    // size. Abort before appending the whole file to the partial file; the
    // caller will remove it and retry once from byte zero.
    if transfer.expected_size > 0 && now > transfer.expected_size {
        if !transfer.progress_overflow {
            transfer.progress_overflow = true
            fmt.printf(
                "\n[DOWNLOAD] Resume overflow name=%s resume_offset=%d now=%d expected=%d response_total=%d\n",
                transfer.file_name,
                transfer.resume_offset,
                now,
                transfer.expected_size,
                i64(download_total),
            )
        }
        return 1
    }

    progress := total > 0 ? f64(now) / f64(total) : 0
    download_set_progress(
        transfer.manager,
        transfer.entry_index,
        progress,
        now,
        total,
    )

    if total > 0 {
        percent := int((now * 100) / total)
        if percent > 100 {
            percent = 100
        }
        if percent != transfer.last_logged_percent {
            transfer.last_logged_percent = percent
            bar_width := 30
            filled := percent * bar_width / 100
            fmt.printf("\r[DOWNLOAD] %s [", transfer.file_name)
            for bar_index in 0..<bar_width {
                fmt.print(bar_index < filled ? "=" : " ")
            }
            fmt.printf("] %3d%% %d/%d MiB", percent, now / (1024 * 1024), total / (1024 * 1024))
            if percent >= 100 {
                fmt.println()
            }
        }
    }
    return 0
}


download_file_once :: proc(
    manager: ^DownloadManager,
    entry_index: int,
    url, part_path, file_name: string,
    expected_size: i64,
) -> (completed, cancelled, restart: bool, error_message: string) {
    file, file_err := os.open(part_path, os.O_RDWR|os.O_CREATE)
    if file_err != nil {
        return false, false, false, fmt.aprintf("Could not open partial download file: %v", file_err)
    }
    defer os.close(file)

    partial_size, partial_err := os.file_size(file)
    if partial_err != nil {
        return false, false, false, fmt.aprintf("Could not inspect partial download file: %v", partial_err)
    }
    if expected_size > 0 && partial_size == expected_size {
        fmt.printf(
            "[DOWNLOAD] Partial file already complete name=%s bytes=%d\n",
            file_name,
            partial_size,
        )
        return true, false, false, ""
    }
    if expected_size > 0 && partial_size > expected_size {
        fmt.printf(
            "[DOWNLOAD] Oversized partial file name=%s bytes=%d expected=%d; restarting\n",
            file_name,
            partial_size,
            expected_size,
        )
        return false, false, true, ""
    }
    if _, seek_err := os.seek(file, partial_size, .Start); seek_err != nil {
        return false, false, false, fmt.aprintf("Could not seek partial download file: %v", seek_err)
    }

    handle := curl.easy_init()
    if handle == nil {
        return false, false, false, "Could not initialize libcurl for file download."
    }
    defer curl.easy_cleanup(handle)

    download_url := strings.clone_to_cstring(url, context.allocator)
    defer delete(download_url)

    transfer := DownloadFileContext{
        manager = manager,
        entry_index = entry_index,
        file = file,
        file_name = file_name,
        expected_size = expected_size,
        resume_offset = partial_size,
        last_logged_percent = -1,
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
        download_set_progress(
            manager,
            entry_index,
            f64(partial_size) / f64(expected_size),
            partial_size,
            expected_size,
        )
    }
    if partial_size > 0 {
        curl.easy_setopt(handle, .RESUME_FROM_LARGE, curl.off_t(partial_size))
    }
    fmt.printf(
        "[DOWNLOAD] Starting local transfer name=%s resume_offset=%d expected_bytes=%d\n",
        file_name,
        partial_size,
        expected_size,
    )

    result := curl.easy_perform(handle)

    if download_should_pause(manager, entry_index) {
        return false, true, false, ""
    }
    if download_should_cancel(manager, entry_index) {
        return false, true, false, ""
    }

    status: libc.long = 0
    curl.easy_getinfo(handle, .RESPONSE_CODE, &status)
    final_size, final_size_err := os.file_size(file)
    if final_size_err != nil {
        return false, false, false, fmt.aprintf("Could not inspect completed partial download file: %v", final_size_err)
    }
    response_bytes := final_size - partial_size
    fmt.printf(
        "[DOWNLOAD] Transfer result name=%s curl=%v http=%d resume_offset=%d response_bytes=%d final_bytes=%d expected_bytes=%d overflow=%t\n",
        file_name,
        result,
        status,
        partial_size,
        response_bytes,
        final_size,
        expected_size,
        transfer.progress_overflow,
    )

    // A 200 response to a resumed request means the server ignored Range and
    // sent the complete file. A 416 can mean the saved range is stale. In
    // either case, discard the partial file and retry once from byte zero.
    if partial_size > 0 && (status == 200 || status == 416 || transfer.progress_overflow) {
        return false, false, true, ""
    }
    if transfer.progress_overflow {
        return false, false, true, ""
    }

    if result != .E_OK {
        return false, false, false, fmt.aprintf("File download failed: %v", result)
    }
    if status < 200 || status >= 300 {
        return false, false, false, fmt.aprintf("File download returned HTTP %d", status)
    }
    if expected_size > 0 && final_size != expected_size {
        return false, false, false, fmt.aprintf(
            "File download size mismatch: got %d bytes, expected %d",
            final_size,
            expected_size,
        )
    }

    fmt.printf("[DOWNLOAD] Local transfer completed name=%s bytes=%d\n", file_name, final_size)
    return true, false, false, ""
}


download_file :: proc(
    manager: ^DownloadManager,
    entry_index: int,
    url, part_path, file_name: string,
    expected_size: i64,
) -> (completed, cancelled: bool, error_message: string) {
    for attempt := 0; attempt < 2; attempt += 1 {
        completed, cancelled, restart, transfer_error := download_file_once(
            manager,
            entry_index,
            url,
            part_path,
            file_name,
            expected_size,
        )
        if !restart {
            return completed, cancelled, transfer_error
        }

        if attempt == 1 {
            delete(transfer_error)
            return false, false, "Could not resume download safely after the server rejected the byte range."
        }

        remove_err := os.remove(part_path)
        if remove_err != nil {
            delete(transfer_error)
            return false, false, fmt.aprintf(
                "Could not reset partial download after resume mismatch: %v",
                remove_err,
            )
        }
        fmt.printf(
            "[DOWNLOAD] Retrying from byte zero after resume mismatch name=%s\n",
            file_name,
        )
        delete(transfer_error)
    }

    return false, false, "File download did not start."
}


download_finalize_file :: proc(
    manager: ^DownloadManager,
    entry_index: int,
    part_path, output_path, marker_path: string,
    expected_size: i64,
    mark_complete: bool,
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

    if mark_complete {
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
    }
    return true, false, ""
}


download_mark_entry_complete :: proc(
    manager: ^DownloadManager,
    entry_index: int,
    marker_path, marker_target: string,
    total_bytes: i64,
) -> (marked: bool, error_message: string) {
    sync.mutex_lock(&manager.mutex)
    defer sync.mutex_unlock(&manager.mutex)

    if entry_index < 0 || entry_index >= len(manager.entries) {
        return false, "Invalid download entry."
    }
    if manager.stop_requested || manager.entries[entry_index].cancel_requested {
        return false, "Download cancelled."
    }

    marker_bytes := transmute([]byte)marker_target
    marker_err := os.write_entire_file(marker_path, marker_bytes)
    if marker_err != nil {
        message := fmt.aprintf(
            "Downloaded files, but completion marker failed: %v",
            marker_err,
        )
        return false, message
    }

    manager.entries[entry_index].progress = 1
    manager.entries[entry_index].bytes_downloaded = total_bytes
    manager.entries[entry_index].bytes_total = total_bytes
    manager.entries[entry_index].state = .Completed
    return true, ""
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
        manager.entries[entry_index].cancel_requested ||
        manager.entries[entry_index].pause_requested
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


download_set_archive_path :: proc(manager: ^DownloadManager, entry_index: int, archive_path: string) {
    sync.mutex_lock(&manager.mutex)
    defer sync.mutex_unlock(&manager.mutex)

    if entry_index < 0 || entry_index >= len(manager.entries) {
        return
    }

    delete(manager.entries[entry_index].archive_path)
    manager.entries[entry_index].archive_path = strings.clone(
        archive_path,
        context.allocator,
    )
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
    if entry_index < 0 || entry_index >= len(manager.entries) {
        sync.mutex_unlock(&manager.mutex)
        return
    }

    delete(manager.entries[entry_index].error_message)
    manager.entries[entry_index].error_message = strings.clone(message, context.allocator)
    manager.entries[entry_index].state = .Failed
    sync.mutex_unlock(&manager.mutex)
    download_write_manifest(manager, entry_index, "failed", message)
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


download_pause_entry :: proc(manager: ^DownloadManager, entry_index: int, client: ^RealDebridClient) {
    torrent_id := download_copy_torrent_id(manager, entry_index)
    defer delete(torrent_id)
    if client != nil && len(torrent_id) > 0 {
        download_delete_remote_torrent(client, torrent_id)
    }

    resume_phase := "paused"
    sync.mutex_lock(&manager.mutex)
    if entry_index >= 0 && entry_index < len(manager.entries) {
        switch manager.entries[entry_index].state {
        case .Extracting: resume_phase = "extracting"
        case .Installing: resume_phase = "installing"
        case .NotDownloaded, .Queued, .Resolving, .Downloading,
             .Completed, .Cancelled, .Paused, .Failed:
            resume_phase = "paused"
        }
    }
    sync.mutex_unlock(&manager.mutex)
    download_set_state(manager, entry_index, .Paused)
    download_write_manifest(manager, entry_index, resume_phase, "Partial work preserved.")
}


download_cancel_entry :: proc(manager: ^DownloadManager, entry_index: int, client: ^RealDebridClient) {
    paused := download_should_pause(manager, entry_index)
    torrent_id := download_copy_torrent_id(manager, entry_index)
    defer delete(torrent_id)

    if client != nil && len(torrent_id) > 0 {
        download_delete_remote_torrent(client, torrent_id)
    }

    if paused {
        download_set_state(manager, entry_index, .Paused)
        download_write_manifest(manager, entry_index, "paused", "Partial download preserved.")
    } else {
        download_set_state(manager, entry_index, .Cancelled)
        download_write_manifest(manager, entry_index, "cancelled", "Download cancelled; partial data preserved.")
    }
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


download_manifest_path :: proc(download_directory, info_hash: string) -> string {
    safe_hash := sanitize_filename(info_hash, context.allocator)
    defer delete(safe_hash)

    filename := fmt.aprintf(".fitdeck-%s.state", safe_hash)
    defer delete(filename)
    path, join_err := filepath.join({download_directory, filename}, context.allocator)
    if join_err != nil {
        return fmt.aprintf("%s/%s", download_directory, filename)
    }
    return path
}


download_manifest_value :: proc(data, key: string) -> string {
    marker := fmt.aprintf("%s=", key)
    defer delete(marker)
    start := strings.index(data, marker)
    if start < 0 {
        return ""
    }
    value_start := start + len(marker)
    value_end := strings.index(data[value_start:], "\n")
    if value_end < 0 {
        value_end = len(data) - value_start
    }
    return strings.clone(data[value_start:value_start+value_end], context.allocator)
}


download_write_manifest :: proc(manager: ^DownloadManager, entry_index: int, phase, message: string) {
    if manager == nil || manager.app == nil {
        return
    }

    sync.mutex_lock(&manager.mutex)
    if entry_index < 0 || entry_index >= len(manager.entries) {
        sync.mutex_unlock(&manager.mutex)
        return
    }
    info_hash := strings.clone(manager.entries[entry_index].info_hash, context.allocator)
    archive_path := strings.clone(manager.entries[entry_index].archive_path, context.allocator)
    output_path := strings.clone(manager.entries[entry_index].output_path, context.allocator)
    part_path := strings.clone(manager.entries[entry_index].part_path, context.allocator)
    torrent_id := strings.clone(manager.entries[entry_index].rd_torrent_id, context.allocator)
    download_directory := strings.clone(manager.app.download_path, context.allocator)
    sync.mutex_unlock(&manager.mutex)

    defer delete(info_hash)
    defer delete(archive_path)
    defer delete(output_path)
    defer delete(part_path)
    defer delete(torrent_id)
    defer delete(download_directory)

    if len(archive_path) == 0 {
        archive_path = strings.clone(output_path, context.allocator)
    }
    manifest_path := download_manifest_path(download_directory, info_hash)
    defer delete(manifest_path)
    temp_path := fmt.aprintf("%s.tmp", manifest_path)
    defer delete(temp_path)
    contents := fmt.aprintf(
        "phase=%s\narchive_path=%s\noutput_path=%s\npart_path=%s\ntorrent_id=%s\nmessage=%s\n",
        phase,
        archive_path,
        output_path,
        part_path,
        torrent_id,
        message,
    )
    defer delete(contents)

    write_err := os.write_entire_file(temp_path, transmute([]byte)contents)
    if write_err == nil {
        rename_err := os.rename(temp_path, manifest_path)
        if rename_err != nil {
            fmt.printf("[DOWNLOAD] WARNING: could not commit state manifest: %v\n", rename_err)
        }
    } else {
        fmt.printf("[DOWNLOAD] WARNING: could not write state manifest: %v\n", write_err)
    }
}


download_read_manifest_for_game :: proc(manager: ^DownloadManager, game_index: int) -> (phase, archive_path, torrent_id: string) {
    if manager == nil || manager.app == nil ||
       game_index < 0 || game_index >= len(manager.app.games) {
        return "", "", ""
    }

    info_hash := download_info_hash(manager.app.games[game_index].magnetLink)
    defer delete(info_hash)
    path := download_manifest_path(manager.app.download_path, info_hash)
    defer delete(path)
    data, read_err := os.read_entire_file_from_path(path, context.allocator)
    if read_err != nil {
        return "", "", ""
    }
    defer delete(data)
    text := string(data[:])
    phase = download_manifest_value(text, "phase")
    archive_path = download_manifest_value(text, "archive_path")
    torrent_id = download_manifest_value(text, "torrent_id")
    return phase, archive_path, torrent_id
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
