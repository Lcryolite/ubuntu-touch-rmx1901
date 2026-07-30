#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tool="$root/scripts/rmx1901-autorecover.sh"
guardian="$root/scripts/rmx1901-sahara-guardian.sh"
capture="$root/scripts/rmx1901-capture-recovery-evidence.sh"

sh -n "$tool"
test -x "$guardian"
bash -n "$guardian"
test -x "$capture"
bash -n "$capture"
if "$tool" >/dev/null 2>&1; then
    echo 'autorecover accepted a missing mode unexpectedly' >&2
    exit 1
fi
grep -Fq 'recovery-control recovery' "$tool"
grep -Fq 'lsusb -d 05c6:900e' "$tool"
grep -Fq 'sahara-reset.c' "$tool"
grep -Fq 'adb -s "$serial" reboot' "$tool"
grep -Fq 'lsusb -d 05c6:900e' "$guardian"
grep -Fq 'lsusb -d 22d9:2765' "$guardian"
grep -Fq 'fastboot -s "$serial" reboot recovery' "$guardian"
grep -Fq 'fastboot_recovery_attempted=0' "$guardian"
grep -Fq 'flock -n 9' "$guardian"
grep -Fq 'RMX1901_ROLLBACK_IMAGE' "$guardian"
grep -Fq 'RMX1901_EXPECTED_BOOT_SHA256' "$guardian"
grep -Fq 'RMX1901_HOLD_AFTER_RECOVERY' "$guardian"
grep -Fq 'Recovery hold mode is enabled' "$guardian"
grep -Fq 'RMX1901_RECOVERY_EVIDENCE_DIR' "$guardian"
grep -Fq 'RMX1901_RECOVERY_EVIDENCE_ROOT' "$guardian"
grep -Fq 'RMX1901_REQUIRE_RECOVERY_DEPARTURE' "$guardian"
grep -Fq 'waiting for the armed candidate to leave pre-existing Recovery' "$guardian"
grep -Fq 'capturing Recovery evidence before rollback' "$guardian"
grep -Fq 'rmx1901-capture-recovery-evidence.sh' "$guardian"
grep -Fq 'Recovery evidence capture failed; no write; retrying in ${retry_seconds}s' "$guardian"
grep -Fq 'recovery_arrival_handled=0' "$guardian"
grep -Fq 'pending candidate confirmed' "$guardian"
grep -Fq 'rollback readback verified; rebooting system' "$guardian"
grep -Fq 'expected exactly one 05c6:900e device' "$root/scripts/sahara-reset.c"
grep -Fq 'capture_block rawdump required' "$capture"
grep -Fq 'capture_block logdump optional' "$capture"
grep -Fq 'capture_block logfs optional' "$capture"
grep -Fq 'optional Recovery block pull failed' "$capture"
grep -Fq 'optional Recovery block size mismatch' "$capture"
grep -Fq 'capture_block boot required' "$capture"
grep -Fq 'capture_block misc required' "$capture"
grep -Fq 'adb exec-out truncates long Recovery streams' "$capture"
grep -Fq 'adb -s "$serial" pull "$path" "$image"' "$capture"
grep -Fq 'dd if=' "$capture"
grep -Fq 'capture size mismatch: expected $bytes got $actual' "$capture"

echo 'RMX1901 autorecover source gate passed'
