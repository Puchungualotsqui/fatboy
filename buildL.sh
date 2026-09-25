#!/usr/bin/env bash
# Build the Linux release from a Linux host.

set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: ./buildL.sh

Builds Fatboy for 64-bit Linux using the native Odin toolchain.
The output executable is ./Fatboy.
EOF
}

case "${1:-}" in
    "")
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        printf 'Unknown option: %s\n\n' "$1" >&2
        usage >&2
        exit 2
        ;;
esac

if ! command -v odin >/dev/null 2>&1; then
    printf 'Error: odin was not found in PATH.\n' >&2
    exit 1
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

output_file="Fatboy"

printf 'Building %s (optimized) for Linux x86_64...\n' "$output_file"
odin build . \
    -target:linux_amd64 \
    "-out:${output_file}" \
    -o:speed

if [[ ! -x "$output_file" ]]; then
    printf 'Error: Odin did not produce an executable at %s.\n' "$output_file" >&2
    exit 1
fi

printf 'Build complete: %s/%s\n' "$script_dir" "$output_file"
printf 'The custom font is embedded in the executable.\n'
