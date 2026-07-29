#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${HALIUM_ROOT:?set HALIUM_ROOT}"
: "${PORT_ROOT:?set PORT_ROOT}"
: "${UNATTENDED_OUTPUT_DIR:=$PORT_ROOT/artifacts/unattended-build}"
: "${BUILD_ATTEMPT_COMMAND:=$repo_root/scripts/build-halium.sh}"
: "${MONITOR_COMMAND:=$repo_root/scripts/monitor-build-host.sh}"
: "${CCACHE_COMMAND:=/usr/bin/ccache}"
: "${JOURNAL_COMMAND:=journalctl}"
: "${SETSID_COMMAND:=setsid}"
: "${SIGNAL_COMMAND:=kill}"
: "${CLEANUP_GRACE_SECONDS:=2}"
: "${LAUNCH_BARRIER_HOOK:=}"

mkdir -p -- "$UNATTENDED_OUTPUT_DIR"

ccache_stats() {
  if command -v "$CCACHE_COMMAND" >/dev/null 2>&1; then
    "$CCACHE_COMMAND" -s 2>&1 || printf 'ccache stats command failed\n'
  else
    printf 'ccache unavailable: %s\n' "$CCACHE_COMMAND"
  fi
}

verified_final_images() {
  local artifact_dir="$PORT_ROOT/artifacts/build"
  local manifest="$artifact_dir/manifest.sha256"
  local checksum filename extra index
  local -a manifest_lines expected_images=(halium-boot.img system.img)
  test -s "$artifact_dir/halium-boot.img" || return 1
  test -s "$artifact_dir/system.img" || return 1
  test -s "$manifest" || return 1
  mapfile -t manifest_lines <"$manifest"
  test "${#manifest_lines[@]}" -eq "${#expected_images[@]}" || return 1
  for index in "${!expected_images[@]}"; do
    checksum=
    filename=
    extra=
    read -r checksum filename extra <<<"${manifest_lines[$index]}"
    [[ "$checksum" =~ ^[0-9a-f]{64}$ ]] || return 1
    test "$filename" = "${expected_images[$index]}" || return 1
    test -z "$extra" || return 1
  done
  (cd "$artifact_dir" && sha256sum --strict --check manifest.sha256 >/dev/null)
}

journal_proves_group_oom() {
  local journal_file="$1"
  local group_pids="$2"
  local line killed_pid
  test -s "$group_pids" || return 1
  while IFS= read -r line; do
    grep -Eiq 'oom-kill|out of memory' <<<"$line" || continue
    killed_pid="$(grep -Eio 'killed process[[:space:]]+[0-9]+' <<<"$line" | awk '{print $3}' || true)"
    test -n "$killed_pid" || continue
    grep -Fxq "$killed_pid" "$group_pids" && return 0
  done <"$journal_file"
  return 1
}

jobs_sequence=(16 12 8)
final_status=1
attempt_number=0
active_attempt_dir=
active_pgid_file=
active_build_pgid=
active_build_pid=
active_supervisor_pid=
active_monitor_pid=
active_build_status=
active_monitor_status=
active_monitor_stop_requested=0
cleanup_running=0
launching_supervisor=0
unpublished_supervisor_pid=
pending_signal_status=

wait_for_child() {
  local child_pid="$1"
  if wait "$child_pid"; then
    child_status=0
  else
    child_status=$?
  fi
}

bounded_wait_for_child() {
  local child_pid="$1"
  (
    sleep "$CLEANUP_GRACE_SECONDS"
    kill -KILL "$child_pid" 2>/dev/null || true
  ) &
  local watchdog_pid=$!
  wait_for_child "$child_pid"
  kill -TERM "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
}

stop_active_monitor() {
  local reason="${1:?intentional monitor-stop reason is required}"
  if test -n "$active_monitor_pid" && test -z "$active_monitor_status"; then
    active_monitor_stop_requested=1
    if test -n "$active_attempt_dir" && \
        ! test -e "$active_attempt_dir/intentional-monitor-stop"; then
      printf 'time=%s reason=%s\n' "$(date --iso-8601=seconds)" "$reason" \
        >"$active_attempt_dir/intentional-monitor-stop"
    fi
    kill -TERM "$active_monitor_pid" 2>/dev/null || true
  fi
}

signal_build_group() {
  local signal="$1"
  "$SIGNAL_COMMAND" "-$signal" -- "-$active_build_pgid"
}

cleanup_active_attempt() {
  local fallback_status="$1"
  local candidate_pgid candidate_group candidate_sid candidate_parent
  test "$cleanup_running" -eq 0 || return 0
  cleanup_running=1

  if test -z "$active_build_pgid" && test -n "$active_pgid_file" && \
      test -n "$active_supervisor_pid"; then
    for _ in {1..100}; do
      if test -s "$active_pgid_file"; then
        candidate_pgid="$(cat "$active_pgid_file")"
        case "$candidate_pgid" in
          ''|*[!0-9]*) ;;
          *)
            candidate_group="$(ps -o pgid= -p "$candidate_pgid" 2>/dev/null | tr -d ' ' || true)"
            candidate_sid="$(ps -o sid= -p "$candidate_pgid" 2>/dev/null | tr -d ' ' || true)"
            candidate_parent="$(ps -o ppid= -p "$candidate_pgid" 2>/dev/null | tr -d ' ' || true)"
            if test "$candidate_pgid" -gt 1 && \
                test "$candidate_group" = "$candidate_pgid" && \
                test "$candidate_sid" = "$candidate_pgid" && \
                test "$candidate_parent" = "$active_supervisor_pid" && \
                kill -0 -- "-$candidate_pgid" 2>/dev/null; then
              active_build_pgid="$candidate_pgid"
              break
            fi
            ;;
        esac
      fi
      kill -0 "$active_supervisor_pid" 2>/dev/null || break
      sleep 0.01
    done
  fi

  if test -n "$active_build_pgid"; then
    if test -n "$active_attempt_dir" && test -f "$active_attempt_dir/build-paused.flag"; then
      signal_build_group CONT || true
      rm -f -- "$active_attempt_dir/build-paused.flag"
      printf '%s action=CONT reason=controller-cleanup\n' "$(date --iso-8601=seconds)" \
        >>"$active_attempt_dir/controller-transitions.log"
    fi
    if kill -0 -- "-$active_build_pgid" 2>/dev/null; then
      signal_build_group TERM || true
      test -z "$active_attempt_dir" || \
        printf '%s action=TERM reason=controller-cleanup\n' "$(date --iso-8601=seconds)" \
          >>"$active_attempt_dir/controller-transitions.log"
    fi
  elif test -n "$active_supervisor_pid" && kill -0 "$active_supervisor_pid" 2>/dev/null; then
    kill -TERM "$active_supervisor_pid" 2>/dev/null || true
  fi
  stop_active_monitor controller-cleanup

  if test -n "$active_supervisor_pid" && test -z "$active_build_status"; then
    bounded_wait_for_child "$active_supervisor_pid"
    active_build_status="$child_status"
  fi
  if test -n "$active_monitor_pid" && test -z "$active_monitor_status"; then
    bounded_wait_for_child "$active_monitor_pid"
    active_monitor_status="$child_status"
  fi
  test -n "$active_build_status" || active_build_status="$fallback_status"
  test -n "$active_monitor_status" || active_monitor_status="$fallback_status"
  if test -n "$active_attempt_dir"; then
    printf '%s\n' "$active_build_status" >"$active_attempt_dir/status"
    printf '%s\n' "$active_monitor_status" >"$active_attempt_dir/monitor-status"
  fi
  cleanup_running=0
}

clear_active_attempt() {
  active_attempt_dir=
  active_pgid_file=
  active_build_pgid=
  active_build_pid=
  active_supervisor_pid=
  active_monitor_pid=
  active_build_status=
  active_monitor_status=
  active_monitor_stop_requested=0
}

handle_controller_signal() {
  local status="$1"
  trap - INT TERM
  cleanup_active_attempt "$status"
  printf '%s\n' "$status" >"$UNATTENDED_OUTPUT_DIR/final-status"
  exit "$status"
}

queue_or_handle_controller_signal() {
  local status="$1"
  if test "$launching_supervisor" -eq 1; then
    test -n "$pending_signal_status" || pending_signal_status="$status"
    return 0
  fi
  handle_controller_signal "$status"
}

cleanup_on_exit() {
  local status=$?
  if test -z "$active_supervisor_pid" && test -n "$unpublished_supervisor_pid"; then
    active_supervisor_pid="$unpublished_supervisor_pid"
  fi
  if test -n "$active_attempt_dir"; then
    cleanup_active_attempt "$status"
  fi
  return "$status"
}
trap cleanup_on_exit EXIT
trap 'queue_or_handle_controller_signal 130' INT
trap 'queue_or_handle_controller_signal 143' TERM

for jobs in "${jobs_sequence[@]}"; do
  attempt_number=$((attempt_number + 1))
  monitor_was_stopped=0
  attempt_dir="$UNATTENDED_OUTPUT_DIR/attempt-$attempt_number"
  if test -e "$attempt_dir"; then
    echo "Refusing to overwrite existing attempt directory: $attempt_dir" >&2
    exit 2
  fi
  mkdir -p -- "$attempt_dir"
  active_attempt_dir="$attempt_dir"
  attempt_start="$(date --iso-8601=seconds)"
  printf '%s\n' "$attempt_start" >"$attempt_dir/started-at"
  printf '%s\n' "$jobs" >"$attempt_dir/jobs"
  ccache_stats >"$attempt_dir/ccache-before.txt"

  pgid_file="$attempt_dir/build.pgid"
  active_pgid_file="$pgid_file"
  handshake_file="$attempt_dir/build.handshake"
  launching_supervisor=1
  unpublished_supervisor_pid=
  HALIUM_JOBS="$jobs" ATTEMPT_OUTPUT_DIR="$attempt_dir" \
    "$SETSID_COMMAND" --fork --wait bash -c '
      handshake_file=$1
      pgid_file=$2
      shift 2
      build_pid=$$
      build_pgid=$(ps -o pgid= -p "$$" | tr -d " ")
      build_sid=$(ps -o sid= -p "$$" | tr -d " ")
      build_parent=$PPID
      printf "%s %s %s %s\n" "$build_pid" "$build_pgid" "$build_sid" "$build_parent" >"$handshake_file"
      printf "%s\n" "$build_pgid" >"$pgid_file"
      exec "$@"
    ' bash "$handshake_file" "$pgid_file" "$BUILD_ATTEMPT_COMMAND" \
    >"$attempt_dir/build.log" 2>&1 &
  supervisor_pid=$!
  unpublished_supervisor_pid="$supervisor_pid"
  launch_hook_status=0
  if test -n "$LAUNCH_BARRIER_HOOK"; then
    if "$LAUNCH_BARRIER_HOOK"; then
      :
    else
      launch_hook_status=$?
    fi
  fi
  active_supervisor_pid="$supervisor_pid"
  printf '%s\n' "$supervisor_pid" >"$attempt_dir/build.supervisor-pid"
  unpublished_supervisor_pid=
  launching_supervisor=0
  if test -n "$pending_signal_status"; then
    queued_status="$pending_signal_status"
    pending_signal_status=
    handle_controller_signal "$queued_status"
  fi
  if test "$launch_hook_status" -ne 0; then
    cleanup_active_attempt 72
    printf '72\n' >"$UNATTENDED_OUTPUT_DIR/final-status"
    clear_active_attempt
    exit 72
  fi

  for _ in {1..100}; do
    test -s "$handshake_file" && break
    kill -0 "$supervisor_pid" 2>/dev/null || break
    sleep 0.01
  done
  if ! test -s "$handshake_file"; then
    cleanup_active_attempt 71
    printf '71\n' >"$attempt_dir/status"
    echo "Build process group was not established" >&2
    printf '71\n' >"$UNATTENDED_OUTPUT_DIR/final-status"
    clear_active_attempt
    exit 71
  fi
  read -r build_pid build_pgid build_sid build_parent <"$handshake_file"
  handshake_valid=1
  for value in "$build_pid" "$build_pgid" "$build_sid" "$build_parent"; do
    case "$value" in ''|*[!0-9]*) handshake_valid=0 ;; esac
  done
  test "$handshake_valid" -eq 0 || test "$build_pid" -gt 1 || handshake_valid=0
  test "$handshake_valid" -eq 0 || test "$build_pid" = "$build_pgid" || handshake_valid=0
  test "$handshake_valid" -eq 0 || test "$build_pid" = "$build_sid" || handshake_valid=0
  test "$handshake_valid" -eq 0 || test "$build_parent" = "$supervisor_pid" || handshake_valid=0
  test "$handshake_valid" -eq 0 || kill -0 "$supervisor_pid" 2>/dev/null || handshake_valid=0
  test "$handshake_valid" -eq 0 || kill -0 "$build_pid" 2>/dev/null || handshake_valid=0
  observed_pgid="$(ps -o pgid= -p "$build_pid" 2>/dev/null | tr -d ' ' || true)"
  observed_sid="$(ps -o sid= -p "$build_pid" 2>/dev/null | tr -d ' ' || true)"
  observed_parent="$(ps -o ppid= -p "$build_pid" 2>/dev/null | tr -d ' ' || true)"
  test "$handshake_valid" -eq 0 || test "$observed_pgid" = "$build_pgid" || handshake_valid=0
  test "$handshake_valid" -eq 0 || test "$observed_sid" = "$build_sid" || handshake_valid=0
  test "$handshake_valid" -eq 0 || test "$observed_parent" = "$supervisor_pid" || handshake_valid=0
  cleanup_group_valid="$handshake_valid"
  published_pgid="$(cat "$pgid_file" 2>/dev/null || true)"
  test "$handshake_valid" -eq 0 || test "$published_pgid" = "$build_pgid" || handshake_valid=0
  if test "$handshake_valid" -ne 1; then
    active_pgid_file=
    if test "$cleanup_group_valid" -eq 1; then
      active_build_pgid="$build_pgid"
    fi
    cleanup_active_attempt 71
    printf '71\n' >"$attempt_dir/status"
    echo "Invalid or stale build process-group handshake" >&2
    printf '71\n' >"$UNATTENDED_OUTPUT_DIR/final-status"
    clear_active_attempt
    exit 71
  fi
  active_build_pid="$build_pid"
  active_build_pgid="$build_pgid"

  "$MONITOR_COMMAND" "$build_pgid" "$attempt_dir" \
    >"$attempt_dir/monitor.log" 2>&1 &
  monitor_pid=$!
  active_monitor_pid="$monitor_pid"

  finished_pid=
  if wait -n -p finished_pid "$supervisor_pid" "$monitor_pid"; then
    first_status=0
  else
    first_status=$?
  fi
  if test "$finished_pid" = "$monitor_pid"; then
    active_monitor_status="$first_status"
    cleanup_active_attempt 70
    build_status="$active_build_status"
    monitor_status="$active_monitor_status"
  else
    active_build_status="$first_status"
    stop_active_monitor build-finished
    bounded_wait_for_child "$monitor_pid"
    active_monitor_status="$child_status"
    build_status="$active_build_status"
    monitor_status="$active_monitor_status"
    monitor_was_stopped="$active_monitor_stop_requested"
  fi
  printf '%s\n' "$build_status" >"$attempt_dir/status"
  printf '%s\n' "$monitor_status" >"$attempt_dir/monitor-status"
  ccache_stats >"$attempt_dir/ccache-after.txt"
  monitor_was_stopped="${monitor_was_stopped:-0}"
  clear_active_attempt

  BUILD_PGID_FOR_JOURNAL="$build_pgid" \
    "$JOURNAL_COMMAND" -k --since "$attempt_start" --no-pager -o short-iso \
    >"$attempt_dir/kernel-journal.txt" 2>&1 || true

  if test "$monitor_status" -ne 0 && test "$monitor_was_stopped" -ne 1; then
    final_status=70
    printf '%s\n' "$final_status" >"$UNATTENDED_OUTPUT_DIR/final-status"
    exit "$final_status"
  fi

  if test "$build_status" -eq 0; then
    if verified_final_images; then
      final_status=0
      printf '%s\n' "$final_status" >"$UNATTENDED_OUTPUT_DIR/final-status"
      printf '%s\n' "$attempt_number" >"$UNATTENDED_OUTPUT_DIR/successful-attempt"
      exit 0
    fi
    final_status=65
    printf 'Build exited successfully but final images failed verification\n' >&2
    printf '%s\n' "$final_status" >"$UNATTENDED_OUTPUT_DIR/final-status"
    exit "$final_status"
  fi

  final_status="$build_status"
  resource_failure=0
  test ! -s "$attempt_dir/resource-pressure.flag" || resource_failure=1
  if test "$resource_failure" -eq 0 && journal_proves_group_oom \
      "$attempt_dir/kernel-journal.txt" "$attempt_dir/build-group-pids.txt"; then
    resource_failure=1
    printf 'reason=kernel-oom pgid=%s\n' "$build_pgid" >"$attempt_dir/resource-pressure.flag"
  fi

  if test "$resource_failure" -eq 0; then
    printf '%s\n' "$final_status" >"$UNATTENDED_OUTPUT_DIR/final-status"
    exit "$final_status"
  fi
done

printf '%s\n' "$final_status" >"$UNATTENDED_OUTPUT_DIR/final-status"
exit "$final_status"
