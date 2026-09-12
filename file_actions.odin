package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import orar "orar"

DownloadPathIsArchive :: proc(path: string) -> bool {
    lower := strings.to_lower(path, context.temp_allocator)
    last_separator := strings.last_index(lower, "/")
    if backslash := strings.last_index(lower, "\\"); backslash > last_separator {
        last_separator = backslash
    }
    dot := strings.last_index(lower, ".")
    if dot <= last_separator || dot < 0 || dot+1 >= len(lower) {
        return false
    }

    extension := lower[dot+1:]
    if extension == "rar" || extension == "7z" || extension == "zip" || extension == "tar" {
        return true
    }
    return strings.ends_with(lower, ".tar.gz") ||
        strings.ends_with(lower, ".tar.xz") ||
        strings.ends_with(lower, ".tgz") ||
        strings.ends_with(lower, ".txz")
}


DownloadArchiveExtractDirectory :: proc(archive_path: string) -> string {
    last_separator := strings.last_index(archive_path, "/")
    if backslash := strings.last_index(archive_path, "\\"); backslash > last_separator {
        last_separator = backslash
    }
    lower := strings.to_lower(archive_path, context.temp_allocator)
    compound_suffix := ""
    if strings.ends_with(lower, ".tar.gz") || strings.ends_with(lower, ".tar.xz") {
        compound_suffix = archive_path[len(archive_path)-7:]
    } else if strings.ends_with(lower, ".tgz") || strings.ends_with(lower, ".txz") {
        compound_suffix = archive_path[len(archive_path)-4:]
    }
    if len(compound_suffix) > 0 {
        return fmt.aprintf("%s_extracted", archive_path[:len(archive_path)-len(compound_suffix)])
    }

    dot := strings.last_index(archive_path, ".")
    if dot > last_separator && dot > 0 {
        return fmt.aprintf("%s_extracted", archive_path[:dot])
    }
    return fmt.aprintf("%s_extracted", archive_path)
}


archive_entry_relative_path :: proc(name: string) -> (string, bool) {
    // Archive names are not filesystem paths. Normalize both separator styles
    // and reject absolute/traversal names before joining them to the output
    // directory. This keeps extraction safe on every supported host OS.
    if len(name) == 0 || name[0] == '/' || name[0] == '\\' ||
       (len(name) >= 2 && name[1] == ':') {
        return "", false
    }

    normalized: [dynamic]byte
    segment_start := 0
    for index := 0; index <= len(name); index += 1 {
        at_separator := index == len(name) ||
            name[index] == '/' || name[index] == '\\'
        if !at_separator {
            if name[index] == 0 || name[index] == ':' || name[index] < 32 {
                delete(normalized)
                return "", false
            }
            continue
        }

        segment := name[segment_start:index]
        if segment == ".." {
            delete(normalized)
            return "", false
        }
        if segment != "" && segment != "." {
            if len(normalized) > 0 {
                append(&normalized, byte('/'))
            }
            append(&normalized, segment)
        }
        segment_start = index + 1
    }

    if len(normalized) == 0 {
        delete(normalized)
        return "", false
    }
    result := strings.clone(string(normalized[:]), context.allocator)
    delete(normalized)
    return result, true
}


archive_error_message :: proc(err: orar.Error) -> string {
    #partial switch err {
    case .Unsupported_Format:
        return "This file is not a supported archive. orar supports RAR, ZIP, TAR, TAR.XZ, and TAR.GZ files; 7z is not supported."
    case .Unsupported_Feature:
        return "This archive uses a compression feature that orar does not support."
    case .Encrypted:
        return "Encrypted archives are not supported."
    case .Checksum_Mismatch:
        return "The archive failed its checksum validation."
    case .Truncated:
        return "The archive is incomplete or truncated."
    case .Invalid_Archive:
        return "The archive is malformed or invalid."
    }
    return "The archive operation failed."
}


ExtractDownloadArchiveAndWait :: proc(
    manager: ^DownloadManager,
    entry_index: int,
    archive_path: string,
) -> (bool, string) {
    output_directory := DownloadArchiveExtractDirectory(archive_path)
    defer delete(output_directory)
    return ExtractArchiveToDirectory(manager, entry_index, archive_path, output_directory)
}


ExtractArchiveToDirectory :: proc(
    manager: ^DownloadManager,
    entry_index: int,
    archive_path, output_directory: string,
) -> (bool, string) {
    if len(archive_path) == 0 || !os.exists(archive_path) {
        return false, "The completed archive could not be found."
    }

    archive, open_err := orar.Open_File(archive_path)
    if open_err != .None {
        return false, archive_error_message(open_err)
    }
    defer orar.Destroy_Archive(&archive)

    if !os.exists(output_directory) {
        if mkdir_err := os.make_directory_all(output_directory); mkdir_err != nil {
            return false, fmt.aprintf("Could not create extraction folder: %v", mkdir_err)
        }
    }

    total_extract_bytes: u64 = 0
    for entry in archive.Entries {
        if entry.Kind == .File {
            total_extract_bytes += entry.Size
        }
    }
    extracted_bytes: u64 = 0
    download_set_progress(manager, entry_index, 0, 0, i64(total_extract_bytes))

    extracted_files := 0
    for {
        if download_should_cancel(manager, entry_index) ||
           download_should_pause(manager, entry_index) {
            return false, "Extraction interrupted."
        }

        entry, next_err := orar.Next(&archive)
        if next_err == .End {
            break
        }
        if next_err != .None {
            return false, archive_error_message(next_err)
        }

        relative_path, path_ok := archive_entry_relative_path(entry.Name)
        if !path_ok {
            return false, fmt.aprintf(
                "Archive contains an unsafe path: %s",
                entry.Name,
            )
        }
        defer delete(relative_path)

        destination, join_err := filepath.join(
            {output_directory, relative_path},
            context.allocator,
        )
        if join_err != nil {
            return false, fmt.aprintf(
                "Could not determine extraction path for %s.",
                entry.Name,
            )
        }
        defer delete(destination)

        if entry.Kind == .Directory {
            // A parent directory may already have been created while writing
            // an earlier file entry. Treat that normal archive layout as
            // success, but reject a file occupying the directory path.
            if os.exists(destination) {
                if !os.is_directory(destination) {
                    return false, fmt.aprintf(
                        "Could not create extracted directory %s: a file already exists at that path.",
                        entry.Name,
                    )
                }
            } else if mkdir_err := os.make_directory_all(destination); mkdir_err != nil {
                return false, fmt.aprintf(
                    "Could not create extracted directory %s: %v",
                    entry.Name,
                    mkdir_err,
                )
            }
            continue
        }
        if entry.Kind != .File {
            // Symlinks and special entries are intentionally not materialized:
            // archive extraction must not create links or devices on the host.
            continue
        }

        parent_directory := output_directory
        separator := strings.last_index(destination, "/")
        if backslash := strings.last_index(destination, "\\"); backslash > separator {
            separator = backslash
        }
        if separator >= 0 {
            parent_directory = destination[:separator]
        }
        if !os.exists(parent_directory) {
            if mkdir_err := os.make_directory_all(parent_directory); mkdir_err != nil {
                return false, fmt.aprintf(
                    "Could not create folder for %s: %v",
                    entry.Name,
                    mkdir_err,
                )
            }
        }

        file, open_err := os.open(destination, os.O_WRONLY|os.O_CREATE|os.O_TRUNC)
        if open_err != nil {
            return false, fmt.aprintf(
                "Could not create extracted file %s: %v",
                entry.Name,
                open_err,
            )
        }
        {
            defer os.close(file)
            buffer: [64 * 1024]byte
            for {
                count, read_err := orar.Read_Current(&archive, buffer[:])
                if read_err == .End {
                    break
                }
                if read_err != .None {
                    return false, fmt.aprintf(
                        "Could not extract %s: %s",
                        entry.Name,
                        archive_error_message(read_err),
                    )
                }
                if count == 0 {
                    continue
                }
                written_total := 0
                for written_total < count {
                    written, write_err := os.write(
                        file,
                        buffer[written_total:count],
                    )
                    if write_err != nil || written <= 0 {
                        return false, fmt.aprintf(
                            "Could not write extracted file %s: %v",
                            entry.Name,
                            write_err,
                        )
                    }
                    written_total += written
                }
            }
        }
        extracted_files += 1
        extracted_bytes += entry.Size
        progress := total_extract_bytes > 0 ? f64(extracted_bytes) / f64(total_extract_bytes) : 1
        download_set_progress(
            manager,
            entry_index,
            progress,
            i64(extracted_bytes),
            i64(total_extract_bytes),
        )
    }

    if extracted_files == 0 {
        return false, "The archive contains no regular files to extract."
    }
    return true, fmt.aprintf("Archive extracted to %s.", output_directory)
}


DownloadInstallerResult :: enum {
    InstallerStarted,
    InstallerNotFound,
    InstallerCancelled,
    InstallerPaused,
    InstallerFailed,
}


LaunchDownloadInstaller :: proc(
    manager: ^DownloadManager,
    entry_index: int,
    archive_path: string,
) -> (DownloadInstallerResult, string) {
    when ODIN_OS == .Linux {
        return LaunchGEProtonInstaller(manager, entry_index, archive_path)
    } else {
        return LaunchNativeDownloadInstaller(manager, entry_index, archive_path)
    }
}


LaunchNativeDownloadInstaller :: proc(
    manager: ^DownloadManager,
    entry_index: int,
    archive_path: string,
) -> (DownloadInstallerResult, string) {
    if len(archive_path) == 0 || !os.exists(archive_path) {
        return .InstallerFailed, "The completed archive could not be found."
    }

    extracted_directory := DownloadArchiveExtractDirectory(archive_path)
    defer delete(extracted_directory)
    if !os.is_directory(extracted_directory) {
        return .InstallerFailed, "Extract the archive first; the extraction folder was not found."
    }

    installer_names := []string{"setup.exe", "install.exe", "installer.exe"}
    installer_path := ""
    for installer_name in installer_names {
        candidate, join_err := filepath.join(
            {extracted_directory, installer_name},
            context.allocator,
        )
        if join_err != nil {
            continue
        }
        if os.is_file(candidate) {
            installer_path = candidate
            break
        }
        delete(candidate)
    }

    if len(installer_path) == 0 {
        return .InstallerNotFound, fmt.aprintf(
            "Archive extracted to %s, but no Windows installer was found.",
            extracted_directory,
        )
    }
    defer delete(installer_path)

    process, start_err := os.process_start(
        os.Process_Desc{command = []string{installer_path}},
    )
    if start_err != nil {
        return .InstallerFailed, fmt.aprintf("Could not launch the native installer: %v", start_err)
    }

    for {
        process_state, wait_err := os.process_wait(process, 250 * time.Millisecond)
        if wait_err == .Timeout {
            if download_should_cancel(manager, entry_index) {
                _ = os.process_terminate(process)
                _, _ = os.process_wait(process)
                return .InstallerCancelled, "Installer cancelled."
            }
            if download_should_pause(manager, entry_index) {
                _ = os.process_terminate(process)
                _, _ = os.process_wait(process)
                return .InstallerPaused, "Installer paused."
            }
            continue
        }
        if wait_err != nil {
            return .InstallerFailed, fmt.aprintf("Could not wait for the native installer: %v", wait_err)
        }
        if !process_state.success {
            return .InstallerFailed, fmt.aprintf(
                "The native installer exited with code %d.",
                process_state.exit_code,
            )
        }
        break
    }
    return .InstallerStarted, "Installer completed."
}
