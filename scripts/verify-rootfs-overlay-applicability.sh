#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image="${1:-$repo_root/images/rootfs.img}"
fail() { printf 'error: %s\n' "$1" >&2; exit 1; }
test -f "$image" || fail "rootfs image is missing: $image"
command -v debugfs >/dev/null 2>&1 || fail 'debugfs is required'
image_stat() { debugfs -R "stat $1" "$image" 2>/dev/null; }
image_cat() { debugfs -R "cat $1" "$image" 2>/dev/null; }
for source in /opt/halium-overlay/etc/default/adbd /opt/halium-overlay/etc/ssh/authorized_keys/rmx1901-ut-debug /opt/halium-overlay/lib/systemd/system/adbd.service; do
  image_stat "$source" | grep -Fq 'Inode:' || fail "overlay source is missing: $source"
done
image_stat /opt/halium-overlay/lib/systemd/system/adbd.service | grep -Fq 'Fast link dest: "/dev/null"' || fail 'ADBD overlay is not a /dev/null mask'
cmp -s "$repo_root/overlay/system/etc/default/adbd" <(image_cat /opt/halium-overlay/etc/default/adbd) || fail 'ADBD default differs from overlay'
cmp -s "$repo_root/overlay/system/etc/ssh/authorized_keys/rmx1901-ut-debug" <(image_cat /opt/halium-overlay/etc/ssh/authorized_keys/rmx1901-ut-debug) || fail 'authorized key differs from overlay'
if image_stat /opt/halium-overlay/lib/systemd/system/usb-moded-ssh.service | grep -Fq 'Inode:'; then fail 'legacy usb-moded SSH service is present'; fi
printf 'rootfs_overlay_applicability=pass\n'
