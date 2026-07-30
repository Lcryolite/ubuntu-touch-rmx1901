#!/bin/sh
# RMX1901 autonomous recovery control.
#
# This intentionally writes only Android's 2 KiB bootloader_message (BCB)
# prefix on misc, never a whole partition.  Qualcomm ABL consumes the
# "boot-recovery" command at the following physical reboot.

set -eu

BCB_BYTES=2048
MISC_DEVICE=${RMX1901_MISC_DEVICE:-/dev/disk/by-partlabel/misc}
STATE_DIR=${RMX1901_RECOVERY_STATE_DIR:-/userdata/rmx1901-autonomous}
REBOOT_CMD=${RMX1901_REBOOT_CMD:-systemctl reboot}
NO_REBOOT=0
FORCE=0

usage() {
    echo "usage: $0 {status|arm-recovery|clear|recovery|normal} [--no-reboot] [--force]" >&2
    exit 64
}

is_zero_bcb() {
    dd if="$MISC_DEVICE" bs="$BCB_BYTES" count=1 status=none | cmp -n "$BCB_BYTES" -s - /dev/zero
}

check_target() {
    [ -b "$MISC_DEVICE" ] || [ "${RMX1901_TEST_MODE:-0}" = 1 ] || {
        echo "refusing non-block misc target: $MISC_DEVICE" >&2
        exit 65
    }
    if [ "${RMX1901_TEST_MODE:-0}" = 1 ] && [ ! -b "$MISC_DEVICE" ]; then
        bytes=$(wc -c < "$MISC_DEVICE")
    else
        bytes=$(blockdev --getsize64 "$MISC_DEVICE")
    fi
    [ "$bytes" -ge "$BCB_BYTES" ] || {
        echo "misc target is smaller than $BCB_BYTES bytes: $MISC_DEVICE" >&2
        exit 65
    }
}

make_bcb() {
    output=$1
    command=$2
    umask 077
    dd if=/dev/zero of="$output" bs="$BCB_BYTES" count=1 status=none
    [ -z "$command" ] || printf '%s\0' "$command" | dd of="$output" conv=notrunc status=none
    [ "$(wc -c < "$output")" -eq "$BCB_BYTES" ] || exit 70
}

backup_and_write() {
    command=$1
    check_target
    if ! is_zero_bcb && [ "$FORCE" -ne 1 ]; then
        echo "refusing to overwrite non-empty BCB; inspect it or pass --force" >&2
        exit 66
    fi
    umask 077
    mkdir -p "$STATE_DIR"
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    backup="$STATE_DIR/misc-bcb-before-$stamp.bin"
    next="$STATE_DIR/misc-bcb-next-$stamp.bin"
    dd if="$MISC_DEVICE" of="$backup" bs="$BCB_BYTES" count=1 status=none
    make_bcb "$next" "$command"
    dd if="$next" of="$MISC_DEVICE" bs="$BCB_BYTES" count=1 conv=fsync,notrunc status=none
    dd if="$MISC_DEVICE" bs="$BCB_BYTES" count=1 status=none | cmp -s - "$next" || {
        echo "BCB readback mismatch; refusing reboot" >&2
        exit 67
    }
    sha256sum "$backup" "$next"
}

reboot_now() {
    [ "$NO_REBOOT" -eq 1 ] && return 0
    exec sh -c "$REBOOT_CMD"
}

action=${1:-}
[ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
    case $1 in
        --no-reboot) NO_REBOOT=1 ;;
        --force) FORCE=1 ;;
        *) usage ;;
    esac
    shift
done

case $action in
    status)
        check_target
        echo "misc=$MISC_DEVICE"
        if is_zero_bcb; then echo "bcb=empty"; else echo "bcb=non-empty"; fi
        ;;
    arm-recovery)
        backup_and_write boot-recovery
        ;;
    clear)
        backup_and_write ''
        ;;
    recovery)
        backup_and_write boot-recovery
        reboot_now
        ;;
    normal)
        backup_and_write ''
        reboot_now
        ;;
    *) usage ;;
esac
