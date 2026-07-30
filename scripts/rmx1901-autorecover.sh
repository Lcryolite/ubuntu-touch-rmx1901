#!/bin/sh
# Drive the verified RMX1901 fallback path without physical keys:
# system -> BCB -> 900e (if it occurs) -> Sahara reset -> Recovery ADB.

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
serial=${RMX1901_SERIAL:-7b0c1c49}
ssh_host=${RMX1901_SSH_HOST:-10.15.19.82}
ssh_port=${RMX1901_SSH_PORT:-8022}
known_hosts=${RMX1901_KNOWN_HOSTS:-/tmp/rmx1901-ssh-known-hosts}
timeout=${RMX1901_RECOVERY_TIMEOUT:-120}
return_system=0

usage() {
    echo "usage: $0 --run [--return-system]" >&2
    exit 64
}

[ $# -ge 1 ] && [ $# -le 2 ] || usage
[ "$1" = --run ] || usage
if [ $# -eq 2 ]; then
    [ "$2" = --return-system ] || usage
    return_system=1
fi

adb_state() {
    adb devices 2>/dev/null | awk -v serial="$serial" '$1 == serial { print $2; exit }'
}

ssh_up() {
    timeout 4 ssh -o BatchMode=yes -o ConnectTimeout=2 -o StrictHostKeyChecking=yes \
        -o UserKnownHostsFile="$known_hosts" -p "$ssh_port" \
        "phablet@$ssh_host" true >/dev/null 2>&1
}

bcb_is_clear_in_recovery() {
    timeout 4 adb -s "$serial" shell \
        'dd if=/dev/block/by-name/misc bs=2048 count=1 2>/dev/null | sha256sum' \
        2>/dev/null | awk '$1 == "e5a00aa9991ac8a5ee3109844d84a55583bd20572ad3ffcd42792f3c36b183ad" { found=1 } END { exit !found }'
}

deadline=$(( $(date +%s) + timeout ))
echo 'arming recovery BCB and rebooting system'
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$known_hosts" -p "$ssh_port" \
    "phablet@$ssh_host" \
    'printf "\n" | sudo -S -k /userdata/rmx1901-autonomous/recovery-control recovery'

reset_sent=0
while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ "$(adb_state)" = recovery ]; then
        echo 'recovery ADB is ready'
        break
    fi
    if [ "$reset_sent" -eq 0 ] && lsusb -d 05c6:900e >/dev/null 2>&1; then
        helper_dir=$(mktemp -d -p /tmp rmx1901-sahara-reset.XXXXXXXX)
        trap 'rm -rf -- "$helper_dir"' EXIT HUP INT TERM
        cc -std=c11 -O2 -Wall -Wextra -Werror "$repo_root/scripts/sahara-reset.c" \
            -o "$helper_dir/sahara-reset" $(pkg-config --cflags --libs libusb-1.0)
        "$helper_dir/sahara-reset"
        reset_sent=1
    fi
    sleep 1
done

[ "$(adb_state)" = recovery ] || {
    echo "Recovery ADB did not appear within ${timeout}s" >&2
    exit 1
}

if [ "$return_system" -eq 0 ]; then
    exit 0
fi

while [ "$(date +%s)" -lt "$deadline" ]; do
    if bcb_is_clear_in_recovery; then
        echo 'Recovery has cleared the BCB'
        break
    fi
    sleep 1
done
bcb_is_clear_in_recovery || {
    echo "Recovery did not clear the BCB within ${timeout}s; refusing system reboot" >&2
    exit 1
}

echo 'rebooting Recovery back to system'
timeout 4 adb -s "$serial" reboot
deadline=$(( $(date +%s) + timeout ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    if ssh_up; then
        echo 'system SSH is ready'
        exit 0
    fi
    sleep 1
done
echo "system SSH did not return within ${timeout}s" >&2
exit 1
