#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/input/partitions" "$fixture/input/system/lib/modules" "$fixture/out"
printf 'boot fixture\n' >"$fixture/input/partitions/boot.img"
printf 'module fixture\n' >"$fixture/input/system/lib/modules/example.ko"
touch "$fixture/input/system/lib/modules/.halium-override-dir"

(
  cd "$repo_root"
  build/build-tarball-mainline.sh RMX1901 "$fixture/out" \
    "$fixture/input" overlaystore
)

tar -tJf "$fixture/out/device_RMX1901.tar.xz" >"$fixture/entries"
grep -Fxq 'partitions/boot.img' "$fixture/entries"
grep -Fxq 'system/opt/halium-overlay/lib/modules/example.ko' "$fixture/entries"
grep -Fxq 'system/opt/halium-overlay/lib/modules/.halium-override-dir' "$fixture/entries"
if grep -Fq 'README' "$fixture/entries"; then
  printf 'error: overlay contract documentation leaked into device tarball\n' >&2
  exit 1
fi

printf 'overlaystore_tarball=pass\n'
