#!/usr/bin/env bash
# Run Fatboy from source using the native Odin toolchain.

set -Eeuo pipefail

if ! command -v odin >/dev/null 2>&1; then
    printf 'Error: odin was not found in PATH.\n' >&2
    exit 1
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

# Some distributions install the mbedTLS development symlinks in a
# versioned directory such as /usr/lib/mbedtls3 instead of a default linker
# directory. Odin's curl bindings link these libraries by name.
if [[ -z "${FATBOY_MBEDTLS_LIB:-}" ]]; then
    for candidate in /usr/lib/mbedtls3 /usr/lib64/mbedtls3; do
        if [[ -f "$candidate/libmbedtls.so" &&
              -f "$candidate/libmbedx509.so" &&
              -f "$candidate/libmbedcrypto.so" ]]; then
            FATBOY_MBEDTLS_LIB="$candidate"
            break
        fi
    done
fi
if [[ -n "${FATBOY_MBEDTLS_LIB:-}" ]]; then
    if [[ ! -f "$FATBOY_MBEDTLS_LIB/libmbedtls.so" ||
          ! -f "$FATBOY_MBEDTLS_LIB/libmbedx509.so" ||
          ! -f "$FATBOY_MBEDTLS_LIB/libmbedcrypto.so" ]]; then
        printf 'Error: FATBOY_MBEDTLS_LIB does not contain the mbedTLS linker libraries: %s\n' "$FATBOY_MBEDTLS_LIB" >&2
        exit 1
    fi
    export LIBRARY_PATH="$FATBOY_MBEDTLS_LIB${LIBRARY_PATH:+:$LIBRARY_PATH}"
    printf 'Using mbedTLS libraries from %s\n' "$FATBOY_MBEDTLS_LIB"
fi

if (($# > 0)); then
    exec odin run . -- "$@"
else
    exec odin run .
fi
