#!/usr/bin/env bash
set -euo pipefail

if test "$#" -ne 2; then
  echo "usage: monitor-build-host.sh BUILD_PGID OUTPUT_DIR" >&2
  exit 2
fi

build_pgid="$1"
output_dir="$2"
case "$build_pgid" in
  ''|*[!0-9]*)
    echo "BUILD_PGID must be a process-group number greater than 1" >&2
    exit 2
    ;;
esac
if test "$build_pgid" -le 1; then
  echo "BUILD_PGID must be a process-group number greater than 1" >&2
  exit 2
fi

: "${PROC_ROOT:=/proc}"
: "${SYS_ROOT:=/sys}"
: "${SAMPLE_INTERVAL:=15}"
: "${SIGNAL_COMMAND:=kill}"

mkdir -p -- "$output_dir"
telemetry="$output_dir/telemetry.tsv"
transitions="$output_dir/transitions.log"
resource_flag="$output_dir/resource-pressure.flag"
group_pids="$output_dir/build-group-pids.txt"
paused_flag="$output_dir/build-paused.flag"
printf 'timestamp\tmem_available_kb\tswap_free_kb\tmemory_psi\tcpu_temp_c\tnvme_temp_c\n' >"$telemetry"

paused=0
low_resource_samples=0

timestamp() {
  date --iso-8601=seconds
}

signal_build_group() {
  local signal="$1"
  "$SIGNAL_COMMAND" "-$signal" -- "-$build_pgid"
}

resume_before_exit() {
  if test "$paused" -eq 1; then
    if test -f "$paused_flag"; then
      signal_build_group CONT || true
      printf '%s action=CONT reason=monitor-exit\n' "$(timestamp)" >>"$transitions"
    fi
    paused=0
    rm -f -- "$paused_flag"
  fi
}
trap resume_before_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

process_group_alive() {
  if test "$PROC_ROOT" = /proc; then
    kill -0 -- "-$build_pgid" 2>/dev/null
  else
    test -d "$PROC_ROOT/$build_pgid"
  fi
}

meminfo_value() {
  local key="$1"
  awk -v key="$key" '$1 == key ":" { print $2; found=1; exit } END { if (!found) print 0 }' \
    "$PROC_ROOT/meminfo"
}

temperature_for() {
  local wanted="$1"
  local hwmon name raw max_raw=0
  for hwmon in "$SYS_ROOT"/class/hwmon/hwmon*; do
    test -d "$hwmon" || continue
    name="$(cat "$hwmon/name" 2>/dev/null || true)"
    case "$wanted:$name" in
      cpu:coretemp|cpu:k10temp|cpu:cpu*|cpu:zenpower|nvme:nvme) ;;
      *) continue ;;
    esac
    for input in "$hwmon"/temp*_input; do
      test -r "$input" || continue
      raw="$(cat "$input")"
      case "$raw" in ''|*[!0-9]*) continue ;; esac
      test "$raw" -le "$max_raw" || max_raw="$raw"
    done
  done
  if test "$max_raw" -eq 0; then
    printf 'NA\n'
  else
    awk -v raw="$max_raw" 'BEGIN { printf "%.1f\n", raw / 1000 }'
  fi
}

record_build_group_members() {
  local process_dir pid stat_line stat_fields state parent pgrp
  for process_dir in "$PROC_ROOT"/[0-9]*; do
    test -r "$process_dir/stat" || continue
    pid="${process_dir##*/}"
    stat_line="$(cat "$process_dir/stat" 2>/dev/null || true)"
    test -n "$stat_line" || continue
    stat_fields="${stat_line##*) }"
    read -r state parent pgrp _ <<<"$stat_fields"
    test "${pgrp:-}" = "$build_pgid" || continue
    printf '%s\n' "$pid" >>"$group_pids"
  done
}

while process_group_alive; do
  record_build_group_members
  mem_available_kb="$(meminfo_value MemAvailable)"
  swap_free_kb="$(meminfo_value SwapFree)"
  memory_psi="$(head -n 1 "$PROC_ROOT/pressure/memory" 2>/dev/null || printf 'unavailable')"
  cpu_temp_c="$(temperature_for cpu)"
  nvme_temp_c="$(temperature_for nvme)"
  now="$(timestamp)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$now" "$mem_available_kb" "$swap_free_kb" "$memory_psi" "$cpu_temp_c" "$nvme_temp_c" \
    >>"$telemetry"

  if test "$cpu_temp_c" != NA && awk -v temp="$cpu_temp_c" 'BEGIN { exit !(temp >= 82) }'; then
    if test "$paused" -eq 0; then
      paused=1
      : >"$paused_flag"
      if ! signal_build_group STOP; then
        paused=0
        rm -f -- "$paused_flag"
        exit 1
      fi
      printf '%s action=STOP reason=cpu-temperature temperature_c=%s\n' "$now" "$cpu_temp_c" >>"$transitions"
    fi
  elif test "$paused" -eq 1 && test "$cpu_temp_c" != NA && \
      awk -v temp="$cpu_temp_c" 'BEGIN { exit !(temp <= 75) }'; then
    signal_build_group CONT
    paused=0
    rm -f -- "$paused_flag"
    printf '%s action=CONT reason=cpu-temperature temperature_c=%s\n' "$now" "$cpu_temp_c" >>"$transitions"
  fi

  if test "$mem_available_kb" -lt 524288 && test "$swap_free_kb" -lt 2097152; then
    low_resource_samples=$((low_resource_samples + 1))
  else
    low_resource_samples=0
  fi

  if test "$low_resource_samples" -ge 3; then
    printf 'reason=low-memory mem_available_kb=%s swap_free_kb=%s consecutive=%s\n' \
      "$mem_available_kb" "$swap_free_kb" "$low_resource_samples" >"$resource_flag"
    if test "$paused" -eq 1; then
      signal_build_group CONT || true
      paused=0
      rm -f -- "$paused_flag"
      printf '%s action=CONT reason=resource-termination\n' "$now" >>"$transitions"
    fi
    printf '%s action=TERM reason=low-memory\n' "$now" >>"$transitions"
    signal_build_group TERM
    break
  fi

  sleep "$SAMPLE_INTERVAL"
done
