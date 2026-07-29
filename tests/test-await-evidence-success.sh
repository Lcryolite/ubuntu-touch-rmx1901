#!/usr/bin/env bash
set -euo pipefail

if test "${RMX1901_EVIDENCE_TEST_NAMESPACE:-}" != 1; then
  exec unshare -Urmpf --mount-proc env RMX1901_EVIDENCE_TEST_NAMESPACE=1 \
    PATH="$PATH" bash "$0"
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
production="$repo_root/scripts/await-evidence-success.sh"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/rmx1901-evidence-gate.XXXXXX")"
trap 'rm -rf -- "$tmp_root"' EXIT

mount -t tmpfs tmpfs /run
mkdir -p /run/rmx1901-evidence
chmod 700 /run/rmx1901-evidence
tools="$tmp_root/tools"
mkdir -p "$tools"
: >"$tmp_root/calls"

cat >"$tools/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'systemctl %s\n' "$*" >>"$FAKE_CALLS"
state_file="$FAKE_STATE/systemctl-count"
count="$(cat "$state_file" 2>/dev/null || printf 0)"
count=$((count + 1))
printf '%s\n' "$count" >"$state_file"
if test "${EVIDENCE_FIXTURE:-success}" = call_timeout; then
  sleep 3
fi
case "${EVIDENCE_FIXTURE:-success}:$count" in
  success:1|early_pass_disappears:1)
    printf 'LoadState=loaded\nActiveState=active\nResult=success\nExecMainStatus=0\n'
    ;;
  success:*|early_pass_disappears:*)
    test "${EVIDENCE_FIXTURE:-success}" != early_pass_disappears || rm -f -- "$RESULT_FILE"
    printf 'LoadState=loaded\nActiveState=inactive\nResult=success\nExecMainStatus=0\n'
    ;;
  result_failure:*) printf 'LoadState=loaded\nActiveState=inactive\nResult=exit-code\nExecMainStatus=1\n' ;;
  status_failure:*) printf 'LoadState=loaded\nActiveState=inactive\nResult=success\nExecMainStatus=1\n' ;;
  no_result:*) printf 'LoadState=loaded\nActiveState=inactive\nResult=success\nExecMainStatus=0\n' ;;
  not_found:*) printf 'LoadState=not-found\nActiveState=inactive\nResult=success\nExecMainStatus=0\n' ;;
  failed_state:*) printf 'LoadState=loaded\nActiveState=failed\nResult=success\nExecMainStatus=0\n' ;;
  deactivating_state:*) printf 'LoadState=loaded\nActiveState=deactivating\nResult=success\nExecMainStatus=0\n' ;;
  unknown_state:*) printf 'LoadState=loaded\nActiveState=unknown\nResult=success\nExecMainStatus=0\n' ;;
  active_timeout:*) printf 'LoadState=loaded\nActiveState=active\nResult=success\nExecMainStatus=0\n' ;;
  malformed:*) printf 'LoadState=loaded\nActiveState=inactive\nResult=success\nExecMainStatus=0\nResult=success\n' ;;
  unknown_property:*) printf 'LoadState=loaded\nActiveState=inactive\nResult=success\nExecMainStatus=0\nNoise=x\n' ;;
  *) printf 'unexpected fixture\n' >&2; exit 98 ;;
esac
EOF

cat >"$tools/clock" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_file="$FAKE_STATE/clock-count"
count="$(cat "$state_file" 2>/dev/null || printf 0)"
count=$((count + 1))
printf '%s\n' "$count" >"$state_file"
sed -n "${count}p" "$FAKE_CLOCK_VALUES"
EOF

cat >"$tools/sleep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'sleep %s\n' "$*" >>"$FAKE_CALLS"
EOF
chmod +x "$tools/systemctl" "$tools/clock" "$tools/sleep"

test -x "$production"

run_case() {
  local name="$1" result_contents="${2-}" timeout_value="${3-3}" result_path="${4-/run/rmx1901-evidence/result.env}"
  local output status
  rm -rf -- "$tmp_root/state"
  mkdir -p "$tmp_root/state"
  : >"$tmp_root/calls"
  rm -f -- /run/rmx1901-evidence/result.env
  if test -n "$result_contents"; then
    printf '%b' "$result_contents" >/run/rmx1901-evidence/result.env
  fi
  printf '0\n0\n1\n2\n3\n4\n5\n' >"$tmp_root/clock-values"
  set +e
  output="$(FAKE_CALLS="$tmp_root/calls" FAKE_STATE="$tmp_root/state" \
    FAKE_CLOCK_VALUES="$tmp_root/clock-values" EVIDENCE_FIXTURE="$name" \
    UNIT=rmx1901-evidence.service RESULT_FILE="$result_path" WAIT_TIMEOUT="$timeout_value" \
    SYSTEMCTL="$tools/systemctl" CLOCK="$tools/clock" SLEEP="$tools/sleep" CALL_TIMEOUT=1 \
    "$production" 2>&1)"
  status=$?
  set -e
  CASE_OUTPUT="$output"
  CASE_STATUS="$status"
}

assert_pass() {
  test "$CASE_STATUS" -eq 0
  test "$CASE_OUTPUT" = evidence_gate=pass
}

assert_fail() {
  test "$CASE_STATUS" -ne 0
  ! grep -Fxq evidence_gate=pass <<<"$CASE_OUTPUT"
}

run_case success 'result=pass\n'
assert_pass
grep -Fq 'sleep 1' "$tmp_root/calls"

for fixture in result_failure status_failure not_found failed_state deactivating_state unknown_state malformed unknown_property; do
  run_case "$fixture" 'result=pass\n'
  assert_fail
done

run_case no_result ''
assert_fail

for contents in '' 'result=fail\n' 'result=pass\nextra=x\n'; do
  run_case no_result "$contents"
  assert_fail
done

run_case active_timeout 'result=pass\n' 1
assert_fail

run_case early_pass_disappears 'result=pass\n'
assert_fail

run_case call_timeout 'result=pass\n' 3
assert_fail

for bad_timeout in '' 0 -1 nope; do
  run_case success 'result=pass\n' "$bad_timeout"
  assert_fail
  test ! -s "$tmp_root/calls"
done

run_case success 'result=pass\n' 3 relative-result.env
assert_fail
test ! -s "$tmp_root/calls"

ln -s /tmp /run/rmx1901-evidence/link.env
run_case success 'result=pass\n' 3 /run/rmx1901-evidence/link.env
assert_fail
rm -f -- /run/rmx1901-evidence/link.env

mkdir -p /run/other-evidence
chmod 700 /run/other-evidence
run_case success 'result=pass\n' 3 /run/other-evidence/result.env
assert_fail
test ! -s "$tmp_root/calls"

chmod 777 /run/rmx1901-evidence
run_case success 'result=pass\n'
assert_fail
chmod 700 /run/rmx1901-evidence

printf 'await_evidence_success=pass\n'
