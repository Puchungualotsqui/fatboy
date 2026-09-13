# Fatboy Linux installation flow

Fatboy installs Windows FitGirl releases on Linux through the pinned
`GE-Proton8-25` runtime. It never executes `setup.exe` as a host process.

## Runtime

On first archive install, Fatboy downloads the release asset with libcurl to
`$XDG_DATA_HOME/fatboy/runtimes/GE-Proton8-25/` (normally
`~/.local/share/fatboy/runtimes/GE-Proton8-25/`). The asset is required to be
exactly `428716716` bytes and must match the pinned SHA-512 digest before it is
opened by `orar`. A failed or incomplete download is removed. TAR.GZ extraction
is performed by the local `orar` package.

## Prefixes and unattended installation

Each game receives a separate prefix at:

```
<download-directory>/.fatboy/prefixes/<info-hash>/
```

The unattended installer is started only as:

```text
STEAM_COMPAT_CLIENT_INSTALL_PATH=<detected Steam root>
STEAM_COMPAT_DATA_PATH=<per-game prefix>
<runtime>/proton run <extracted-directory>/setup.exe /VERYSILENT /SILENT /SUPPRESSMSGBOXES /NOCANCEL /NORESTART /NOICONS /DIR="..." /LOG="..."
```

The game files go under a sanitized game-name folder directly inside the selected
download directory, for example `<download-directory>/Alchemy_Factory/`. FitGirl's
installer log is saved as `fatboy-install.log` in that directory. After a
successful install, Fatboy removes the downloaded archive and extracted source
folder.
Fatboy's Cancel action still terminates the Proton process even though the
installer's own Cancel button is disabled; Pause terminates it while preserving
resumable download data and the prefix.

## State and cleanup

Fatboy stores manifests, completion markers, and Proton prefixes under the
selected directory's `.fatboy/` folder. On startup it removes only artifacts
that have no resumable manifest, such as orphan `.part` files and abandoned
extraction folders. Paused or failed work with usable archive data is preserved
for resume.

## Steam

Fatboy detects common native and Flatpak Steam roots and supplies the detected
root through `STEAM_COMPAT_CLIENT_INSTALL_PATH`. It does not currently modify
Steam's `shortcuts.vdf` or automatically create a non-Steam shortcut: the
installed executable is not available in the catalog metadata, and editing
Steam's shortcut database while Steam is running can corrupt user data. The
runtime, per-game prefix, and unattended installer flow are implemented first;
a user can add the final executable to Steam after installation and choose
Steam's preferred compatibility settings.
