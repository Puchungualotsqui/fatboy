package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
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


archive_link_target_within_output :: proc(link_name, target: string) -> (string, bool) {
	if len(target) == 0 || target[0] == '/' || target[0] == '\\' ||
	   (len(target) >= 2 && target[1] == ':') {
		return "", false
	}

	normalized_bytes: [dynamic]byte
	for value in target {
		if value == 0 || value == ':' || value < 32 {
			delete(normalized_bytes)
			return "", false
		}
		append(&normalized_bytes, value == '\\' ? byte('/') : byte(value))
	}
	normalized_target := strings.clone(string(normalized_bytes[:]), context.allocator)
	delete(normalized_bytes)

	component_count := 0
	validate_components :: proc(path: string, component_count: ^int) -> bool {
		start := 0
		for index := 0; index <= len(path); index += 1 {
			if index < len(path) && path[index] != '/' {
				continue
			}
			segment := path[start:index]
			if segment == "" || segment == "." {
				start = index + 1
				continue
			}
			if segment == ".." {
				if component_count^ == 0 {
					return false
				}
				component_count^ -= 1
			} else {
				component_count^ += 1
			}
			start = index + 1
		}
		return true
	}

	parent_end := strings.last_index(link_name, "/")
	if parent_end >= 0 && !validate_components(link_name[:parent_end], &component_count) {
		delete(normalized_target)
		return "", false
	}
	if !validate_components(normalized_target, &component_count) {
		delete(normalized_target)
		return "", false
	}
	return normalized_target, true
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
    case .Limit_Exceeded:
        return "The archive expands beyond the supported extraction limit."
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
        return false, strings.clone("The completed archive could not be found.", context.allocator)
    }

    archive, open_err := orar.Open_File(archive_path)
    if open_err != .None {
        return false, strings.clone(archive_error_message(open_err), context.allocator)
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
            return false, strings.clone("Extraction interrupted.", context.allocator)
        }

        entry, next_err := orar.Next(&archive)
        if next_err == .End {
            break
        }
        if next_err != .None {
            return false, strings.clone(archive_error_message(next_err), context.allocator)
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
        if entry.Kind == .Symlink {
            // ZIP symlink entries do not expose their payload as metadata yet;
            // leave those special entries untouched rather than guessing a target.
            if len(entry.Link_Target) == 0 {
                continue
            }
            when ODIN_OS == .Linux {
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
                        return false, fmt.aprintf("Could not create folder for link %s: %v", entry.Name, mkdir_err)
                    }
                }

                target, target_ok := archive_link_target_within_output(relative_path, entry.Link_Target)
                if !target_ok {
                    return false, fmt.aprintf("Archive link target escapes the extraction folder: %s -> %s", entry.Name, entry.Link_Target)
                }
                defer delete(target)
                if os.exists(destination) {
                    return false, fmt.aprintf("Could not create extracted link %s: a file already exists at that path.", entry.Name)
                }
                if link_err := os.symlink(target, destination); link_err != nil {
                    return false, fmt.aprintf("Could not create extracted link %s: %v", entry.Name, link_err)
                }
                extracted_files += 1
            }
            continue
        }
        if entry.Kind != .File {
            // Devices and other special entries are never materialized on the host.
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
        return false, strings.clone("The archive contains no regular files to extract.", context.allocator)
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
        return LaunchWineInstaller(manager, entry_index, archive_path)
    } else {
        return LaunchNativeDownloadInstaller(manager, entry_index, archive_path)
    }
}


download_installer_candidate :: struct {
    path:  string,
    score: int,
}


find_download_installer_candidates :: proc(
    directory: string,
    candidates: ^[dynamic]download_installer_candidate,
) {
    entries, read_err := os.read_all_directory_by_path(directory, context.allocator)
    if read_err != nil {
        return
    }
    defer os.file_info_slice_delete(entries, context.allocator)

    for info in entries {
        if os.is_directory(info.fullpath) {
            find_download_installer_candidates(info.fullpath, candidates)
            continue
        }
        if !os.is_file(info.fullpath) || !strings.ends_with(strings.to_lower(info.name, context.temp_allocator), ".exe") {
            continue
        }

        lower_name := strings.to_lower(info.name, context.allocator)
        if lower_name == "quicksfv.exe" {
            delete(lower_name)
            continue
        }
        score := 100
        if lower_name == "setup.exe" {
            score = 10000
        } else if strings.contains(lower_name, "setup") {
            score = 5000 - len(lower_name)
        } else if strings.contains(lower_name, "install") {
            score = 4000 - len(lower_name)
        } else if strings.contains(lower_name, "installer") {
            score = 3000 - len(lower_name)
        }
        delete(lower_name)
        append(candidates, download_installer_candidate{
            path = strings.clone(info.fullpath, context.allocator),
            score = score,
        })
    }
}


FindDownloadInstaller :: proc(extracted_directory: string) -> string {
    if len(extracted_directory) == 0 || !os.is_directory(extracted_directory) {
        return ""
    }
    candidates: [dynamic]download_installer_candidate
    defer {
        for candidate in candidates {
            delete(candidate.path)
        }
        delete(candidates)
    }
    find_download_installer_candidates(extracted_directory, &candidates)
    if len(candidates) == 0 {
        return ""
    }

    best := 0
    for index := 1; index < len(candidates); index += 1 {
        if candidates[index].score > candidates[best].score ||
           (candidates[index].score == candidates[best].score && candidates[index].path < candidates[best].path) {
            best = index
        }
    }
    return strings.clone(candidates[best].path, context.allocator)
}


LaunchNativeDownloadInstaller :: proc(
    manager: ^DownloadManager,
    entry_index: int,
    archive_path: string,
) -> (DownloadInstallerResult, string) {
    if len(archive_path) == 0 || !os.exists(archive_path) {
        return .InstallerFailed, strings.clone("The completed archive could not be found.", context.allocator)
    }

    extracted_directory := DownloadArchiveExtractDirectory(archive_path)
    defer delete(extracted_directory)
    if !os.is_directory(extracted_directory) {
        return .InstallerFailed, strings.clone("Extract the archive first; the extraction folder was not found.", context.allocator)
    }

    installer_path := FindDownloadInstaller(extracted_directory)
    if len(installer_path) == 0 {
        return .InstallerNotFound, fmt.aprintf(
            "Archive extracted to %s, but no Windows .exe installer was found.",
            extracted_directory,
        )
    }
    defer delete(installer_path)

    use_ram_limit := false
    if manager != nil && manager.app != nil {
        sync.mutex_lock(&manager.mutex)
        use_ram_limit = manager.app.use_ram_limit
        sync.mutex_unlock(&manager.mutex)
    }
    command: [dynamic]string
    append(&command, installer_path)
    append(&command, "/NOMUSIC")
    if use_ram_limit {
        append(&command, "/RAM=2")
    }
    defer delete(command)

    process, start_err := os.process_start(
        os.Process_Desc{command = command[:]},
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
                return .InstallerCancelled, strings.clone("Installer cancelled.", context.allocator)
            }
            if download_should_pause(manager, entry_index) {
                _ = os.process_terminate(process)
                _, _ = os.process_wait(process)
                return .InstallerPaused, strings.clone("Installer paused.", context.allocator)
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
    return .InstallerStarted, strings.clone("Installer completed.", context.allocator)
}
