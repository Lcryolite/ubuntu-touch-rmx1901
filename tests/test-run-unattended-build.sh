#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
controller="$repo_root/scripts/run-unattended-build.sh"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/unattended-build-test.XXXXXX")"
unrelated_supervisor=
unrelated_release=
cleanup_test() {
  test -z "$unrelated_release" || : >"$unrelated_release"
  if test -n "$unrelated_supervisor"; then
    wait "$unrelated_supervisor" 2>/dev/null || true
  fi
  rm -rf "$tmp_root"
}
trap cleanup_test EXIT

fake_attempt="$tmp_root/fake-attempt"
cat >"$fake_attempt" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
attempt=1
test ! -f "$FAKE_STATE" || attempt=$(( $(cat "$FAKE_STATE") + 1 ))
printf '%s\n' "$attempt" >"$FAKE_STATE"
printf '%s\n' "$HALIUM_JOBS" >>"$FAKE_JOBS"
ps -o pgid= -p "$$" | tr -d ' ' >"$ATTEMPT_OUTPUT_DIR/observed.pgid"
IFS=, read -r -a statuses <<<"$FAKE_STATUSES"
IFS=, read -r -a flagged <<<"$FAKE_FLAGGED"
status="${statuses[$((attempt - 1))]}"
if test "${flagged[$((attempt - 1))]}" = 1; then
  printf 'fixture resource pressure\n' >"$ATTEMPT_OUTPUT_DIR/resource-pressure.flag"
fi
if test "$status" -eq 0; then
  mkdir -p "$PORT_ROOT/artifacts/build"
  printf 'halium fixture\n' >"$PORT_ROOT/artifacts/build/halium-boot.img"
  printf 'system fixture\n' >"$PORT_ROOT/artifacts/build/system.img"
  (
    cd "$PORT_ROOT/artifacts/build"
    case "${FAKE_MANIFEST_MODE:-valid}" in
      valid)
        sha256sum halium-boot.img system.img >manifest.sha256
        ;;
      missing)
        sha256sum halium-boot.img >manifest.sha256
        ;;
      extra)
        printf 'extra fixture\n' >extra.img
        sha256sum halium-boot.img system.img extra.img >manifest.sha256
        ;;
      duplicate)
        sha256sum halium-boot.img halium-boot.img >manifest.sha256
        ;;
      uppercase)
        sha256sum halium-boot.img system.img | tr 'a-f' 'A-F' >manifest.sha256
        ;;
    esac
  )
fi
sleep 0.05
exit "$status"
EOF
chmod +x "$fake_attempt"

fake_monitor="$tmp_root/fake-monitor"
cat >"$fake_monitor" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
pgid="$1"
out="$2"
printf 'fixture telemetry for pgid %s\n' "$pgid" >"$out/telemetry.tsv"
test -z "${FAKE_GROUP_MEMBER_PID:-}" || printf '%s\n' "$FAKE_GROUP_MEMBER_PID" >"$out/build-group-pids.txt"
while kill -0 -- "-$pgid" 2>/dev/null; do sleep 0.01; done
EOF
chmod +x "$fake_monitor"

fake_ccache="$tmp_root/fake-ccache"
cat >"$fake_ccache" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
test "$1" = -s
printf 'cache fixture\n'
EOF
chmod +x "$fake_ccache"

fake_journal="$tmp_root/fake-journal"
cat >"$fake_journal" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_JOURNAL_CALLS"
if test -n "${FAKE_JOURNAL_TEXT:-}"; then
  printf '%s\n' "${FAKE_JOURNAL_TEXT/__BUILD_PGID__/$BUILD_PGID_FOR_JOURNAL}"
fi
EOF
chmod +x "$fake_journal"

run_case() {
  local name="$1"
  local statuses="$2"
  local flagged="$3"
  local expected_status="$4"
  local expected_jobs="$5"
  local case_root="$tmp_root/$name"
  mkdir -p "$case_root/port" "$case_root/halium"

  set +e
  HALIUM_ROOT="$case_root/halium" \
  PORT_ROOT="$case_root/port" \
  UNATTENDED_OUTPUT_DIR="$case_root/output" \
  BUILD_ATTEMPT_COMMAND="$fake_attempt" \
  MONITOR_COMMAND="$fake_monitor" \
  CCACHE_COMMAND="$fake_ccache" \
  JOURNAL_COMMAND="$fake_journal" \
  FAKE_STATE="$case_root/state" \
  FAKE_JOBS="$case_root/jobs" \
  FAKE_STATUSES="$statuses" \
  FAKE_FLAGGED="$flagged" \
  FAKE_MANIFEST_MODE="${FAKE_MANIFEST_MODE:-valid}" \
  FAKE_JOURNAL_CALLS="$case_root/journal-calls" \
    "$controller"
  status=$?
  set -e

  test "$status" -eq "$expected_status"
  expected="$case_root/expected-jobs"
  printf '%s' "$expected_jobs" >"$expected"
  cmp "$expected" "$case_root/jobs"
  test "$(find "$case_root/output" -mindepth 1 -maxdepth 1 -type d -name 'attempt-*' | wc -l)" \
    -eq "$(wc -l <"$expected")"
  for attempt_dir in "$case_root"/output/attempt-*; do
    test -s "$attempt_dir/status"
    test -f "$attempt_dir/build.log"
    test -s "$attempt_dir/telemetry.tsv"
    test -s "$attempt_dir/ccache-before.txt"
    test -s "$attempt_dir/ccache-after.txt"
    cmp "$attempt_dir/build.pgid" "$attempt_dir/observed.pgid"
    test "$(cat "$attempt_dir/build.supervisor-pid")" != "$(cat "$attempt_dir/build.pgid")"
    read -r handshake_pid handshake_pgid handshake_sid handshake_parent <"$attempt_dir/build.handshake"
    test "$handshake_pid" = "$handshake_pgid"
    test "$handshake_pid" = "$handshake_sid"
    test "$handshake_parent" = "$(cat "$attempt_dir/build.supervisor-pid")"
  done
  grep -F -- '--since' "$case_root/journal-calls" >/dev/null
}

run_case compile-error '1' '0' 1 $'16\n'
run_case supervisor-preserves-exit-seven '7' '0' 7 $'16\n'
run_case one-resource-retry '137,0' '1,0' 0 $'16\n12\n'
run_case two-resource-retries '137,137,0' '1,1,0' 0 $'16\n12\n8\n'
run_case exhausted-resources '137,137,137' '1,1,1' 137 $'16\n12\n8\n'
FAKE_MANIFEST_MODE=missing \
  run_case final-manifest-missing-image '0' '0' 65 $'16\n'
FAKE_MANIFEST_MODE=extra \
  run_case final-manifest-extra-image '0' '0' 65 $'16\n'
FAKE_MANIFEST_MODE=duplicate \
  run_case final-manifest-duplicate-image '0' '0' 65 $'16\n'
FAKE_MANIFEST_MODE=uppercase \
  run_case final-manifest-uppercase-digest '0' '0' 65 $'16\n'

# A killed PID is OOM retry evidence only when telemetry placed it in this build PGID.
case_root="$tmp_root/proven-oom"
mkdir -p "$case_root/port" "$case_root/halium"
FAKE_JOURNAL_TEXT='kernel: Out of memory: Killed process 9876 (cc1plus)' \
FAKE_GROUP_MEMBER_PID=9876 \
HALIUM_ROOT="$case_root/halium" PORT_ROOT="$case_root/port" \
UNATTENDED_OUTPUT_DIR="$case_root/output" BUILD_ATTEMPT_COMMAND="$fake_attempt" \
MONITOR_COMMAND="$fake_monitor" CCACHE_COMMAND="$fake_ccache" JOURNAL_COMMAND="$fake_journal" \
FAKE_STATE="$case_root/state" FAKE_JOBS="$case_root/jobs" FAKE_STATUSES='137,0' \
FAKE_FLAGGED='0,0' FAKE_JOURNAL_CALLS="$case_root/journal-calls" \
  "$controller"
test "$(cat "$case_root/jobs")" = $'16\n12'

# Unrelated records cannot be combined into proof for this build group.
case_root="$tmp_root/unrelated-oom-and-pgid"
mkdir -p "$case_root/port" "$case_root/halium"
set +e
FAKE_JOURNAL_TEXT=$'kernel: Out of memory: Killed process 1111 (other)\nkernel: diagnostic pgid=__BUILD_PGID__' \
FAKE_GROUP_MEMBER_PID=9876 \
HALIUM_ROOT="$case_root/halium" PORT_ROOT="$case_root/port" \
UNATTENDED_OUTPUT_DIR="$case_root/output" BUILD_ATTEMPT_COMMAND="$fake_attempt" \
MONITOR_COMMAND="$fake_monitor" CCACHE_COMMAND="$fake_ccache" JOURNAL_COMMAND="$fake_journal" \
FAKE_STATE="$case_root/state" FAKE_JOBS="$case_root/jobs" FAKE_STATUSES='137,0' \
FAKE_FLAGGED='0,0' FAKE_JOURNAL_CALLS="$case_root/journal-calls" \
  "$controller"
unrelated_status=$?
set -e
test "$unrelated_status" -eq 137
test "$(cat "$case_root/jobs")" = '16'

# An early monitor failure must interrupt and reap a still-running build supervisor.
long_attempt="$tmp_root/long-attempt"
cat >"$long_attempt" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ps -o pgid= -p "$$" | tr -d ' ' >"$ATTEMPT_OUTPUT_DIR/observed.pgid"
tick=0
while test "$tick" -lt 100; do
  tick=$((tick + 1))
  printf '%s\n' "$tick" >"$ATTEMPT_OUTPUT_DIR/ticks"
  test ! -f "$FAKE_CONTROL_DIR/TERM" || exit 7
  sleep 0.01
done
exit 99
EOF
chmod +x "$long_attempt"

early_monitor="$tmp_root/early-monitor"
cat >"$early_monitor" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'fixture telemetry\n' >"$2/telemetry.tsv"
: >"$2/build-paused.flag"
exit 42
EOF
chmod +x "$early_monitor"

controller_signal="$tmp_root/controller-signal"
cat >"$controller_signal" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_CONTROLLER_SIGNALS"
case "$1" in
  -CONT) : >"$FAKE_CONTROL_DIR/CONT" ;;
  -TERM) : >"$FAKE_CONTROL_DIR/TERM" ;;
esac
EOF
chmod +x "$controller_signal"

case_root="$tmp_root/monitor-died-first"
mkdir -p "$case_root/port" "$case_root/halium" "$case_root/control"
set +e
HALIUM_ROOT="$case_root/halium" PORT_ROOT="$case_root/port" \
UNATTENDED_OUTPUT_DIR="$case_root/output" BUILD_ATTEMPT_COMMAND="$long_attempt" \
MONITOR_COMMAND="$early_monitor" SIGNAL_COMMAND="$controller_signal" \
CCACHE_COMMAND="$fake_ccache" JOURNAL_COMMAND="$fake_journal" \
FAKE_CONTROL_DIR="$case_root/control" FAKE_CONTROLLER_SIGNALS="$case_root/signals" \
FAKE_JOURNAL_CALLS="$case_root/journal-calls" \
  "$controller"
monitor_first_status=$?
set -e
test "$monitor_first_status" -eq 70
test "$(cat "$case_root/output/attempt-1/status")" -eq 7
test "$(cat "$case_root/output/attempt-1/monitor-status")" -eq 42
test "$(cat "$case_root/output/attempt-1/ticks")" -lt 20
printf '%s\n' \
  "-CONT -- -$(cat "$case_root/output/attempt-1/build.pgid")" \
  "-TERM -- -$(cat "$case_root/output/attempt-1/build.pgid")" >"$case_root/expected-signals"
cmp "$case_root/expected-signals" "$case_root/signals"
test -s "$case_root/output/attempt-1/build.supervisor-pid"
test "$(cat "$case_root/output/attempt-1/build.supervisor-pid")" != \
  "$(cat "$case_root/output/attempt-1/build.pgid")"
test ! -e "$case_root/output/attempt-1/build-paused.flag"

holding_monitor="$tmp_root/holding-monitor"
cat >"$holding_monitor" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
pgid="$1"
out="$2"
printf 'fixture telemetry\n' >"$out/telemetry.tsv"
: >"$out/build-paused.flag"
while kill -0 -- "-$pgid" 2>/dev/null; do sleep 0.01; done
EOF
chmod +x "$holding_monitor"

signal_driver="$tmp_root/signal-driver.py"
cat >"$signal_driver" <<'EOF'
#!/usr/bin/env python3
import os
import signal
import subprocess
import sys
import time

child = subprocess.Popen([os.environ["CONTROLLER_COMMAND"]], env=os.environ.copy())
deadline = time.monotonic() + float(os.environ.get("DRIVER_TIMEOUT", "5"))
while not os.path.isfile(os.environ["READY_FILE"]):
    if child.poll() is not None:
        sys.exit(child.returncode)
    if time.monotonic() >= deadline:
        child.terminate()
        child.wait()
        sys.exit(125)
    time.sleep(0.005)
os.kill(child.pid, getattr(signal, "SIG" + os.environ["SIGNAL_NAME"]))
sys.exit(child.wait())
EOF
chmod +x "$signal_driver"

run_controller_signal_case() {
  local signal="$1"
  local expected_status="$2"
  local case_root="$tmp_root/controller-$signal"
  mkdir -p "$case_root/port" "$case_root/halium" "$case_root/control"
  set +e
  HALIUM_ROOT="$case_root/halium" PORT_ROOT="$case_root/port" \
  UNATTENDED_OUTPUT_DIR="$case_root/output" BUILD_ATTEMPT_COMMAND="$long_attempt" \
  MONITOR_COMMAND="$holding_monitor" SIGNAL_COMMAND="$controller_signal" \
  CCACHE_COMMAND="$fake_ccache" JOURNAL_COMMAND="$fake_journal" \
  FAKE_CONTROL_DIR="$case_root/control" FAKE_CONTROLLER_SIGNALS="$case_root/signals" \
  FAKE_JOURNAL_CALLS="$case_root/journal-calls" \
  CONTROLLER_COMMAND="$controller" READY_FILE="$case_root/output/attempt-1/build-paused.flag" \
  SIGNAL_NAME="$signal" \
    "$signal_driver"
  interrupted_status=$?
  set -e
  test "$interrupted_status" -eq "$expected_status"
  pgid="$(cat "$case_root/output/attempt-1/build.pgid")"
  printf '%s\n' "-CONT -- -$pgid" "-TERM -- -$pgid" >"$case_root/expected-signals"
  cmp "$case_root/expected-signals" "$case_root/signals"
  test "$(cat "$case_root/output/attempt-1/status")" -eq 7
  monitor_status="$(cat "$case_root/output/attempt-1/monitor-status")"
  test "$monitor_status" -eq 0 || test "$monitor_status" -eq 143
  test "$(cat "$case_root/output/final-status")" -eq "$expected_status"
  ! kill -0 -- "-$pgid" 2>/dev/null
}

run_controller_signal_case TERM 143
run_controller_signal_case INT 130

# A supervisor that never publishes a live session-leader handshake fails immediately.
broken_setsid="$tmp_root/broken-setsid"
cat >"$broken_setsid" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"$FAKE_SETSID_ARGS"
exit 0
EOF
chmod +x "$broken_setsid"
case_root="$tmp_root/handshake-failure"
mkdir -p "$case_root/port" "$case_root/halium"
set +e
HALIUM_ROOT="$case_root/halium" PORT_ROOT="$case_root/port" \
UNATTENDED_OUTPUT_DIR="$case_root/output" BUILD_ATTEMPT_COMMAND="$long_attempt" \
MONITOR_COMMAND="$holding_monitor" SETSID_COMMAND="$broken_setsid" \
CCACHE_COMMAND="$fake_ccache" JOURNAL_COMMAND="$fake_journal" \
FAKE_SETSID_ARGS="$case_root/setsid-args" FAKE_CONTROL_DIR="$case_root/control" \
FAKE_JOURNAL_CALLS="$case_root/journal-calls" \
  "$controller" >/dev/null 2>&1
handshake_status=$?
set -e
test "$handshake_status" -eq 71
test "$(cat "$case_root/output/attempt-1/status")" -eq 71
grep -F -- '--fork --wait' "$case_root/setsid-args" >/dev/null
test ! -e "$case_root/output/attempt-1/telemetry.tsv"

# A corrupt handshake pointing at an unrelated live session never authorizes group signaling.
unrelated_build="$tmp_root/unrelated-build"
cat >"$unrelated_build" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$$" >"$UNRELATED_PGID_FILE"
while test ! -f "$UNRELATED_RELEASE"; do sleep 0.01; done
EOF
chmod +x "$unrelated_build"
unrelated_dir="$tmp_root/unrelated-group"
mkdir -p "$unrelated_dir"
unrelated_release="$unrelated_dir/release"
UNRELATED_PGID_FILE="$unrelated_dir/pgid" UNRELATED_RELEASE="$unrelated_dir/release" \
  /usr/bin/setsid --fork --wait "$unrelated_build" &
unrelated_supervisor=$!
for _ in {1..100}; do
  test -s "$unrelated_dir/pgid" && break
  sleep 0.01
done
unrelated_pgid="$(cat "$unrelated_dir/pgid")"

malicious_setsid="$tmp_root/malicious-setsid"
cat >"$malicious_setsid" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
handshake_file="$7"
pgid_file="$8"
printf '%s\n' "$UNRELATED_PGID" >"$pgid_file"
if test "${MALICIOUS_HANDSHAKE_MODE:-full}" = pgid-only; then
  sleep 0.05
  exit 0
fi
printf '%s %s %s %s\n' "$UNRELATED_PGID" "$UNRELATED_PGID" "$UNRELATED_PGID" "$$" >"$handshake_file"
trap 'exit 0' TERM
while :; do sleep 0.01; done
EOF
chmod +x "$malicious_setsid"
case_root="$tmp_root/malicious-handshake"
mkdir -p "$case_root/port" "$case_root/halium" "$case_root/control"
set +e
HALIUM_ROOT="$case_root/halium" PORT_ROOT="$case_root/port" \
UNATTENDED_OUTPUT_DIR="$case_root/output" BUILD_ATTEMPT_COMMAND="$long_attempt" \
MONITOR_COMMAND="$holding_monitor" SETSID_COMMAND="$malicious_setsid" \
SIGNAL_COMMAND="$controller_signal" CLEANUP_GRACE_SECONDS=0.2 \
CCACHE_COMMAND="$fake_ccache" JOURNAL_COMMAND="$fake_journal" \
UNRELATED_PGID="$unrelated_pgid" FAKE_CONTROL_DIR="$case_root/control" \
FAKE_CONTROLLER_SIGNALS="$case_root/signals" FAKE_JOURNAL_CALLS="$case_root/journal-calls" \
  "$controller" >/dev/null 2>&1
malicious_status=$?
set -e
test "$malicious_status" -eq 71
test ! -e "$case_root/signals"
kill -0 -- "-$unrelated_pgid" 2>/dev/null
test "$(cat "$case_root/output/attempt-1/status")" -eq 71

case_root="$tmp_root/malicious-pgid-only"
mkdir -p "$case_root/port" "$case_root/halium" "$case_root/control"
set +e
HALIUM_ROOT="$case_root/halium" PORT_ROOT="$case_root/port" \
UNATTENDED_OUTPUT_DIR="$case_root/output" BUILD_ATTEMPT_COMMAND="$long_attempt" \
MONITOR_COMMAND="$holding_monitor" SETSID_COMMAND="$malicious_setsid" \
SIGNAL_COMMAND="$controller_signal" CLEANUP_GRACE_SECONDS=0.2 \
CCACHE_COMMAND="$fake_ccache" JOURNAL_COMMAND="$fake_journal" \
UNRELATED_PGID="$unrelated_pgid" MALICIOUS_HANDSHAKE_MODE=pgid-only \
FAKE_CONTROL_DIR="$case_root/control" FAKE_CONTROLLER_SIGNALS="$case_root/signals" \
FAKE_JOURNAL_CALLS="$case_root/journal-calls" \
  "$controller" >/dev/null 2>&1
pgid_only_status=$?
set -e
test "$pgid_only_status" -eq 71
test ! -e "$case_root/signals"
kill -0 -- "-$unrelated_pgid" 2>/dev/null
: >"$unrelated_release"
wait "$unrelated_supervisor"
unrelated_supervisor=

# TERM arriving after supervisor launch but before handshake waits for the PGID, then cleans it.
delayed_setsid="$tmp_root/delayed-setsid"
cat >"$delayed_setsid" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
sleep 0.05
exec /usr/bin/setsid "$@"
EOF
chmod +x "$delayed_setsid"
case_root="$tmp_root/signal-before-handshake"
mkdir -p "$case_root/port" "$case_root/halium" "$case_root/control"
set +e
HALIUM_ROOT="$case_root/halium" PORT_ROOT="$case_root/port" \
UNATTENDED_OUTPUT_DIR="$case_root/output" BUILD_ATTEMPT_COMMAND="$long_attempt" \
MONITOR_COMMAND="$holding_monitor" SETSID_COMMAND="$delayed_setsid" \
SIGNAL_COMMAND="$controller_signal" CCACHE_COMMAND="$fake_ccache" JOURNAL_COMMAND="$fake_journal" \
FAKE_CONTROL_DIR="$case_root/control" FAKE_CONTROLLER_SIGNALS="$case_root/signals" \
FAKE_JOURNAL_CALLS="$case_root/journal-calls" CONTROLLER_COMMAND="$controller" \
READY_FILE="$case_root/output/attempt-1/build.supervisor-pid" SIGNAL_NAME=TERM \
  "$signal_driver"
pre_handshake_status=$?
set -e
test "$pre_handshake_status" -eq 143
test "$(cat "$case_root/output/attempt-1/status")" -eq 7
pgid="$(cat "$case_root/output/attempt-1/build.pgid")"
test "$(cat "$case_root/signals")" = "-TERM -- -$pgid"
! kill -0 -- "-$pgid" 2>/dev/null

# TERM in the post-spawn/pre-publication barrier is queued until supervisor ownership is published.
launch_barrier="$tmp_root/launch-barrier"
cat >"$launch_barrier" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: >"$FAKE_LAUNCH_BARRIER_READY"
sleep 0.05
EOF
chmod +x "$launch_barrier"
case_root="$tmp_root/signal-in-launch-window"
mkdir -p "$case_root/port" "$case_root/halium" "$case_root/control"
set +e
HALIUM_ROOT="$case_root/halium" PORT_ROOT="$case_root/port" \
UNATTENDED_OUTPUT_DIR="$case_root/output" BUILD_ATTEMPT_COMMAND="$long_attempt" \
MONITOR_COMMAND="$holding_monitor" SIGNAL_COMMAND="$controller_signal" \
CCACHE_COMMAND="$fake_ccache" JOURNAL_COMMAND="$fake_journal" \
LAUNCH_BARRIER_HOOK="$launch_barrier" FAKE_LAUNCH_BARRIER_READY="$case_root/barrier-ready" \
FAKE_CONTROL_DIR="$case_root/control" FAKE_CONTROLLER_SIGNALS="$case_root/signals" \
FAKE_JOURNAL_CALLS="$case_root/journal-calls" CONTROLLER_COMMAND="$controller" \
READY_FILE="$case_root/barrier-ready" SIGNAL_NAME=TERM DRIVER_TIMEOUT=1 \
  "$signal_driver"
launch_window_status=$?
set -e
test "$launch_window_status" -eq 143
test -s "$case_root/output/attempt-1/build.supervisor-pid"
test "$(cat "$case_root/output/attempt-1/status")" -eq 7
pgid="$(cat "$case_root/output/attempt-1/build.pgid")"
test "$(cat "$case_root/signals")" = "-TERM -- -$pgid"
! kill -0 -- "-$pgid" 2>/dev/null

# A monitor that ignores PGID disappearance is explicitly terminated and reaped.
stuck_monitor="$tmp_root/stuck-monitor"
cat >"$stuck_monitor" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out="$2"
printf 'fixture telemetry\n' >"$out/telemetry.tsv"
trap 'exit 0' TERM
tick=0
while test "$tick" -lt 100; do
  tick=$((tick + 1))
  printf '%s\n' "$tick" >"$out/monitor-ticks"
  sleep 0.01
done
exit 99
EOF
chmod +x "$stuck_monitor"
case_root="$tmp_root/stuck-monitor-cleanup"
mkdir -p "$case_root/port" "$case_root/halium"
set +e
HALIUM_ROOT="$case_root/halium" PORT_ROOT="$case_root/port" \
UNATTENDED_OUTPUT_DIR="$case_root/output" BUILD_ATTEMPT_COMMAND="$fake_attempt" \
MONITOR_COMMAND="$stuck_monitor" CCACHE_COMMAND="$fake_ccache" JOURNAL_COMMAND="$fake_journal" \
FAKE_STATE="$case_root/state" FAKE_JOBS="$case_root/jobs" FAKE_STATUSES='7' FAKE_FLAGGED='0' \
FAKE_JOURNAL_CALLS="$case_root/journal-calls" \
  "$controller"
stuck_monitor_status=$?
set -e
test "$stuck_monitor_status" -eq 7
test "$(cat "$case_root/output/attempt-1/status")" -eq 7
test "$(cat "$case_root/output/attempt-1/monitor-status")" -eq 0
test "$(cat "$case_root/output/final-status")" -eq 7
test "$(cat "$case_root/output/attempt-1/monitor-ticks")" -lt 20
test -s "$case_root/output/attempt-1/intentional-monitor-stop"
grep -F 'reason=build-finished' "$case_root/output/attempt-1/intentional-monitor-stop" >/dev/null

# A monitor killed with 137 after an intentional stop is not resource-pressure proof.
kill_resistant_monitor="$tmp_root/kill-resistant-monitor"
cat >"$kill_resistant_monitor" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out="$2"
printf 'fixture telemetry\n' >"$out/telemetry.tsv"
trap '' TERM
while :; do sleep 0.01; done
EOF
chmod +x "$kill_resistant_monitor"
case_root="$tmp_root/monitor-137-is-not-resource"
mkdir -p "$case_root/port" "$case_root/halium"
set +e
HALIUM_ROOT="$case_root/halium" PORT_ROOT="$case_root/port" \
UNATTENDED_OUTPUT_DIR="$case_root/output" BUILD_ATTEMPT_COMMAND="$fake_attempt" \
MONITOR_COMMAND="$kill_resistant_monitor" CLEANUP_GRACE_SECONDS=0.05 \
CCACHE_COMMAND="$fake_ccache" JOURNAL_COMMAND="$fake_journal" \
FAKE_STATE="$case_root/state" FAKE_JOBS="$case_root/jobs" FAKE_STATUSES='137,0' \
FAKE_FLAGGED='0,0' FAKE_JOURNAL_CALLS="$case_root/journal-calls" \
  "$controller"
monitor_137_status=$?
set -e
test "$monitor_137_status" -eq 137
test "$(cat "$case_root/jobs")" = 16
test "$(cat "$case_root/output/attempt-1/monitor-status")" -eq 137
test -s "$case_root/output/attempt-1/intentional-monitor-stop"
grep -F 'reason=build-finished' "$case_root/output/attempt-1/intentional-monitor-stop" >/dev/null
test ! -e "$case_root/output/attempt-2"

# Intentional monitor-stop state is attempt-local and cannot mask the next monitor failure.
second_attempt_monitor_failure="$tmp_root/second-attempt-monitor-failure"
cat >"$second_attempt_monitor_failure" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
pgid="$1"
out="$2"
printf 'fixture telemetry\n' >"$out/telemetry.tsv"
case "$out" in
  */attempt-1)
    while kill -0 -- "-$pgid" 2>/dev/null; do sleep 0.01; done
    ;;
  */attempt-2)
    exit 42
    ;;
esac
EOF
chmod +x "$second_attempt_monitor_failure"
case_root="$tmp_root/attempt-local-monitor-state"
mkdir -p "$case_root/port" "$case_root/halium" "$case_root/control"
set +e
HALIUM_ROOT="$case_root/halium" PORT_ROOT="$case_root/port" \
UNATTENDED_OUTPUT_DIR="$case_root/output" BUILD_ATTEMPT_COMMAND="$fake_attempt" \
MONITOR_COMMAND="$second_attempt_monitor_failure" SIGNAL_COMMAND="$controller_signal" \
CCACHE_COMMAND="$fake_ccache" JOURNAL_COMMAND="$fake_journal" \
FAKE_STATE="$case_root/state" FAKE_JOBS="$case_root/jobs" FAKE_STATUSES='137,0' FAKE_FLAGGED='1,0' \
FAKE_CONTROL_DIR="$case_root/control" FAKE_CONTROLLER_SIGNALS="$case_root/signals" \
FAKE_JOURNAL_CALLS="$case_root/journal-calls" \
  "$controller"
second_monitor_status=$?
set -e
test "$second_monitor_status" -eq 70
test "$(cat "$case_root/output/attempt-2/monitor-status")" -eq 42
test -s "$case_root/output/attempt-1/intentional-monitor-stop"
test ! -e "$case_root/output/attempt-2/intentional-monitor-stop"

echo "unattended build controller behavior tests passed"
