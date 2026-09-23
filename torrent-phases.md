### Phase 1: Provider/settings foundation

- Add provider enum and settings v4.
- Add provider selector to settings.
- Make startup authentication conditional.
- Refactor `DownloadEntry` away from RD-specific assumptions such as `rd_torrent_id`.
- Preserve current Real-Debrid behavior through an adapter or provider switch.

### Phase 2: Local `.torrent` vertical slice

Before supporting magnets, integrate a local `.torrent` file path internally.

Implement:

- Parse `.torrent`
- Open `Torrent_Session_Loop`
- Start/pause/cancel/shutdown
- Read loop snapshots
- Map progress into `DownloadSnapshot`
- Persist and restore `.durrent.resume`
- Reuse Fatboy’s archive extraction and installation flow

This isolates provider integration from the more difficult magnet metadata problem.

### Phase 3: Magnet metadata coordinator

Add a real magnet resolver that:

1. Parses the magnet.
2. Announces through its tracker URLs.
3. Uses DHT where allowed.
4. Connects to candidate peers.
5. Performs the BitTorrent handshake.
6. Routes extension events to `Metadata_Downloader`.
7. Verifies the metadata info-hash.
8. Caches the resulting `.torrent` data.
9. Starts the normal torrent session loop.

This needs timeout, retry, peer-limit, and cancellation handling.

### Phase 4: Persistence and restart recovery

Fatboy’s `.state` manifest should store:

- Provider
- Game title
- Magnet
- Info-hash
- Phase
- Cached torrent metadata path
- Torrent output path
- Post-processing state

Durrent should remain authoritative for piece-level resume data through its `.durrent.resume` file.

On restart:

- Restore local jobs from Fatboy state files.
- Reopen cached torrent metadata.
- Let durrent verify existing pieces.
- Resume the loop only after the provider/backend is initialized.

### Phase 5: UI and lifecycle hardening

- Show local torrent progress and speed.
- Add local-specific status messages.
- Ensure pause/resume APIs exist in `durrent/loop.odin`.
- Ensure cancellation shuts down the loop before deleting files.
- Stop every durrent session before Fatboy exits.
- Handle multi-file torrents and identify the archive or install directory correctly.
