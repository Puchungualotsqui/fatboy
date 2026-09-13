package main

import "core:crypto/sha2"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:time"


GE_PROTON_VERSION          :: "GE-Proton8-25"
GE_PROTON_ARCHIVE_URL      :: "https://github.com/GloriousEggroll/proton-ge-custom/releases/download/GE-Proton8-25/GE-Proton8-25.tar.gz"
GE_PROTON_CHECKSUM_URL     :: "https://github.com/GloriousEggroll/proton-ge-custom/releases/download/GE-Proton8-25/GE-Proton8-25.sha512sum"
GE_PROTON_ARCHIVE_NAME     :: "GE-Proton8-25.tar.gz"
GE_PROTON_ARCHIVE_SIZE     :: i64(428716716)
GE_PROTON_SHA512           :: "287b10bad211e471772017da801089dae2a83a1da50a584b75e3c1c25339768e5a9f25c4cd0cf7db07aa6c5887abe3e8928cae835a5b21c58c95e5fd0dd3f65e"


ProtonRuntimePaths :: struct {
    root:       string,
    archive:    string,
    part:       string,
    proton:     string,
}


DestroyProtonRuntimePaths :: proc(paths: ^ProtonRuntimePaths) {
    if paths == nil {
        return
    }
    delete(paths.root)
    delete(paths.archive)
    delete(paths.part)
    delete(paths.proton)
    paths^ = {}
}


// RuntimeInstallationPath is kept separate from environment discovery so the
// storage policy can be tested without touching a user's filesystem.
RuntimeInstallationPath :: proc(runtime_base_directory: string) -> string {
    if len(runtime_base_directory) == 0 {
        return ""
    }
    return fmt.aprintf("%s/%s", runtime_base_directory, GE_PROTON_VERSION)
}


ProtonRuntimePathsForBase :: proc(runtime_base_directory: string) -> ProtonRuntimePaths {
    if len(runtime_base_directory) == 0 {
        return ProtonRuntimePaths{}
    }
    root := RuntimeInstallationPath(runtime_base_directory)
    archive := fmt.aprintf("%s/%s", runtime_base_directory, GE_PROTON_ARCHIVE_NAME)
    part := fmt.aprintf("%s.part", archive)
    proton := fmt.aprintf("%s/proton", root)
    return ProtonRuntimePaths{
        root = root,
        archive = archive,
        part = part,
        proton = proton,
    }
}


GEProtonChecksumMatches :: proc(actual, expected: string) -> bool {
    actual_lower := strings.to_lower(actual, context.temp_allocator)
    expected_lower := strings.to_lower(expected, context.temp_allocator)
    return actual_lower == expected_lower
}


proton_runtime_base_directory :: proc() -> string {
    when ODIN_OS == .Linux {
        data_directory, data_err := os.user_data_dir(context.allocator)
        if data_err != nil || len(data_directory) == 0 {
            delete(data_directory)
            return ""
        }
        defer delete(data_directory)
        return fmt.aprintf("%s/fitdeck/runtimes", data_directory)
    } else {
        return ""
    }
}


proton_runtime_paths :: proc() -> ProtonRuntimePaths {
    base_directory := proton_runtime_base_directory()
    defer delete(base_directory)
    return ProtonRuntimePathsForBase(base_directory)
}


// Cleanup is deliberately limited to the pinned runtime asset. It is called
// after a checksum or extraction failure so a later attempt cannot mistake a
// corrupt archive for an installed runtime.
CleanupGEProtonRuntimeDownload :: proc() {
    when ODIN_OS == .Linux {
        paths := proton_runtime_paths()
        defer DestroyProtonRuntimePaths(&paths)
        if len(paths.archive) > 0 {
            _ = os.remove(paths.archive)
        }
        if len(paths.part) > 0 {
            _ = os.remove(paths.part)
        }
    }
}


runtime_sha512_file :: proc(path: string) -> (digest: string, ok: bool, error_message: string) {
    file, open_err := os.open(path, os.O_RDONLY)
    if open_err != nil {
        return "", false, fmt.aprintf("Could not open GE-Proton runtime for checksum verification: %v", open_err)
    }
    defer os.close(file)

    hash_context: sha2.Context_512
    sha2.init_512(&hash_context)
    buffer, buffer_err := make([]byte, 1024 * 1024, context.allocator)
    if buffer_err != nil {
        return "", false, fmt.aprintf("Could not allocate checksum verification buffer.")
    }
    defer delete(buffer)
    for {
        count, read_err := os.read(file, buffer[:])
        if count > 0 {
            sha2.update(&hash_context, buffer[:count])
        }
        if read_err != nil {
            if read_err == .EOF {
                break
            }
            return "", false, fmt.aprintf("Could not read GE-Proton runtime for checksum verification: %v", read_err)
        }
        if count == 0 {
            break
        }
    }

    bytes: [sha2.DIGEST_SIZE_512]byte
    sha2.final(&hash_context, bytes[:])
    builder: strings.Builder
    strings.builder_init(&builder, context.allocator)
    hex := "0123456789abcdef"
    for value in bytes {
        strings.write_byte(&builder, hex[value >> 4])
        strings.write_byte(&builder, hex[value & 0x0f])
    }
    digest = strings.to_string(builder)
    return digest, true, ""
}


verify_ge_proton_archive :: proc(path: string) -> (bool, string) {
    file, open_err := os.open(path, os.O_RDONLY)
    if open_err != nil {
        return false, fmt.aprintf("Could not inspect GE-Proton runtime archive: %v", open_err)
    }
    size, size_err := os.file_size(file)
    os.close(file)
    if size_err != nil {
        return false, fmt.aprintf("Could not determine GE-Proton runtime archive size: %v", size_err)
    }
    if size != GE_PROTON_ARCHIVE_SIZE {
        return false, fmt.aprintf(
            "GE-Proton runtime size mismatch: got %d bytes, expected %d.",
            size,
            GE_PROTON_ARCHIVE_SIZE,
        )
    }

    actual, hashed, hash_error := runtime_sha512_file(path)
    if !hashed {
        return false, hash_error
    }
    defer delete(actual)
    if !GEProtonChecksumMatches(actual, GE_PROTON_SHA512) {
        return false, fmt.aprintf(
            "GE-Proton runtime SHA-512 mismatch. Expected %s, got %s.",
            GE_PROTON_SHA512,
            actual,
        )
    }
    return true, ""
}


runtime_file_is_executable :: proc(path: string) -> bool {
    when ODIN_OS == .Linux {
        if !os.is_file(path) {
            return false
        }
        chmod_err := os.chmod(path, os.Permissions_Read_All + os.Permissions_Execute_All)
        if chmod_err != nil {
            fmt.printf("[PROTON] WARNING: could not make runtime file executable %s: %v\n", path, chmod_err)
            return false
        }
    }
    return true
}


prepare_ge_proton_permissions :: proc(root: string) -> bool {
    when ODIN_OS == .Linux {
        // orar intentionally creates regular files with safe default modes.
        // GE-Proton contains native launchers as well as the proton script, so
        // restore executable permission on the known runtime launch points.
        known_files := []string{
            "proton",
            "files/bin/wine",
            "files/bin/wine64",
            "files/bin/wineserver",
            "files/bin/wine-preloader",
            "files/bin/wine64-preloader",
            "dist/bin/wine",
            "dist/bin/wine64",
            "dist/bin/wineserver",
            "dist/bin/wine-preloader",
            "dist/bin/wine64-preloader",
        }
        for relative in known_files {
            path, join_err := filepath.join({root, relative}, context.allocator)
            if join_err != nil {
                return false
            }
            defer delete(path)
            if os.exists(path) && !runtime_file_is_executable(path) {
                return false
            }
        }
    }
    return true
}


EnsureGEProtonRuntime :: proc(manager: ^DownloadManager, entry_index: int) -> (ready: bool, message: string) {
    when ODIN_OS != .Linux {
        return true, ""
    } else {
        paths := proton_runtime_paths()
        defer DestroyProtonRuntimePaths(&paths)

        if len(paths.proton) > 0 && os.is_file(paths.proton) {
            if !runtime_file_is_executable(paths.proton) {
                return false, strings.clone("The installed GE-Proton runtime is not executable.", context.allocator)
            }
            return true, strings.clone("GE-Proton8-25 is already installed.", context.allocator)
        }

        if len(paths.root) == 0 || len(paths.archive) == 0 {
            return false, strings.clone("Could not determine the Linux runtime installation directory.", context.allocator)
        }
        parent_directory := fmt.aprintf("%s/..", paths.root)
        defer delete(parent_directory)
        if mkdir_err := os.make_directory_all(parent_directory); mkdir_err != nil {
            return false, fmt.aprintf("Could not create the GE-Proton runtime directory: %v", mkdir_err)
        }

        if os.exists(paths.archive) {
            archive_file, archive_open_err := os.open(paths.archive, os.O_RDONLY)
            if archive_open_err != nil {
                return false, fmt.aprintf("Could not inspect the downloaded GE-Proton runtime: %v", archive_open_err)
            }
            archive_size, archive_size_err := os.file_size(archive_file)
            os.close(archive_file)
            if archive_size_err != nil || archive_size != GE_PROTON_ARCHIVE_SIZE {
                fmt.printf("[PROTON] Removing incomplete runtime archive %s\n", paths.archive)
                _ = os.remove(paths.archive)
            }
        }

        if !os.exists(paths.archive) {
            download_set_state(manager, entry_index, .Downloading)
            download_set_message(manager, entry_index, "Downloading GE-Proton8-25 runtime...")
            fmt.printf(
                "[PROTON] Downloading %s (%d bytes) from %s\n",
                GE_PROTON_VERSION,
                GE_PROTON_ARCHIVE_SIZE,
                GE_PROTON_ARCHIVE_URL,
            )
            completed, cancelled, transfer_error := download_file(
                manager,
                entry_index,
                GE_PROTON_ARCHIVE_URL,
                paths.part,
                GE_PROTON_ARCHIVE_NAME,
                GE_PROTON_ARCHIVE_SIZE,
            )
            if cancelled {
                if download_should_cancel(manager, entry_index) && !download_should_pause(manager, entry_index) {
                    _ = os.remove(paths.part)
                }
                delete(transfer_error)
                return false, strings.clone("GE-Proton runtime download interrupted.", context.allocator)
            }
            if !completed {
                // Ordinary transfer failures must not leave a corrupt runtime
                // partial to be resumed as if it were valid.
                _ = os.remove(paths.part)
                if len(transfer_error) == 0 {
                    return false, ""
                }
                message := strings.clone(transfer_error, context.allocator)
                delete(transfer_error)
                return false, message
            }
            if rename_err := os.rename(paths.part, paths.archive); rename_err != nil {
                _ = os.remove(paths.part)
                return false, fmt.aprintf("Could not finalize the GE-Proton runtime download: %v", rename_err)
            }
        }

        download_set_message(manager, entry_index, "Verifying GE-Proton8-25 runtime...")
        verified, verify_error := verify_ge_proton_archive(paths.archive)
        if !verified {
            fmt.printf("[PROTON] Runtime verification failed: %s\n", verify_error)
            _ = os.remove(paths.archive)
            _ = os.remove(paths.part)
            return false, verify_error
        }
        fmt.printf("[PROTON] Runtime checksum verified using pinned SHA-512 (checksum source: %s)\n", GE_PROTON_CHECKSUM_URL)

        staging_directory := fmt.aprintf("%s.installing", paths.root)
        defer delete(staging_directory)
        if os.exists(staging_directory) {
            _ = os.remove_all(staging_directory)
        }
        if mkdir_err := os.make_directory_all(staging_directory); mkdir_err != nil {
            _ = os.remove(paths.archive)
            return false, fmt.aprintf("Could not create the GE-Proton extraction directory: %v", mkdir_err)
        }

        download_set_state(manager, entry_index, .Extracting)
        download_set_message(manager, entry_index, "Extracting GE-Proton8-25 runtime...")
        extracted, extraction_message := ExtractArchiveToDirectory(
            manager,
            entry_index,
            paths.archive,
            staging_directory,
        )
        delete(extraction_message)
        if !extracted {
            fmt.printf("[PROTON] Runtime extraction failed\n")
            _ = os.remove_all(staging_directory)
            _ = os.remove(paths.archive)
            _ = os.remove(paths.part)
            return false, strings.clone("Could not extract the GE-Proton8-25 runtime. The runtime download was removed; try again.", context.allocator)
        }

        source_root := staging_directory
        nested_root := fmt.aprintf("%s/%s", staging_directory, GE_PROTON_VERSION)
        defer delete(nested_root)
        if os.is_directory(nested_root) {
            source_root = nested_root
        }
        source_proton := fmt.aprintf("%s/proton", source_root)
        defer delete(source_proton)
        if !os.is_file(source_proton) {
            _ = os.remove_all(staging_directory)
            _ = os.remove(paths.archive)
            _ = os.remove(paths.part)
            return false, strings.clone("The GE-Proton archive did not contain its proton launcher. The runtime download was removed.", context.allocator)
        }

        if os.exists(paths.root) {
            _ = os.remove_all(paths.root)
        }
        if rename_err := os.rename(source_root, paths.root); rename_err != nil {
            _ = os.remove_all(staging_directory)
            _ = os.remove(paths.archive)
            _ = os.remove(paths.part)
            return false, fmt.aprintf("Could not install the extracted GE-Proton runtime: %v", rename_err)
        }
        _ = os.remove_all(staging_directory)

        if !prepare_ge_proton_permissions(paths.root) || !os.is_file(paths.proton) {
            _ = os.remove_all(paths.root)
            _ = os.remove(paths.archive)
            _ = os.remove(paths.part)
            return false, strings.clone("The installed GE-Proton runtime is missing executable launch files.", context.allocator)
        }
        fmt.printf("[PROTON] Installed GE-Proton8-25 at %s\n", paths.root)
        return true, strings.clone("GE-Proton8-25 is ready.", context.allocator)
    }
}


DownloadGamePrefixPath :: proc(download_directory, info_hash: string) -> string {
    if len(download_directory) == 0 || len(info_hash) == 0 {
        return ""
    }
    safe_hash := sanitize_filename(info_hash, context.temp_allocator)
    if len(safe_hash) == 0 {
        return ""
    }
    return fmt.aprintf("%s/.fitdeck/prefixes/%s", download_directory, safe_hash)
}


DownloadGameInstallPath :: proc(download_directory, info_hash: string) -> string {
    if len(download_directory) == 0 || len(info_hash) == 0 {
        return ""
    }
    safe_hash := sanitize_filename(info_hash, context.temp_allocator)
    if len(safe_hash) == 0 {
        return ""
    }
    return fmt.aprintf("%s/.fitdeck/games/%s", download_directory, safe_hash)
}


ensure_game_proton_prefix :: proc(download_directory, info_hash: string) -> (string, string) {
    prefix := DownloadGamePrefixPath(download_directory, info_hash)
    if len(prefix) == 0 {
        return "", strings.clone("Could not determine the per-game Proton prefix path.", context.allocator)
    }
    if os.exists(prefix) {
        if !os.is_directory(prefix) {
            prefix_error := fmt.aprintf(
                "Could not create the per-game Proton prefix: path already exists but is not a directory: %s",
                prefix,
            )
            delete(prefix)
            return "", prefix_error
        }
    } else if mkdir_err := os.make_directory_all(prefix); mkdir_err != nil {
        delete(prefix)
        return "", fmt.aprintf("Could not create the per-game Proton prefix: %v", mkdir_err)
    }
    fmt.printf("[PROTON] Using per-game prefix %s\n", prefix)
    return prefix, ""
}


DetectSteamInstallation :: proc() -> string {
    when ODIN_OS == .Linux {
        home, home_err := os.user_home_dir(context.allocator)
        if home_err != nil || len(home) == 0 {
            delete(home)
            return ""
        }
        defer delete(home)

        candidates: [dynamic]string
        xdg_data_home := ""
        inherited, env_err := os.environ(context.allocator)
        if env_err == nil {
            for value in inherited {
                separator := strings.index(value, "=")
                key := separator >= 0 ? value[:separator] : value
                if separator >= 0 {
                    setting := value[separator+1:]
                    if key == "STEAM_COMPAT_CLIENT_INSTALL_PATH" ||
                       key == "STEAM_ROOT" ||
                       key == "STEAM_PATH" ||
                       key == "STEAM_INSTALL_PATH" {
                        if len(setting) > 0 {
                            append(&candidates, strings.clone(setting, context.allocator))
                        }
                    } else if key == "XDG_DATA_HOME" && len(setting) > 0 {
                        xdg_data_home = strings.clone(setting, context.allocator)
                    }
                }
                delete(value)
            }
            delete(inherited)
        }
        defer delete(xdg_data_home)

        append(&candidates, fmt.aprintf("%s/.steam/root", home))
        append(&candidates, fmt.aprintf("%s/.steam/steam", home))
        append(&candidates, fmt.aprintf("%s/.local/share/Steam", home))
        if len(xdg_data_home) > 0 {
            append(&candidates, fmt.aprintf("%s/Steam", xdg_data_home))
            append(&candidates, fmt.aprintf("%s/steam", xdg_data_home))
        }

        // Flatpak and Snap keep their Steam data under different per-user
        // roots. Check both the conventional Steam symlink and its targets.
        append(&candidates, fmt.aprintf("%s/.var/app/com.valvesoftware.Steam/.steam/steam", home))
        append(&candidates, fmt.aprintf("%s/.var/app/com.valvesoftware.Steam/data/Steam", home))
        append(&candidates, fmt.aprintf("%s/.var/app/com.valvesoftware.Steam/.local/share/Steam", home))
        append(&candidates, fmt.aprintf("%s/snap/steam/common/.steam/root", home))
        append(&candidates, fmt.aprintf("%s/snap/steam/common/.steam/steam", home))
        append(&candidates, fmt.aprintf("%s/snap/steam/common/.local/share/Steam", home))

        for candidate in candidates {
            if os.is_directory(candidate) {
                result := strings.clone(candidate, context.allocator)
                for other in candidates {
                    delete(other)
                }
                delete(candidates)
                return result
            }
        }
        for candidate in candidates {
            delete(candidate)
        }
        delete(candidates)
    }
    return ""
}


proton_process_environment :: proc(steam_root, prefix: string) -> ([]string, string) {
    inherited, env_err := os.environ(context.allocator)
    if env_err != nil {
        return nil, fmt.aprintf("Could not read the current process environment: %v", env_err)
    }

    environment: [dynamic]string
    for value in inherited {
        separator := strings.index(value, "=")
        key := separator >= 0 ? value[:separator] : value
        is_compat_override := key == "STEAM_COMPAT_CLIENT_INSTALL_PATH" ||
                              key == "STEAM_COMPAT_DATA_PATH"
        owned_value := strings.clone(value, context.allocator)
        delete(value)
        if is_compat_override {
            delete(owned_value)
            continue
        }
        append(&environment, owned_value)
    }
    delete(inherited)

    append(&environment, fmt.aprintf("STEAM_COMPAT_CLIENT_INSTALL_PATH=%s", steam_root))
    append(&environment, fmt.aprintf("STEAM_COMPAT_DATA_PATH=%s", prefix))
    return environment[:], ""
}


DestroyProtonProcessEnvironment :: proc(environment: []string) {
    for value in environment {
        delete(value)
    }
    delete(environment)
}


terminate_proton_process_tree :: proc(process: os.Process) {
    when ODIN_OS == .Linux {
        // The Linux launcher is started through setsid above. Signal its
        // process group, not just the Proton parent, so Wine children cannot
        // survive a cancelled installer.
        group_id := fmt.aprintf("-%d", process.pid)
        defer delete(group_id)
        term, term_err := os.process_start(os.Process_Desc{
            command = []string{"kill", "-TERM", "--", group_id},
        })
        if term_err == nil {
            _, _ = os.process_wait(term)
        }
        _ = os.process_terminate(process)
        kill, kill_err := os.process_start(os.Process_Desc{
            command = []string{"kill", "-KILL", "--", group_id},
        })
        if kill_err == nil {
            _, _ = os.process_wait(kill)
        }
    } else {
        // Keep the existing native behavior for Windows and other targets.
        _ = os.process_terminate(process)
    }
    _, _ = os.process_wait(process)
}


proton_windows_path :: proc(path: string) -> string {
    builder: strings.Builder
    strings.builder_init(&builder, context.allocator)
    strings.write_string(&builder, "Z:")
    for value in path {
        if value == '/' {
            strings.write_byte(&builder, '\\')
        } else {
            strings.write_rune(&builder, value)
        }
    }
    return strings.to_string(builder)
}


LaunchGEProtonInstaller :: proc(
    manager: ^DownloadManager,
    entry_index: int,
    archive_path: string,
) -> (DownloadInstallerResult, string) {
    when ODIN_OS != .Linux {
        return .InstallerFailed, strings.clone("GE-Proton is only used for Linux installs.", context.allocator)
    } else {
        extracted_directory := DownloadArchiveExtractDirectory(archive_path)
        defer delete(extracted_directory)
        installer_path, join_err := filepath.join(
            {extracted_directory, "setup.exe"},
            context.allocator,
        )
        if join_err != nil || !os.is_file(installer_path) {
            delete(installer_path)
            return .InstallerNotFound, fmt.aprintf(
                "Archive extracted to %s, but setup.exe was not found. The archive is extracted but not installed.",
                extracted_directory,
            )
        }
        defer delete(installer_path)

        runtime_paths := proton_runtime_paths()
        defer DestroyProtonRuntimePaths(&runtime_paths)
        if !os.is_file(runtime_paths.proton) {
            return .InstallerFailed, strings.clone("GE-Proton8-25 is not installed; install the runtime before running the game installer.", context.allocator)
        }

        steam_root := DetectSteamInstallation()
        if len(steam_root) == 0 {
            return .InstallerFailed, strings.clone("Could not find a Steam installation. Install Steam or start it once before installing through GE-Proton.", context.allocator)
        }
        defer delete(steam_root)

        sync.mutex_lock(&manager.mutex)
        info_hash := ""
        download_directory := ""
        use_ram_limit := false
        if entry_index >= 0 && entry_index < len(manager.entries) {
            info_hash = strings.clone(manager.entries[entry_index].info_hash, context.allocator)
            download_directory = strings.clone(manager.app.download_path, context.allocator)
            use_ram_limit = manager.app.use_ram_limit
        }
        sync.mutex_unlock(&manager.mutex)
        defer delete(info_hash)
        defer delete(download_directory)

        prefix, prefix_error := ensure_game_proton_prefix(download_directory, info_hash)
        if len(prefix_error) > 0 {
            return .InstallerFailed, prefix_error
        }
        defer delete(prefix)

        install_directory := DownloadGameInstallPath(download_directory, info_hash)
        if len(install_directory) == 0 || !EnsureDownloadDirectory(install_directory) {
            delete(install_directory)
            return .InstallerFailed, strings.clone("Could not create the per-game installation directory.", context.allocator)
        }
        defer delete(install_directory)
        install_log_path := fmt.aprintf("%s/fitdeck-install.log", install_directory)
        defer delete(install_log_path)

        environment, environment_error := proton_process_environment(steam_root, prefix)
        if len(environment_error) > 0 {
            return .InstallerFailed, environment_error
        }
        defer DestroyProtonProcessEnvironment(environment)

        installer_dir_arg := proton_windows_path(install_directory)
        defer delete(installer_dir_arg)
        installer_log_arg := proton_windows_path(install_log_path)
        defer delete(installer_log_arg)
        // These are already individual argv elements, not shell text. Do not
        // embed quote characters: Wine/Proton performs the necessary command
        // line quoting when it forwards the argv vector to the Windows process.
        dir_argument := fmt.aprintf("/DIR=%s", installer_dir_arg)
        defer delete(dir_argument)
        log_argument := fmt.aprintf("/LOG=%s", installer_log_arg)
        defer delete(log_argument)

        command: [dynamic]string
        when ODIN_OS == .Linux {
            // setsid makes the Proton launcher the leader of a private process
            // group, so cancellation can terminate Wine/installer descendants.
            append(&command, "setsid")
        }
        append(&command, runtime_paths.proton)
        append(&command, "run")
        append(&command, installer_path)
        append(&command, "/VERYSILENT")
        append(&command, "/SILENT")
        append(&command, "/SUPPRESSMSGBOXES")
        if use_ram_limit {
            append(&command, "/RAM=2")
        }
        append(&command, "/NOCANCEL")
        append(&command, "/NORESTART")
        append(&command, "/NOICONS")
        append(&command, dir_argument)
        append(&command, log_argument)
        defer delete(command)
        fmt.printf(
            "[PROTON] Starting unattended installer through GE-Proton8-25: %s/proton run %s /VERYSILENT /SILENT /SUPPRESSMSGBOXES /NORESTART /NOICONS%s\n",
            runtime_paths.root,
            installer_path,
            use_ram_limit ? " /RAM=2" : "",
        )
        fmt.printf(
            "[PROTON] Child environment paths: Steam root=%s, per-game prefix=%s\n",
            steam_root,
            prefix,
        )
        process, start_err := os.process_start(os.Process_Desc{
            working_dir = extracted_directory,
            command = command[:],
            env = environment,
        })
        if start_err != nil {
            return .InstallerFailed, fmt.aprintf("Could not start the GE-Proton-wrapped installer: %v", start_err)
        }
        fmt.println("[PROTON] GE-Proton installer process started")

        for {
            process_state, wait_err := os.process_wait(process, 250 * time.Millisecond)
            if wait_err == .Timeout {
                if download_should_cancel(manager, entry_index) {
                    terminate_proton_process_tree(process)
                    return .InstallerCancelled, strings.clone("Installer cancelled; the Proton process tree was terminated.", context.allocator)
                }
                if download_should_pause(manager, entry_index) {
                    terminate_proton_process_tree(process)
                    return .InstallerPaused, strings.clone("Installer paused; the Proton process tree was terminated.", context.allocator)
                }
                continue
            }
            if wait_err != nil {
                return .InstallerFailed, fmt.aprintf("Could not wait for the GE-Proton installer: %v", wait_err)
            }
            if !process_state.success {
                return .InstallerFailed, fmt.aprintf(
                    "The GE-Proton installer exited with code %d. See the installer log at %s.",
                    process_state.exit_code,
                    install_log_path,
                )
            }
            break
        }
        return .InstallerStarted, strings.clone("GE-Proton installer completed.", context.allocator)
    }
}
