package main

import "core:testing"


@(test)
runtime_archive_detection_test :: proc(t: ^testing.T) {
    testing.expect(t, DownloadPathIsArchive("wine-runtime.tar.gz"))
    testing.expect(t, DownloadPathIsArchive("runtime.TAR.XZ"))
    testing.expect(t, DownloadPathIsArchive("runtime.tar"))
    testing.expect(t, !DownloadPathIsArchive("runtime.exe"))
}



@(test)
runtime_installation_path_test :: proc(t: ^testing.T) {
    paths := WineRuntimePathsForBase("/tmp/fatboy/runtimes")
    defer DestroyWineRuntimePaths(&paths)
    testing.expect_value(t, paths.root, "/tmp/fatboy/runtimes/wine-11.18-pipe")
    testing.expect_value(t, paths.wine, "/tmp/fatboy/runtimes/wine-11.18-pipe/bin/wine")
    testing.expect_value(t, paths.wineboot, "/tmp/fatboy/runtimes/wine-11.18-pipe/bin/wineboot")
    testing.expect_value(t, paths.wineserver, "/tmp/fatboy/runtimes/wine-11.18-pipe/bin/wineserver")
    prefix := DownloadGamePrefixPath("/games", "ABC123")
    defer delete(prefix)
    install := DownloadGameInstallPath("/games", "Alchemy Factory", "ABC123")
    defer delete(install)
    testing.expect_value(t, prefix, "/games/.fatboy/wine-prefix")
    testing.expect_value(t, install, "/games/Alchemy_Factory")
}


@(test)
wine_installing_state_text_test :: proc(t: ^testing.T) {
    testing.expect_value(t, DownloadStateText(.Extracted), "EXTRACTED - NOT INSTALLED")
    testing.expect_value(t, DownloadStateText(.Installing), "INSTALLING THROUGH WINE-11.18-PIPE")
}
