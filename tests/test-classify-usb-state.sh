#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
classifier="$repo_root/scripts/classify-usb-state.sh"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/rmx1901-usb-state-test.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

test -x "$classifier"

write_facts() {
  local destination="$1"
  shift
  printf '%s\n' "$@" >"$destination"
}

base_facts() {
  printf '%s\n' \
    'ADB_STATE=' 'ADB_SERIAL=' 'ADB_PRODUCT=' 'ADB_MODEL=' 'ADB_DEVICE=' \
    'USB_VIDPID=' 'USB_PRODUCT=' 'TCP22_BANNER=' 'SSH_HOST_KEY=' 'SSH_AUTH=' \
    'TCP23_TELNET=' 'PID1_COMM=' 'PID1_EXE=' 'PID1_CMDLINE='
}

run_known() {
  local expected="$1" facts="$2"
  local output
  output="$(PINNED_SSH_HOST_KEY='SHA256:pinned-rmx1901-key' "$classifier" "$facts")"
  test "$output" = $'state='"$expected"$'\nresult=pass'
}

run_unknown() {
  local facts="$1"
  local output status
  set +e
  output="$(PINNED_SSH_HOST_KEY='SHA256:pinned-rmx1901-key' "$classifier" "$facts" 2>&1)"
  status=$?
  set -e
  test "$status" -eq 40
  test "$output" = $'state=unknown\nresult=fail'
}

make_case() {
  local destination="$1"
  shift
  base_facts >"$destination"
  local replacement key scratch="$tmp_root/scratch"
  for replacement in "$@"; do
    key="${replacement%%=*}"
    awk -v key="$key" -v replacement="$replacement" \
      'index($0, key "=") == 1 {$0 = replacement} {print}' \
      "$destination" >"$scratch"
    mv -- "$scratch" "$destination"
  done
}

facts="$tmp_root/facts.env"
make_case "$facts" \
  'ADB_STATE=recovery' 'ADB_SERIAL=7b0c1c49' 'ADB_PRODUCT=fox_RMX1901' \
  'ADB_MODEL=RMX1901' 'ADB_DEVICE=RMX1901'
run_known recovery "$facts"

make_case "$facts" \
  'USB_VIDPID=18d1:d001' 'USB_PRODUCT=Failed to boot' 'TCP23_TELNET=yes' \
  'PID1_COMM=sh' 'PID1_CMDLINE=/bin/sh /init'
run_known panic "$facts"

make_case "$facts" \
  'USB_VIDPID=18d1:d001' 'USB_PRODUCT=RMX1901 diagnostic bridge' \
  'TCP22_BANNER=yes' 'SSH_HOST_KEY=SHA256:pinned-rmx1901-key' 'SSH_AUTH=no'
run_known diagnostic-ssh-candidate "$facts"

make_case "$facts" \
  'USB_VIDPID=18d1:d001' 'USB_PRODUCT=RMX1901 diagnostic bridge' \
  'TCP22_BANNER=yes' 'SSH_HOST_KEY=SHA256:pinned-rmx1901-key' 'SSH_AUTH=yes' \
  'PID1_COMM=sh' 'PID1_CMDLINE=/bin/sh /init'
run_known diagnostic-ssh "$facts"

make_case "$facts" \
  'USB_VIDPID=18d1:d001' 'USB_PRODUCT=RMX1901 diagnostic bridge' \
  'TCP22_BANNER=yes' 'SSH_HOST_KEY=SHA256:pinned-rmx1901-key' 'SSH_AUTH=yes' \
  'PID1_COMM=systemd' 'PID1_EXE=/usr/lib/systemd/systemd' \
  'PID1_CMDLINE=/usr/lib/systemd/systemd'
run_known systemd-ssh "$facts"

# Same VID:PID, ping-like facts, incomplete SSH, and overlaps must fail closed.
make_case "$facts" 'USB_VIDPID=18d1:d001'
run_unknown "$facts"
make_case "$facts" 'USB_PRODUCT=RMX1901 diagnostic bridge' 'TCP22_BANNER=yes'
run_unknown "$facts"
make_case "$facts" \
  'USB_VIDPID=18d1:d001' 'USB_PRODUCT=RMX1901 diagnostic bridge' \
  'TCP22_BANNER=yes' 'SSH_HOST_KEY=' 'SSH_AUTH=no'
run_unknown "$facts"
make_case "$facts" \
  'USB_VIDPID=18d1:d001' 'USB_PRODUCT=RMX1901 diagnostic bridge' \
  'TCP22_BANNER=yes' 'SSH_HOST_KEY=wrong-key' 'SSH_AUTH=yes' \
  'PID1_COMM=sh' 'PID1_CMDLINE=/bin/sh /init'
run_unknown "$facts"
make_case "$facts" \
  'USB_VIDPID=18d1:d001' 'USB_PRODUCT=Failed to boot' 'TCP22_BANNER=yes' \
  'TCP23_TELNET=yes' 'PID1_COMM=sh' 'PID1_CMDLINE=/bin/sh /init'
run_unknown "$facts"
make_case "$facts" \
  'USB_VIDPID=18d1:d001' 'USB_PRODUCT=usb-moded rescue' 'TCP22_BANNER=yes' \
  'SSH_HOST_KEY=SHA256:pinned-rmx1901-key' 'SSH_AUTH=no'
run_unknown "$facts"

# Parser boundaries: duplicate/unknown/malformed, CRLF, no final newline, symlink, size.
make_case "$facts" \
  'USB_VIDPID=18d1:d001' 'USB_PRODUCT=RMX1901 diagnostic bridge' \
  'TCP22_BANNER=yes' 'SSH_HOST_KEY=SHA256:pinned-rmx1901-key' 'SSH_AUTH=no'
printf 'SSH_AUTH=no\n' >>"$facts"
run_unknown "$facts"
write_facts "$facts" 'ADB_STATE=recovery'
run_unknown "$facts"
base_facts >"$facts"
printf 'NOT_A_FACT=value\n' >>"$facts"
run_unknown "$facts"
base_facts >"$facts"
printf 'malformed\n' >>"$facts"
run_unknown "$facts"
make_case "$facts" \
  'USB_VIDPID=18d1:d001' 'USB_PRODUCT=RMX1901 diagnostic bridge' \
  'TCP22_BANNER=yes' 'SSH_HOST_KEY=SHA256:pinned-rmx1901-key' 'SSH_AUTH=no'
sed 's/$/\r/' "$facts" >"$tmp_root/crlf.env"
run_known diagnostic-ssh-candidate "$tmp_root/crlf.env"
head -c -1 "$facts" >"$tmp_root/no-newline.env"
run_known diagnostic-ssh-candidate "$tmp_root/no-newline.env"
ln -s "$facts" "$tmp_root/facts-link.env"
run_unknown "$tmp_root/facts-link.env"
base_facts >"$facts"
truncate -s 16385 "$facts"
run_unknown "$facts"

! rg -n 'source |eval |ping.*state=|18d1:d001.*result=pass|ssh[[:space:]]' "$classifier"
echo 'USB state classifier tests passed'
