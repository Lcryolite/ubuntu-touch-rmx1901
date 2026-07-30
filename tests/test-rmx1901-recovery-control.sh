#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tool="$root/scripts/rmx1901-recovery-control.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

truncate -s 4096 "$tmp/misc"
RMX1901_TEST_MODE=1 RMX1901_MISC_DEVICE="$tmp/misc" \
RMX1901_RECOVERY_STATE_DIR="$tmp/state" "$tool" status | grep -qx 'bcb=empty'

RMX1901_TEST_MODE=1 RMX1901_MISC_DEVICE="$tmp/misc" \
RMX1901_RECOVERY_STATE_DIR="$tmp/state" "$tool" arm-recovery >/dev/null
printf 'boot-recovery\0' > "$tmp/expected-command"
dd if="$tmp/misc" bs=1 count=14 status=none | cmp - "$tmp/expected-command"
[ "$(wc -c < "$tmp/misc")" -eq 4096 ]

if RMX1901_TEST_MODE=1 RMX1901_MISC_DEVICE="$tmp/misc" \
    RMX1901_RECOVERY_STATE_DIR="$tmp/state" "$tool" arm-recovery >/dev/null 2>&1; then
    echo 'non-empty BCB overwrite was not rejected' >&2
    exit 1
fi

RMX1901_TEST_MODE=1 RMX1901_MISC_DEVICE="$tmp/misc" \
RMX1901_RECOVERY_STATE_DIR="$tmp/state" "$tool" clear --force >/dev/null
cmp -n 2048 "$tmp/misc" /dev/zero

echo 'RMX1901 recovery-control test passed'
