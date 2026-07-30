#!/usr/bin/env bash
# Keep an unattended RMX1901 recoverable if an early boot failure exposes
# Qualcomm Sahara (05c6:900e) after the system-side controller has vanished.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
serial="${RMX1901_SERIAL:-7b0c1c49}"
poll_seconds="${RMX1901_SAHARA_GUARDIAN_POLL_SECONDS:-1}"
runtime_dir="${XDG_RUNTIME_DIR:-/tmp}"
lock_file="$runtime_dir/rmx1901-sahara-guardian.lock"
rollback_image="${RMX1901_ROLLBACK_IMAGE:-}"
expected_boot_sha256="${RMX1901_EXPECTED_BOOT_SHA256:-}"
hold_after_recovery="${RMX1901_HOLD_AFTER_RECOVERY:-0}"
recovery_evidence_dir="${RMX1901_RECOVERY_EVIDENCE_DIR:-}"
recovery_evidence_root="${RMX1901_RECOVERY_EVIDENCE_ROOT:-}"
require_recovery_departure="${RMX1901_REQUIRE_RECOVERY_DEPARTURE:-0}"

[[ "$poll_seconds" =~ ^[1-9][0-9]*$ ]] || {
    echo 'RMX1901_SAHARA_GUARDIAN_POLL_SECONDS must be a positive integer' >&2
    exit 2
}
[[ "$hold_after_recovery" == 0 || "$hold_after_recovery" == 1 ]] || {
    echo 'RMX1901_HOLD_AFTER_RECOVERY must be 0 or 1' >&2
    exit 2
}
[[ "$require_recovery_departure" == 0 || "$require_recovery_departure" == 1 ]] || {
    echo 'RMX1901_REQUIRE_RECOVERY_DEPARTURE must be 0 or 1' >&2
    exit 2
}
if [[ -n "$rollback_image" || -n "$expected_boot_sha256" ]]; then
    [[ -n "$rollback_image" && "$expected_boot_sha256" =~ ^[0-9a-f]{64}$ ]] || {
        echo 'RMX1901_ROLLBACK_IMAGE and a lowercase 64-character RMX1901_EXPECTED_BOOT_SHA256 are required together' >&2
        exit 2
    }
    rollback_image="$(realpath -e "$rollback_image")"
    [[ "$(stat -c %s "$rollback_image")" -eq 67108864 ]] || {
        echo 'rollback image must be exactly 67108864 bytes' >&2
        exit 2
    }
    rollback_sha256="$(sha256sum "$rollback_image" | awk '{print $1}')"
fi

exec 9>"$lock_file"
flock -n 9 || {
    echo 'another RMX1901 Sahara guardian is already running' >&2
    exit 0
}

helper_dir="$(mktemp -d -p /tmp rmx1901-sahara-guardian.XXXXXXXX)"
helper="$helper_dir/sahara-reset"
cc -std=c11 -O2 -Wall -Wextra -Werror "$repo_root/scripts/sahara-reset.c" \
    -o "$helper" $(pkg-config --cflags --libs libusb-1.0)

echo "RMX1901 Sahara guardian active for serial $serial"
if [[ "$hold_after_recovery" == 1 ]]; then
    echo 'Recovery hold mode is enabled; no rollback write or reboot will occur'
fi
if [[ -n "$recovery_evidence_dir" ]]; then
    [[ -z "$recovery_evidence_root" ]] || {
        echo 'RMX1901_RECOVERY_EVIDENCE_DIR and RMX1901_RECOVERY_EVIDENCE_ROOT are mutually exclusive' >&2
        exit 2
    }
    [[ ! -e "$recovery_evidence_dir" ]] || {
        echo "RMX1901_RECOVERY_EVIDENCE_DIR already exists: $recovery_evidence_dir" >&2
        exit 2
    }
    recovery_evidence_dir="$(realpath -m "$recovery_evidence_dir")"
    echo "Recovery evidence will be captured to $recovery_evidence_dir before any rollback"
fi
if [[ -n "$recovery_evidence_root" ]]; then
    recovery_evidence_root="$(realpath -e "$recovery_evidence_root")"
    [[ -d "$recovery_evidence_root" ]] || {
        echo 'RMX1901_RECOVERY_EVIDENCE_ROOT must be an existing directory' >&2
        exit 2
    }
    echo "Recovery evidence will be captured under $recovery_evidence_root before any rollback"
fi
rollback_if_expected_candidate() {
    [[ -n "$rollback_image" ]] || return 0
    current_sha256="$(adb -s "$serial" shell 'sha256sum /dev/block/by-name/boot' | awk 'NR == 1 { print $1 }')"
    if [[ "$current_sha256" != "$expected_boot_sha256" ]]; then
        echo "$(date -Is) Recovery boot hash $current_sha256 is not the pending candidate; no rollback"
        return 0
    fi
    echo "$(date -Is) pending candidate confirmed; restoring $rollback_sha256"
    adb -s "$serial" push "$rollback_image" /tmp/rmx1901-guardian-rollback.img
    restored_sha256="$(adb -s "$serial" shell 'set -e; dd if=/tmp/rmx1901-guardian-rollback.img of=/dev/block/by-name/boot bs=4M conv=fsync; sync; sha256sum /dev/block/by-name/boot' | awk 'END { print $1 }')"
    [[ "$restored_sha256" == "$rollback_sha256" ]] || {
        echo "$(date -Is) rollback readback mismatch: expected $rollback_sha256 got $restored_sha256" >&2
        return 1
    }
    echo "$(date -Is) rollback readback verified; rebooting system"
    adb -s "$serial" reboot
}

recovery_arrival_handled=0
recovery_departure_observed=$((1 - require_recovery_departure))
fastboot_recovery_attempted=0
recovery_capture_failures=0
while :; do
    if lsusb -d 05c6:900e >/dev/null 2>&1; then
        echo "$(date -Is) detected 05c6:900e; sending Sahara reset"
        if "$helper"; then
            echo "$(date -Is) Sahara reset completed"
        else
            echo "$(date -Is) Sahara reset attempt failed; will retry" >&2
        fi
        # Give the boot ROM time to disconnect before looking again.
        sleep 5
        continue
    fi

    # OrangeFox can first enumerate as 22d9:2765 without ADB.  Only a
    # fastboot transport bearing the RMX1901 serial is actionable: ask it once
    # to enter Recovery, then let the existing ADB evidence/rollback gate take
    # over.  A plain MTP/recovery enumeration is never written to.
    if lsusb -d 22d9:2765 >/dev/null 2>&1; then
        if [[ "$fastboot_recovery_attempted" == 0 ]] && \
            fastboot devices 2>/dev/null | awk -v serial="$serial" \
                '$1 == serial && $2 == "fastboot" { found = 1 } END { exit !found }'; then
            echo "$(date -Is) detected RMX1901 fastboot; requesting Recovery"
            if fastboot -s "$serial" reboot recovery; then
                fastboot_recovery_attempted=1
                echo "$(date -Is) fastboot Recovery request completed"
            else
                echo "$(date -Is) fastboot Recovery request failed; will retry" >&2
            fi
            sleep 5
            continue
        fi
    else
        fastboot_recovery_attempted=0
    fi

    # Recovery hold preserves an unattended but stable acquisition point for
    # evidence capture.  Otherwise only a hash-pinned pending rollback writes.
    if adb -s "$serial" get-state 2>/dev/null | grep -qx recovery; then
        echo "$(date -Is) Recovery ADB is available"
        if [[ "$recovery_departure_observed" == 0 ]]; then
            echo "$(date -Is) waiting for the armed candidate to leave pre-existing Recovery"
            sleep 5
            continue
        fi
        if [[ "$recovery_arrival_handled" == 1 ]]; then
            sleep 5
            continue
        fi
        recovery_arrival_handled=1
        if [[ -n "$recovery_evidence_dir" || -n "$recovery_evidence_root" ]]; then
            capture_dir="$recovery_evidence_dir"
            if [[ -n "$recovery_evidence_root" ]]; then
                capture_dir="$recovery_evidence_root/$(date -u +%Y%m%dT%H%M%SZ)-boot-${expected_boot_sha256:-unknown}"
            fi
            echo "$(date -Is) capturing Recovery evidence before rollback"
            if "$repo_root/scripts/rmx1901-capture-recovery-evidence.sh" \
                --serial "$serial" --out "$capture_dir"; then
                echo "$(date -Is) Recovery evidence capture completed"
                recovery_capture_failures=0
            else
                # ADB can transiently lose a block pull immediately after
                # Recovery appears.  Do not write without complete evidence,
                # but also do not leave an unattended device stuck forever.
                recovery_capture_failures=$((recovery_capture_failures + 1))
                recovery_arrival_handled=0
                retry_seconds=$((recovery_capture_failures * 5))
                (( retry_seconds <= 30 )) || retry_seconds=30
                echo "$(date -Is) Recovery evidence capture failed; no write; retrying in ${retry_seconds}s" >&2
                sleep "$retry_seconds"
                continue
            fi
        fi
        if [[ "$hold_after_recovery" == 1 ]]; then
            sleep 5
        else
            rollback_if_expected_candidate
        fi
    else
        recovery_arrival_handled=0
        recovery_departure_observed=1
    fi
    sleep "$poll_seconds"
done
