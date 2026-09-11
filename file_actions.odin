package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

DownloadPathIsArchive :: proc(path: string) -> bool {
    lower := strings.to_lower(path, context.temp_allocator)
    return strings.contains(lower, ".rar") ||
        strings.contains(lower, ".7z") ||
        strings.contains(lower, ".zip")
}


DownloadArchiveExtractDirectory :: proc(archive_path: string) -> string {
    dot := strings.last_index(archive_path, ".")
    if dot > 0 {
        return fmt.aprintf("%s_extracted", archive_path[:dot])
    }
    return fmt.aprintf("%s_extracted", archive_path)
}


find_seven_zip :: proc() -> string {
    candidates := [3]string{
        "C:/Program Files/7-Zip/7z.exe",
        "C:/Program Files (x86)/7-Zip/7z.exe",
        "7z.exe",
    }
    for candidate in candidates {
        if candidate == "7z.exe" || os.exists(candidate) {
            return strings.clone(candidate, context.allocator)
        }
    }
    return ""
}


ExtractDownloadArchiveAndWait :: proc(
    manager: ^DownloadManager,
    entry_index: int,
    archive_path: string,
) -> (bool, string) {
    if len(archive_path) == 0 || !os.exists(archive_path) {
        return false, "The completed archive could not be found."
    }

    seven_zip := find_seven_zip()
    if len(seven_zip) == 0 {
        return false, "7-Zip was not found. Install 7-Zip and try again."
    }
    defer delete(seven_zip)

    output_directory := DownloadArchiveExtractDirectory(archive_path)
    defer delete(output_directory)
    if !os.exists(output_directory) {
        if mkdir_err := os.make_directory_all(output_directory); mkdir_err != nil {
            return false, fmt.aprintf("Could not create extraction folder: %v", mkdir_err)
        }
    }

    output_parameter := fmt.aprintf("-o%s", output_directory)
    defer delete(output_parameter)
    command := []string{seven_zip, "x", archive_path, output_parameter, "-y"}
    process, start_err := os.process_start(os.Process_Desc{command = command})
    if start_err != nil {
        return false, fmt.aprintf("Could not start 7-Zip: %v", start_err)
    }

    for {
        process_state, wait_err := os.process_wait(process, 250 * time.Millisecond)
        if wait_err == .Timeout {
            if download_should_cancel(manager, entry_index) ||
               download_should_pause(manager, entry_index) {
                _ = os.process_terminate(process)
                _, _ = os.process_wait(process)
                return false, "Extraction interrupted."
            }
            continue
        }
        if wait_err != nil {
            return false, fmt.aprintf("Could not wait for 7-Zip: %v", wait_err)
        }
        if !process_state.success {
            return false, fmt.aprintf(
                "7-Zip extraction failed with exit code %d.",
                process_state.exit_code,
            )
        }
        break
    }

    return true, fmt.aprintf("Archive extracted to %s.", output_directory)
}


LaunchDownloadInstaller :: proc(
    manager: ^DownloadManager,
    entry_index: int,
    archive_path: string,
) -> (bool, string) {
    if len(archive_path) == 0 || !os.exists(archive_path) {
        return false, "The completed archive could not be found."
    }

    extracted_directory := DownloadArchiveExtractDirectory(archive_path)
    defer delete(extracted_directory)
    installer_path, join_err := filepath.join(
        {extracted_directory, "setup.exe"},
        context.allocator,
    )
    if join_err != nil {
        return false, "Could not determine the installer path."
    }
    defer delete(installer_path)

    if !os.exists(installer_path) {
        return false, "Extract the archive first; setup.exe was not found."
    }
    process, start_err := os.process_start(
        os.Process_Desc{command = []string{installer_path}},
    )
    if start_err != nil {
        return false, fmt.aprintf("Could not launch setup.exe: %v", start_err)
    }

    for {
        process_state, wait_err := os.process_wait(process, 250 * time.Millisecond)
        if wait_err == .Timeout {
            if download_should_cancel(manager, entry_index) ||
               download_should_pause(manager, entry_index) {
                _ = os.process_terminate(process)
                _, _ = os.process_wait(process)
                return false, "Installer interrupted."
            }
            continue
        }
        if wait_err != nil {
            return false, fmt.aprintf("Could not wait for setup.exe: %v", wait_err)
        }
        if !process_state.success {
            return false, fmt.aprintf(
                "setup.exe exited with code %d.",
                process_state.exit_code,
            )
        }
        break
    }
    return true, "Installer completed."
}
