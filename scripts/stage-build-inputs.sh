#!/usr/bin/env bash
set -euo pipefail

source_ramdisk="${1:?usage: stage-build-inputs.sh RAMDISK SHA256 BUILD_DIR}"
expected_sha="${2:?usage: stage-build-inputs.sh RAMDISK SHA256 BUILD_DIR}"
build_dir="${3:?usage: stage-build-inputs.sh RAMDISK SHA256 BUILD_DIR}"
destination_dir="$build_dir/downloads"
destination="$destination_dir/halium-boot-ramdisk.img"
staged="$destination_dir/.halium-boot-ramdisk.img.stage"

printf '%s  %s\n' "$expected_sha" "$source_ramdisk" | sha256sum --check --status || {
  printf 'error: source ramdisk digest mismatch\n' >&2
  exit 1
}

mkdir -p "$destination_dir"
trap 'test ! -e "$staged" || unlink "$staged"' EXIT
install -m 0644 "$source_ramdisk" "$staged"
printf '%s  %s\n' "$expected_sha" "$staged" | sha256sum --check --status
mv -f "$staged" "$destination"
trap - EXIT
