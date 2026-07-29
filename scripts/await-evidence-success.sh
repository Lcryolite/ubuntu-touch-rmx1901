#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'evidence_gate=fail reason=%s\n' "$1" >&2
  exit 1
}

positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

safe_mode() {
  local mode
  mode="$(stat -c '%a' -- "$1")" || return 1
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0022) == 0 ))
}

UNIT="${UNIT:-}"
RESULT_FILE="${RESULT_FILE:-}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-}"
SYSTEMCTL="${SYSTEMCTL:-systemctl}"
CLOCK="${CLOCK:-date}"
SLEEP="${SLEEP:-sleep}"
TIMEOUT="${TIMEOUT:-timeout}"
CALL_TIMEOUT="${CALL_TIMEOUT:-5}"
controlled_dir=/run/rmx1901-evidence

test -n "$UNIT" || fail missing_unit
positive_integer "$WAIT_TIMEOUT" || fail invalid_wait_timeout
positive_integer "$CALL_TIMEOUT" || fail invalid_call_timeout
case "$RESULT_FILE" in
  /run/rmx1901-evidence/*) ;;
  *) fail invalid_result_path ;;
esac
test -d "$controlled_dir" || fail missing_controlled_directory
test ! -L "$controlled_dir" || fail symlinked_controlled_directory
safe_mode "$controlled_dir" || fail unsafe_controlled_directory

canonical_dir="$(readlink -f -- "$controlled_dir")" || fail unresolved_controlled_directory
test "$canonical_dir" = "$controlled_dir" || fail redirected_controlled_directory
canonical_result="$(readlink -f -- "$RESULT_FILE")" || fail unresolved_result_path
test "$canonical_result" = "$RESULT_FILE" || fail noncanonical_result_path
test "$(dirname -- "$canonical_result")" = "$controlled_dir" || fail result_outside_controlled_directory

clock_now() {
  "$CLOCK" +%s
}

parse_snapshot() {
  local line key value seen_load=0 seen_active=0 seen_result=0 seen_status=0
  LOAD_STATE= ACTIVE_STATE= SERVICE_RESULT= EXEC_STATUS=
  while IFS= read -r line || test -n "$line"; do
    case "$line" in
      LoadState=*)
        (( seen_load == 0 )) || return 1
        LOAD_STATE="${line#LoadState=}"; seen_load=1 ;;
      ActiveState=*)
        (( seen_active == 0 )) || return 1
        ACTIVE_STATE="${line#ActiveState=}"; seen_active=1 ;;
      Result=*)
        (( seen_result == 0 )) || return 1
        SERVICE_RESULT="${line#Result=}"; seen_result=1 ;;
      ExecMainStatus=*)
        (( seen_status == 0 )) || return 1
        EXEC_STATUS="${line#ExecMainStatus=}"; seen_status=1 ;;
      *) return 1 ;;
    esac
  done <<<"$1"
  (( seen_load == 1 && seen_active == 1 && seen_result == 1 && seen_status == 1 ))
}

result_is_pass() {
  test -f "$RESULT_FILE" || return 1
  test ! -L "$RESULT_FILE" || return 1
  test "$(readlink -f -- "$RESULT_FILE")" = "$RESULT_FILE" || return 1
  safe_mode "$RESULT_FILE" || return 1
  test "$(wc -l <"$RESULT_FILE")" -eq 1 || return 1
  grep -Fxq 'result=pass' "$RESULT_FILE"
}

start="$(clock_now)" || fail invalid_clock
[[ "$start" =~ ^[0-9]+$ ]] || fail invalid_clock
deadline=$((start + WAIT_TIMEOUT))

while :; do
  snapshot="$($TIMEOUT --foreground "${CALL_TIMEOUT}s" "$SYSTEMCTL" --user show "$UNIT" \
    --property LoadState --property ActiveState --property Result --property ExecMainStatus)" || fail service_query_failed
  now="$(clock_now)" || fail invalid_clock
  [[ "$now" =~ ^[0-9]+$ ]] || fail invalid_clock
  (( now <= deadline )) || fail wait_timeout
  parse_snapshot "$snapshot" || fail malformed_service_snapshot
  test "$LOAD_STATE" = loaded || fail unexpected_load_state
  case "$ACTIVE_STATE" in
    active|activating)
      (( now < deadline )) || fail wait_timeout
      "$SLEEP" 1 || fail sleep_failed
      ;;
    inactive)
      test "$SERVICE_RESULT" = success || fail service_result_not_success
      test "$EXEC_STATUS" = 0 || fail service_status_not_zero
      result_is_pass || fail missing_or_invalid_pass_record
      printf 'evidence_gate=pass\n'
      exit 0
      ;;
    *) fail unexpected_active_state ;;
  esac
done
