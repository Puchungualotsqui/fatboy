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
import durrent "./durrent"


DownloadState :: enum {
    NotDownloaded,
    Queued,
    Resolving,
    Downloading,
    Extracting,
    Installing,
    Installed,
    Extracted,
    Cancelled,
    Paused,
    Failed,
}


DownloadEntry :: struct {
    game_index:  int,
    info_hash:   string,
    game_title:  string,
    magnet_link: string,

    provider:           DownloadProvider,
    provider_job_id:    string,
    local_torrent_path: string,
    output_path:        string,
    part_path:     string,
    archive_path:  string,

    state:            DownloadState,
    progress:              f64,
    bytes_downloaded:      i64,
    bytes_total:            i64,
    speed_bytes_per_second: f64,
    error_message:          string,
    status_message:   string,
    resolver_attempt: u32,
    resolver_error:   string,

    cancel_requested:  bool,
    pause_requested:  bool,
}


DownloadSnapshot :: struct {
    found:             bool,
    state:             DownloadState,
    progress:              f64,
    bytes_downloaded:      i64,
    bytes_total:            i64,
    speed_bytes_per_second: f64,
    status_message:         string,
    error_message:    string,
}


DownloadManager :: struct {
    app: ^App,

    mutex: sync.Mutex,
    entries: [dynamic]DownloadEntry,

    worker:          ^thread.Thread,
    stop_requested:  bool,
    metadata_cancel: ^durrent.Metadata_Resolver_Cancel_Token,
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
    metadata_cancel := manager.metadata_cancel
    manager.metadata_cancel = nil
    sync.mutex_unlock(&manager.mutex)
    if metadata_cancel != nil {
        durrent.Metadata_Resolver_Cancel(metadata_cancel)
    }

    if manager.worker != nil {
        thread.destroy(manager.worker)
        manager.worker = nil
    }

    sync.mutex_lock(&manager.mutex)
    for &entry in manager.entries {
        delete(entry.info_hash)
        delete(entry.game_title)
        delete(entry.magnet_link)
        delete(entry.provider_job_id)
        delete(entry.local_torrent_path)
        delete(entry.output_path)
        delete(entry.part_path)
        delete(entry.archive_path)
        delete(entry.error_message)
        delete(entry.status_message)
        delete(entry.resolver_error)
    }
    delete(manager.entries)
    sync.mutex_unlock(&manager.mutex)

    manager.app = nil
}


// ---------------------------------------------------------
// Queue API
// ---------------------------------------------------------

download_torrent_hash_to_string :: proc(info_hash: durrent.Torrent_Hash) -> string {
    hex := "0123456789abcdef"
    result: strings.Builder
    strings.builder_init(&result, context.allocator)
    for value in info_hash {
        strings.write_byte(&result, hex[value >> 4])
        strings.write_byte(&result, hex[value & 0x0f])
    }
    return strings.to_string(result)
}


download_game_info_hash :: proc(game: ^GameRelease) -> string {
    if game == nil {
        return ""
    }
    if len(game.source_info_hash) > 0 {
        return strings.clone(game.source_info_hash, context.allocator)
    }
    return download_info_hash(game.magnetLink)
}


download_prepare_durrent_magnet_identity :: proc(app: ^App, game_index: int) -> bool {
    if app == nil || game_index < 0 || game_index >= len(app.games) {
        return false
    }
    if len(app.games[game_index].source_info_hash) > 0 {
        return true
    }
    magnet, parse_error := durrent.Parse_Magnet(app.games[game_index].magnetLink)
    if parse_error != .None {
        return false
    }
    defer durrent.Destroy_Magnet_Link(&magnet)
    canonical_hash := download_torrent_hash_to_string(magnet.Info_Hash)
    defer delete(canonical_hash)
    app.games[game_index].source_info_hash = strings.clone(
        canonical_hash,
        context.allocator,
    )
    return true
}


// DownloadQueueLocalTorrent is the phase-2 local-provider entry point. The
// caller supplies a verified local .torrent path; magnet metadata discovery is
// intentionally outside this slice.
DownloadQueueLocalTorrent :: proc(
    manager: ^DownloadManager,
    game_index: int,
    torrent_path: string,
) -> bool {
    if manager == nil || manager.app == nil ||
       manager.app.download_provider != .Durrent ||
       game_index < 0 || game_index >= len(manager.app.games) ||
       len(torrent_path) == 0 {
        return false
    }

    data, read_error := os.read_entire_file_from_path(
        torrent_path,
        context.allocator,
    )
    if read_error != nil {
        return false
    }
    defer delete(data)

    torrent, parse_error := durrent.Parse_Torrent(data[:])
    if parse_error != .None {
        return false
    }
    defer durrent.Destroy_Torrent(&torrent)

    info_hash := download_torrent_hash_to_string(torrent.Info_Hash)
    defer delete(info_hash)
    delete(manager.app.games[game_index].local_torrent_path)
    delete(manager.app.games[game_index].source_info_hash)
    manager.app.games[game_index].local_torrent_path = strings.clone(
        torrent_path,
        context.allocator,
    )
    manager.app.games[game_index].source_info_hash = strings.clone(
        info_hash,
        context.allocator,
    )

    return DownloadQueueGame(manager, game_index)
}


DownloadQueueGame :: proc(manager: ^DownloadManager, game_index: int) -> bool {
    if manager == nil || manager.app == nil {
        return false
    }

    app := manager.app
    if game_index < 0 || game_index >= len(app.games) {
        return false
    }
    if app.download_provider == .Durrent &&
       len(app.games[game_index].local_torrent_path) == 0 &&
       !download_prepare_durrent_magnet_identity(app, game_index) {
        return false
    }

    info_hash := download_game_info_hash(&app.games[game_index])
    defer delete(info_hash)

    manifest_phase, manifest_archive, manifest_torrent, manifest_provider := download_read_manifest_for_game(manager, game_index)
    defer delete(manifest_phase)
    defer delete(manifest_archive)
    defer delete(manifest_torrent)
    manifest_archive_exists := len(manifest_archive) > 0 && os.exists(manifest_archive)
    failed_archive_resume := manifest_phase == "failed" && manifest_archive_exists
    stale_failed_manifest := manifest_phase == "failed" && len(manifest_archive) > 0 && !manifest_archive_exists
    stale_failed_part := ""
    if stale_failed_manifest {
        stale_failed_part = fmt.aprintf("%s.part", manifest_archive)
        defer delete(stale_failed_part)
    }

    sync.mutex_lock(&manager.mutex)

    if manager.stop_requested {
        sync.mutex_unlock(&manager.mutex)
        return false
    }

    if len(info_hash) > 0 && download_marker_valid_for_game(app.download_path, info_hash) {
        sync.mutex_unlock(&manager.mutex)
        return false
    }

    retry_cleanup_index := -1
    for &entry, entry_index in manager.entries {
        same_game := entry.game_index == game_index
        same_hash := len(info_hash) > 0 && entry.info_hash == info_hash

        if !same_game && !same_hash {
            continue
        }

        switch entry.state {
        case .Queued, .Resolving, .Downloading, .Extracting, .Installing, .Installed:
            sync.mutex_unlock(&manager.mutex)
            return false
        case .Cancelled, .Paused, .Failed, .Extracted, .NotDownloaded:
            if entry.state == .Failed && stale_failed_manifest {
                retry_cleanup_index = entry_index
            }
            delete(entry.error_message)
            delete(entry.status_message)
            entry.error_message = ""
            entry.status_message = ""
            entry.state = .Queued
            entry.progress = 0
            entry.bytes_downloaded = 0
            entry.bytes_total = 0
            entry.cancel_requested = false
            entry.pause_requested = false
            break
        }
        break
    }

    if retry_cleanup_index < 0 {
        resume_manifest := failed_archive_resume ||
            manifest_phase == "paused" ||
            manifest_phase == "extracted" ||
            manifest_phase == "installing" ||
            manifest_phase == "archive_ready" ||
            manifest_phase == "extracting"
        cleanup_manifest := resume_manifest || stale_failed_manifest
        append(&manager.entries, DownloadEntry{
            game_index = game_index,
            info_hash = strings.clone(info_hash, context.allocator),
            game_title = strings.clone(app.games[game_index].title, context.allocator),
            magnet_link = strings.clone(app.games[game_index].magnetLink, context.allocator),
            provider = manifest_provider,
            provider_job_id = resume_manifest ? strings.clone(manifest_torrent, context.allocator) : "",
            local_torrent_path = strings.clone(app.games[game_index].local_torrent_path, context.allocator),
            output_path = cleanup_manifest ? strings.clone(manifest_archive, context.allocator) : "",
            part_path = stale_failed_manifest ? strings.clone(stale_failed_part, context.allocator) : "",
            archive_path = cleanup_manifest ? strings.clone(manifest_archive, context.allocator) : "",
            state = .Queued,
        })
        if stale_failed_manifest {
            retry_cleanup_index = len(manager.entries) - 1
        }
    }
    sync.mutex_unlock(&manager.mutex)

    if retry_cleanup_index >= 0 {
        download_remove_local_artifacts(manager, retry_cleanup_index)
    }
    return true
}


DownloadCancelGame :: proc(manager: ^DownloadManager, game_index: int) -> bool {
    if manager == nil {
        return false
    }

    sync.mutex_lock(&manager.mutex)
    for &entry, entry_index in manager.entries {
        if entry.game_index != game_index {
            continue
        }

        switch entry.state {
        case .Queued:
            entry.state = .Cancelled
            entry.cancel_requested = true
            provider_job_id := strings.clone(entry.provider_job_id, context.allocator)
            local_torrent_path := strings.clone(entry.local_torrent_path, context.allocator)
            delete(entry.status_message)
            entry.status_message = strings.clone(
                "Cancelled; local partial files were removed.",
                context.allocator,
            )
            sync.mutex_unlock(&manager.mutex)

            // A queued retry may still reference files from an earlier
            // attempt, even though its worker has not started yet. If its
            // manifest restored a remote torrent, release that torrent too.
            if manager.app != nil &&
               entry.provider == .RealDebrid &&
               len(provider_job_id) > 0 &&
               len(manager.app.rd_key) > 0 {
                token := strings.clone(manager.app.rd_key, context.allocator)
                client := NewRealDebridClient(token)
                download_delete_remote_torrent(&client, provider_job_id)
                delete(token)
            }
            delete(provider_job_id)
            if entry.provider == .Durrent {
                download_remove_durrent_artifacts(
                    manager.app.download_path,
                    local_torrent_path,
                )
            }
            delete(local_torrent_path)
            download_remove_local_artifacts(manager, entry_index)
            return true
        case .Resolving, .Downloading, .Extracting, .Installing:
            entry.cancel_requested = true
            entry.pause_requested = false
            metadata_cancel := manager.metadata_cancel
            resolving_metadata := entry.state == .Resolving
            sync.mutex_unlock(&manager.mutex)
            if resolving_metadata && metadata_cancel != nil {
                durrent.Metadata_Resolver_Cancel(metadata_cancel)
            }
            return true
        case .NotDownloaded, .Installed, .Extracted, .Cancelled, .Paused, .Failed:
            sync.mutex_unlock(&manager.mutex)
            return false
        }
    }

    sync.mutex_unlock(&manager.mutex)
    return false
}


DownloadPauseGame :: proc(manager: ^DownloadManager, game_index: int) -> bool {
    if manager == nil {
        return false
    }

    sync.mutex_lock(&manager.mutex)
    metadata_cancel: ^durrent.Metadata_Resolver_Cancel_Token = nil
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
            if entry.state == .Resolving {
                metadata_cancel = manager.metadata_cancel
            }
            sync.mutex_unlock(&manager.mutex)
            if metadata_cancel != nil {
                durrent.Metadata_Resolver_Cancel(metadata_cancel)
            }
            return true
        }
    }
    sync.mutex_unlock(&manager.mutex)
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
        info_hash = download_game_info_hash(&manager.app.games[game_index])
    }
    defer delete(info_hash)

    // A completion marker is authoritative, including when a process exited
    // after writing the marker but before updating the manifest or queue entry.
    if game_index >= 0 && game_index < len(manager.app.games) {
        if len(info_hash) > 0 && download_marker_valid_for_game(manager.app.download_path, info_hash) {
            result.found = true
            result.state = .Installed
            result.progress = 1
            result.status_message = "Installed."
            return result
        }
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
            result.speed_bytes_per_second = entry.speed_bytes_per_second
            result.status_message = strings.clone(entry.status_message, context.temp_allocator)
            result.error_message = strings.clone(entry.error_message, context.temp_allocator)
            sync.mutex_unlock(&manager.mutex)
            return result
        }
    }
    sync.mutex_unlock(&manager.mutex)

    phase, manifest_archive, manifest_torrent, _ := download_read_manifest_for_game(manager, game_index)
    defer delete(phase)
    defer delete(manifest_archive)
    defer delete(manifest_torrent)
    if len(phase) > 0 && phase != "completed" {
        result.found = true
        switch phase {
        case "extracted", "installing":
            result.state = .Extracted
            result.status_message = "Archive extracted; installer has not completed."
        case "archive_ready", "extracting":
            result.state = .Paused
            result.status_message = "Archive work is paused and can be resumed."
        case "cancelled":
            result.state = .Cancelled
            result.status_message = "Installation cancelled."
        case "failed":
            result.state = .Failed
            result.error_message = download_manifest_value_from_file(manager, game_index, "message")
        case:
            result.state = .Paused
            result.status_message = "Partial work is paused and can be resumed."
        }
        return result
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

    info_hash := download_game_info_hash(&app.games[game_index])
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


ResumePersistedDownloadJobs :: proc(app: ^App) {
    if app == nil || len(app.download_path) == 0 {
        return
    }
    for game_index in 0..<len(app.games) {
        phase, archive_path, _, _ := download_read_manifest_for_game(
            &app.download_manager,
            game_index,
        )
        defer delete(phase)
        defer delete(archive_path)

        resume_phase := phase == "metadata_resolving" ||
            phase == "metadata_ready" ||
            phase == "resolving" ||
            phase == "remote_downloading" ||
            phase == "local_downloading" ||
            phase == "archive_ready" ||
            phase == "extracting" ||
            phase == "extracted" ||
            phase == "installing"
        if !resume_phase {
            continue
        }
        if DownloadQueueGame(&app.download_manager, game_index) {
            fmt.printf(
                "[STATE] Resuming game %q from phase=%s\n",
                app.games[game_index].title,
                phase,
            )
        }
    }
}


DownloadStateText :: proc(state: DownloadState) -> string {
    switch state {
    case .NotDownloaded: return "DOWNLOAD"
    case .Queued:        return "QUEUED"
    case .Resolving:     return "PREPARING"
    case .Downloading:   return "DOWNLOADING"
    case .Extracting:    return "EXTRACTING"
    case .Installing:    return "INSTALLING THROUGH GE-PROTON8-25"
    case .Installed:     return "INSTALLED"
    case .Extracted:     return "EXTRACTED - NOT INSTALLED"
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
    if client != nil && len(torrent_id) > 0 {
        // Archive installation can finish, fail, pause, or be cancelled through
        // many branches. All of those outcomes release the remote torrent.
        defer download_delete_remote_torrent(client, torrent_id)
    }
    if !os.exists(archive_path) {
        download_fail_entry(manager, entry_index, "Saved archive is missing; download it again.")
        return
    }

    // An old manifest could say "installing" after the process was killed.
    // It is never safe to interpret that phase as permission to execute setup.exe
    // directly; all resumes go through the current GE-Proton path.
    if phase == "installing" {
        fmt.printf("[DOWNLOAD] Migrating legacy installing phase to GE-Proton\n")
        download_write_manifest(manager, entry_index, "extracted", "Legacy installer phase migrated; resume through GE-Proton.")
    }

    runtime_ready, runtime_message := EnsureGEProtonRuntime(manager, entry_index)
    if !runtime_ready {
        if download_should_pause(manager, entry_index) {
            download_pause_entry(manager, entry_index, client)
        } else if download_should_cancel(manager, entry_index) {
            download_cancel_entry(manager, entry_index, client)
        } else {
            download_fail_entry(manager, entry_index, runtime_message)
        }
        delete(runtime_message)
        return
    }
    delete(runtime_message)

    extracted_directory := DownloadArchiveExtractDirectory(archive_path)
    defer delete(extracted_directory)
    reuse_extracted_directory := phase == "extracted" || phase == "installing"
    if !reuse_extracted_directory && os.exists(extracted_directory) {
        // Only an explicit extracted phase, or the legacy installing phase,
        // proves that the extraction directory is complete. Every other phase
        // must discard an existing tree before extracting again.
        if remove_err := os.remove_all(extracted_directory); remove_err != nil {
            message := fmt.aprintf("Could not reset extraction directory: %v", remove_err)
            download_fail_entry(manager, entry_index, message)
            delete(message)
            return
        }
    }
    if !os.is_directory(extracted_directory) {
        download_set_state(manager, entry_index, .Extracting)
        download_set_message(manager, entry_index, "Extracting archive...")
        download_write_manifest(manager, entry_index, "extracting", "")
        fmt.printf("[DOWNLOAD] Extracting archive %s\n", archive_path)
        extracted, extraction_message := ExtractDownloadArchiveAndWait(
            manager,
            entry_index,
            archive_path,
        )
        if !extracted {
            fmt.printf("[DOWNLOAD] Archive extraction failed: %s\n", extraction_message)
            if download_should_pause(manager, entry_index) {
                download_pause_entry(manager, entry_index, client)
            } else if download_should_cancel(manager, entry_index) {
                download_cancel_entry(manager, entry_index, client)
            } else {
                download_fail_entry(manager, entry_index, extraction_message)
            }
            delete(extraction_message)
            return
        }
        fmt.printf("[DOWNLOAD] Archive extraction completed: %s\n", extraction_message)
        delete(extraction_message)
    }

    download_set_state(manager, entry_index, .Extracted)
    download_set_message(manager, entry_index, "Archive extracted; preparing GE-Proton installer...")
    download_write_manifest(manager, entry_index, "extracted", "Archive extracted; installer has not completed.")

    download_set_state(manager, entry_index, .Installing)
    download_set_message(manager, entry_index, "Installing through GE-Proton8-25...")
    download_write_manifest(manager, entry_index, "installing", "Installing through GE-Proton8-25.")
    install_result, install_message := LaunchDownloadInstaller(
        manager,
        entry_index,
        archive_path,
    )
    if install_result != .InstallerStarted {
        if install_result == .InstallerNotFound {
            download_set_state(manager, entry_index, .Extracted)
            download_set_message(manager, entry_index, install_message)
            download_write_manifest(manager, entry_index, "extracted", install_message)
        } else if install_result == .InstallerPaused || download_should_pause(manager, entry_index) {
            download_pause_entry(manager, entry_index, client)
        } else if install_result == .InstallerCancelled || download_should_cancel(manager, entry_index) {
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
    resume_game_name := ""
    resume_game_index := manager.entries[entry_index].game_index
    if resume_game_index >= 0 && resume_game_index < len(manager.app.games) {
        resume_game_name = strings.clone(manager.app.games[resume_game_index].title, context.allocator)
    }
    resume_directory := strings.clone(manager.app.download_path, context.allocator)
    sync.mutex_unlock(&manager.mutex)
    defer delete(resume_info_hash)
    defer delete(resume_game_name)
    defer delete(resume_directory)
    install_directory := DownloadGameInstallPath(resume_directory, resume_game_name, resume_info_hash)
    defer delete(install_directory)
    marker_path := download_marker_path(resume_directory, resume_info_hash)
    marked, marker_error := download_mark_entry_complete(
        manager,
        entry_index,
        marker_path,
        install_directory,
        0,
    )
    delete(marker_path)
    if !marked {
        if download_should_cancel(manager, entry_index) {
            download_cancel_entry(manager, entry_index, client)
        } else {
            download_fail_entry(manager, entry_index, marker_error)
        }
        delete(marker_error)
        return
    }
    delete(marker_error)
    download_cleanup_completed_archive_artifacts(archive_path)
    sync.mutex_lock(&manager.mutex)
    if entry_index >= 0 && entry_index < len(manager.entries) {
        delete(manager.entries[entry_index].output_path)
        delete(manager.entries[entry_index].part_path)
        delete(manager.entries[entry_index].archive_path)
        manager.entries[entry_index].output_path = ""
        manager.entries[entry_index].part_path = ""
        manager.entries[entry_index].archive_path = ""
    }
    sync.mutex_unlock(&manager.mutex)
    download_set_message(manager, entry_index, "Installed through GE-Proton8-25; archive cleaned up.")
    download_write_manifest(manager, entry_index, "completed", "Installed through GE-Proton8-25; archive and extraction cleaned up.")
}


download_process_entry :: proc(manager: ^DownloadManager, entry_index: int) {
    if manager == nil || manager.app == nil {
        return
    }

    provider := DownloadProvider.RealDebrid
    sync.mutex_lock(&manager.mutex)
    if entry_index >= 0 && entry_index < len(manager.entries) {
        provider = manager.entries[entry_index].provider
    }
    sync.mutex_unlock(&manager.mutex)

    switch provider {
    case .RealDebrid:
        download_process_realdebrid_entry(manager, entry_index)
    case .Durrent:
        download_process_durrent_entry(manager, entry_index)
    }
}


download_manager_stop_requested :: proc(manager: ^DownloadManager) -> bool {
    if manager == nil {
        return true
    }
    sync.mutex_lock(&manager.mutex)
    defer sync.mutex_unlock(&manager.mutex)
    return manager.stop_requested
}


download_copy_local_torrent_path :: proc(manager: ^DownloadManager, entry_index: int) -> string {
    sync.mutex_lock(&manager.mutex)
    defer sync.mutex_unlock(&manager.mutex)
    if entry_index < 0 || entry_index >= len(manager.entries) {
        return ""
    }
    return strings.clone(manager.entries[entry_index].local_torrent_path, context.allocator)
}


download_torrent_file_path :: proc(
    torrent: ^durrent.Torrent,
    output_directory: string,
    file_index: int,
) -> string {
    if torrent == nil || file_index < 0 || file_index >= len(torrent.Files) {
        return ""
    }

    result := fmt.aprintf("%s/%s", output_directory, string(torrent.Name))
    if !torrent.Multi_File {
        return result
    }

    for component in torrent.Files[file_index].Path {
        next := fmt.aprintf("%s/%s", result, string(component))
        delete(result)
        result = next
    }
    return result
}


download_find_torrent_archive :: proc(
    torrent: ^durrent.Torrent,
    output_directory: string,
) -> string {
    if torrent == nil {
        return ""
    }
    for file_index := 0; file_index < len(torrent.Files); file_index += 1 {
        path := download_torrent_file_path(torrent, output_directory, file_index)
        if DownloadPathIsArchive(path) {
            return path
        }
        delete(path)
    }
    return ""
}


download_torrent_install_target :: proc(
    torrent: ^durrent.Torrent,
    output_directory: string,
) -> string {
    if torrent == nil {
        return ""
    }
    if torrent.Multi_File {
        return fmt.aprintf("%s/%s", output_directory, string(torrent.Name))
    }
    return download_torrent_file_path(torrent, output_directory, 0)
}


download_remove_durrent_artifacts :: proc(
    output_directory, torrent_path: string,
) {
    if len(output_directory) == 0 || len(torrent_path) == 0 {
        return
    }
    data, read_error := os.read_entire_file_from_path(
        torrent_path,
        context.allocator,
    )
    if read_error != nil {
        return
    }
    defer delete(data)
    torrent, parse_error := durrent.Parse_Torrent(data[:])
    if parse_error != .None {
        return
    }
    defer durrent.Destroy_Torrent(&torrent)

    output_root := fmt.aprintf("%s/%s", output_directory, string(torrent.Name))
    defer delete(output_root)
    if os.is_directory(output_root) {
        if remove_error := os.remove_all(output_root); remove_error != nil {
            fmt.printf("[DOWNLOAD] WARNING: could not remove Durrent torrent data %s: %v\n", output_root, remove_error)
        }
    } else {
        download_remove_local_path(output_root, "Durrent torrent data")
    }

    resume_path := fmt.aprintf(
        "%s/.%s.durrent.resume",
        output_directory,
        string(torrent.Name),
    )
    defer delete(resume_path)
    download_remove_local_path(resume_path, "Durrent resume data")
}


durrent_peer_id: [20]byte
durrent_peer_id_initialized: bool


download_durrent_peer_id :: proc() -> (peer_id: [20]byte) {
    // Reuse one ID for this process so tracker, metadata, and download
    // connections identify the same client, but never reuse the old fixed
    // ID across launches.
    if !durrent_peer_id_initialized {
        prefix := "-FB0100-"
        for index := 0; index < len(prefix); index += 1 {
            durrent_peer_id[index] = prefix[index]
        }

        // A timestamp-seeded nonce prevents reuse across Fatboy processes.
        value := u64(time.to_unix_nanoseconds(time.now()))
        alphabet := "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
        for index := 8; index < len(durrent_peer_id); index += 1 {
            value = value ~ (value << 13)
            value = value ~ (value >> 7)
            value = value ~ (value << 17)
            durrent_peer_id[index] = alphabet[int(value % u64(len(alphabet)))]
        }
        durrent_peer_id_initialized = true
        fmt.printf("[DURRENT-PEER] local peer_id=%q\n", string(durrent_peer_id[:]))
    }
    return durrent_peer_id
}


download_set_metadata_cancel :: proc(
    manager: ^DownloadManager,
    token: ^durrent.Metadata_Resolver_Cancel_Token,
) {
    if manager == nil {
        return
    }
    sync.mutex_lock(&manager.mutex)
    manager.metadata_cancel = token
    sync.mutex_unlock(&manager.mutex)
}


download_metadata_cache_path :: proc(download_directory, info_hash: string) -> string {
    if len(download_directory) == 0 || len(info_hash) == 0 {
        return ""
    }
    state_directory := download_state_directory(download_directory)
    defer delete(state_directory)
    return fmt.aprintf("%s/torrents/%s.torrent", state_directory, info_hash)
}


download_validate_metadata_cache :: proc(path: string, expected_hash: durrent.Torrent_Hash) -> bool {
    if len(path) == 0 || !os.is_file(path) {
        return false
    }
    data, read_error := os.read_entire_file_from_path(path, context.allocator)
    if read_error != nil {
        return false
    }
    defer delete(data)
    torrent, parse_error := durrent.Parse_Torrent(data[:])
    if parse_error != .None {
        return false
    }
    defer durrent.Destroy_Torrent(&torrent)
    return torrent.Info_Hash == expected_hash
}


download_attach_magnet_trackers :: proc(torrent: ^durrent.Torrent, magnet_uri: string) {
    if torrent == nil || len(magnet_uri) == 0 || len(torrent.Announce_List) > 0 {
        return
    }
    magnet, parse_error := durrent.Parse_Magnet(magnet_uri)
    if parse_error != .None {
        return
    }
    defer durrent.Destroy_Magnet_Link(&magnet)

    tracker_urls := magnet.Trackers
    fallback_trackers: [4]string
    if len(tracker_urls) == 0 {
        fallback_trackers = [4]string{
            "udp://tracker.opentrackr.org:1337/announce",
            "udp://open.stealth.si:80/announce",
            "udp://tracker.torrent.eu.org:451/announce",
            "http://tracker.openbittorrent.com:80/announce",
        }
    }

    if len(tracker_urls) > 0 {
        for tracker_url in tracker_urls {
            copied_url := strings.clone(string(tracker_url), context.allocator)
            tier: durrent.Torrent_Tracker_Tier
            append(&tier.URLs, transmute([]byte)copied_url)
            append(&torrent.Announce_List, tier)
            copied_url = ""
        }
        if len(torrent.Announce) == 0 {
            copied_announce := strings.clone(string(tracker_urls[0]), context.allocator)
            torrent.Announce = transmute([]byte)copied_announce
            copied_announce = ""
        }
    } else {
        for tracker_url in fallback_trackers {
            copied_url := strings.clone(tracker_url, context.allocator)
            tier: durrent.Torrent_Tracker_Tier
            append(&tier.URLs, transmute([]byte)copied_url)
            append(&torrent.Announce_List, tier)
            copied_url = ""
        }
        copied_announce := strings.clone(fallback_trackers[0], context.allocator)
        torrent.Announce = transmute([]byte)copied_announce
        copied_announce = ""
    }
}


download_write_metadata_cache :: proc(path: string, data: []byte) -> bool {
    if len(path) == 0 || len(data) == 0 {
        return false
    }
    separator := strings.last_index(path, "/")
    if separator < 0 {
        return false
    }
    directory := path[:separator]
    if !os.exists(directory) && os.make_directory_all(directory) != nil {
        return false
    }
    temporary_path := fmt.aprintf("%s.tmp", path)
    defer delete(temporary_path)
    if os.write_entire_file(temporary_path, data) != nil {
        return false
    }
    return os.rename(temporary_path, path) == nil
}


download_set_entry_local_torrent_path :: proc(
    manager: ^DownloadManager,
    entry_index: int,
    path: string,
) {
    if manager == nil {
        return
    }
    sync.mutex_lock(&manager.mutex)
    if entry_index >= 0 && entry_index < len(manager.entries) {
        delete(manager.entries[entry_index].local_torrent_path)
        manager.entries[entry_index].local_torrent_path = strings.clone(
            path,
            context.allocator,
        )
    }
    sync.mutex_unlock(&manager.mutex)
}


download_set_resolver_status :: proc(
    manager: ^DownloadManager,
    entry_index: int,
    attempt: u32,
    error_message: string,
) {
    if manager == nil {
        return
    }
    sync.mutex_lock(&manager.mutex)
    if entry_index >= 0 && entry_index < len(manager.entries) {
        manager.entries[entry_index].resolver_attempt = attempt
        delete(manager.entries[entry_index].resolver_error)
        manager.entries[entry_index].resolver_error = strings.clone(
            error_message,
            context.allocator,
        )
    }
    sync.mutex_unlock(&manager.mutex)
}


download_copy_entry_magnet :: proc(manager: ^DownloadManager, entry_index: int) -> string {
    if manager == nil {
        return ""
    }
    sync.mutex_lock(&manager.mutex)
    defer sync.mutex_unlock(&manager.mutex)
    if entry_index < 0 || entry_index >= len(manager.entries) {
        return ""
    }
    return strings.clone(manager.entries[entry_index].magnet_link, context.allocator)
}


download_metadata_error_message :: proc(error: durrent.Metadata_Resolver_Error) -> string {
    switch error {
    case .Invalid_Magnet: return "The game magnet link is invalid."
    case .Cancelled: return "Magnet metadata resolution was cancelled."
    case .Timed_Out: return "Magnet metadata resolution timed out."
    case .No_Peers: return "No peers were found for the magnet."
    case .Tracker: return "The magnet trackers could not be reached."
    case .DHT: return "DHT peer discovery failed."
    case .Metadata: return "Peers did not provide valid torrent metadata."
    case .Out_Of_Memory: return "Not enough memory to resolve torrent metadata."
    case .None: return ""
    }
    return "Magnet metadata resolution failed."
}


download_resolve_durrent_torrent :: proc(
    manager: ^DownloadManager,
    entry_index: int,
) -> (torrent_path, error_message: string, cancelled: bool) {
    app := manager.app
    if app == nil {
        return "", "Download manager is unavailable.", false
    }
    magnet_uri := download_copy_entry_magnet(manager, entry_index)
    defer delete(magnet_uri)
    magnet, parse_error := durrent.Parse_Magnet(magnet_uri)
    if parse_error != .None {
        return "", "The game magnet link is invalid.", false
    }
    defer durrent.Destroy_Magnet_Link(&magnet)

    info_hash := download_torrent_hash_to_string(magnet.Info_Hash)
    defer delete(info_hash)
    cache_path := download_metadata_cache_path(app.download_path, info_hash)
    fmt.printf(
        "[DOWNLOAD] Durrent metadata entry=%d hash=%s cache=%s\n",
        entry_index,
        info_hash,
        cache_path,
    )
    if download_validate_metadata_cache(cache_path, magnet.Info_Hash) {
        fmt.printf("[DOWNLOAD] Durrent metadata cache hit entry=%d\n", entry_index)
        download_set_entry_local_torrent_path(manager, entry_index, cache_path)
        sync.mutex_lock(&manager.mutex)
        game_index := manager.entries[entry_index].game_index
        sync.mutex_unlock(&manager.mutex)
        if game_index >= 0 && game_index < len(app.games) {
            delete(app.games[game_index].local_torrent_path)
            app.games[game_index].local_torrent_path = strings.clone(cache_path, context.allocator)
            delete(app.games[game_index].source_info_hash)
            app.games[game_index].source_info_hash = strings.clone(info_hash, context.allocator)
        }
        download_write_manifest(manager, entry_index, "metadata_ready", "Cached torrent metadata validated.")
        return cache_path, "", false
    }
    if os.exists(cache_path) {
        fmt.printf("[DOWNLOAD] Durrent metadata cache invalid; deleting %s\n", cache_path)
        download_remove_local_path(cache_path, "invalid metadata cache")
    } else {
        fmt.printf("[DOWNLOAD] Durrent metadata cache miss entry=%d\n", entry_index)
    }

    download_set_state(manager, entry_index, .Resolving)
    download_set_message(manager, entry_index, "Resolving magnet metadata...")
    download_set_resolver_status(manager, entry_index, 1, "")
    download_write_manifest(manager, entry_index, "metadata_resolving", "Resolving magnet metadata.")

    cancel_token: durrent.Metadata_Resolver_Cancel_Token
    download_set_metadata_cancel(manager, &cancel_token)
    options := durrent.Metadata_Resolver_Default_Options()
    options.Cancel = &cancel_token
    state_directory := download_state_directory(app.download_path)
    defer delete(state_directory)
    if !os.exists(state_directory) {
        _ = os.make_directory_all(state_directory)
    }
    routing_cache_path := fmt.aprintf("%s/dht-routing.bin", state_directory)
    defer delete(routing_cache_path)
    options.Routing_Cache_Path = routing_cache_path
    fmt.printf("[DOWNLOAD] Starting Durrent metadata resolver entry=%d\n", entry_index)
    metadata, resolver_error := durrent.Resolve_Magnet_Metadata(
        &magnet,
        download_durrent_peer_id(),
        options,
    )
    download_set_metadata_cancel(manager, nil)
    fmt.printf(
        "[DOWNLOAD] Durrent metadata resolver finished entry=%d result=%v bytes=%d\n",
        entry_index,
        resolver_error,
        len(metadata),
    )
    if resolver_error != .None {
        if resolver_error == .Cancelled ||
           download_should_cancel(manager, entry_index) ||
           download_manager_stop_requested(manager) {
            return "", "Magnet metadata resolution was cancelled.", true
        }
        message := download_metadata_error_message(resolver_error)
        download_set_resolver_status(manager, entry_index, 1, message)
        return "", message, false
    }
    defer delete(metadata)

    if !download_write_metadata_cache(cache_path, metadata) {
        fmt.printf("[DOWNLOAD] ERROR: could not write Durrent metadata cache %s\n", cache_path)
        return "", "Could not cache the resolved torrent metadata.", false
    }
    fmt.printf("[DOWNLOAD] Durrent metadata cache written path=%s bytes=%d\n", cache_path, len(metadata))
    download_set_entry_local_torrent_path(manager, entry_index, cache_path)
    sync.mutex_lock(&manager.mutex)
    game_index := manager.entries[entry_index].game_index
    sync.mutex_unlock(&manager.mutex)
    if game_index >= 0 && game_index < len(app.games) {
        delete(app.games[game_index].local_torrent_path)
        app.games[game_index].local_torrent_path = strings.clone(cache_path, context.allocator)
        delete(app.games[game_index].source_info_hash)
        app.games[game_index].source_info_hash = strings.clone(info_hash, context.allocator)
    }
    download_write_manifest(manager, entry_index, "metadata_ready", "Magnet metadata cached.")
    return cache_path, "", false
}


download_process_durrent_entry :: proc(manager: ^DownloadManager, entry_index: int) {
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

    resume_phase, resume_archive, _, _ := download_read_manifest_for_game(manager, game_index)
    defer delete(resume_phase)
    defer delete(resume_archive)
    if (resume_phase == "archive_ready" ||
        resume_phase == "extracting" ||
        resume_phase == "extracted" ||
        resume_phase == "installing" ||
        resume_phase == "paused" ||
        resume_phase == "failed") &&
       len(resume_archive) > 0 && os.exists(resume_archive) {
        download_resume_archive_entry(
            manager,
            entry_index,
            resume_archive,
            "",
            resume_phase,
            nil,
        )
        return
    }

    torrent_path := download_copy_local_torrent_path(manager, entry_index)
    fmt.printf("[DOWNLOAD] Durrent entry=%d torrent_path=%s\n", entry_index, torrent_path)
    if len(torrent_path) == 0 {
        resolved_path, resolve_error, cancelled := download_resolve_durrent_torrent(
            manager,
            entry_index,
        )
        if cancelled {
            if download_should_pause(manager, entry_index) || download_manager_stop_requested(manager) {
                download_pause_entry(manager, entry_index, nil)
            } else {
                download_cancel_entry(manager, entry_index, nil)
            }
            return
        }
        if len(resolve_error) > 0 {
            // Resolver error messages and the empty path may be string
            // literals, so neither result is owned by this caller.
            download_fail_entry(manager, entry_index, resolve_error)
            return
        }
        delete(torrent_path)
        torrent_path = resolved_path
    }
    defer delete(torrent_path)

    data, read_error := os.read_entire_file_from_path(
        torrent_path,
        context.allocator,
    )
    if read_error != nil {
        download_fail_entry(manager, entry_index, "Could not read the local .torrent file.")
        return
    }
    defer delete(data)

    torrent, parse_error := durrent.Parse_Torrent(data[:])
    fmt.printf("[DOWNLOAD] Durrent torrent parse entry=%d result=%v bytes=%d\n", entry_index, parse_error, len(data))
    if parse_error != .None {
        download_fail_entry(manager, entry_index, "The local .torrent file is invalid.")
        return
    }
    defer durrent.Destroy_Torrent(&torrent)
    source_magnet := download_copy_entry_magnet(manager, entry_index)
    defer delete(source_magnet)
    download_attach_magnet_trackers(&torrent, source_magnet)

    if download_should_cancel(manager, entry_index) {
        download_remove_durrent_artifacts(app.download_path, torrent_path)
        download_cancel_entry(manager, entry_index, nil)
        return
    }
    if download_should_pause(manager, entry_index) ||
       download_manager_stop_requested(manager) {
        download_pause_entry(manager, entry_index, nil)
        return
    }

    download_set_state(manager, entry_index, .Resolving)
    download_set_message(manager, entry_index, "Opening local torrent...")
    download_write_manifest(manager, entry_index, "resolving", "Opening local torrent.")
    if !EnsureDownloadDirectory(app.download_path) {
        download_fail_entry(manager, entry_index, "Download folder is not usable.")
        return
    }

    loop: durrent.Torrent_Session_Loop
    fmt.printf(
        "[DOWNLOAD] Opening Durrent session entry=%d output=%s files=%d multi=%v\n",
        entry_index,
        app.download_path,
        len(torrent.Files),
        torrent.Multi_File,
    )
    // Do not synchronously hash the entire output directory here. A
    // multi-file game can already contain tens of gigabytes, and that scan
    // blocks the download worker before it can publish a progress state.
    // Resume metadata still restores trusted completed pieces; missing pieces
    // are verified as they are received by the scheduler/storage path.
    open_error := durrent.Torrent_Session_Loop_Open(
        &loop,
        &torrent,
        app.download_path,
        download_durrent_peer_id(),
        0,
        false,
    )
    fmt.printf("[DOWNLOAD] Durrent session open entry=%d result=%v\n", entry_index, open_error)
    if open_error != .None {
        download_fail_entry(manager, entry_index, "Could not open the local torrent session.")
        return
    }

    start_error := durrent.Torrent_Session_Loop_Start(&loop)
    fmt.printf("[DOWNLOAD] Durrent session start entry=%d result=%v\n", entry_index, start_error)
    if start_error != .None {
        _ = durrent.Torrent_Session_Loop_Shutdown(&loop)
        download_fail_entry(manager, entry_index, "Could not start the local torrent session.")
        return
    }

    download_set_state(manager, entry_index, .Downloading)
    download_set_message(manager, entry_index, "Downloading through Durrent...")
    download_write_manifest(manager, entry_index, "local_downloading", "Downloading through Durrent.")

    completed := false
    stats_log_at := time.time_add(time.now(), 2*time.Second)
    no_progress_since := time.now()
    for {
        if download_should_cancel(manager, entry_index) {
            _ = durrent.Torrent_Session_Loop_Shutdown(&loop)
            download_remove_durrent_artifacts(app.download_path, torrent_path)
            download_cancel_entry(manager, entry_index, nil)
            return
        }
        if download_should_pause(manager, entry_index) ||
           download_manager_stop_requested(manager) {
            _ = durrent.Torrent_Session_Loop_Pause(&loop)
            _ = durrent.Torrent_Session_Loop_Shutdown(&loop)
            download_pause_entry(manager, entry_index, nil)
            return
        }

        stats, snapshot_error := durrent.Torrent_Session_Loop_Snapshot(&loop)
        if snapshot_error != .None {
            _ = durrent.Torrent_Session_Loop_Shutdown(&loop)
            download_fail_entry(manager, entry_index, "Could not read the Durrent session state.")
            return
        }

        total_bytes := i64(torrent.Total_Length)
        completed_bytes := i64(stats.Completed_Bytes)
        fraction := f64(0)
        if total_bytes > 0 {
            fraction = f64(completed_bytes) / f64(total_bytes)
        }
        download_set_progress(
            manager,
            entry_index,
            fraction,
            completed_bytes,
            total_bytes,
        )
        download_set_speed(
            manager,
            entry_index,
            stats.Download_Bytes_Per_Second,
        )
        if completed_bytes > 0 {
            no_progress_since = time.now()
        }
        if completed_bytes == 0 && stats.Connected_Peers == 0 &&
           time.diff(no_progress_since, time.now()) >= 5*time.Minute {
            _ = durrent.Torrent_Session_Loop_Shutdown(&loop)
            download_fail_entry(manager, entry_index, "No reachable data peers were found.")
            return
        }
        if time.diff(stats_log_at, time.now()) >= 0 {
            fmt.printf(
                "[DOWNLOAD] Durrent stats state=%v peers=%d connected=%d progress=%.1f%% bytes=%d/%d speed=%.1f KiB/s\n",
                stats.State,
                stats.Peer_Count,
                stats.Connected_Peers,
                fraction * 100,
                completed_bytes,
                total_bytes,
                stats.Download_Bytes_Per_Second / 1024,
            )
            status := fmt.aprintf(
                "Downloading through Durrent... peers=%d connected=%d",
                stats.Peer_Count,
                stats.Connected_Peers,
            )
            download_set_message(manager, entry_index, status)
            delete(status)
            stats_log_at = time.time_add(time.now(), 2*time.Second)
        }

        if stats.State == .Failed {
            _ = durrent.Torrent_Session_Loop_Shutdown(&loop)
            download_fail_entry(manager, entry_index, "Durrent reported a torrent failure.")
            return
        }
        if stats.Seeding || stats.Completed_Bytes >= torrent.Total_Length {
            completed = true
            break
        }
        time.sleep(250 * time.Millisecond)
    }

    shutdown_error := durrent.Torrent_Session_Loop_Shutdown(&loop)
    fmt.printf("[DOWNLOAD] Durrent session shutdown entry=%d result=%v completed=%v\n", entry_index, shutdown_error, completed)
    if !completed {
        download_fail_entry(manager, entry_index, "Durrent stopped before the torrent completed.")
        return
    }

    archive_path := download_find_torrent_archive(&torrent, app.download_path)
    fmt.printf("[DOWNLOAD] Durrent archive scan entry=%d archive=%s\n", entry_index, archive_path)
    if len(archive_path) == 0 {
        install_target := download_torrent_install_target(&torrent, app.download_path)
        defer delete(install_target)
        if len(install_target) == 0 || !os.exists(install_target) {
            download_fail_entry(manager, entry_index, "The completed torrent did not contain an archive or install directory.")
            return
        }
        download_set_paths(manager, entry_index, install_target, "")
        download_set_progress(
            manager,
            entry_index,
            1,
            i64(torrent.Total_Length),
            i64(torrent.Total_Length),
        )
        info_hash := ""
        sync.mutex_lock(&manager.mutex)
        if entry_index >= 0 && entry_index < len(manager.entries) {
            info_hash = strings.clone(manager.entries[entry_index].info_hash, context.allocator)
        }
        sync.mutex_unlock(&manager.mutex)
        defer delete(info_hash)
        marker_path := download_marker_path(app.download_path, info_hash)
        defer delete(marker_path)
        marked, marker_error := download_mark_entry_complete(
            manager,
            entry_index,
            marker_path,
            install_target,
            i64(torrent.Total_Length),
        )
        if !marked {
            download_fail_entry(manager, entry_index, marker_error)
            delete(marker_error)
            return
        }
        download_set_message(manager, entry_index, "Durrent content is ready.")
        download_write_manifest(manager, entry_index, "completed", "Durrent content is ready.")
        return
    }
    defer delete(archive_path)

    download_set_paths(manager, entry_index, archive_path, "")
    download_set_archive_path(manager, entry_index, archive_path)
    download_set_progress(
        manager,
        entry_index,
        1,
        i64(torrent.Total_Length),
        i64(torrent.Total_Length),
    )
    download_write_manifest(manager, entry_index, "archive_ready", "Archive downloaded; preparing extraction.")
    download_resume_archive_entry(
        manager,
        entry_index,
        archive_path,
        "",
        "archive_ready",
        nil,
    )
}


download_process_realdebrid_entry :: proc(manager: ^DownloadManager, entry_index: int) {
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

    // A fully downloaded archive must remain installable even if the
    // Real-Debrid token expired after the download completed. Resume the
    // archive/runtime/install path before contacting the API again.
    resume_phase, resume_archive, resume_torrent, _ := download_read_manifest_for_game(manager, game_index)
    defer delete(resume_phase)
    defer delete(resume_archive)
    defer delete(resume_torrent)
    if download_should_cancel(manager, entry_index) {
        download_cancel_entry(manager, entry_index, nil)
        return
    }
    resume_token := strings.clone(app.rd_key, context.allocator)
    defer delete(resume_token)
    resume_client: RealDebridClient
    resume_client_ptr: ^RealDebridClient = nil
    if len(resume_token) > 0 {
        resume_client = NewRealDebridClient(resume_token)
        resume_client_ptr = &resume_client
    }
    if (resume_phase == "archive_ready" ||
        resume_phase == "extracting" ||
        resume_phase == "extracted" ||
        resume_phase == "installing" ||
        resume_phase == "paused" ||
        resume_phase == "failed") &&
       len(resume_archive) > 0 && os.exists(resume_archive) {
        download_resume_archive_entry(
            manager,
            entry_index,
            resume_archive,
            resume_torrent,
            resume_phase,
            resume_client_ptr,
        )
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
    download_set_message(manager, entry_index, "Preparing Real-Debrid torrent...")
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

    download_set_provider_job_id(manager, entry_index, created.id)
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

        if download_should_pause(manager, entry_index) {
            download_pause_entry(manager, entry_index, &client)
            return
        }

        conversion_info, conversion_err := RDGetTorrentInfo(&client, torrent_id)
        if conversion_err.message != "" {
            download_fail_entry_from_rd(manager, entry_index, &conversion_err)
            download_delete_remote_torrent(&client, torrent_id)
            return
        }

        // These booleans must be computed before destroying conversion_info:
        // conversion_status is a string owned by that response object.
        conversion_status := conversion_info.status
        waiting_for_selection := conversion_status == "waiting_files_selection"
        terminal_conversion_error :=
            conversion_status == "magnet_error" ||
            conversion_status == "error" ||
            conversion_status == "virus" ||
            conversion_status == "dead"
        conversion_is_still_running := conversion_status == "magnet_conversion"
        conversion_failure_message := ""
        if terminal_conversion_error {
            conversion_failure_message = fmt.aprintf(
                "Real-Debrid torrent failed: %s",
                conversion_status,
            )
        }

        selected_files := "all"
        if waiting_for_selection {
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

        if waiting_for_selection {
            rd_err = RDSelectTorrentFiles(&client, torrent_id, selected_files)
            if rd_err.message != "" {
                download_fail_entry_from_rd(manager, entry_index, &rd_err)
                download_delete_remote_torrent(&client, torrent_id)
                return
            }
            fmt.println("[DOWNLOAD] Torrent file selection accepted; waiting for download to start")
            break
        }

        if terminal_conversion_error {
            download_fail_entry(manager, entry_index, conversion_failure_message)
            delete(conversion_failure_message)
            download_delete_remote_torrent(&client, torrent_id)
            return
        }

        // queued/downloading/downloaded means selection has already been
        // accepted, while magnet_conversion means we should keep polling.
        if !conversion_is_still_running {
            break
        }

        if download_should_pause(manager, entry_index) {
            download_pause_entry(manager, entry_index, &client)
            return
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
        if download_should_pause(manager, entry_index) {
            download_pause_entry(manager, entry_index, &client)
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
        if download_should_pause(manager, entry_index) {
            download_pause_entry(manager, entry_index, &client)
            return
        }
        time.sleep(2 * time.Second)
    }

    download_set_state(manager, entry_index, .Downloading)
    download_set_message(manager, entry_index, "Downloading game archive...")

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
        file_status_message := fmt.aprintf("Downloading %s...", filename)
        download_set_message(manager, entry_index, file_status_message)
        delete(file_status_message)
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
            interrupted_by_pause := download_should_pause(manager, entry_index)
            interrupted_by_cancel := download_should_cancel(manager, entry_index)
            if interrupted_by_pause || interrupted_by_cancel {
                delete(filename)
                delete(output_path)
                delete(part_path)
                DestroyRealDebridTorrentInfo(&info)
                delete(first_output_path)
                if interrupted_by_pause {
                    download_pause_entry(manager, entry_index, &client)
                } else {
                    download_cancel_entry(manager, entry_index, &client)
                }
                delete(transfer_error)
                return
            }

            delete(filename)
            delete(output_path)
            delete(part_path)
            DestroyRealDebridTorrentInfo(&info)
            delete(first_output_path)
            download_fail_entry(manager, entry_index, transfer_error)
            delete(transfer_error)
            download_delete_remote_torrent(&client, torrent_id)
            return
        }

        fmt.printf("[DOWNLOAD] Finalizing local file %s\n", output_path)
        finalized, finalize_cancelled, finalize_error := download_finalize_file(
            manager,
            entry_index,
            part_path,
            output_path,
            marker_path,
            expected_size,
            false,
        )
        fmt.printf(
            "[DOWNLOAD] Local file finalization result finalized=%v cancelled=%v\n",
            finalized,
            finalize_cancelled,
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

    fmt.println("[DOWNLOAD] Local files finalized; releasing torrent metadata")
    DestroyRealDebridTorrentInfo(&info)
    if len(first_output_path) == 0 {
        download_fail_entry(manager, entry_index, "Real-Debrid returned no file paths.")
        download_delete_remote_torrent(&client, torrent_id)
        return
    }

    if DownloadPathIsArchive(first_output_path) {
        fmt.printf("[DOWNLOAD] Archive detected; starting GE-Proton install flow %s\n", first_output_path)
        download_write_manifest(manager, entry_index, "archive_ready", "Archive downloaded; preparing extraction.")
        download_resume_archive_entry(
            manager,
            entry_index,
            first_output_path,
            torrent_id,
            "archive_ready",
            &client,
        )
        delete(first_output_path)
        return
    }

    marked, marker_error := download_mark_entry_complete(
        manager,
        entry_index,
        marker_path,
        first_output_path,
        completed_bytes,
    )
    if marked {
        download_set_message(manager, entry_index, "Installed.")
        download_write_manifest(manager, entry_index, "completed", "Installed.")
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
        return false, false, false, strings.clone("Could not initialize libcurl for file download.", context.allocator)
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
            return false, false, strings.clone("Could not resume download safely after the server rejected the byte range.", context.allocator)
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

    return false, false, strings.clone("File download did not start.", context.allocator)
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
        if !download_ensure_state_directory(manager.app.download_path) {
            os.remove(output_path)
            return false, false, strings.clone("Downloaded file, but the Fatboy state directory could not be created.", context.allocator)
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
        manager.entries[entry_index].state = .Installed
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
        return false, strings.clone("Invalid download entry.", context.allocator)
    }
    if manager.stop_requested || manager.entries[entry_index].cancel_requested {
        return false, strings.clone("Download cancelled.", context.allocator)
    }

    download_directory := strings.clone(manager.app.download_path, context.allocator)
    sync.mutex_unlock(&manager.mutex)
    state_ready := download_ensure_state_directory(download_directory)
    delete(download_directory)
    sync.mutex_lock(&manager.mutex)
    if !state_ready {
        return false, strings.clone("Could not create the Fatboy state directory.", context.allocator)
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
    manager.entries[entry_index].state = .Installed
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
        manager.entries[entry_index].cancel_requested
}


download_set_state :: proc(manager: ^DownloadManager, entry_index: int, state: DownloadState) {
    sync.mutex_lock(&manager.mutex)
    defer sync.mutex_unlock(&manager.mutex)

    if entry_index >= 0 && entry_index < len(manager.entries) {
        manager.entries[entry_index].state = state
    }
}


download_set_message :: proc(manager: ^DownloadManager, entry_index: int, message: string) {
    sync.mutex_lock(&manager.mutex)
    defer sync.mutex_unlock(&manager.mutex)

    if entry_index < 0 || entry_index >= len(manager.entries) {
        return
    }
    delete(manager.entries[entry_index].status_message)
    manager.entries[entry_index].status_message = strings.clone(message, context.allocator)
}


download_set_provider_job_id :: proc(manager: ^DownloadManager, entry_index: int, provider_job_id: string) {
    sync.mutex_lock(&manager.mutex)
    defer sync.mutex_unlock(&manager.mutex)

    if entry_index < 0 || entry_index >= len(manager.entries) {
        return
    }

    delete(manager.entries[entry_index].provider_job_id)
    manager.entries[entry_index].provider_job_id = strings.clone(
        provider_job_id,
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


download_set_speed :: proc(manager: ^DownloadManager, entry_index: int, speed_bytes_per_second: f64) {
    sync.mutex_lock(&manager.mutex)
    defer sync.mutex_unlock(&manager.mutex)
    if entry_index >= 0 && entry_index < len(manager.entries) {
        manager.entries[entry_index].speed_bytes_per_second = speed_bytes_per_second
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
    fmt.printf("[DOWNLOAD] FAILED entry=%d message=%s\n", entry_index, message)
    sync.mutex_lock(&manager.mutex)
    if entry_index < 0 || entry_index >= len(manager.entries) {
        sync.mutex_unlock(&manager.mutex)
        return
    }

    delete(manager.entries[entry_index].error_message)
    delete(manager.entries[entry_index].status_message)
    manager.entries[entry_index].error_message = strings.clone(message, context.allocator)
    manager.entries[entry_index].status_message = strings.clone(message, context.allocator)
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
    provider_job_id := download_copy_provider_job_id(manager, entry_index)
    defer delete(provider_job_id)
    if client != nil && len(provider_job_id) > 0 {
        download_delete_remote_torrent(client, provider_job_id)
    }

    resume_phase := "paused"
    sync.mutex_lock(&manager.mutex)
    if entry_index >= 0 && entry_index < len(manager.entries) {
        switch manager.entries[entry_index].state {
        case .Extracting: resume_phase = "extracting"
        case .Installing: resume_phase = "installing"
        case .Extracted: resume_phase = "extracted"
        case .NotDownloaded, .Queued, .Resolving, .Downloading,
             .Installed, .Cancelled, .Paused, .Failed:
            resume_phase = "paused"
        }
    }
    sync.mutex_unlock(&manager.mutex)
    download_set_state(manager, entry_index, .Paused)
    download_set_message(manager, entry_index, "Paused; resumable data was preserved.")
    download_write_manifest(manager, entry_index, resume_phase, "Partial work preserved.")
}


download_remove_local_path :: proc(path, label: string) {
    if len(path) == 0 || !os.exists(path) {
        return
    }
    if remove_err := os.remove(path); remove_err != nil {
        fmt.printf(
            "[DOWNLOAD] WARNING: could not remove %s %s: %v\n",
            label,
            path,
            remove_err,
        )
    } else {
        fmt.printf("[DOWNLOAD] Removed %s %s\n", label, path)
    }
}


download_cleanup_completed_archive_artifacts :: proc(archive_path: string) {
    if len(archive_path) == 0 {
        return
    }
    part_path := fmt.aprintf("%s.part", archive_path)
    defer delete(part_path)
    download_remove_local_path(part_path, "archive partial file")
    download_remove_local_path(archive_path, "completed archive")

    extracted_directory := DownloadArchiveExtractDirectory(archive_path)
    defer delete(extracted_directory)
    if os.exists(extracted_directory) {
        if remove_err := os.remove_all(extracted_directory); remove_err != nil {
            fmt.printf("[DOWNLOAD] WARNING: could not remove extracted directory %s: %v\n", extracted_directory, remove_err)
        } else {
            fmt.printf("[DOWNLOAD] Removed extracted directory %s\n", extracted_directory)
        }
    }
}


download_remove_local_artifacts :: proc(manager: ^DownloadManager, entry_index: int) {
    if manager == nil {
        return
    }

    sync.mutex_lock(&manager.mutex)
    if entry_index < 0 || entry_index >= len(manager.entries) {
        sync.mutex_unlock(&manager.mutex)
        return
    }
    output_path := strings.clone(manager.entries[entry_index].output_path, context.allocator)
    part_path := strings.clone(manager.entries[entry_index].part_path, context.allocator)
    archive_path := strings.clone(manager.entries[entry_index].archive_path, context.allocator)
    info_hash := strings.clone(manager.entries[entry_index].info_hash, context.allocator)
    game_name := ""
    game_index := manager.entries[entry_index].game_index
    if game_index >= 0 && game_index < len(manager.app.games) {
        game_name = strings.clone(manager.app.games[game_index].title, context.allocator)
    }
    download_directory := strings.clone(manager.app.download_path, context.allocator)

    delete(manager.entries[entry_index].output_path)
    delete(manager.entries[entry_index].part_path)
    delete(manager.entries[entry_index].archive_path)
    manager.entries[entry_index].output_path = ""
    manager.entries[entry_index].part_path = ""
    manager.entries[entry_index].archive_path = ""
    sync.mutex_unlock(&manager.mutex)

    defer delete(output_path)
    defer delete(part_path)
    defer delete(archive_path)
    defer delete(info_hash)
    defer delete(game_name)
    defer delete(download_directory)

    download_remove_local_path(output_path, "downloaded file")
    if len(part_path) > 0 && part_path != output_path {
        download_remove_local_path(part_path, "partial file")
    }
    if len(archive_path) > 0 && archive_path != output_path && archive_path != part_path {
        download_remove_local_path(archive_path, "archive file")
    }

    if DownloadPathIsArchive(archive_path) {
        extracted_directory := DownloadArchiveExtractDirectory(archive_path)
        defer delete(extracted_directory)
        if os.exists(extracted_directory) {
            if remove_err := os.remove_all(extracted_directory); remove_err != nil {
                fmt.printf(
                    "[DOWNLOAD] WARNING: could not remove extracted directory %s: %v\n",
                    extracted_directory,
                    remove_err,
                )
            } else {
                fmt.printf(
                    "[DOWNLOAD] Removed extracted directory %s\n",
                    extracted_directory,
                )
            }
        }
    }

    prefix_path := DownloadGamePrefixPath(download_directory, info_hash)
    defer delete(prefix_path)
    install_path := DownloadGameInstallPath(download_directory, game_name, info_hash)
    defer delete(install_path)
    if len(prefix_path) > 0 && os.exists(prefix_path) {
        if remove_err := os.remove_all(prefix_path); remove_err != nil {
            fmt.printf("[DOWNLOAD] WARNING: could not remove Proton prefix %s: %v\n", prefix_path, remove_err)
        } else {
            fmt.printf("[DOWNLOAD] Removed Proton prefix %s\n", prefix_path)
        }
    }

    if len(install_path) > 0 && os.exists(install_path) {
        if remove_err := os.remove_all(install_path); remove_err != nil {
            fmt.printf("[DOWNLOAD] WARNING: could not remove partial game installation %s: %v\n", install_path, remove_err)
        } else {
            fmt.printf("[DOWNLOAD] Removed partial game installation %s\n", install_path)
        }
    }

}


download_cancel_entry :: proc(manager: ^DownloadManager, entry_index: int, client: ^RealDebridClient) {
    paused := download_should_pause(manager, entry_index)
    provider_job_id := download_copy_provider_job_id(manager, entry_index)
    defer delete(provider_job_id)

    if client != nil && len(provider_job_id) > 0 {
        download_delete_remote_torrent(client, provider_job_id)
    }

    if paused {
        download_set_state(manager, entry_index, .Paused)
        download_write_manifest(manager, entry_index, "paused", "Partial download preserved.")
    } else {
        download_remove_local_artifacts(manager, entry_index)
        download_set_state(manager, entry_index, .Cancelled)
        download_set_message(manager, entry_index, "Cancelled; local partial files were removed.")
        download_write_manifest(manager, entry_index, "cancelled", "Download cancelled; local partial files removed.")
    }
}


download_delete_remote_torrent :: proc(client: ^RealDebridClient, torrent_id: string) {
    if client == nil || len(torrent_id) == 0 {
        return
    }

    err := RDDeleteTorrent(client, torrent_id)
    torrent_already_gone := err.http_status == 404 && err.message == "unknown_ressource"
    if err.message != "" && !torrent_already_gone {
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


download_copy_provider_job_id :: proc(manager: ^DownloadManager, entry_index: int) -> string {
    sync.mutex_lock(&manager.mutex)
    defer sync.mutex_unlock(&manager.mutex)

    if entry_index < 0 || entry_index >= len(manager.entries) {
        return ""
    }
    return strings.clone(manager.entries[entry_index].provider_job_id, context.allocator)
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
    parsed_magnet, parse_error := durrent.Parse_Magnet(magnet)
    if parse_error == .None {
        defer durrent.Destroy_Magnet_Link(&parsed_magnet)
        return download_torrent_hash_to_string(parsed_magnet.Info_Hash)
    }

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


download_state_directory :: proc(download_directory: string) -> string {
    if len(download_directory) == 0 {
        return ""
    }
    return fmt.aprintf("%s/.fatboy", download_directory)
}


download_ensure_state_directory :: proc(download_directory: string) -> bool {
    state_directory := download_state_directory(download_directory)
    defer delete(state_directory)
    if len(state_directory) == 0 {
        return false
    }
    if os.exists(state_directory) {
        return os.is_directory(state_directory)
    }
    return os.make_directory_all(state_directory) == nil
}



download_manifest_path :: proc(download_directory, info_hash: string) -> string {
    safe_hash := sanitize_filename(info_hash, context.allocator)
    defer delete(safe_hash)
    filename := fmt.aprintf("%s.state", safe_hash)
    defer delete(filename)
    state_directory := download_state_directory(download_directory)
    defer delete(state_directory)
    path, join_err := filepath.join({state_directory, filename}, context.allocator)
    if join_err != nil {
        return fmt.aprintf("%s/%s", state_directory, filename)
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


restore_persisted_download_state_file :: proc(
    app: ^App,
    name, path: string,
) {
    if app == nil || !os.is_file(path) || !strings.ends_with(name, ".state") {
        return
    }

    data, read_err := os.read_entire_file_from_path(path, context.allocator)
    if read_err != nil {
        return
    }
    text := string(data[:])
    title := download_manifest_value(text, "title")
    magnet := download_manifest_value(text, "magnet")
    provider_name := download_manifest_value(text, "provider")
    info_hash := download_manifest_value(text, "info_hash")
    torrent_path := download_manifest_value(text, "metadata_path")
    if len(torrent_path) == 0 {
        torrent_path = download_manifest_value(text, "torrent_path")
    }
    delete(data)

    provider := download_provider_from_manifest(provider_name, app.download_provider)
    delete(provider_name)
    is_local_identity := provider == .Durrent && len(info_hash) > 0

    // Current manifests require title and either a magnet or the canonical
    // Durrent identity. A resolver may fail before a cache path exists.
    if len(title) == 0 || (!is_local_identity && len(magnet) == 0) {
        delete(title)
        delete(magnet)
        delete(info_hash)
        delete(torrent_path)
        return
    }

    if len(magnet) > 0 {
        magnet = download_normalize_magnet(magnet)
    }
    existing_index := FindCachedGameIndex(app, magnet)
    if existing_index < 0 && is_local_identity {
        for game, game_index in app.games {
            if game.source_info_hash == info_hash {
                existing_index = game_index
                break
            }
        }
    }
    if existing_index >= 0 {
        delete(title)
        delete(magnet)
        delete(info_hash)
        delete(torrent_path)
        return
    }

    safe_title := sanitize_filename(title, context.allocator)
    cover_path := ""
    if len(safe_title) > 0 {
        cover_path = fmt.aprintf("covers/%s.png", safe_title)
    }
    delete(safe_title)

    append(&app.games, GameRelease{
        title = title,
        magnetLink = magnet,
        local_torrent_path = torrent_path,
        source_info_hash = info_hash,
        coverPath = cover_path,
        state_placeholder = true,
    })
    fmt.printf(
        "[STATE] Restored persisted game %q from %s\n",
        title,
        name,
    )
}


RestorePersistedDownloadGames :: proc(app: ^App) {
    if app == nil || len(app.download_path) == 0 {
        return
    }

    state_directory := download_state_directory(app.download_path)
    defer delete(state_directory)
    if len(state_directory) == 0 || !os.is_directory(state_directory) {
        return
    }

    entries, read_err := os.read_all_directory_by_path(
        state_directory,
        context.allocator,
    )
    if read_err != nil {
        return
    }
    defer os.file_info_slice_delete(entries, context.allocator)

    for info in entries {
        restore_persisted_download_state_file(
            app,
            info.name,
            info.fullpath,
        )
    }
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
    game_title := strings.clone(manager.entries[entry_index].game_title, context.allocator)
    magnet_link := strings.clone(manager.entries[entry_index].magnet_link, context.allocator)
    archive_path := strings.clone(manager.entries[entry_index].archive_path, context.allocator)
    output_path := strings.clone(manager.entries[entry_index].output_path, context.allocator)
    part_path := strings.clone(manager.entries[entry_index].part_path, context.allocator)
    provider_job_id := strings.clone(manager.entries[entry_index].provider_job_id, context.allocator)
    resolver_attempt := manager.entries[entry_index].resolver_attempt
    resolver_error := strings.clone(manager.entries[entry_index].resolver_error, context.allocator)
    provider_name := manager.entries[entry_index].provider == .Durrent ? "durrent" : "real-debrid"
    torrent_path := strings.clone(manager.entries[entry_index].local_torrent_path, context.allocator)
    download_directory := strings.clone(manager.app.download_path, context.allocator)
    sync.mutex_unlock(&manager.mutex)

    defer delete(info_hash)
    defer delete(game_title)
    defer delete(magnet_link)
    defer delete(archive_path)
    defer delete(output_path)
    defer delete(part_path)
    defer delete(provider_job_id)
    defer delete(resolver_error)
    defer delete(torrent_path)
    defer delete(download_directory)

    if len(archive_path) == 0 {
        archive_path = strings.clone(output_path, context.allocator)
    }
    if !download_ensure_state_directory(download_directory) {
        fmt.printf("[DOWNLOAD] WARNING: could not create Fatboy state directory %s/.fatboy\n", download_directory)
        return
    }
    manifest_path := download_manifest_path(download_directory, info_hash)
    defer delete(manifest_path)
    temp_path := fmt.aprintf("%s.tmp", manifest_path)
    defer delete(temp_path)
    contents := fmt.aprintf(
        "phase=%s\nprovider=%s\ninfo_hash=%s\ntorrent_path=%s\nmetadata_path=%s\ntorrent_output_path=%s\nresolver_attempt=%d\nresolver_error=%s\ntitle=%s\nmagnet=%s\narchive_path=%s\noutput_path=%s\npart_path=%s\nprovider_job_id=%s\nmessage=%s\n",
        phase,
        provider_name,
        info_hash,
        torrent_path,
        torrent_path,
        download_directory,
        resolver_attempt,
        resolver_error,
        game_title,
        magnet_link,
        archive_path,
        output_path,
        part_path,
        provider_job_id,
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


download_provider_from_manifest :: proc(value: string, fallback: DownloadProvider) -> DownloadProvider {
    if value == "durrent" {
        return .Durrent
    }
    if value == "real-debrid" {
        return .RealDebrid
    }
    return fallback
}


download_read_manifest_for_game :: proc(manager: ^DownloadManager, game_index: int) -> (phase, archive_path, provider_job_id: string, provider: DownloadProvider) {
    provider = .RealDebrid
    if manager == nil || manager.app == nil ||
       game_index < 0 || game_index >= len(manager.app.games) {
        return "", "", "", provider
    }
    provider = manager.app.download_provider

    info_hash := download_game_info_hash(&manager.app.games[game_index])
    defer delete(info_hash)
    path := download_manifest_path(manager.app.download_path, info_hash)
    defer delete(path)
    data, read_err := os.read_entire_file_from_path(path, context.allocator)
    if read_err != nil {
        return "", "", "", provider
    }
    defer delete(data)
    text := string(data[:])
    phase = download_manifest_value(text, "phase")
    archive_path = download_manifest_value(text, "archive_path")
    provider_name := download_manifest_value(text, "provider")
    provider = download_provider_from_manifest(provider_name, provider)
    delete(provider_name)
    provider_job_id = download_manifest_value(text, "provider_job_id")
    if len(provider_job_id) == 0 {
        // Current pre-provider manifests used this generic key for the
        // Real-Debrid job id. Keep those resumable while new manifests use
        // provider_job_id explicitly.
        provider_job_id = download_manifest_value(text, "torrent_id")
    }
    return phase, archive_path, provider_job_id, provider
}


download_manifest_value_from_file :: proc(manager: ^DownloadManager, game_index: int, key: string) -> string {
    if manager == nil || manager.app == nil ||
       game_index < 0 || game_index >= len(manager.app.games) {
        return ""
    }
    info_hash := download_game_info_hash(&manager.app.games[game_index])
    defer delete(info_hash)
    path := download_manifest_path(manager.app.download_path, info_hash)
    defer delete(path)
    data, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
    if read_err != nil {
        return ""
    }
    defer delete(data, context.temp_allocator)
    return download_manifest_value(string(data[:]), key)
}


download_remove_local_directory :: proc(path, label: string) {
    if len(path) == 0 || !os.exists(path) {
        return
    }
    if remove_err := os.remove_all(path); remove_err != nil {
        fmt.printf("[STARTUP] WARNING: could not remove %s %s: %v\n", label, path, remove_err)
    } else {
        fmt.printf("[STARTUP] Fatboy removed %s %s\n", label, path)
    }
}



download_manifest_references_path :: proc(manager: ^DownloadManager, path: string) -> bool {
    if manager == nil || manager.app == nil || len(path) == 0 {
        return false
    }
    keys: [3]string = {"archive_path", "output_path", "part_path"}
    for game_index in 0..<len(manager.app.games) {
        for key in keys {
            value := download_manifest_value_from_file(manager, game_index, key)
            matches := value == path
            delete(value)
            if matches {
                return true
            }
        }
    }
    return false
}


download_cleanup_startup_game :: proc(manager: ^DownloadManager, game_index: int) {
    if manager == nil || manager.app == nil ||
       game_index < 0 || game_index >= len(manager.app.games) {
        return
    }
    phase, archive_path, _, _ := download_read_manifest_for_game(manager, game_index)
    defer delete(phase)
    defer delete(archive_path)
    if len(phase) == 0 {
        return
    }

    info_hash := download_info_hash(manager.app.games[game_index].magnetLink)
    defer delete(info_hash)
    part_path := download_manifest_value_from_file(manager, game_index, "part_path")
    defer delete(part_path)
    archive_exists := len(archive_path) > 0 && os.exists(archive_path)
    part_exists := len(part_path) > 0 && os.exists(part_path)
    marker_valid := download_marker_valid_for_game(manager.app.download_path, info_hash)

    game_path := DownloadGameInstallPath(
        manager.app.download_path,
        manager.app.games[game_index].title,
        info_hash,
    )
    defer delete(game_path)

    no_resume_data := !archive_exists && !part_exists
    cleanup_archive := phase == "completed" || phase == "cancelled" || marker_valid || no_resume_data
    if !cleanup_archive {
        return
    }

    if len(archive_path) > 0 {
        download_cleanup_completed_archive_artifacts(archive_path)
    }
    if len(part_path) > 0 && part_path != archive_path {
        download_remove_local_path(part_path, "orphan partial file")
    }

    if phase == "cancelled" || (no_resume_data && phase != "completed") {
        prefix_path := DownloadGamePrefixPath(manager.app.download_path, info_hash)
        defer delete(prefix_path)
        download_remove_local_directory(prefix_path, "orphan Proton prefix")
        game_path := DownloadGameInstallPath(
            manager.app.download_path,
            manager.app.games[game_index].title,
            info_hash,
        )
        defer delete(game_path)
        download_remove_local_directory(game_path, "orphan game installation")
    }
}


download_cleanup_unresumable_artifacts :: proc(manager: ^DownloadManager) {
    if manager == nil || manager.app == nil || len(manager.app.download_path) == 0 {
        return
    }
    state_directory := download_state_directory(manager.app.download_path)
    defer delete(state_directory)
    if state_entries, state_read_err := os.read_all_directory_by_path(state_directory, context.allocator); state_read_err == nil {
        defer os.file_info_slice_delete(state_entries, context.allocator)
        for info in state_entries {
            if os.is_file(info.fullpath) && strings.ends_with(info.name, ".tmp") {
                download_remove_local_path(info.fullpath, "stale state temporary file")
            }
        }
    }
    for game_index in 0..<len(manager.app.games) {
        download_cleanup_startup_game(manager, game_index)
    }

    entries, read_err := os.read_all_directory_by_path(manager.app.download_path, context.allocator)
    if read_err != nil {
        return
    }
    defer os.file_info_slice_delete(entries, context.allocator)
    for info in entries {
        if os.is_file(info.fullpath) && strings.ends_with(info.name, ".part") &&
           !download_manifest_references_path(manager, info.fullpath) {
            download_remove_local_path(info.fullpath, "unresumable partial file")
        } else if os.is_directory(info.fullpath) && strings.ends_with(info.name, "_extracted") {
            archive_candidate := info.fullpath[:len(info.fullpath)-len("_extracted")]
            referenced := download_manifest_references_path(manager, archive_candidate)
            archive_exists := os.exists(archive_candidate)
            delete(archive_candidate)
            if !referenced && !archive_exists {
                download_remove_local_directory(info.fullpath, "unresumable extraction directory")
            }
        }
    }
}



download_marker_path :: proc(download_directory, info_hash: string) -> string {
    safe_hash := sanitize_filename(info_hash, context.allocator)
    defer delete(safe_hash)
    filename := fmt.aprintf("%s.complete", safe_hash)
    defer delete(filename)
    state_directory := download_state_directory(download_directory)
    defer delete(state_directory)
    path, join_err := filepath.join({state_directory, filename}, context.allocator)
    if join_err != nil {
        return fmt.aprintf("%s/%s", state_directory, filename)
    }
    return path
}


download_marker_valid_for_game :: proc(download_directory, info_hash: string) -> bool {
    marker_path := download_marker_path(download_directory, info_hash)
    defer delete(marker_path)
    return download_marker_valid(marker_path)
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

    target := string(marker_data[:])
    if os.is_file(target) {
        return true
    }
    if !os.is_directory(target) {
        return false
    }

    // An installed game must contain something. This prevents an empty
    // directory left behind by an interrupted installer from being treated
    // as a valid completion marker during startup or UI refresh.
    entries, directory_err := os.read_all_directory_by_path(target, context.allocator)
    if directory_err != nil {
        return false
    }
    defer os.file_info_slice_delete(entries, context.allocator)
    return len(entries) > 0
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
