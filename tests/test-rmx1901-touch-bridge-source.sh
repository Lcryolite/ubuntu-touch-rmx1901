#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bridge="$repo_root/scripts/rmx1901-touch-bridge.py"

test -x "$bridge"
python3 -c 'import pathlib, sys; compile(pathlib.Path(sys.argv[1]).read_bytes(), sys.argv[1], "exec")' "$bridge"

grep -Fq 'SOURCE = "/dev/input/event1"' "$bridge"
grep -Fq 'UINPUT = "/dev/uinput"' "$bridge"
grep -Fq 'name != "touchpanel"' "$bridge"
grep -Fq 'x_info[1:3] != (0, 1079)' "$bridge"
grep -Fq 'y_info[1:3] != (0, 2339)' "$bridge"
grep -Fq 'repair_abs_range(source_fd, ABS_MT_WIDTH_MAJOR)' "$bridge"
grep -Fq 'repair_abs_range(source_fd, ABS_MT_PRESSURE)' "$bridge"
grep -Fq 'fcntl.ioctl(source_fd, EVIOCGRAB, 1)' "$bridge"
grep -Fq 'current_slot == 0' "$bridge"
grep -Fq 'raise RuntimeError("touch source reported SYN_DROPPED")' "$bridge"
grep -Fq 'b"rmx1901-touch-bridge"' "$bridge"
grep -Fq 'fcntl.ioctl(target_fd, UI_DEV_DESTROY)' "$bridge"
grep -Fq 'wait_for_character_device(SOURCE)' "$bridge"
grep -Fq 'socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)' "$bridge"
grep -Fq 'sd_notify("READY=1\nSTATUS=RMX1901 touch bridge ready")' "$bridge"

if grep -Ein 'subprocess|requests|urllib|AF_INET|AF_INET6|(^|[^[:alnum:]_])(wipe|erase|flash|blkdiscard)([^[:alnum:]_]|$)' "$bridge"; then
    echo 'touch bridge contains an unexpected external-process, network, or storage operation' >&2
    exit 1
fi

echo 'RMX1901 touch bridge source gate passed'
