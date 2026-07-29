#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT

source_ramdisk="$fixture/pinned-ramdisk.img"
build_dir="$fixture/workdir"
printf 'reviewed initrd\n' >"$source_ramdisk"
expected_sha="$(sha256sum "$source_ramdisk" | awk '{print $1}')"
mkdir -p "$build_dir/downloads"
printf 'stale initrd\n' >"$build_dir/downloads/halium-boot-ramdisk.img"

"$repo_root/scripts/stage-build-inputs.sh" \
  "$source_ramdisk" "$expected_sha" "$build_dir"

printf '%s  %s\n' "$expected_sha" \
  "$build_dir/downloads/halium-boot-ramdisk.img" | sha256sum --check --status
test ! -e "$build_dir/downloads/.halium-boot-ramdisk.img.stage"

printf 'stage_build_inputs=pass\n'
