#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fetcher="$repo_root/scripts/fetch-verified-halium-initrd.sh"
validator="$repo_root/scripts/validate-safe-halium-initrd-provenance.py"
auditor="$repo_root/scripts/audit-safe-halium-initrd.sh"
fixture="${SAFE_INITRD_FIXTURE:-/home/lknife/android/rmx1901-halium11-artifacts/initrd-91cad41-20260728T/a/initrd.img-touch-arm64-rmx1901-safe}"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/fetch-safe-initrd-test.XXXXXX")"
trap 'rm -rf -- "$tmp_root"' EXIT
test -f "$fixture"

downloader="$tmp_root/downloader"
cat >"$downloader" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" >>"$DOWNLOAD_CALLS"
cp -- "$DOWNLOAD_FIXTURE" "$2"
EOF
chmod +x "$downloader"

run_fetch() {
  DOWNLOAD_CALLS="$tmp_root/download-calls" DOWNLOAD_FIXTURE="$fixture" \
  HALIUM_ROOT="$1" PORT_ROOT="$repo_root" HALIUM_INITRD_CACHE_DIR="$2" \
  HALIUM_INITRD_DOWNLOADER="$downloader" "$fetcher"
}

halium_root="$tmp_root/halium checkout"
cache_dir="$tmp_root/non-source cache"
mkdir -p "$halium_root/device/realme/RMX1901"
run_fetch "$halium_root" "$cache_dir"
stage="$halium_root/device/realme/RMX1901/initramfs.gz"
cmp "$fixture" "$stage"
test "$(cat "$tmp_root/download-calls")" = \
  'https://api.github.com/repos/Lcryolite/initramfs-tools-halium-rmx1901/releases/assets/491999765'

# A verified cache is reused without invoking the downloader.
: >"$tmp_root/download-calls"
run_fetch "$halium_root" "$cache_dir"
test ! -s "$tmp_root/download-calls"

# The legacy metadata environment escape must be ignored by production.
rm -f -- "$stage"
HALIUM_INITRD_METADATA="$repo_root/artifacts/supply-chain/halium-initrd-arm64.provenance.json" \
  run_fetch "$halium_root" "$cache_dir"
cmp "$fixture" "$stage"

# Old official initrd content is rejected and never staged.
old_initrd=/var/tmp/rmx1901-halium-initrd-cache/92015679-0bbac4577f3567aec935c958216de5d30c7355452ca56248d6728f4f2634bdb6-initrd.img-touch-arm64
rm -f -- "$stage"
set +e
DOWNLOAD_FIXTURE="$old_initrd" DOWNLOAD_CALLS="$tmp_root/old-download-calls" \
HALIUM_ROOT="$halium_root" PORT_ROOT="$repo_root" \
HALIUM_INITRD_CACHE_DIR="$tmp_root/old cache" HALIUM_INITRD_DOWNLOADER="$downloader" \
  "$fetcher" >/dev/null 2>&1
old_status=$?
set -e
test "$old_status" -ne 0
test ! -e "$stage"

# A byte-level digest change is rejected before the artifact can be staged.
tampered_digest="$tmp_root/tampered-digest-initrd.gz"
cp -- "$fixture" "$tampered_digest"
printf '\001' | dd of="$tampered_digest" bs=1 seek=64 conv=notrunc status=none
rm -f -- "$stage"
set +e
DOWNLOAD_FIXTURE="$tampered_digest" DOWNLOAD_CALLS="$tmp_root/tampered-digest-download-calls" \
HALIUM_ROOT="$halium_root" PORT_ROOT="$repo_root" \
HALIUM_INITRD_CACHE_DIR="$tmp_root/tampered digest cache" HALIUM_INITRD_DOWNLOADER="$downloader" \
  "$fetcher" >/dev/null 2>&1
tampered_digest_status=$?
set -e
test "$tampered_digest_status" -ne 0
test ! -e "$stage"

# The archive semantic gate must reject a modified derived boot-control script,
# even when this direct audit intentionally bypasses the release digest gate.
tampered_tree="$tmp_root/tampered-script-tree"
mkdir -p "$tampered_tree"
gzip -dc "$fixture" | (cd "$tampered_tree" && cpio -idm --no-absolute-filenames >/dev/null 2>&1)
printf '\n# test tamper\n' >>"$tampered_tree/scripts/halium-userdata"
tampered_script="$tmp_root/tampered-script-initrd.gz"
(cd "$tampered_tree" && find . -print | cpio -o -H newc 2>/dev/null | gzip -n >"$tampered_script")
set +e
"$auditor" "$tampered_script" >/dev/null 2>&1
tampered_script_status=$?
set -e
test "$tampered_script_status" -ne 0

# A mutable browser URL cannot replace the immutable asset-ID API endpoint.
tampered_url_metadata="$tmp_root/tampered-url-metadata.json"
python3 - "$repo_root/artifacts/supply-chain/rmx1901-safe-initrd-arm64.provenance.json" \
  "$tampered_url_metadata" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
data["asset_api_url"] = data["asset_browser_download_url"]
pathlib.Path(sys.argv[2]).write_text(json.dumps(data), encoding="utf-8")
PY
set +e
python3 "$validator" "$tampered_url_metadata" >/dev/null 2>&1
tampered_url_status=$?
set -e
test "$tampered_url_status" -ne 0

# Cache storage inside either source checkout is forbidden.
for forbidden_cache in "$repo_root/.forbidden-cache" "$halium_root/.forbidden-cache"; do
  rm -f -- "$stage"
  set +e
  run_fetch "$halium_root" "$forbidden_cache" >/dev/null 2>&1
  status=$?
  set -e
  test "$status" -ne 0
  test ! -e "$stage"
done

# PORT_ROOT is caller input; it cannot hide a cache path below this checkout.
mkdir -p "$tmp_root/alternate port"
set +e
cache_output="$(HALIUM_ROOT="$halium_root" PORT_ROOT="$tmp_root/alternate port" \
  HALIUM_INITRD_CACHE_DIR="$repo_root/tests" HALIUM_INITRD_DOWNLOADER=/bin/false \
  "$fetcher" 2>&1)"
cache_status=$?
set -e
test "$cache_status" -ne 0
test "$cache_output" = 'Halium initrd cache must be outside source checkouts'

echo 'verified RMX1901 safe initrd fetch tests passed'
