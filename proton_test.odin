package main

import "core:testing"


@(test)
runtime_archive_detection_test :: proc(t: ^testing.T) {
    testing.expect(t, DownloadPathIsArchive("GE-Proton8-25.tar.gz"))
    testing.expect(t, DownloadPathIsArchive("runtime.TAR.XZ"))
    testing.expect(t, DownloadPathIsArchive("runtime.tar"))
    testing.expect(t, !DownloadPathIsArchive("runtime.exe"))
}


@(test)
runtime_checksum_mismatch_test :: proc(t: ^testing.T) {
    testing.expect(t, GEProtonChecksumMatches(GE_PROTON_SHA512, GE_PROTON_SHA512))
    testing.expect(t, !GEProtonChecksumMatches("0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000", GE_PROTON_SHA512))
}


@(test)
runtime_installation_path_test :: proc(t: ^testing.T) {
    paths := ProtonRuntimePathsForBase("/tmp/fitdeck/runtimes")
    defer DestroyProtonRuntimePaths(&paths)
    testing.expect_value(t, paths.root, "/tmp/fitdeck/runtimes/GE-Proton8-25")
    testing.expect_value(t, paths.archive, "/tmp/fitdeck/runtimes/GE-Proton8-25.tar.gz")
    testing.expect_value(t, paths.part, "/tmp/fitdeck/runtimes/GE-Proton8-25.tar.gz.part")
    testing.expect_value(t, paths.proton, "/tmp/fitdeck/runtimes/GE-Proton8-25/proton")
    prefix := DownloadGamePrefixPath("/games", "ABC123")
    defer delete(prefix)
    install := DownloadGameInstallPath("/games", "ABC123")
    defer delete(install)
    testing.expect_value(t, prefix, "/games/.fitdeck/prefixes/ABC123")
    testing.expect_value(t, install, "/games/.fitdeck/games/ABC123")
}


@(test)
legacy_installing_phase_is_not_a_direct_launch_test :: proc(t: ^testing.T) {
    // The state exposed to the UI for a legacy manifest is Extracted, not an
    // installer-launched state. The worker then enters the GE-Proton path.
    testing.expect_value(t, DownloadStateText(.Extracted), "EXTRACTED - NOT INSTALLED")
    testing.expect_value(t, DownloadStateText(.Installing), "INSTALLING THROUGH GE-PROTON8-25")
}
