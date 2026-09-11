# orar

`orar` is a pure Odin archive reader for Windows and UNIX-like systems. It has
no `foreign` declarations, C sources, system compression libraries, subprocess
requirements, or platform-specific archive APIs.

The package is a portable Odin implementation of the useful RAR/TAR/ZIP parts
of the checked-in `unarr` reference implementation.

## Supported formats

- **RAR4**: stored entries and RAR v2/v3 Huffman + LZSS entries, including
  solid archives. RAR5, encrypted/password-protected archives, split volumes,
  PPMd entries, audio blocks, and RAR virtual-machine filters return
  `Error.Unsupported_Feature`.
- **TAR**: traditional and ustar headers, GNU long names, and PAX `path`,
  `size`, and `mtime` records.
- **ZIP**: stored and raw Deflate entries, ZIP64 metadata, UTF-8 and CP437
  names, directory metadata, archive comments, and CRC32 verification.
  Deflate64, BZip2, LZMA, XZ, and PPMd ZIP methods return
  `Error.Unsupported_Feature`.

7z is intentionally not part of this package.

## Basic usage

```odin
import "orar"

archive, err := orar.Open_File("game.part1.rar")
if err != .None {
    // Handle err.
    return
}
defer orar.Destroy_Archive(&archive)

for {
    entry, next_err := orar.Next(&archive)
    if next_err == .End {
        break
    }
    if next_err != .None {
        // The archive was malformed or truncated.
        break
    }
    if entry.Kind != .File {
        continue
    }

    contents, extract_err := orar.Extract_Current(&archive)
    if extract_err != .None {
        // Checksum or unsupported-method failure.
        break
    }
    // Use contents, then release it with delete(contents).
    delete(contents)
}
```

`Open_Bytes` copies its input. Use `Open_Bytes_Borrowed` when the caller owns
the source buffer and can keep it alive until `Destroy_Archive`. `Open_File`
reads the complete file into memory. Entry names and archive comments are owned
by `Archive`; returned extracted buffers are independent allocations.

For streaming-style extraction, call `Read_Current` repeatedly after `Next`:

```odin
buffer: [64 * 1024]byte
for {
    count, read_err := orar.Read_Current(&archive, buffer[:])
    if read_err == .End {
        break
    }
    if read_err != .None {
        break
    }
    // Consume buffer[:count].
}
```

## Validation

The repository uses the portable Visual C++/Windows SDK environment for Odin:

```powershell
& C:\BuildTools\devcmd.ps1
odin check orar -no-entry-point
odin test orar -debug
```

The tests construct RAR4, TAR, ZIP-store, and ZIP-Deflate archives in memory.
When the checked-in unarr corpus is available, they additionally exercise the
real TAR, ZIP, and compressed RAR4 files.

## License

The implementation is derived from the LGPLv3-licensed unarr project. See
`COPYING` and `AUTHORS` for the applicable license and attribution information.
