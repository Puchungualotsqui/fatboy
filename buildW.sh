#!/usr/bin/env bash
# Build the Windows release from a Linux host.
#
# By default this uses an xwin-compatible SDK layout at ~/.xwin:
#   $XWIN_ROOT/crt/lib/x86_64
#   $XWIN_ROOT/sdk/lib/ucrt/x86_64
#   $XWIN_ROOT/sdk/lib/um/x86_64
#
# Set XWIN_ROOT or FATBOY_MSVC_LIB, FATBOY_UCRT_LIB, and FATBOY_UM_LIB to use another
# MSVC/Windows-SDK-compatible toolchain instead.

set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: ./buildW.sh [--console]

Builds Fatboy.exe for 64-bit Windows from Linux.

Options:
  --console  Build a console application instead of the default GUI application.
  -h, --help Show this help message.

Toolchain setup:
  Install Odin and provide MSVC-compatible Windows import libraries. An xwin
  SDK is supported by placing its output in ~/.xwin, or by setting XWIN_ROOT
  to its output directory, for example:

    xwin --accept-license --cache-dir "$HOME/.xwin-cache" splat --copy --output "$HOME/.xwin"
    ./buildW.sh

  For another SDK layout, set all three directories explicitly:

    export FATBOY_MSVC_LIB=/path/to/crt/lib/x86_64
    export FATBOY_UCRT_LIB=/path/to/sdk/lib/ucrt/x86_64
    export FATBOY_UM_LIB=/path/to/sdk/lib/um/x86_64
    ./buildW.sh
EOF
}

subsystem="windows"

while (($# > 0)); do
    case "$1" in
        --console)
            subsystem="console"
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
    shift
done

if ! command -v odin >/dev/null 2>&1; then
    printf 'Error: odin was not found in PATH.\n' >&2
    exit 1
fi
if ! command -v lld-link >/dev/null 2>&1; then
    printf 'Error: lld-link was not found in PATH.\n' >&2
    exit 1
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

xwin_root="${XWIN_ROOT:-${HOME}/.xwin}"
msvc_lib="${FATBOY_MSVC_LIB:-${xwin_root}/crt/lib/x86_64}"
ucrt_lib="${FATBOY_UCRT_LIB:-${xwin_root}/sdk/lib/ucrt/x86_64}"
um_lib="${FATBOY_UM_LIB:-${xwin_root}/sdk/lib/um/x86_64}"

for library_dir in "$msvc_lib" "$ucrt_lib" "$um_lib"; do
    if [[ -z "$library_dir" || ! -d "$library_dir" ]]; then
        printf 'Error: Windows import-library directory is unavailable: %s\n' "${library_dir:-<not configured>}" >&2
        printf 'Set XWIN_ROOT or FATBOY_MSVC_LIB, FATBOY_UCRT_LIB, and FATBOY_UM_LIB.\n' >&2
        exit 1
    fi
done

# Odin reads LIB when locating the Windows CRT and SDK import libraries. The
# host is Linux, so use the Linux path separator even though the target is Windows.
windows_lib_path="${msvc_lib}:${ucrt_lib}:${um_lib}"
if [[ -n "${LIB:-}" ]]; then
    export LIB="${windows_lib_path}:${LIB}"
else
    export LIB="$windows_lib_path"
fi

odin_root="$(odin root)"
raylib_lib="${FATBOY_RAYLIB_LIB:-${odin_root}/vendor/raylib/windows/raylib.lib}"
curl_lib="${FATBOY_CURL_LIB:-${odin_root}/vendor/curl/lib/libcurl.lib}"
tinyfiledialogs_lib="${FATBOY_TINYFILEDIALOGS_LIB:-${script_dir}/tinyfiledialogs/windows/tinyfiledialogs.lib}"

for library_file in "$raylib_lib" "$curl_lib" "$tinyfiledialogs_lib"; do
    if [[ ! -f "$library_file" ]]; then
        printf 'Error: Windows dependency library is unavailable: %s\n' "$library_file" >&2
        printf 'Set FATBOY_RAYLIB_LIB, FATBOY_CURL_LIB, or FATBOY_TINYFILEDIALOGS_LIB as needed.\n' >&2
        exit 1
    fi
done

object_file="Fatboy.obj"
output_file="Fatboy.exe"

printf 'Compiling Fatboy.obj (%s, optimized) for Windows x86_64...\n' "$subsystem"
odin build . \
    -target:windows_amd64 \
    -build-mode:obj \
    "-out:${object_file}" \
    -o:speed

if [[ ! -f "$object_file" ]]; then
    printf 'Error: Odin did not produce %s.\n' "$object_file" >&2
    exit 1
fi

# Odin can emit the Windows object from Linux, but its build driver does not
# perform the final Windows link. Link explicitly with lld-link instead.
printf 'Linking %s...\n' "$output_file"
linker_args=(
    "/out:${output_file}"
    "/subsystem:${subsystem}"
    "/entry:main"
    "/libpath:${msvc_lib}"
    "/libpath:${ucrt_lib}"
    "/libpath:${um_lib}"
    "$object_file"
    "$raylib_lib"
    "$curl_lib"
    "$tinyfiledialogs_lib"
    "msvcrt.lib"
    "vcruntime.lib"
    "ucrt.lib"
    "oldnames.lib"
    "kernel32.lib"
    "user32.lib"
    "gdi32.lib"
    "winmm.lib"
    "shell32.lib"
    "advapi32.lib"
    "ws2_32.lib"
    "crypt32.lib"
    "wldap32.lib"
    "normaliz.lib"
    "secur32.lib"
    "bcrypt.lib"
    "comdlg32.lib"
    "ole32.lib"
    "iphlpapi.lib"
    "ntdll.lib"
    "dnsapi.lib"
    "synchronization.lib"
    "/force:multiple"
)
lld-link "${linker_args[@]}"

printf 'Build complete: %s/%s\n' "$script_dir" "$output_file"
printf 'The custom font is embedded in the executable.\n'
