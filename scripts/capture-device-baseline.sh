#!/usr/bin/env bash
set -euo pipefail

out="${1:-artifacts/baseline}"
adb_bin="${ADB:-adb}"
count="$($adb_bin devices | awk 'NR>1 && $2=="device" {n++} END {print n+0}')"
test "$count" = 1 || { echo "exactly one adb device in device state is required" >&2; exit 1; }

mkdir -p "$out"
$adb_bin shell getprop | grep -Ev 'serial|imei|meid|subscriber|phone' >"$out/getprop.txt"
$adb_bin shell 'ls -l /dev/block/by-name 2>/dev/null || ls -l /dev/block/bootdevice/by-name' >"$out/partitions.txt"
for repo in device/realme/RMX1901 vendor/realme/RMX1901 kernel/realme/sdm710; do
  git -C "$HALIUM_ROOT/$repo" rev-parse HEAD
done >"$out/source-revisions.txt"
printf '%s\n' 'Record the known-good recovery image filename and its sha256 here after verifying a recovery boot.' >"$out/rollback-proof.txt"
