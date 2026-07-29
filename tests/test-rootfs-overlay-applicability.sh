#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"; trap 'rm -rf -- "$fixture"' EXIT
root="$fixture/root"; image="$fixture/rootfs.img"
mkdir -p "$root/opt/halium-overlay/etc/default" "$root/opt/halium-overlay/etc/ssh/authorized_keys" "$root/opt/halium-overlay/lib/systemd/system"
cp "$repo_root/overlay/system/etc/default/adbd" "$root/opt/halium-overlay/etc/default/adbd"
cp "$repo_root/overlay/system/etc/ssh/authorized_keys/rmx1901-ut-debug" "$root/opt/halium-overlay/etc/ssh/authorized_keys/rmx1901-ut-debug"
cp -a "$repo_root/overlay/system/lib/systemd/system/adbd.service" "$root/opt/halium-overlay/lib/systemd/system/adbd.service"
truncate -s 16M "$image"; mke2fs -q -F -t ext4 -d "$root" "$image"
"$repo_root/scripts/verify-rootfs-overlay-applicability.sh" "$image"
echo 'rootfs_overlay_applicability=pass'
