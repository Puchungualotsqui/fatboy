#!/usr/bin/env bash
# Push the current committed state and create a GitHub Actions release tag.

set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: ./releaseNewVersion.sh <version>

Examples:
  ./releaseNewVersion.sh 0.1.0
  ./releaseNewVersion.sh v0.1.0

The script:
  1. Verifies the locally compiled custom Wine 11.18 runtime.
  2. Requires a clean working tree.
  3. Pushes the current branch to origin.
  4. Creates and pushes an annotated v<version> tag.
  5. Uploads the verified Wine runtime as a release asset.
  6. Starts the GitHub release workflow, which packages that runtime without compiling Wine.

The script does not create a commit. Commit and test your changes first.

Set FATBOY_WINE_RUNTIME_SOURCE to override the default ../wine-build/install-pipe path.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ $# -gt 1 ]]; then
    printf 'Error: expected exactly one version argument.\n\n' >&2
    usage >&2
    exit 2
fi

if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
    printf 'Error: this script must be run inside the Git repository.\n' >&2
    exit 1
fi

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

wine_runtime_version="wine-11.18-pipe"
wine_runtime_source="${FATBOY_WINE_RUNTIME_SOURCE:-${repo_root}/../wine-build/install-pipe}"
wine_runtime_archive="$(mktemp "${TMPDIR:-/tmp}/fatboy-${wine_runtime_version}.XXXXXX.tar.gz")"
cleanup_runtime_archive() {
    rm -f -- "$wine_runtime_archive"
}
trap cleanup_runtime_archive EXIT

verify_wine_runtime() {
    local required_file
    for required_file in bin/wine bin/wineboot bin/wineserver lib/wine share/wine; do
        if [[ ! -e "$wine_runtime_source/$required_file" ]]; then
            printf 'Error: bundled Wine runtime is missing %s under %s.\n' "$required_file" "$wine_runtime_source" >&2
            printf 'Build Wine 11.18 with the pipe fix first, or set FATBOY_WINE_RUNTIME_SOURCE.\n' >&2
            exit 1
        fi
    done

    local wine_version
    wine_version="$($wine_runtime_source/bin/wine --version 2>&1)" || {
        printf 'Error: could not execute the bundled Wine runtime at %s.\n' "$wine_runtime_source" >&2
        exit 1
    }
    if [[ "$wine_version" != *"wine-11.18"* ]]; then
        printf 'Error: expected Wine 11.18, got: %s\n' "$wine_version" >&2
        exit 1
    fi

    tar --create --gzip --file "$wine_runtime_archive" \
        --directory "$wine_runtime_source" .
    if [[ ! -s "$wine_runtime_archive" ]]; then
        printf 'Error: Wine runtime archive was not created.\n' >&2
        exit 1
    fi
    printf 'Verified custom Wine runtime: %s (%s)\n' "$wine_version" "$wine_runtime_source"
}

verify_wine_runtime

if [[ $# -eq 0 ]]; then
    current_version="$(git tag --list 'v[0-9]*' --sort=-version:refname | sed -n '1p')"
    if [[ -z "$current_version" ]]; then
        current_version="no release tags yet"
    fi
    printf 'Error: no release version was provided.\n' >&2
    printf 'Current version: %s\n\n' "$current_version" >&2
    printf 'Create a release with:\n  ./releaseNewVersion.sh 0.1.0\n\n' >&2
    usage >&2
    exit 2
fi

version="$1"
if [[ "$version" != v* ]]; then
    version="v${version}"
fi

if [[ ! "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
    printf 'Error: invalid version "%s". Use a version such as v0.1.0.\n' "$version" >&2
    exit 2
fi

if ! git remote get-url origin >/dev/null 2>&1; then
    printf 'Error: Git remote "origin" is not configured.\n' >&2
    exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
    printf 'Error: GitHub CLI (gh) is required to upload the verified Wine runtime asset.\n' >&2
    exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
    printf 'Error: authenticate GitHub CLI with gh auth login before releasing.\n' >&2
    exit 1
fi

branch="$(git branch --show-current)"
if [[ -z "$branch" ]]; then
    printf 'Error: release must be created from a named branch, not detached HEAD.\n' >&2
    exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
    printf 'Error: working tree is not clean. Commit or stash changes first.\n' >&2
    git status --short >&2
    exit 1
fi

if git rev-parse --verify --quiet "refs/tags/${version}" >/dev/null; then
    printf 'Error: local tag %s already exists.\n' "$version" >&2
    exit 1
fi

if git ls-remote --exit-code --tags origin "refs/tags/${version}" >/dev/null 2>&1; then
    printf 'Error: remote tag %s already exists.\n' "$version" >&2
    exit 1
fi

commit="$(git rev-parse --short HEAD)"
printf 'Preparing %s from %s at commit %s...\n' "$version" "$branch" "$commit"

printf 'Pushing branch %s...\n' "$branch"
git push origin "$branch"

git tag --annotate "$version" --message "Release ${version}"
printf 'Pushing tag %s...\n' "$version"
git push origin "$version"

# Create the draft release early so the workflow can retrieve the runtime asset.
# The workflow publishes the release after it has built Fatboy and packaged Linux.
if ! gh release view "$version" >/dev/null 2>&1; then
    gh release create "$version" \
        --draft \
        --title "Fatboy ${version}" \
        --target "$version"
fi
gh release upload "$version" "$wine_runtime_archive#$wine_runtime_version.tar.gz" --clobber

printf 'Release %s pushed successfully with the verified %s runtime asset.\n' "$version" "$wine_runtime_version"
printf 'GitHub Actions will build Fatboy and publish the release assets without compiling Wine.\n'
