#!/usr/bin/env bash
set -euo pipefail

out="${1:-artifacts/runtime}"
adb_bin="${ADB:-adb}"
command -v "$adb_bin" >/dev/null 2>&1 || {
  echo "adb executable is missing" >&2
  exit 1
}

mkdir -p -- "$out"
"$adb_bin" wait-for-device
"$adb_bin" logcat -b all -d >"$out/logcat.txt"
"$adb_bin" shell dmesg >"$out/dmesg.txt"
"$adb_bin" shell 'cat /sys/fs/pstore/console-ramoops 2>/dev/null || true' >"$out/pstore.txt"
