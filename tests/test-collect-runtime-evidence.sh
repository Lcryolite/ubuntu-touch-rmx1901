#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
collector="$repo_root/scripts/collect-runtime-evidence.sh"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/runtime-evidence-test.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

fake_tools="$tmp_root/fake tools"
fake_adb="$fake_tools/adb fixture"
mkdir -p "$fake_tools"
cat >"$fake_adb" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"$FAKE_ADB_CALLS"
case "$*" in
  wait-for-device)
    ;;
  'logcat -b all -d')
    test "${FAKE_ADB_FAIL:-}" != logcat || exit 42
    printf 'logcat fixture\n'
    ;;
  'shell dmesg')
    test "${FAKE_ADB_FAIL:-}" != dmesg || exit 43
    printf 'dmesg fixture\n'
    ;;
  'shell cat /sys/fs/pstore/console-ramoops 2>/dev/null || true')
    printf 'pstore fixture\n'
    ;;
  *)
    printf 'unexpected or unsafe adb request: %s\n' "$*" >&2
    exit 97
    ;;
esac
EOF
chmod +x "$fake_adb"

out="$tmp_root/runtime evidence"
calls="$tmp_root/adb-calls.txt"
ADB="$fake_adb" FAKE_ADB_CALLS="$calls" "$collector" "$out"

expected_calls="$tmp_root/expected-adb-calls.txt"
printf '%s\n' \
  'wait-for-device' \
  'logcat -b all -d' \
  'shell dmesg' \
  'shell cat /sys/fs/pstore/console-ramoops 2>/dev/null || true' \
  >"$expected_calls"
cmp "$expected_calls" "$calls"
test "$(cat "$out/logcat.txt")" = 'logcat fixture'
test "$(cat "$out/dmesg.txt")" = 'dmesg fixture'
test "$(cat "$out/pstore.txt")" = 'pstore fixture'

failure_out="$tmp_root/partial runtime evidence"
failure_calls="$tmp_root/partial-adb-calls.txt"
set +e
ADB="$fake_adb" \
FAKE_ADB_CALLS="$failure_calls" \
FAKE_ADB_FAIL=logcat \
  "$collector" "$failure_out"
failure_status=$?
set -e
test "$failure_status" -eq 42
printf '%s\n' \
  'wait-for-device' \
  'logcat -b all -d' \
  >"$tmp_root/expected-failure-calls.txt"
cmp "$tmp_root/expected-failure-calls.txt" "$failure_calls"
test -f "$failure_out/logcat.txt"
test ! -s "$failure_out/logcat.txt"
test ! -e "$failure_out/dmesg.txt"
test ! -e "$failure_out/pstore.txt"

set +e
missing_output="$(ADB="$tmp_root/missing-adb" "$collector" "$tmp_root/missing-adb-out" 2>&1)"
missing_status=$?
set -e
test "$missing_status" -eq 1
test "$missing_output" = 'adb executable is missing'

echo "runtime evidence collector behavior tests passed"
