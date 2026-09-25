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
  1. Requires a clean working tree.
  2. Pushes the current branch to origin.
  3. Creates an annotated v<version> tag.
  4. Pushes the tag, which starts the GitHub release workflow.

The script does not create a commit. Commit and test your changes first.
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

printf 'Release %s pushed successfully.\n' "$version"
printf 'GitHub Actions should now build and publish the release assets.\n'
