#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tools_dir="$repo_root/build"
source_script="$tools_dir/system-image-from-ota.sh"
helper="$repo_root/scripts/prepare-unprivileged-system-image-script.sh"
runner="$repo_root/scripts/run-unprivileged-system-image-script.sh"
expected_tools_commit='d5838d5c4cf90c7dbece749a451fb14271847dc9'

test "$#" -eq 2 || {
    echo 'usage: system-image-from-ota-unprivileged.sh OTA_COMMAND OUTPUT_DIRECTORY' >&2
    exit 2
}
test -d "$tools_dir/.git" || {
    echo 'error: pinned adaptation-tools checkout is missing' >&2
    exit 1
}
test "$(git -C "$tools_dir" rev-parse HEAD)" = "$expected_tools_commit" || {
    echo 'error: adaptation-tools checkout is not at the pinned commit' >&2
    exit 1
}
test -z "$(git -C "$tools_dir" status --porcelain --untracked-files=all)" || {
    echo 'error: adaptation-tools checkout is dirty' >&2
    exit 1
}

workdir="$repo_root/workdir"
mkdir -p "$workdir"
scratch="$(mktemp -d -p "$workdir" system-image.XXXXXXXXXX)"
cleanup() {
    local status=$?
    trap - EXIT
    if test -d "$scratch"; then
        "$runner" /usr/bin/rm -rf -- "$scratch" || {
            echo 'error: failed to clean system-image scratch in its ID namespace' >&2
            exit 1
        }
    fi
    exit "$status"
}
trap cleanup EXIT

transformed="$scratch/system-image-from-ota.sh"
"$helper" "$source_script" "$transformed" "$scratch"

cd "$repo_root"
"$runner" "$transformed" "$@"
