#!/usr/bin/env bash
set -euo pipefail

SELF=$(readlink -f "$0")

emit_process_table() {
    local caller_pid=$PPID
    local signal_log=${FAKE_SIGNAL_LOG:?}

    if [[ ${FAKE_SCENARIO:-base} != base ]]; then
        local count=0
        if [[ -f ${FAKE_PS_COUNT_FILE:?} ]]; then
            read -r count < "$FAKE_PS_COUNT_FILE"
        fi
        count=$((count + 1))
        printf '%s\n' "$count" > "$FAKE_PS_COUNT_FILE"
        printf '%s\n' \
            "1 0 1 /sbin/init" \
            "100 1 100 /opt/codex/bin/codex --session current"
        if [[ ${FAKE_SCENARIO} == lost-keep && $count -ge 2 ]]; then
            printf '%s\n' "$caller_pid 1 $caller_pid bash scripts/prepare-speed-build.sh"
        else
            printf '%s\n' "$caller_pid 100 $caller_pid bash scripts/prepare-speed-build.sh"
        fi
        if [[ ${FAKE_SCENARIO} != survivor && -f "$signal_log" ]] &&
           grep -Fxq -- '-200' "$signal_log"; then
            return
        fi
        case "${FAKE_SCENARIO}" in
            new-descendant)
                printf '%s\n' "200 1 200 /usr/local/bin/codex --session stale"
                if (( count >= 2 )); then
                    printf '%s\n' "150 100 200 /usr/bin/bash --new-protected-descendant"
                fi
                ;;
            changed-command)
                if (( count == 1 )); then
                    printf '%s\n' "200 1 200 /usr/local/bin/codex --session stale"
                else
                    printf '%s\n' "200 1 200 /usr/local/bin/codex --session changed"
                fi
                ;;
            changed-pgid)
                if (( count == 1 )); then
                    printf '%s\n' "200 1 200 /usr/local/bin/codex --session stale"
                else
                    printf '%s\n' "200 1 201 /usr/local/bin/codex --session stale"
                fi
                ;;
            lost-keep)
                printf '%s\n' "200 1 200 /usr/local/bin/codex --session stale"
                ;;
            survivor)
                printf '%s\n' "200 1 200 /usr/local/bin/codex --session stale"
                ;;
            *)
                printf 'unknown FAKE_SCENARIO: %s\n' "$FAKE_SCENARIO" >&2
                exit 2
                ;;
        esac
        return
    fi

    printf '%s\n' \
        "1 0 1 /sbin/init" \
        "100 1 100 /opt/codex/bin/codex --session current" \
        "$caller_pid 100 $caller_pid bash scripts/prepare-speed-build.sh" \
        "101 100 101 /opt/codex/bin/codex --session nested" \
        "102 100 100 gh run watch 12" \
        "200 1 200 /usr/local/bin/codex --session stale" \
        "201 200 200 codex-helper" \
        "300 1 300 node /opt/agents/okx-a2a run --worker stale" \
        "350 1 350 node /opt/important/server.js --label /tmp/okx-a2a run --do-not-stop" \
        "400 1 400 gh run watch 999 --exit-status" \
        "500 1 500 /usr/bin/proxychains4 codex --proxy-session" \
        "600 1 600 /usr/bin/plasmashell" \
        "700 1 100 /usr/local/bin/codex --session shared-pgid" \
        "800 1 801 /usr/local/bin/codex --session not-group-root" \
        "900 1 900 /usr/local/bin/codex --session contains-mihomo-party" \
        "901 900 900 /opt/mihomo-party/mihomo-party --profile default" \
        "910 1 910 /usr/local/bin/codex --session contains-kde" \
        "911 910 910 /usr/bin/plasmashell --no-respawn" \
        "920 1 920 /usr/local/bin/codex --session contains-protected" \
        "921 100 920 /usr/bin/bash --protected-descendant" |
    while IFS= read -r row; do
        local pgid
        pgid=$(printf '%s\n' "$row" | awk '{print $3}')
        if [[ ! -f "$signal_log" ]] || ! grep -Fxq -- "-$pgid" "$signal_log"; then
            printf '%s\n' "$row"
        fi
    done
}

case "$(basename "$0")" in
    ps)
        emit_process_table
        exit 0
        ;;
    pstree)
        printf '%s\n' 'codex(100)---bash' 'codex(100)---codex(101)'
        exit 0
        ;;
    signal-command)
        [[ $# -eq 3 ]]
        [[ $1 == -TERM ]]
        [[ $2 == -- ]]
        printf '%s\n' "$3" >> "${FAKE_SIGNAL_LOG:?}"
        exit 0
        ;;
    monotonic-seconds)
        count=0
        if [[ -f ${FAKE_TIME_COUNT_FILE:?} ]]; then
            read -r count < "$FAKE_TIME_COUNT_FILE"
        fi
        count=$((count + 1))
        printf '%s\n' "$count" > "$FAKE_TIME_COUNT_FILE"
        if (( count <= 2 )); then
            printf '0\n'
        else
            printf '15\n'
        fi
        exit 0
        ;;
    sleep-command)
        [[ $# -eq 1 && $1 == 1 ]]
        printf '%s\n' "$1" >> "${FAKE_SLEEP_LOG:?}"
        exit 0
        ;;
esac

ROOT=$(cd "$(dirname "$SELF")/.." && pwd)
SCRIPT="$ROOT/scripts/prepare-speed-build.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_BIN" "$TMP/port/artifacts/host-optimization"
ln -s "$SELF" "$FAKE_BIN/ps"
ln -s "$SELF" "$FAKE_BIN/pstree"
ln -s "$SELF" "$FAKE_BIN/signal-command"
ln -s "$SELF" "$FAKE_BIN/monotonic-seconds"
ln -s "$SELF" "$FAKE_BIN/sleep-command"
export FAKE_SIGNAL_LOG="$TMP/signals.log"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

[[ -x "$SCRIPT" ]] || fail "production script does not exist: $SCRIPT"

assert_selected_only() {
    local output=$1
    local selected
    selected=$(awk '
        /action=(dry-run|term)/ {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^pid=/) {
                    sub(/^pid=/, "", $i)
                    print $i
                }
            }
        }
    ' "$output" | sort -n | paste -sd, -)
    [[ $selected == 200,300,400 ]] ||
        fail "selected PIDs were [$selected], expected [200,300,400]"
}

DRY_OUTPUT="$TMP/dry-run.out"
PATH="$FAKE_BIN:$PATH" PORT_ROOT="$TMP/port" KEEP_CODEX_PID=100 \
    DRY_RUN=1 SIGNAL_COMMAND="$FAKE_BIN/signal-command" \
    "$SCRIPT" >"$DRY_OUTPUT" 2>&1

assert_selected_only "$DRY_OUTPUT"
[[ ! -e "$FAKE_SIGNAL_LOG" ]] || fail 'dry-run invoked the signal command'
grep -Fq 'cmd=/usr/local/bin/codex --session stale' "$DRY_OUTPUT" ||
    fail 'cleanup record omitted the complete command'
find "$TMP/port/artifacts/host-optimization" -type f -name 'process-cleanup-*.log' |
    grep -q . || fail 'dry-run did not create a timestamped cleanup log'

LIVE_OUTPUT="$TMP/live.out"
PATH="$FAKE_BIN:$PATH" PORT_ROOT="$TMP/port" KEEP_CODEX_PID=100 \
    SIGNAL_COMMAND="$FAKE_BIN/signal-command" \
    "$SCRIPT" >"$LIVE_OUTPUT" 2>&1

assert_selected_only "$LIVE_OUTPUT"
[[ $(sort -n "$FAKE_SIGNAL_LOG" | paste -sd, -) == -400,-300,-200 ]] ||
    fail 'live mode did not signal exactly PGIDs 200, 300, and 400'
grep -q 'action=exited' "$LIVE_OUTPUT" || fail 'live mode did not record exited process groups'
if grep -q 'action=survivor' "$LIVE_OUTPUT"; then
    fail 'live fixture unexpectedly reported survivors'
fi

INVALID_OUTPUT="$TMP/invalid.out"
if PATH="$FAKE_BIN:$PATH" PORT_ROOT="$TMP/port" KEEP_CODEX_PID=200 \
    DRY_RUN=1 SIGNAL_COMMAND="$FAKE_BIN/signal-command" \
    "$SCRIPT" >"$INVALID_OUTPUT" 2>&1; then
    fail 'existing KEEP_CODEX_PID outside the current ancestry was accepted'
fi
grep -q 'KEEP_CODEX_PID.*ancestry' "$INVALID_OUTPUT" ||
    fail 'invalid ancestry refusal was not explained'

run_changed_snapshot_case() {
    local scenario=$1
    rm -f "$FAKE_SIGNAL_LOG" "$FAKE_PS_COUNT_FILE"
    local output="$TMP/$scenario.out"
    PATH="$FAKE_BIN:$PATH" PORT_ROOT="$TMP/port" KEEP_CODEX_PID=100 \
        FAKE_SCENARIO="$scenario" SIGNAL_COMMAND="$FAKE_BIN/signal-command" \
        "$SCRIPT" >"$output" 2>&1
    grep -q 'action=changed-skip' "$output" ||
        fail "$scenario was not recorded as changed-skip"
    [[ ! -s "$FAKE_SIGNAL_LOG" ]] ||
        fail "$scenario invoked the signal command"
}

export FAKE_PS_COUNT_FILE="$TMP/ps-count"
run_changed_snapshot_case new-descendant
run_changed_snapshot_case changed-command
run_changed_snapshot_case changed-pgid
run_changed_snapshot_case lost-keep

rm -f "$FAKE_SIGNAL_LOG" "$FAKE_PS_COUNT_FILE"
export FAKE_TIME_COUNT_FILE="$TMP/time-count"
export FAKE_SLEEP_LOG="$TMP/sleep.log"
SURVIVOR_OUTPUT="$TMP/survivor.out"
if ! /usr/bin/timeout 3 env PATH="$FAKE_BIN:$PATH" PORT_ROOT="$TMP/port" \
    KEEP_CODEX_PID=100 FAKE_SCENARIO=survivor \
    SIGNAL_COMMAND="$FAKE_BIN/signal-command" \
    MONOTONIC_SECONDS_COMMAND="$FAKE_BIN/monotonic-seconds" \
    SLEEP_COMMAND="$FAKE_BIN/sleep-command" \
    "$SCRIPT" >"$SURVIVOR_OUTPUT" 2>&1; then
    fail 'survivor fixture did not complete through the injected 15-second clock'
fi
grep -q 'action=survivor' "$SURVIVOR_OUTPUT" ||
    fail 'live timeout did not record the surviving process group'
[[ $(cat "$FAKE_SIGNAL_LOG") == -200 ]] ||
    fail 'survivor fixture did not receive exactly one SIGTERM delivery'
[[ $(cat "$FAKE_SLEEP_LOG") == 1 ]] ||
    fail 'survivor polling did not use the injected one-second sleep'

printf 'PASS: safe aggressive cleanup behavior\n'
