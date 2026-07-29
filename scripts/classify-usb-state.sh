#!/usr/bin/env bash
# Classify RMX1901 USB facts without treating enumeration as SSH readiness.
set -euo pipefail

facts_file="${1:-}"
: "${PINNED_SSH_HOST_KEY:=}"

unknown() {
  printf 'state=unknown\nresult=fail\n' >&2
  exit 40
}

test "$#" -eq 1 || unknown
test -f "$facts_file" && test ! -L "$facts_file" || unknown
test "$(stat -Lc %s -- "$facts_file")" -le 16384 || unknown

readonly -a expected_keys=(
  ADB_STATE ADB_SERIAL ADB_PRODUCT ADB_MODEL ADB_DEVICE
  USB_VIDPID USB_PRODUCT TCP22_BANNER SSH_HOST_KEY SSH_AUTH
  TCP23_TELNET PID1_COMM PID1_EXE PID1_CMDLINE
)
declare -A facts seen

is_expected_key() {
  local candidate="$1" key
  for key in "${expected_keys[@]}"; do
    test "$candidate" = "$key" && return 0
  done
  return 1
}

while IFS= read -r line || test -n "$line"; do
  line="${line%$'\r'}"
  [[ "$line" == *=* ]] || unknown
  key="${line%%=*}"
  value="${line#*=}"
  [[ "$key" =~ ^[A-Z0-9_]+$ ]] || unknown
  is_expected_key "$key" || unknown
  test -z "${seen[$key]+x}" || unknown
  [[ "$value" != *$'\r'* && "$value" != *$'\n'* ]] || unknown
  facts["$key"]="$value"
  seen["$key"]=1
done <"$facts_file"

for key in "${expected_keys[@]}"; do
  test -n "${seen[$key]+x}" || unknown
done

empty() { test -z "${facts[$1]}"; }
all_empty() {
  local key
  for key in "$@"; do
    empty "$key" || return 1
  done
}
is_pinned_key() {
  test -n "$PINNED_SSH_HOST_KEY" && \
    test "${facts[SSH_HOST_KEY]}" = "$PINNED_SSH_HOST_KEY"
}

if test "${facts[ADB_STATE]}" = recovery && \
   test "${facts[ADB_SERIAL]}" = 7b0c1c49 && \
   test "${facts[ADB_PRODUCT]}" = fox_RMX1901 && \
   test "${facts[ADB_MODEL]}" = RMX1901 && \
   test "${facts[ADB_DEVICE]}" = RMX1901 && \
   all_empty USB_VIDPID USB_PRODUCT TCP22_BANNER SSH_HOST_KEY SSH_AUTH \
             TCP23_TELNET PID1_COMM PID1_EXE PID1_CMDLINE; then
  printf 'state=recovery\nresult=pass\n'
  exit 0
fi

if all_empty ADB_STATE ADB_SERIAL ADB_PRODUCT ADB_MODEL ADB_DEVICE \
             TCP22_BANNER SSH_HOST_KEY SSH_AUTH PID1_EXE && \
   test "${facts[USB_VIDPID]}" = 18d1:d001 && \
   test "${facts[USB_PRODUCT]}" = 'Failed to boot' && \
   test "${facts[TCP23_TELNET]}" = yes && \
   test "${facts[PID1_COMM]}" = sh && \
   test "${facts[PID1_CMDLINE]}" = '/bin/sh /init'; then
  printf 'state=panic\nresult=pass\n'
  exit 0
fi

if all_empty ADB_STATE ADB_SERIAL ADB_PRODUCT ADB_MODEL ADB_DEVICE \
             TCP23_TELNET PID1_COMM PID1_EXE PID1_CMDLINE && \
   test "${facts[USB_VIDPID]}" = 18d1:d001 && \
   test "${facts[USB_PRODUCT]}" = 'RMX1901 diagnostic bridge' && \
   test "${facts[TCP22_BANNER]}" = yes && \
   test -n "${facts[SSH_HOST_KEY]}" && \
   test "${facts[SSH_AUTH]}" = no; then
  printf 'state=diagnostic-ssh-candidate\nresult=pass\n'
  exit 0
fi

if all_empty ADB_STATE ADB_SERIAL ADB_PRODUCT ADB_MODEL ADB_DEVICE TCP23_TELNET && \
   test "${facts[USB_VIDPID]}" = 18d1:d001 && \
   test "${facts[USB_PRODUCT]}" = 'RMX1901 diagnostic bridge' && \
   test "${facts[TCP22_BANNER]}" = yes && \
   test "${facts[SSH_AUTH]}" = yes && \
   is_pinned_key && \
   test "${facts[PID1_COMM]}" = systemd && \
   test "${facts[PID1_EXE]}" = /usr/lib/systemd/systemd && \
   test "${facts[PID1_CMDLINE]}" = /usr/lib/systemd/systemd; then
  printf 'state=systemd-ssh\nresult=pass\n'
  exit 0
fi

if all_empty ADB_STATE ADB_SERIAL ADB_PRODUCT ADB_MODEL ADB_DEVICE TCP23_TELNET && \
   test "${facts[USB_VIDPID]}" = 18d1:d001 && \
   test "${facts[USB_PRODUCT]}" = 'RMX1901 diagnostic bridge' && \
   test "${facts[TCP22_BANNER]}" = yes && \
   test "${facts[SSH_AUTH]}" = yes && \
   is_pinned_key && \
   test "${facts[PID1_COMM]}" != systemd && \
   test -n "${facts[PID1_COMM]}" && \
   test "${facts[PID1_CMDLINE]}" = '/bin/sh /init'; then
  printf 'state=diagnostic-ssh\nresult=pass\n'
  exit 0
fi

unknown
