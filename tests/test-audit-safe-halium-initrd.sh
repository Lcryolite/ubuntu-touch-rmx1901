#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
auditor="$repo_root/scripts/audit-safe-halium-initrd.sh"
# This is the first independently derived copy of the immutable 91cad41
# release asset.  Keep the test offline: the semantic auditor must exercise
# the same byte-for-byte archive pinned by provenance, not a mutable checkout
# output under initramfs-tools-halium-rmx1901/out/.
safe_initrd="${SAFE_INITRD_FIXTURE:-/home/lknife/android/rmx1901-halium11-artifacts/initrd-91cad41-20260728T/a/initrd.img-touch-arm64-rmx1901-safe}"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/safe-initrd-audit-test.XXXXXX")"
trap 'rm -rf -- "$tmp_root"' EXIT

test -f "$safe_initrd"
"$auditor" "$safe_initrd"

make_variant() {
  local variant="$1"
  local tree="$tmp_root/$variant-tree"
  mkdir -p "$tree"
  (
    cd "$tree"
    gzip -dc "$safe_initrd" | cpio -idm --no-absolute-filenames 2>/dev/null
  )
  case "$variant" in
    missing-policy) rm -f -- "$tree/scripts/halium-userdata" ;;
    forbidden-tool)
      mkdir -p "$tree/sbin"
      cp -- /bin/true "$tree/sbin/e2fsck"
      ;;
    tampered-policy) printf '\n# tampered\n' >>"$tree/scripts/halium-userdata" ;;
  esac
  (
    cd "$tree"
    find . -print0 | LC_ALL=C sort -z | cpio --null -o -H newc 2>/dev/null | gzip -n -9 >"$tmp_root/$variant.gz"
  )
}

for variant in missing-policy forbidden-tool tampered-policy; do
  make_variant "$variant"
  if "$auditor" "$tmp_root/$variant.gz" >/dev/null 2>&1; then
    echo "safe initrd auditor accepted $variant" >&2
    exit 1
  fi
done

echo 'safe initrd semantic audit tests passed'
