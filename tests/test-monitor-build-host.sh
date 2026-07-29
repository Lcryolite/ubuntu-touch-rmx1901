#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
monitor="$repo_root/scripts/monitor-build-host.sh"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/monitor-build-host-test.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

proc_root="$tmp_root/proc"
sys_root="$tmp_root/sys"
out="$tmp_root/output"
fake_bin="$tmp_root/bin"
build_pgid=4242
mkdir -p "$proc_root/$build_pgid" "$proc_root/4243" "$proc_root/9000" "$proc_root/pressure" \
  "$sys_root/class/hwmon/hwmon0" "$sys_root/class/hwmon/hwmon1" \
  "$fake_bin"

printf 'MemAvailable:    4194304 kB\nSwapFree:        4194304 kB\n' >"$proc_root/meminfo"
printf 'some avg10=0.00 avg60=0.01 avg300=0.02 total=3\n' >"$proc_root/pressure/memory"
printf 'cpu  100 0 20 300 0 0 0 0 0 0\n' >"$proc_root/stat"
printf '4242 (build leader) S 1 4242 0 0\n' >"$proc_root/4242/stat"
printf '4243 (compiler child) S 4242 4242 0 0\n' >"$proc_root/4243/stat"
printf '9000 (codex proxy) S 1 9000 0 0\n' >"$proc_root/9000/stat"
printf 'coretemp\n' >"$sys_root/class/hwmon/hwmon0/name"
printf '60000\n' >"$sys_root/class/hwmon/hwmon0/temp1_input"
printf 'nvme\n' >"$sys_root/class/hwmon/hwmon1/name"
printf '50000\n' >"$sys_root/class/hwmon/hwmon1/temp1_input"

signals="$tmp_root/signals"
fake_signal="$fake_bin/fake-signal"
cat >"$fake_signal" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_SIGNAL_LOG"
case "$1" in
  -STOP|-CONT)
    test -z "${EXPECTED_PAUSED_FLAG:-}" || test -f "$EXPECTED_PAUSED_FLAG"
    ;;
esac
test "${FAKE_SIGNAL_FAIL:-}" != "${1#-}" || exit 88
EOF
chmod +x "$fake_signal"

cat >"$fake_bin/sleep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_file="$FIXTURE_ROOT/sample-number"
sample=0
test ! -f "$state_file" || sample="$(cat "$state_file")"
sample=$((sample + 1))
printf '%s\n' "$sample" >"$state_file"
if test "${FIXTURE_MODE:-}" != high-exit; then
case "$sample" in
  1)
    printf '82000\n' >"$FIXTURE_SYS/class/hwmon/hwmon0/temp1_input"
    ;;
  2)
    printf '75000\n' >"$FIXTURE_SYS/class/hwmon/hwmon0/temp1_input"
    printf 'MemAvailable:     500000 kB\nSwapFree:        2000000 kB\n' >"$FIXTURE_PROC/meminfo"
    ;;
  3)
    printf 'MemAvailable:    4194304 kB\nSwapFree:        4194304 kB\n' >"$FIXTURE_PROC/meminfo"
    ;;
  4)
    printf 'MemAvailable:     500000 kB\nSwapFree:        2000000 kB\n' >"$FIXTURE_PROC/meminfo"
    ;;
esac
fi
if test "${FIXTURE_MODE:-}" = high-exit && test "$sample" -eq 3; then
  mv "$FIXTURE_PROC/$FIXTURE_PGID" "$FIXTURE_PROC/exited-$FIXTURE_PGID"
fi
if test "${FIXTURE_MODE:-}" = hold; then
  while test ! -f "$FIXTURE_RELEASE"; do /usr/bin/sleep 0.005; done
fi
if test "${FIXTURE_MODE:-}" = controller-resumed && test "$sample" -eq 1; then
  rm -f -- "$EXPECTED_PAUSED_FLAG"
  mv "$FIXTURE_PROC/$FIXTURE_PGID" "$FIXTURE_PROC/exited-$FIXTURE_PGID"
fi
EOF
chmod +x "$fake_bin/sleep"

PATH="$fake_bin:$PATH" \
PROC_ROOT="$proc_root" \
SYS_ROOT="$sys_root" \
SAMPLE_INTERVAL=0 \
SIGNAL_COMMAND="$fake_signal" \
FAKE_SIGNAL_LOG="$signals" \
FIXTURE_ROOT="$tmp_root" \
FIXTURE_PROC="$proc_root" \
FIXTURE_SYS="$sys_root" \
EXPECTED_PAUSED_FLAG="$out/build-paused.flag" \
  "$monitor" "$build_pgid" "$out"

expected_signals="$tmp_root/expected-signals"
printf '%s\n' \
  '-STOP -- -4242' \
  '-CONT -- -4242' \
  '-TERM -- -4242' >"$expected_signals"
cmp "$expected_signals" "$signals"
test -f "$out/resource-pressure.flag"
grep -F 'reason=low-memory mem_available_kb=500000 swap_free_kb=2000000 consecutive=3' \
  "$out/resource-pressure.flag" >/dev/null

telemetry="$out/telemetry.tsv"
test "$(wc -l <"$telemetry")" -eq 8
expected_header=$'timestamp\tmem_available_kb\tswap_free_kb\tmemory_psi\tcpu_temp_c\tnvme_temp_c'
test "$(head -n 1 "$telemetry")" = "$expected_header"
grep -F $'4194304\t4194304\tsome avg10=0.00 avg60=0.01 avg300=0.02 total=3\t60.0\t50.0' "$telemetry" >/dev/null
grep -F $'500000\t2000000\tsome avg10=0.00 avg60=0.01 avg300=0.02 total=3\t75.0\t50.0' "$telemetry" >/dev/null
grep -F 'action=STOP reason=cpu-temperature temperature_c=82.0' "$out/transitions.log" >/dev/null
grep -F 'action=CONT reason=cpu-temperature temperature_c=75.0' "$out/transitions.log" >/dev/null
grep -F 'action=TERM reason=low-memory' "$out/transitions.log" >/dev/null
printf '%s\n' 4242 4243 >"$tmp_root/expected-build-pids"
sort -nu "$out/build-group-pids.txt" | cmp "$tmp_root/expected-build-pids" -

# A group that disappears while continuously hot gets one STOP and an exit CONT.
high_out="$tmp_root/high-exit-output"
high_signals="$tmp_root/high-exit-signals"
rm -f -- "$tmp_root/sample-number"
printf '83000\n' >"$sys_root/class/hwmon/hwmon0/temp1_input"
printf 'MemAvailable:    4194304 kB\nSwapFree:        4194304 kB\n' >"$proc_root/meminfo"
PATH="$fake_bin:$PATH" PROC_ROOT="$proc_root" SYS_ROOT="$sys_root" SAMPLE_INTERVAL=0 \
SIGNAL_COMMAND="$fake_signal" FAKE_SIGNAL_LOG="$high_signals" FIXTURE_ROOT="$tmp_root" \
FIXTURE_PROC="$proc_root" FIXTURE_SYS="$sys_root" FIXTURE_MODE=high-exit \
FIXTURE_PGID="$build_pgid" EXPECTED_PAUSED_FLAG="$high_out/build-paused.flag" \
  "$monitor" "$build_pgid" "$high_out"
printf '%s\n' '-STOP -- -4242' '-CONT -- -4242' >"$tmp_root/expected-high-signals"
cmp "$tmp_root/expected-high-signals" "$high_signals"
test ! -e "$high_out/build-paused.flag"

mv "$proc_root/exited-$build_pgid" "$proc_root/$build_pgid"

# A failed STOP rolls persisted/local paused state back without a false CONT.
failed_stop_out="$tmp_root/failed-stop-output"
failed_stop_signals="$tmp_root/failed-stop-signals"
printf '83000\n' >"$sys_root/class/hwmon/hwmon0/temp1_input"
set +e
PROC_ROOT="$proc_root" SYS_ROOT="$sys_root" SAMPLE_INTERVAL=0 SIGNAL_COMMAND="$fake_signal" \
FAKE_SIGNAL_LOG="$failed_stop_signals" FAKE_SIGNAL_FAIL=STOP \
EXPECTED_PAUSED_FLAG="$failed_stop_out/build-paused.flag" \
  "$monitor" "$build_pgid" "$failed_stop_out"
failed_stop_status=$?
set -e
test "$failed_stop_status" -eq 1
test "$(cat "$failed_stop_signals")" = '-STOP -- -4242'
test ! -e "$failed_stop_out/build-paused.flag"

# TERM delivered while STOPped must run EXIT cleanup and send CONT.
monitor_signal_driver="$tmp_root/monitor-signal-driver.py"
cat >"$monitor_signal_driver" <<'EOF'
#!/usr/bin/env python3
import os
import signal
import subprocess
import sys
import time

child = subprocess.Popen([os.environ["MONITOR"], os.environ["PGID"], os.environ["OUT"]], env=os.environ.copy())
deadline = time.monotonic() + 5
while True:
    try:
        if "-STOP" in open(os.environ["SIGNALS"], encoding="utf-8").read():
            break
    except FileNotFoundError:
        pass
    if child.poll() is not None or time.monotonic() >= deadline:
        sys.exit(125)
    time.sleep(0.005)
os.kill(child.pid, signal.SIGTERM)
open(os.environ["RELEASE"], "w", encoding="utf-8").close()
sys.exit(child.wait())
EOF
chmod +x "$monitor_signal_driver"
term_out="$tmp_root/term-output"
term_signals="$tmp_root/term-signals"
term_release="$tmp_root/term-release"
mkdir -p "$tmp_root/term"
set +e
PATH="$fake_bin:$PATH" PROC_ROOT="$proc_root" SYS_ROOT="$sys_root" SAMPLE_INTERVAL=0 \
SIGNAL_COMMAND="$fake_signal" FAKE_SIGNAL_LOG="$term_signals" FIXTURE_ROOT="$tmp_root/term" \
FIXTURE_PROC="$proc_root" FIXTURE_SYS="$sys_root" FIXTURE_MODE=hold \
FIXTURE_RELEASE="$term_release" EXPECTED_PAUSED_FLAG="$term_out/build-paused.flag" \
MONITOR="$monitor" PGID="$build_pgid" OUT="$term_out" SIGNALS="$term_signals" \
RELEASE="$term_release" \
  "$monitor_signal_driver"
term_status=$?
set -e
test "$term_status" -eq 143
printf '%s\n' '-STOP -- -4242' '-CONT -- -4242' >"$tmp_root/expected-term-signals"
cmp "$tmp_root/expected-term-signals" "$term_signals"
test ! -e "$term_out/build-paused.flag"

# If controller already consumed the paused flag and resumed the group, monitor must not CONT twice.
controller_resumed_out="$tmp_root/controller-resumed-output"
controller_resumed_signals="$tmp_root/controller-resumed-signals"
rm -f -- "$tmp_root/sample-number"
printf '83000\n' >"$sys_root/class/hwmon/hwmon0/temp1_input"
PATH="$fake_bin:$PATH" PROC_ROOT="$proc_root" SYS_ROOT="$sys_root" SAMPLE_INTERVAL=0 \
SIGNAL_COMMAND="$fake_signal" FAKE_SIGNAL_LOG="$controller_resumed_signals" FIXTURE_ROOT="$tmp_root" \
FIXTURE_PROC="$proc_root" FIXTURE_SYS="$sys_root" FIXTURE_MODE=controller-resumed \
FIXTURE_PGID="$build_pgid" EXPECTED_PAUSED_FLAG="$controller_resumed_out/build-paused.flag" \
  "$monitor" "$build_pgid" "$controller_resumed_out"
test "$(cat "$controller_resumed_signals")" = '-STOP -- -4242'
mv "$proc_root/exited-$build_pgid" "$proc_root/$build_pgid"

set +e
invalid_output="$(PROC_ROOT="$proc_root" SYS_ROOT="$sys_root" SIGNAL_COMMAND="$fake_signal" \
  FAKE_SIGNAL_LOG="$signals" "$monitor" '4242;9999' "$tmp_root/invalid" 2>&1)"
invalid_status=$?
set -e
test "$invalid_status" -eq 2
test "$invalid_output" = 'BUILD_PGID must be a process-group number greater than 1'
cmp "$expected_signals" "$signals"

echo "build host monitor behavior tests passed"
