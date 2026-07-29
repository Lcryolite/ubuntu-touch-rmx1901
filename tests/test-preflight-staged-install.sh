#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
production_preflight="$repo_root/scripts/preflight-staged-install.sh"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/rmx1901-preflight-test.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

test -x "$production_preflight"

tools="$tmp_root/tools"
mkdir -p "$tools"

cat >"$tools/timeout" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_TIMEOUT_CALLS"
test "$1" = --foreground
shift
case "$1" in
  *s) shift ;;
  *) exit 95 ;;
esac
exec "$@"
EOF

cat >"$tools/adb" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'adb %s\n' "$*" >>"$FAKE_TOOL_CALLS"
serial="${TEST_SERIAL:-RMX1901-TEST-SERIAL}"
case "$*" in
  devices)
    printf 'List of devices attached\n'
    case "${ADB_FIXTURE:-green}" in
      offline) printf '%s\toffline\n' "$serial" ;;
      unauthorized) printf '%s\tunauthorized\n' "$serial" ;;
      second) printf '%s\trecovery\nOTHER\trecovery\n' "$serial" ;;
      missing) ;;
      *) printf '%s\trecovery\n' "$serial" ;;
    esac
    ;;
  "-s $serial get-serialno")
    if test "${ADB_FIXTURE:-green}" = changed_identity; then
      printf 'CHANGED\n'
    else
      printf '%s\n' "$serial"
    fi
    ;;
  "-s $serial shell getprop ro.product.device")
    test "${ADB_FIXTURE:-green}" = wrong_product && printf 'OTHER\n' || printf 'RMX1901\n'
    ;;
  "-s $serial shell getprop ro.bootmode")
    test "${ADB_FIXTURE:-green}" = wrong_mode && printf 'normal\n' || printf 'recovery\n'
    ;;
  "-s $serial shell getprop ro.boot.vbmeta.device_state")
    test "${ADB_FIXTURE:-green}" = locked && printf 'locked\n' || printf 'unlocked\n'
    ;;
  "-s $serial shell cat /sys/class/power_supply/battery/capacity")
    test "${ADB_FIXTURE:-green}" = low_battery && printf '59\n' || printf '84\n'
    ;;
  "-s $serial shell readlink -f /dev/block/by-name")
    if test "${ADB_FIXTURE:-green}" = injected_by_name; then
      printf '/dev/block/platform/$(unsafe)/by-name\n'
    else
      printf '/dev/block/platform/soc/c0c4000.sdhci/by-name\n'
    fi
    ;;
  "-s $serial shell readlink -f /dev/block/platform/soc/c0c4000.sdhci/by-name/boot")
    if test "${ADB_FIXTURE:-green}" = bad_target; then
      count="$(cat "$FAKE_STATE" 2>/dev/null || printf 0)"
      count=$((count + 1))
      printf '%s\n' "$count" >"$FAKE_STATE"
      test "$count" -gt 1 && printf '/dev/block/sda99\n' || printf '/dev/block/sde11\n'
    else
      printf '/dev/block/sde11\n'
    fi
    ;;
  "-s $serial shell readlink -f /dev/block/platform/soc/c0c4000.sdhci/by-name/recovery") printf '/dev/block/sde12\n' ;;
  "-s $serial shell readlink -f /dev/block/platform/soc/c0c4000.sdhci/by-name/system") printf '/dev/block/sda18\n' ;;
  "-s $serial shell readlink -f /dev/block/platform/soc/c0c4000.sdhci/by-name/userdata") printf '/dev/block/sda21\n' ;;
  "-s $serial shell stat -Lc %t:%T /dev/block/sde11")
    if test "${ADB_FIXTURE:-green}" = changed_partition_identity; then
      count="$(cat "$FAKE_STATE.mm" 2>/dev/null || printf 0)"
      count=$((count + 1))
      printf '%s\n' "$count" >"$FAKE_STATE.mm"
      test "$count" -gt 1 && printf '8:6b\n' || printf '8:4b\n'
    else
      printf '8:4b\n'
    fi
    ;;
  "-s $serial shell stat -Lc %t:%T /dev/block/sda99") printf '8:63\n' ;;
  "-s $serial shell stat -Lc %t:%T /dev/block/sde12") printf '8:4c\n' ;;
  "-s $serial shell stat -Lc %t:%T /dev/block/sda18") printf '8:12\n' ;;
  "-s $serial shell stat -Lc %t:%T /dev/block/sda21") printf '8:15\n' ;;
  "-s $serial shell blockdev --getsize64 /dev/block/sde11")
    test "${ADB_FIXTURE:-green}" = bad_boot_size && printf '1\n' || printf '67108864\n'
    ;;
  "-s $serial shell blockdev --getsize64 /dev/block/sda99") printf '67108864\n' ;;
  "-s $serial shell blockdev --getsize64 /dev/block/sde12") printf '67108864\n' ;;
  "-s $serial shell blockdev --getsize64 /dev/block/sda18") printf '5213519872\n' ;;
  "-s $serial shell blockdev --getsize64 /dev/block/sda21") printf '118111600640\n' ;;
  "-s $serial shell blkid -s TYPE -o value /dev/block/sda21")
    if test "${ADB_FIXTURE:-green}" = missing_blkid; then
      exit 127
    elif test "${ADB_FIXTURE:-green}" = bad_fs; then
      printf 'exfat\n'
    else
      printf 'f2fs\n'
    fi
    ;;
  "-s $serial shell findmnt -n -o SOURCE,FSTYPE,OPTIONS /data")
    test "${ADB_FIXTURE:-green}" = unmounted && exit 1
    if test "${ADB_FIXTURE:-green}" = missing_findmnt; then
      printf '/system/bin/sh: findmnt: inaccessible or not found\n'
      exit 127
    elif test "${ADB_FIXTURE:-green}" = injected_mount_source; then
      printf '/dev/block/$(unsafe) f2fs rw,nosuid,nodev\n'
    elif test "${ADB_FIXTURE:-green}" = bad_fs; then
      printf '/dev/block/sda21 exfat rw,nosuid,nodev\n'
    else
      printf '/dev/block/sda21 f2fs rw,nosuid,nodev\n'
    fi
    ;;
  "-s $serial shell cat /proc/mounts")
    printf '/dev/block/sda21 /data f2fs rw,nosuid,nodev 0 0\n'
    ;;
  "-s $serial shell readlink -f /dev/block/sda21") printf '/dev/block/sda21\n' ;;
  "-s $serial reboot bootloader") ;;
  *) printf 'unexpected adb command: %s\n' "$*" >&2; exit 96 ;;
esac
EOF

cat >"$tools/fastboot" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'fastboot %s\n' "$*" >>"$FAKE_TOOL_CALLS"
serial="${TEST_SERIAL:-RMX1901-TEST-SERIAL}"
fastboot_serial="$serial"
test "${FASTBOOT_FIXTURE:-green}" = wrong_identity && fastboot_serial=OTHER
case "$*" in
  "-s $serial wait-for-device") ;;
  devices)
    printf '%s\tfastboot\n' "$fastboot_serial"
    if test "${FASTBOOT_FIXTURE:-green}" = second; then
      printf 'SECOND\tfastboot\n'
    fi
    ;;
  "-s $serial getvar serialno")
    if test "${FASTBOOT_FIXTURE:-green}" = decorated; then
      printf '(bootloader) serialno: %s\nFinished. Total time: 0.001s\n' "$fastboot_serial" >&2
    else
      printf 'serialno: %s\n' "$fastboot_serial" >&2
    fi
    ;;
  "-s $serial getvar product")
    if test "${FASTBOOT_FIXTURE:-green}" = wrong_product; then
      printf 'product: OTHER\n' >&2
    elif test "${FASTBOOT_FIXTURE:-green}" = decorated; then
      printf '(bootloader) product: RMX1901\nFinished. Total time: 0.001s\n' >&2
    else
      printf 'product: RMX1901\n' >&2
    fi
    ;;
  "-s $serial getvar unlocked")
    if test "${FASTBOOT_FIXTURE:-green}" = locked; then
      printf 'unlocked: no\n' >&2
    elif test "${FASTBOOT_FIXTURE:-green}" = decorated; then
      printf '(bootloader) unlocked: yes\nFinished. Total time: 0.001s\n' >&2
    else
      printf 'unlocked: yes\n' >&2
    fi
    ;;
  *) printf 'unexpected fastboot command: %s\n' "$*" >&2; exit 97 ;;
esac
EOF
chmod +x "$tools/timeout" "$tools/adb" "$tools/fastboot"

serial=RMX1901-TEST-SERIAL
serial_sha="$(printf %s "$serial" | sha256sum | awk '{print $1}')"
approved_sha=340fb6677be5dd42accc3813c0c3c0ed2c855f54976c12f4e8a1019a0db3ece6
test "$(grep -Foc "$approved_sha" "$production_preflight")" -eq 1
preflight="$tmp_root/preflight-staged-install.sh"
sed "s/$approved_sha/$serial_sha/" "$production_preflight" >"$preflight"
chmod +x "$preflight"
calls="$tmp_root/tool-calls"
timeout_calls="$tmp_root/timeout-calls"
state="$tmp_root/state"

run_preflight() {
  : >"$calls"
  : >"$timeout_calls"
  rm -f "$state"
  rm -f "$state.mm"
  env \
    ADB="$tools/adb" \
    FASTBOOT="$tools/fastboot" \
    TIMEOUT="$tools/timeout" \
    FAKE_TOOL_CALLS="$calls" \
    FAKE_TIMEOUT_CALLS="$timeout_calls" \
    FAKE_STATE="$state" \
    TEST_SERIAL="$serial" \
    ADB_SERIAL="$serial" \
    "$@" "$preflight"
}

# Only the explicit read-only mode may contact ADB.  In particular, the
# legacy EXECUTE=1 knob is not authorization to touch the device.
set +e
dry_output="$(run_preflight 2>&1)"
dry_status=$?
set -e
test "$dry_status" -ne 0
grep -Fqx 'error=MODE=readonly is required' <<<"$dry_output"
test ! -s "$calls"
test ! -s "$timeout_calls"

set +e
legacy_output="$(run_preflight EXECUTE=1 2>&1)"
legacy_status=$?
set -e
test "$legacy_status" -ne 0
grep -Fqx 'error=MODE=readonly is required' <<<"$legacy_output"
test ! -s "$calls"
test ! -s "$timeout_calls"

green_output="$(run_preflight MODE=readonly)"
for fact in \
  'mode=read-only' \
  'device=RMX1901' \
  'adb_mode=recovery' \
  'bootloader=unlocked' \
  'battery_percent=84' \
  'by_name=/dev/block/platform/soc/c0c4000.sdhci/by-name' \
  'boot=/dev/block/sde11 major_minor=8:4b capacity=67108864' \
  'recovery=/dev/block/sde12 major_minor=8:4c capacity=67108864' \
  'system=/dev/block/sda18 major_minor=8:12 capacity=5213519872' \
  'userdata=/dev/block/sda21 major_minor=8:15 capacity=118111600640' \
  'userdata_fs=f2fs' \
  'data_mount=mounted source=/dev/block/sda21 fs=f2fs options=rw,nosuid,nodev' \
  'identity_binding=pass' \
  'result=pass'; do
  grep -Fqx "$fact" <<<"$green_output"
done
test "$(wc -l <"$calls")" -eq "$(wc -l <"$timeout_calls")"

fallback_output="$(run_preflight MODE=readonly ADB_FIXTURE=missing_findmnt)"
grep -Fqx 'data_mount=mounted source=/dev/block/sda21 fs=f2fs options=rw,nosuid,nodev' <<<"$fallback_output"
grep -Fqx 'result=pass' <<<"$fallback_output"
grep -Fq 'shell cat /proc/mounts' "$calls"

missing_blkid_output="$(run_preflight MODE=readonly ADB_FIXTURE=missing_blkid)"
grep -Fqx 'userdata_fs=f2fs' <<<"$missing_blkid_output"
grep -Fqx 'data_mount=mounted source=/dev/block/sda21 fs=f2fs options=rw,nosuid,nodev' <<<"$missing_blkid_output"
grep -Fqx 'result=pass' <<<"$missing_blkid_output"

unmounted_output="$(run_preflight MODE=readonly ADB_FIXTURE=unmounted)"
grep -Fqx 'data_mount=unmounted' <<<"$unmounted_output"
grep -Fqx 'result=pass' <<<"$unmounted_output"

assert_rejected() {
  local expected="$1"
  shift
  local output status
  set +e
  output="$(run_preflight MODE=readonly "$@" 2>&1)"
  status=$?
  set -e
  test "$status" -ne 0
  grep -Fq "$expected" <<<"$output"
  ! grep -Fqx 'result=pass' <<<"$output"
}

assert_rejected 'ADB target is not uniquely present in recovery state' ADB_FIXTURE=offline
assert_rejected 'ADB target is not uniquely present in recovery state' ADB_FIXTURE=unauthorized
assert_rejected 'exactly one ADB transport is required' ADB_FIXTURE=second
assert_rejected 'ADB serial hash does not match the approved identity' ADB_SERIAL=OTHER
assert_rejected 'unexpected Android product' ADB_FIXTURE=wrong_product
assert_rejected 'device is not in recovery mode' ADB_FIXTURE=wrong_mode
assert_rejected 'bootloader is not unlocked' ADB_FIXTURE=locked
assert_rejected 'battery is below 60 percent' ADB_FIXTURE=low_battery
assert_rejected 'boot capacity mismatch' ADB_FIXTURE=bad_boot_size
assert_rejected 'boot canonical target changed' ADB_FIXTURE=bad_target
assert_rejected 'boot major:minor changed' ADB_FIXTURE=changed_partition_identity
assert_rejected 'canonical by-name directory is invalid' ADB_FIXTURE=injected_by_name
assert_rejected 'data mount source is invalid' ADB_FIXTURE=injected_mount_source
assert_rejected 'unsupported userdata filesystem' ADB_FIXTURE=bad_fs
assert_rejected 'ADB identity changed' ADB_FIXTURE=changed_identity
# A read-only gate must never issue a reboot, invoke fastboot, or include
# storage-mutating commands in its source or observed command record.
if grep -Ein '(^|[^[:alnum:]_])(reboot|fastboot|flash|erase|format|wipe|dd|blkdiscard)([^[:alnum:]_]|$)' "$production_preflight"; then
  echo 'preflight contains a forbidden state-changing command' >&2
  exit 1
fi
if rg -n '(^|[[:space:]])adb[[:space:]].*reboot|(^|[[:space:]])fastboot[[:space:]]' "$calls"; then
  echo 'read-only preflight invoked a forbidden transport command' >&2
  exit 1
fi

echo 'staged-install read-only preflight tests passed'
