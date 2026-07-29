#!/usr/bin/env bash
set -euo pipefail

adb_bin="${ADB:-adb}"
timeout_bin="${TIMEOUT:-timeout}"
step_timeout="${STEP_TIMEOUT:-10}"
mode="${MODE:-}"
adb_serial="${ADB_SERIAL:-}"
expected_device_sha256='340fb6677be5dd42accc3813c0c3c0ed2c855f54976c12f4e8a1019a0db3ece6'

fail() {
  printf 'result=fail\n' >&2
  printf 'error=%s\n' "$1" >&2
  exit 1
}

trim_output() {
  tr -d '\r' | sed -e 's/[[:space:]]*$//'
}

safe_block_path() {
  local path="$1"
  [[ "$path" =~ ^/dev/block/[[:alnum:]_.:/-]+$ ]] || return 1
  case "$path" in
    *//*|*/./*|*/../*|*/.|*/..) return 1 ;;
  esac
}

test "$mode" = readonly || fail 'MODE=readonly is required'

test -n "$adb_serial" || fail 'ADB_SERIAL is required'
[[ "$step_timeout" =~ ^[1-9][0-9]*$ ]] || fail 'STEP_TIMEOUT must be a positive integer'
[[ "$expected_device_sha256" =~ ^[0-9a-f]{64}$ ]] || fail 'EXPECTED_DEVICE_SHA256 must be lowercase SHA-256'
command -v "$adb_bin" >/dev/null 2>&1 || fail 'adb executable is missing'
command -v "$timeout_bin" >/dev/null 2>&1 || fail 'timeout executable is missing'

serial_sha256="$(printf %s "$adb_serial" | sha256sum | awk '{print $1}')"
test "$serial_sha256" = "$expected_device_sha256" || fail 'ADB serial hash does not match the approved identity'

run_adb() {
  "$timeout_bin" --foreground "${step_timeout}s" "$adb_bin" -s "$adb_serial" "$@"
}

run_adb_transport() {
  "$timeout_bin" --foreground "${step_timeout}s" "$adb_bin" "$@"
}

assert_adb_transport() {
  local listing rows count state
  listing="$(run_adb_transport devices | trim_output)" || fail 'ADB transport query failed or timed out'
  rows="$(printf '%s\n' "$listing" | awk 'NR > 1 && NF {print $1, $2}')"
  count="$(printf '%s\n' "$rows" | awk 'NF {n++} END {print n+0}')"
  test "$count" -eq 1 || fail 'exactly one ADB transport is required'
  state="$(printf '%s\n' "$rows" | awk -v serial="$adb_serial" '$1 == serial {print $2}')"
  test "$state" = recovery || fail 'ADB target is not uniquely present in recovery state'
}

adb_value() {
  local value
  value="$(run_adb "$@" | trim_output)" || fail 'ADB fact query failed or timed out'
  test -n "$value" || fail 'ADB fact query returned no value'
  printf '%s\n' "$value"
}

assert_adb_transport
reported_serial="$(adb_value get-serialno)"
test "$reported_serial" = "$adb_serial" || fail 'ADB identity changed'

device="$(adb_value shell getprop ro.product.device)"
test "$device" = RMX1901 || fail 'unexpected Android product'
adb_mode="$(adb_value shell getprop ro.bootmode)"
test "$adb_mode" = recovery || fail 'device is not in recovery mode'
bootloader="$(adb_value shell getprop ro.boot.vbmeta.device_state)"
test "$bootloader" = unlocked || fail 'bootloader is not unlocked'
battery="$(adb_value shell cat /sys/class/power_supply/battery/capacity)"
[[ "$battery" =~ ^[0-9]+$ ]] || fail 'battery capacity is not numeric'
test "$battery" -ge 60 || fail 'battery is below 60 percent'

set +e
by_name="$(run_adb shell readlink -f /dev/block/by-name 2>/dev/null | trim_output)"
by_name_status=$?
set -e
if test "$by_name_status" -ne 0 || test -z "$by_name"; then
  by_name="$(adb_value shell readlink -f /dev/block/bootdevice/by-name)"
fi
safe_block_path "$by_name" || fail 'canonical by-name directory is invalid'
[[ "$by_name" =~ /by-name$ ]] || fail 'canonical by-name directory is invalid'

declare -A partition_target partition_mm partition_capacity
for name in boot recovery system userdata; do
  target="$(adb_value shell readlink -f "$by_name/$name")"
  safe_block_path "$target" || fail "$name canonical target is invalid"
  mm="$(adb_value shell stat -Lc %t:%T "$target")"
  [[ "$mm" =~ ^[0-9a-fA-F]+:[0-9a-fA-F]+$ ]] || fail "$name major:minor is invalid"
  capacity="$(adb_value shell blockdev --getsize64 "$target")"
  [[ "$capacity" =~ ^[1-9][0-9]*$ ]] || fail "$name capacity is invalid"
  partition_target[$name]="$target"
  partition_mm[$name]="$mm"
  partition_capacity[$name]="$capacity"
done

test "${partition_capacity[boot]}" -eq 67108864 || fail 'boot capacity mismatch'
test "${partition_capacity[recovery]}" -eq 67108864 || fail 'recovery capacity mismatch'
test "${partition_capacity[system]}" -eq 5213519872 || fail 'system capacity mismatch'

for first in boot recovery system userdata; do
  for second in boot recovery system userdata; do
    test "$first" = "$second" && continue
    test "${partition_mm[$first]}" != "${partition_mm[$second]}" || fail 'partition identities are not unique'
  done
done

set +e
userdata_fs_probe="$(run_adb shell blkid -s TYPE -o value "${partition_target[userdata]}" 2>/dev/null | trim_output)"
userdata_fs_probe_status=$?
set -e
case "$userdata_fs_probe_status" in
  0)
    case "$userdata_fs_probe" in
      ext4|f2fs) ;;
      *) fail 'unsupported userdata filesystem' ;;
    esac
    ;;
  127) userdata_fs_probe='' ;;
  *) fail 'userdata filesystem query failed or timed out' ;;
esac

set +e
mount_line="$(run_adb shell findmnt -n -o SOURCE,FSTYPE,OPTIONS /data | trim_output)"
mount_status=$?
set -e
if test "$mount_status" -eq 127 || { [[ "$mount_line" == *findmnt:* ]] && \
   { [[ "$mount_line" == *inaccessible* ]] || [[ "$mount_line" == *"not found"* ]]; }; }; then
  mount_table="$(run_adb shell cat /proc/mounts | trim_output)" || fail 'proc mounts fallback query failed or timed out'
  mount_line="$(awk '$2 == "/data" { print $1, $3, $4; exit }' <<<"$mount_table")"
  if test -n "$mount_line"; then
    mount_status=0
  else
    mount_status=1
  fi
fi
if test "$mount_status" -eq 1; then
  test -n "$userdata_fs_probe" || fail 'userdata filesystem cannot be proven while /data is unmounted'
  userdata_fs="$userdata_fs_probe"
  data_mount='unmounted'
elif test "$mount_status" -ne 0; then
  fail 'data mount query failed or timed out'
else
  read -r mount_source mount_fs mount_options extra <<<"$mount_line"
  test -z "${extra:-}" && test -n "${mount_options:-}" || fail 'data mount facts are malformed'
  safe_block_path "$mount_source" || fail 'data mount source is invalid'
  mount_source="$(adb_value shell readlink -f "$mount_source")"
  test "$mount_source" = "${partition_target[userdata]}" || fail 'data mount source differs from userdata'
  case "$mount_fs" in
    ext4|f2fs) ;;
    *) fail 'unsupported userdata filesystem' ;;
  esac
  test -z "$userdata_fs_probe" || test "$mount_fs" = "$userdata_fs_probe" \
    || fail 'data mount filesystem differs from userdata'
  userdata_fs="$mount_fs"
  data_mount="mounted source=$mount_source fs=$mount_fs options=$mount_options"
fi

reported_serial="$(adb_value get-serialno)"
test "$reported_serial" = "$adb_serial" || fail 'ADB identity changed'
assert_adb_transport
for name in boot recovery system userdata; do
  current_target="$(adb_value shell readlink -f "$by_name/$name")"
  test "$current_target" = "${partition_target[$name]}" || fail "$name canonical target changed"
  current_mm="$(adb_value shell stat -Lc %t:%T "$current_target")"
  test "$current_mm" = "${partition_mm[$name]}" || fail "$name major:minor changed"
  current_capacity="$(adb_value shell blockdev --getsize64 "$current_target")"
  test "$current_capacity" = "${partition_capacity[$name]}" || fail "$name capacity changed"
done

printf 'mode=read-only\n'
printf 'device=%s\n' "$device"
printf 'adb_mode=%s\n' "$adb_mode"
printf 'bootloader=%s\n' "$bootloader"
printf 'battery_percent=%s\n' "$battery"
printf 'device_sha256=%s\n' "$serial_sha256"
printf 'by_name=%s\n' "$by_name"
for name in boot recovery system userdata; do
  printf '%s=%s major_minor=%s capacity=%s\n' \
    "$name" "${partition_target[$name]}" "${partition_mm[$name]}" "${partition_capacity[$name]}"
done
printf 'userdata_fs=%s\n' "$userdata_fs"
printf 'data_mount=%s\n' "$data_mount"
printf 'identity_binding=pass\n'
printf 'result=pass\n'
