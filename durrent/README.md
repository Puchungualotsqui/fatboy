# durrent

`durrent` is the Odin BitTorrent core for FitDeck. It is being developed as a
portable Windows/Unix counterpart to the checked-in `carl` reference client.

The first milestone is intentionally offline and dependency-free. It provides
the protocol data model that the future peer/session engine can share across
Windows, Linux, and other Unix systems:

- Bencode decoding and encoding with ordered dictionaries, duplicate-key
  rejection, nesting/allocation limits, and explicit destruction.
- Magnet URI parsing with hexadecimal and unpadded Base32 BTIH values,
  percent-decoded names, and repeated tracker parameters.
- `.torrent` metainfo parsing for single- and multi-file torrents, tracker
  tiers, web seeds, safe path components, ordered info bytes, and SHA-1
  info-hashes.
- BEP 3 piece geometry, MSB-first bitfields, block progress, in-flight request
  tracking, and SHA-1 piece verification.
- Allocation-free handshake parsing plus bounded borrowed peer-wire message
  views and encoders, including BEP 5 `port` and BEP 10 extension frames.
- Tracker announce URL construction and bencoded response parsing for compact
  and dictionary IPv4 peers.

Parsed values own their variable-length fields. Call the matching `Destroy_*`
procedure exactly once, and keep the same Odin allocator context active when
destroying an object. Wire message payloads are borrowed views into the input
buffer and must be copied before that buffer is reused. A tracker failure can
return a response with an owned `Failure_Reason` and `Tracker_Failure`; destroy
that response on every return path, regardless of the error value.

## Validate the package

The repository uses a portable Visual C++/Windows SDK environment for Odin:

```powershell
& C:\BuildTools\devcmd.ps1
odin test durrent -debug
```

The package currently has no socket, HTTP, UDP, storage, DHT, peer state
machine, or session loop. Those are the next layers; keeping this foundation
pure makes their platform-specific behavior testable against deterministic
fixtures first.
