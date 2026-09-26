package main


import "core:fmt"
import "core:os"

import "core:strings"
import "core:sync"
import "core:time"


WINE_RUNTIME_VERSION :: "wine-11.18-pipe"
WINE_RUNTIME_DIRECTORY :: "runtimes/wine-11.18-pipe"


WineRuntimePaths :: struct {
    root:       string,
    wine:       string,
    wineboot:   string,
    wineserver: string,
}


DestroyWineRuntimePaths :: proc(paths: ^WineRuntimePaths) {
    if paths == nil {
        return
    }
    delete(paths.root)
    delete(paths.wine)
    delete(paths.wineboot)
    delete(paths.wineserver)
    paths^ = {}
}


// RuntimeInstallationPath is kept separate from environment discovery so the
// storage policy can be tested without touching a user's filesystem.
RuntimeInstallationPath :: proc(runtime_base_directory: string) -> string {
    if len(runtime_base_directory) == 0 {
        return ""
    }
    return fmt.aprintf("%s/%s", runtime_base_directory, WINE_RUNTIME_VERSION)
}


WineRuntimePathsForBase :: proc(runtime_base_directory: string) -> WineRuntimePaths {
    if len(runtime_base_directory) == 0 {
        return WineRuntimePaths{}
    }
    root := RuntimeInstallationPath(runtime_base_directory)
    wine := fmt.aprintf("%s/bin/wine", root)
    wineboot := fmt.aprintf("%s/bin/wineboot", root)
    wineserver := fmt.aprintf("%s/bin/wineserver", root)
    return WineRuntimePaths{
        root = root,
        wine = wine,
        wineboot = wineboot,
        wineserver = wineserver,
    }
}


fatboy_installation_directory :: proc() -> string {
    executable, executable_error := os.get_executable_path(context.allocator)
    if executable_error != nil || len(executable) == 0 {
        delete(executable)
        return ""
    }
    separator := strings.last_index(executable, "/")
    backslash := strings.last_index(executable, "\\")
    if backslash > separator {
        separator = backslash
    }
    if separator < 0 {
        delete(executable)
        return ""
    }
    result := strings.clone(executable[:separator], context.allocator)
    delete(executable)
    return result
}


wine_runtime_paths :: proc() -> WineRuntimePaths {
    installation_directory := fatboy_installation_directory()
    defer delete(installation_directory)
    if len(installation_directory) == 0 {
        return WineRuntimePaths{}
    }
    root := fmt.aprintf("%s/%s", installation_directory, WINE_RUNTIME_DIRECTORY)
    wine := fmt.aprintf("%s/bin/wine", root)
    wineboot := fmt.aprintf("%s/bin/wineboot", root)
    wineserver := fmt.aprintf("%s/bin/wineserver", root)
    return WineRuntimePaths{root = root, wine = wine, wineboot = wineboot, wineserver = wineserver}
}



runtime_file_is_executable :: proc(path: string) -> bool {
    when ODIN_OS == .Linux {
        if !os.is_file(path) {
            return false
        }
        chmod_err := os.chmod(path, os.Permissions_Read_All + os.Permissions_Execute_All)
        if chmod_err != nil {
            fmt.printf("[WINE] WARNING: could not make runtime file executable %s: %v\n", path, chmod_err)
            return false
        }
    }
    return true
}



EnsureWineRuntime :: proc(manager: ^DownloadManager, entry_index: int) -> (ready: bool, message: string) {
    when ODIN_OS != .Linux {
        return true, ""
    } else {
        paths := wine_runtime_paths()
        defer DestroyWineRuntimePaths(&paths)
        if len(paths.wine) == 0 || len(paths.wineboot) == 0 || len(paths.wineserver) == 0 {
            return false, strings.clone("Could not locate the Fatboy installation directory.", context.allocator)
        }
        if !os.is_file(paths.wine) || !os.is_file(paths.wineboot) || !os.is_file(paths.wineserver) {
            return false, fmt.aprintf(
                "The bundled Wine runtime is missing or incomplete: %s",
                paths.root,
            )
        }
        if !runtime_file_is_executable(paths.wine) ||
           !runtime_file_is_executable(paths.wineboot) ||
           !runtime_file_is_executable(paths.wineserver) {
            return false, fmt.aprintf("The bundled Wine runtime is not executable: %s", paths.root)
        }
        _ = manager
        _ = entry_index
        return true, fmt.aprintf("Bundled Wine %s is ready.", WINE_RUNTIME_VERSION)
    }
}


DownloadGamePrefixPath :: proc(download_directory, info_hash: string) -> string {
    _ = info_hash
    if len(download_directory) == 0 {
        return ""
    }
    return fmt.aprintf("%s/.fatboy/wine-prefix", download_directory)
}


DownloadGameInstallPath :: proc(download_directory, game_name, fallback_id: string) -> string {
    if len(download_directory) == 0 {
        return ""
    }
    folder_name := sanitize_filename(game_name, context.temp_allocator)
    if len(folder_name) == 0 {
        folder_name = sanitize_filename(fallback_id, context.temp_allocator)
    }
    if len(folder_name) == 0 {
        return ""
    }
    return fmt.aprintf("%s/%s", download_directory, folder_name)
}



ensure_shared_wine_prefix :: proc(download_directory: string) -> (string, string) {
    prefix := DownloadGamePrefixPath(download_directory, "")
    if len(prefix) == 0 {
        return "", strings.clone("Could not determine the shared Wine prefix path.", context.allocator)
    }
    if os.exists(prefix) {
        if !os.is_directory(prefix) {
            prefix_error := fmt.aprintf(
                "The shared Wine prefix path is not a directory: %s",
                prefix,
            )
            delete(prefix)
            return "", prefix_error
        }
    } else if mkdir_err := os.make_directory_all(prefix); mkdir_err != nil {
        delete(prefix)
        return "", fmt.aprintf("Could not create the shared Wine prefix: %v", mkdir_err)
    }
    fmt.printf("[WINE] Using shared prefix %s\n", prefix)
    return prefix, ""
}



wine_process_environment :: proc(runtime_root, prefix, temporary_directory: string) -> ([]string, string) {
    inherited, env_err := os.environ(context.allocator)
    if env_err != nil {
        return nil, fmt.aprintf("Could not read the current process environment: %v", env_err)
    }

    environment: [dynamic]string
    inherited_path := ""
    for value in inherited {
        separator := strings.index(value, "=")
        key := separator >= 0 ? value[:separator] : value
        if key == "PATH" && separator >= 0 {
            inherited_path = strings.clone(value[separator+1:], context.allocator)
        }
        overridden := key == "PATH" || key == "WINEPREFIX" || key == "WINEARCH" ||
                     key == "WINELOADER" || key == "WINESERVER" || key == "WINEPATCH" || key == "TMPDIR"
        if !overridden {
            append(&environment, strings.clone(value, context.allocator))
        }
        delete(value)
    }
    delete(inherited)

    runtime_bin := fmt.aprintf("%s/bin", runtime_root)
    append(&environment, fmt.aprintf("PATH=%s%s%s", runtime_bin, len(inherited_path) > 0 ? ":" : "", inherited_path))
    append(&environment, fmt.aprintf("WINEPATCH=%s", runtime_root))
    append(&environment, fmt.aprintf("WINEPREFIX=%s", prefix))
    append(&environment, fmt.aprintf("TMPDIR=%s", temporary_directory))
    delete(runtime_bin)
    delete(inherited_path)
    return environment[:], ""
}


DestroyWineProcessEnvironment :: proc(environment: []string) {
    for value in environment {
        delete(value)
    }
    delete(environment)
}


initialize_shared_wine_prefix :: proc(runtime_paths: WineRuntimePaths, prefix, working_directory: string, environment: []string) -> (bool, string) {
    command: [dynamic]string
    when ODIN_OS == .Linux {
        append(&command, "setsid")
        append(&command, "--wait")
    }
    append(&command, runtime_paths.wineboot)
    append(&command, "-u")
    defer delete(command)

    process, start_error := os.process_start(os.Process_Desc{
        working_dir = working_directory,
        command = command[:],
        env = environment,
    })
    if start_error != nil {
        return false, fmt.aprintf("Could not initialize the shared Wine prefix: %v", start_error)
    }
    process_state, wait_error := os.process_wait(process)
    if wait_error != nil {
        return false, fmt.aprintf("Could not wait for Wine prefix initialization: %v", wait_error)
    }
    if !process_state.success {
        return false, fmt.aprintf("Wine prefix initialization exited with code %d.", process_state.exit_code)
    }
    _ = prefix
    return true, ""
}


terminate_wine_process_tree :: proc(process: os.Process) {
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


wine_windows_path :: proc(path: string) -> string {
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


LaunchWineInstaller :: proc(
    manager: ^DownloadManager,
    entry_index: int,
    archive_path: string,
) -> (DownloadInstallerResult, string) {
    when ODIN_OS != .Linux {
        return .InstallerFailed, strings.clone("The bundled Wine runtime is only used for Linux installs.", context.allocator)
    } else {
        extracted_directory := DownloadArchiveExtractDirectory(archive_path)
        defer delete(extracted_directory)
        installer_path := FindDownloadInstaller(extracted_directory)
        if len(installer_path) == 0 {
            return .InstallerNotFound, fmt.aprintf(
                "Archive extracted to %s, but no Windows .exe installer was found. The archive is extracted but not installed.",
                extracted_directory,
            )
        }
        defer delete(installer_path)

        runtime_paths := wine_runtime_paths()
        defer DestroyWineRuntimePaths(&runtime_paths)
        if !os.is_file(runtime_paths.wine) {
            return .InstallerFailed, strings.clone("The bundled Wine runtime is unavailable.", context.allocator)
        }

        sync.mutex_lock(&manager.mutex)
        info_hash := ""
        game_name := ""
        download_directory := ""
        use_ram_limit := false
        if entry_index >= 0 && entry_index < len(manager.entries) {
            info_hash = strings.clone(manager.entries[entry_index].info_hash, context.allocator)
            game_index := manager.entries[entry_index].game_index
            if game_index >= 0 && game_index < len(manager.app.games) {
                game_name = strings.clone(manager.app.games[game_index].title, context.allocator)
            }
            download_directory = strings.clone(manager.app.download_path, context.allocator)
            use_ram_limit = manager.app.use_ram_limit
        }
        sync.mutex_unlock(&manager.mutex)
        defer delete(info_hash)
        defer delete(game_name)
        defer delete(download_directory)

        prefix, prefix_error := ensure_shared_wine_prefix(download_directory)
        if len(prefix_error) > 0 {
            return .InstallerFailed, prefix_error
        }
        defer delete(prefix)

        install_directory := DownloadGameInstallPath(download_directory, game_name, info_hash)
        if len(install_directory) == 0 || !EnsureDownloadDirectory(install_directory) {
            delete(install_directory)
            return .InstallerFailed, strings.clone("Could not create the game installation directory.", context.allocator)
        }
        defer delete(install_directory)
        install_log_path := fmt.aprintf("%s/fatboy-install.log", install_directory)
        defer delete(install_log_path)

        temporary_directory := fmt.aprintf("%s/.fatboy/wine-tmp", download_directory)
        defer delete(temporary_directory)
        if !EnsureDownloadDirectory(temporary_directory) {
            return .InstallerFailed, strings.clone("Could not create the Wine temporary directory.", context.allocator)
        }
        environment, environment_error := wine_process_environment(runtime_paths.root, prefix, temporary_directory)
        if len(environment_error) > 0 {
            return .InstallerFailed, environment_error
        }
        defer DestroyWineProcessEnvironment(environment)
        prefix_ready, prefix_message := initialize_shared_wine_prefix(
            runtime_paths,
            prefix,
            extracted_directory,
            environment,
        )
        if !prefix_ready {
            return .InstallerFailed, prefix_message
        }
        delete(prefix_message)

        installer_dir_arg := wine_windows_path(install_directory)
        defer delete(installer_dir_arg)
        installer_log_arg := wine_windows_path(install_log_path)
        defer delete(installer_log_arg)
        // These are already individual argv elements, not shell text. Do not
        // embed quote characters: Wine performs the necessary command-line
        // quoting when it forwards the argv vector to the Windows process.
        dir_argument := fmt.aprintf("/DIR=%s", installer_dir_arg)
        defer delete(dir_argument)
        log_argument := fmt.aprintf("/LOG=%s", installer_log_arg)
        defer delete(log_argument)

        command: [dynamic]string
        when ODIN_OS == .Linux {
            // setsid makes Wine the leader of a private process group so
            // cancellation can terminate the installer and its descendants.
            // --wait keeps this process attached to the installer.
            append(&command, "setsid")
            append(&command, "--wait")
        }
        append(&command, runtime_paths.wine)
        append(&command, installer_path)
        append(&command, "/VERYSILENT")
        append(&command, "/SILENT")
        append(&command, "/NOMUSIC")
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
            "[WINE] Starting unattended installer through bundled %s: %s %s /VERYSILENT /SILENT /NOMUSIC /SUPPRESSMSGBOXES /NORESTART /NOICONS%s\n",
            WINE_RUNTIME_VERSION,
            runtime_paths.wine,
            installer_path,
            use_ram_limit ? " /RAM=2" : "",
        )
        fmt.printf(
            "[WINE] Child environment paths: runtime=%s prefix=%s tmp=%s\n",
            runtime_paths.root,
            prefix,
            temporary_directory,
        )
        process, start_err := os.process_start(os.Process_Desc{
            working_dir = extracted_directory,
            command = command[:],
            env = environment,
        })
        if start_err != nil {
            return .InstallerFailed, fmt.aprintf("Could not start the bundled Wine installer: %v", start_err)
        }
        fmt.println("[WINE] Installer process started")

        for {
            process_state, wait_err := os.process_wait(process, 250 * time.Millisecond)
            if wait_err == .Timeout {
                if download_should_cancel(manager, entry_index) {
                    terminate_wine_process_tree(process)
                    return .InstallerCancelled, strings.clone("Installer cancelled; the Wine process tree was terminated.", context.allocator)
                }
                if download_should_pause(manager, entry_index) {
                    terminate_wine_process_tree(process)
                    return .InstallerPaused, strings.clone("Installer paused; the Wine process tree was terminated.", context.allocator)
                }
                continue
            }
            if wait_err != nil {
                return .InstallerFailed, fmt.aprintf("Could not wait for the Wine installer: %v", wait_err)
            }
            if !process_state.success {
                return .InstallerFailed, fmt.aprintf(
                    "The Wine installer exited with code %d. See the installer log at %s.",
                    process_state.exit_code,
                    install_log_path,
                )
            }
            break
        }
        return .InstallerStarted, strings.clone("Wine installer completed.", context.allocator)
    }
}
