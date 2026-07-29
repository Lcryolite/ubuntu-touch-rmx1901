#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${HALIUM_ROOT:?set HALIUM_ROOT}"
: "${PORT_ROOT:?set PORT_ROOT}"
: "${HALIUM_INITRD_CACHE_DIR:=/var/tmp/rmx1901-halium-initrd-cache}"
: "${HALIUM_INITRD_DOWNLOADER:=}"
metadata="$repo_root/artifacts/supply-chain/rmx1901-safe-initrd-arm64.provenance.json"
validator="$repo_root/scripts/validate-safe-halium-initrd-provenance.py"
auditor="$repo_root/scripts/audit-safe-halium-initrd.sh"

test -d "$HALIUM_ROOT/device/realme/RMX1901" || {
  echo "RMX1901 device tree is missing" >&2
  exit 1
}
test -x "$validator" && test -x "$auditor" || {
  echo "RMX1901 safe initrd verification tools are missing" >&2
  exit 1
}

mapfile -t values < <(python3 "$validator" "$metadata")
test "${#values[@]}" -eq 6 || {
  echo "Invalid RMX1901 safe initrd provenance" >&2
  exit 1
}
asset_url="${values[0]}"
asset_id="${values[1]}"
expected_size="${values[2]}"
expected_sha="${values[3]}"
asset_name="${values[4]}"
source_commit="${values[5]}"

path_is_below() {
  python3 - "$1" "$2" <<'PY'
import os, sys
child, parent = map(os.path.realpath, sys.argv[1:])
try:
    inside = os.path.commonpath((child, parent)) == parent
except ValueError:
    inside = False
raise SystemExit(0 if inside else 1)
PY
}
if path_is_below "$HALIUM_INITRD_CACHE_DIR" "$repo_root" || \
   path_is_below "$HALIUM_INITRD_CACHE_DIR" "$HALIUM_ROOT" || \
   path_is_below "$HALIUM_INITRD_CACHE_DIR" "$PORT_ROOT"; then
  echo "Halium initrd cache must be outside source checkouts" >&2
  exit 1
fi

verify_file() {
  local file="$1"
  test -f "$file" || return 1
  test "$(stat -c %s "$file")" -eq "$expected_size" || return 1
  test "$(sha256sum "$file" | awk '{print $1}')" = "$expected_sha" || return 1
  "$auditor" "$file" >/dev/null
}

mkdir -p -- "$HALIUM_INITRD_CACHE_DIR"
cache_file="$HALIUM_INITRD_CACHE_DIR/${asset_id}-${source_commit}-${expected_sha}-${asset_name}"
download_tmp=
stage_tmp=
trap 'rm -f -- "${download_tmp:-}" "${stage_tmp:-}"' EXIT
if ! verify_file "$cache_file"; then
  download_tmp="$(mktemp "$HALIUM_INITRD_CACHE_DIR/.download-${asset_id}.XXXXXX")"
  if test -n "$HALIUM_INITRD_DOWNLOADER"; then
    "$HALIUM_INITRD_DOWNLOADER" "$asset_url" "$download_tmp"
  else
    curl --fail --location --silent --show-error \
      --header 'Accept: application/octet-stream' \
      --output "$download_tmp" "$asset_url"
  fi
  verify_file "$download_tmp" || {
    echo "Downloaded RMX1901 safe initrd failed verification" >&2
    exit 1
  }
  mv -f -- "$download_tmp" "$cache_file"
  download_tmp=
fi

stage="$HALIUM_ROOT/device/realme/RMX1901/initramfs.gz"
stage_tmp="$(mktemp "$HALIUM_ROOT/device/realme/RMX1901/.initramfs.gz.XXXXXX")"
cp -- "$cache_file" "$stage_tmp"
verify_file "$stage_tmp" || {
  echo "Staged RMX1901 safe initrd failed verification" >&2
  exit 1
}
mv -f -- "$stage_tmp" "$stage"
stage_tmp=
printf 'staged verified RMX1901 safe initrd asset %s source %s (%s bytes)\n' \
  "$asset_id" "$source_commit" "$expected_size"
