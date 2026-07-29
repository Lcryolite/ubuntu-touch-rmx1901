#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
key="$repo_root/overlay/system/etc/ssh/authorized_keys/rmx1901-ut-debug"
test -L "$repo_root/overlay/system/lib/systemd/system/adbd.service"
test "$(readlink "$repo_root/overlay/system/lib/systemd/system/adbd.service")" = /dev/null
test -f "$key"
test "$(stat -c '%a' "$key")" = 644
test "$(ssh-keygen -lf "$key" | awk '{print $2}')" = SHA256:lsIzmHt5xg5MgPXBHr+eXPnl4H2gH0RTTvWi6G1+DlE
! find "$repo_root/overlay" -type f -o -type l | grep -Eq 'rmx1901-bringup|usb-moded-ssh|\.force-(adb|ssh)'
printf 'secure_bringup_overlay=pass\n'
