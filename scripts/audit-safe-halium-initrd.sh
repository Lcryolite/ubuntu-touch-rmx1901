#!/usr/bin/env bash
set -euo pipefail

artifact="${1:?usage: audit-safe-halium-initrd.sh INITRD}"
test -f "$artifact" || {
  echo "safe initrd is missing: $artifact" >&2
  exit 1
}
gzip -t "$artifact"

audit_root="$(mktemp -d "${TMPDIR:-/tmp}/audit-safe-initrd.XXXXXX")"
trap 'rm -rf -- "$audit_root"' EXIT
gzip -dc "$artifact" >"$audit_root/archive.cpio"
mkdir "$audit_root/tree"
(
  cd "$audit_root/tree"
  cpio -idm --no-absolute-filenames <"$audit_root/archive.cpio" 2>"$audit_root/cpio.log"
)

declare -A required=(
  [scripts/halium]=e5894ea3bc0d2c74e19bc9fa6cf27d95f94a89b3ea534d8ef0fbe6a0b70252a1
  [scripts/halium-userdata]=58b8b722c015ede3c103858ed267ddb82c39440ec16a8296a03bca26b3a3b899
)
for path in "${!required[@]}"; do
  test -f "$audit_root/tree/$path" || {
    echo "safe initrd required file is missing: $path" >&2
    exit 1
  }
  actual="$(sha256sum "$audit_root/tree/$path" | awk '{print $1}')"
  test "$actual" = "${required[$path]}" || {
    echo "safe initrd required file hash mismatch: $path" >&2
    exit 1
  }
done

if find "$audit_root/tree" \( -type f -o -type l \) -printf '%f\n' | \
    grep -Eq '^(e2fsck|resize2fs|dumpe2fs|mke2fs|mkfs([.].*)?|fsck[.]f2fs([.].*)?)$'; then
  echo "safe initrd contains a forbidden filesystem mutation executable" >&2
  exit 1
fi
if grep -Eiq '(^|[;&|[:space:]])(e2fsck|resize2fs|dumpe2fs|mke2fs|mkfs([.][^;&|[:space:]]*)?|fsck[.]f2fs)([;&|[:space:]]|$)' \
    "$audit_root/tree/scripts/halium" "$audit_root/tree/scripts/halium-userdata"; then
  echo "safe initrd boot control path invokes a forbidden filesystem mutation tool" >&2
  exit 1
fi

echo 'verified RMX1901 safe initrd archive semantics'
