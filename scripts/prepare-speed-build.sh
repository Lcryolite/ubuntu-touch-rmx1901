#!/usr/bin/env bash
set -euo pipefail

: "${KEEP_CODEX_PID:?set KEEP_CODEX_PID to the current Codex root PID}"
: "${PORT_ROOT:?set PORT_ROOT}"

if [[ ! $KEEP_CODEX_PID =~ ^[1-9][0-9]*$ ]]; then
    printf 'error: KEEP_CODEX_PID must be a positive PID\n' >&2
    exit 2
fi

SIGNAL_COMMAND=${SIGNAL_COMMAND:-kill}
SLEEP_COMMAND=${SLEEP_COMMAND:-sleep}
LOG_DIR="$PORT_ROOT/artifacts/host-optimization"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/process-cleanup-$(date -u +%Y%m%dT%H%M%SZ)-$$.log"
SNAPSHOT=$(mktemp)
VERIFY_SNAPSHOT=$(mktemp)
trap 'rm -f "$SNAPSHOT" "$VERIFY_SNAPSHOT"' EXIT

snapshot_processes() {
    ps -eo pid=,ppid=,pgid=,args= > "$1"
}

declare -A parent_by_pid=()
declare -A pgid_by_pid=()
declare -A command_by_pid=()

snapshot_processes "$SNAPSHOT"
while read -r pid ppid pgid command; do
    [[ $pid =~ ^[1-9][0-9]*$ ]] || continue
    [[ $ppid =~ ^[0-9]+$ ]] || continue
    [[ $pgid =~ ^[1-9][0-9]*$ ]] || continue
    parent_by_pid[$pid]=$ppid
    pgid_by_pid[$pid]=$pgid
    command_by_pid[$pid]=$command
done < "$SNAPSHOT"

declare -A protected_pid=()
cursor=$$
found_keep=0
while [[ $cursor =~ ^[1-9][0-9]*$ ]]; do
    protected_pid[$cursor]=1
    if [[ $cursor == "$KEEP_CODEX_PID" ]]; then
        found_keep=1
    fi
    [[ -v parent_by_pid[$cursor] ]] || break
    next=${parent_by_pid[$cursor]}
    [[ $next != "$cursor" && $next != 0 ]] || break
    cursor=$next
done

if (( ! found_keep )); then
    printf 'error: KEEP_CODEX_PID=%s is not in the current process ancestry\n' \
        "$KEEP_CODEX_PID" >&2
    exit 2
fi

# Protect the complete subtree rooted at KEEP_CODEX_PID, not the descendants
# of its ancestors (which would otherwise make every child of init protected).
declare -A descendant_pid=()
descendant_pid[$KEEP_CODEX_PID]=1
changed=1
while (( changed )); do
    changed=0
    for pid in "${!parent_by_pid[@]}"; do
        ppid=${parent_by_pid[$pid]}
        if [[ -v descendant_pid[$ppid] && ! -v descendant_pid[$pid] ]]; then
            descendant_pid[$pid]=1
            changed=1
        fi
    done
done
for pid in "${!descendant_pid[@]}"; do
    protected_pid[$pid]=1
done

declare -A protected_pgid=()
for pid in "${!protected_pid[@]}"; do
    if [[ -v pgid_by_pid[$pid] ]]; then
        protected_pgid[${pgid_by_pid[$pid]}]=1
    fi
done

is_allowed_root_command() {
    local command=$1
    local -a argv=()
    read -r -a argv <<< "$command"
    ((${#argv[@]})) || return 1
    local executable=${argv[0]##*/}
    if [[ $executable == codex ]]; then
        return 0
    fi
    if [[ $executable == node && ${#argv[@]} -ge 3 &&
          ${argv[1]##*/} == okx-a2a && ${argv[2]} == run ]]; then
        return 0
    fi
    if [[ $executable == gh && ${#argv[@]} -ge 3 &&
          ${argv[1]} == run && ${argv[2]} == watch ]]; then
        return 0
    fi
    return 1
}

is_forbidden_core_command() {
    local command=$1
    local -a argv=()
    read -r -a argv <<< "$command"
    ((${#argv[@]})) || return 1
    local executable=${argv[0]##*/}
    case "$executable" in
        clash|clash-*|mihomo|mihomo-*|sing-box|v2ray|xray|trojan|privoxy|redsocks|proxychains|proxychains4)
            return 0
            ;;
        plasmashell|kwin_x11|kwin_wayland|kded|kded[0-9]*|startplasma-x11|startplasma-wayland|ksmserver|Xorg|Xwayland)
            return 0
            ;;
    esac
    return 1
}

group_contains_forbidden_core() {
    local wanted_pgid=$1
    local row_pid row_ppid row_pgid row_command
    while read -r row_pid row_ppid row_pgid row_command; do
        [[ $row_pgid == "$wanted_pgid" ]] || continue
        if is_forbidden_core_command "$row_command"; then
            return 0
        fi
    done < "$SNAPSHOT"
    return 1
}

record() {
    local pid=$1 pgid=$2 action=$3 command=$4
    local line
    line="timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ) pid=$pid pgid=$pgid action=$action cmd=$command"
    printf '%s\n' "$line" | tee -a "$LOG_FILE"
}

monotonic_seconds() {
    local value
    if [[ -n ${MONOTONIC_SECONDS_COMMAND:-} ]]; then
        value=$("$MONOTONIC_SECONDS_COMMAND")
    else
        value=$SECONDS
    fi
    [[ $value =~ ^[0-9]+$ ]] || {
        printf 'error: monotonic clock returned a non-integer value\n' >&2
        return 2
    }
    printf '%s\n' "$value"
}

candidate_still_verified() {
    local wanted_pid=$1 wanted_pgid=$2 wanted_command=$3
    local pid ppid pgid command
    snapshot_processes "$VERIFY_SNAPSHOT"

    declare -A verify_parent=()
    declare -A verify_pgid=()
    declare -A verify_command=()
    while read -r pid ppid pgid command; do
        [[ $pid =~ ^[1-9][0-9]*$ ]] || continue
        [[ $ppid =~ ^[0-9]+$ ]] || continue
        [[ $pgid =~ ^[1-9][0-9]*$ ]] || continue
        verify_parent[$pid]=$ppid
        verify_pgid[$pid]=$pgid
        verify_command[$pid]=$command
    done < "$VERIFY_SNAPSHOT"

    declare -A verify_protected_pid=()
    local verify_cursor=$$
    local verify_found_keep=0
    while [[ $verify_cursor =~ ^[1-9][0-9]*$ ]]; do
        verify_protected_pid[$verify_cursor]=1
        if [[ $verify_cursor == "$KEEP_CODEX_PID" ]]; then
            verify_found_keep=1
        fi
        [[ -v verify_parent[$verify_cursor] ]] || break
        local verify_next=${verify_parent[$verify_cursor]}
        [[ $verify_next != "$verify_cursor" && $verify_next != 0 ]] || break
        verify_cursor=$verify_next
    done
    (( verify_found_keep )) || return 1

    declare -A verify_descendant_pid=()
    verify_descendant_pid[$KEEP_CODEX_PID]=1
    local verify_changed=1
    while (( verify_changed )); do
        verify_changed=0
        for pid in "${!verify_parent[@]}"; do
            ppid=${verify_parent[$pid]}
            if [[ -v verify_descendant_pid[$ppid] && ! -v verify_descendant_pid[$pid] ]]; then
                verify_descendant_pid[$pid]=1
                verify_changed=1
            fi
        done
    done
    for pid in "${!verify_descendant_pid[@]}"; do
        verify_protected_pid[$pid]=1
    done

    declare -A verify_protected_pgid=()
    for pid in "${!verify_protected_pid[@]}"; do
        if [[ -v verify_pgid[$pid] ]]; then
            verify_protected_pgid[${verify_pgid[$pid]}]=1
        fi
    done
    [[ ! -v verify_protected_pgid[$wanted_pgid] ]] || return 1

    [[ -v verify_command[$wanted_pid] ]] || return 1
    [[ ${verify_pgid[$wanted_pid]} == "$wanted_pgid" ]] || return 1
    [[ $wanted_pid == "$wanted_pgid" ]] || return 1
    [[ ${verify_command[$wanted_pid]} == "$wanted_command" ]] || return 1

    local initial_group verify_group
    initial_group=$(
        for pid in "${!command_by_pid[@]}"; do
            [[ ${pgid_by_pid[$pid]} == "$wanted_pgid" ]] || continue
            printf '%s\t%s\t%s\t%s\n' "$pid" "${parent_by_pid[$pid]}" \
                "${pgid_by_pid[$pid]}" "${command_by_pid[$pid]}"
        done | sort -n
    )
    verify_group=$(
        for pid in "${!verify_command[@]}"; do
            [[ ${verify_pgid[$pid]} == "$wanted_pgid" ]] || continue
            printf '%s\t%s\t%s\t%s\n' "$pid" "${verify_parent[$pid]}" \
                "${verify_pgid[$pid]}" "${verify_command[$pid]}"
        done | sort -n
    )
    [[ $verify_group == "$initial_group" ]] || return 1

    for pid in "${!verify_command[@]}"; do
        [[ ${verify_pgid[$pid]} == "$wanted_pgid" ]] || continue
        [[ ! -v verify_protected_pid[$pid] ]] || return 1
        is_forbidden_core_command "${verify_command[$pid]}" && return 1
    done
    return 0
}

declare -a candidate_pids=()
declare -a candidate_pgids=()
declare -a candidate_commands=()
for pid in "${!command_by_pid[@]}"; do
    pgid=${pgid_by_pid[$pid]}
    command=${command_by_pid[$pid]}
    [[ $pid == "$pgid" ]] || continue
    [[ ! -v protected_pid[$pid] ]] || continue
    [[ ! -v protected_pgid[$pgid] ]] || continue
    is_allowed_root_command "$command" || continue
    group_contains_forbidden_core "$pgid" && continue
    candidate_pids+=("$pid")
    candidate_pgids+=("$pgid")
    candidate_commands+=("$command")
done

if ((${#candidate_pids[@]})); then
    mapfile -t order < <(
        for index in "${!candidate_pids[@]}"; do
            printf '%s %s\n' "${candidate_pids[$index]}" "$index"
        done | sort -n | awk '{print $2}'
    )
else
    order=()
fi

declare -a signaled_pids=()
declare -a signaled_pgids=()
declare -a signaled_commands=()
for index in "${order[@]}"; do
    pid=${candidate_pids[$index]}
    pgid=${candidate_pgids[$index]}
    command=${candidate_commands[$index]}
    if [[ ${DRY_RUN:-0} == 1 ]]; then
        record "$pid" "$pgid" dry-run "$command"
        continue
    fi
    if ! candidate_still_verified "$pid" "$pgid" "$command"; then
        record "$pid" "$pgid" changed-skip "$command"
        continue
    fi
    if "$SIGNAL_COMMAND" -TERM -- "-$pgid"; then
        record "$pid" "$pgid" term "$command"
        signaled_pids+=("$pid")
        signaled_pgids+=("$pgid")
        signaled_commands+=("$command")
    else
        record "$pid" "$pgid" signal-failed "$command"
    fi
done

if ((${#signaled_pgids[@]})); then
    now=$(monotonic_seconds)
    deadline=$((now + 15))
    while :; do
        snapshot_processes "$VERIFY_SNAPSHOT"
        survivors=0
        for pgid in "${signaled_pgids[@]}"; do
            if awk -v pgid="$pgid" '$3 == pgid { found=1 } END { exit !found }' "$VERIFY_SNAPSHOT"; then
                survivors=$((survivors + 1))
            fi
        done
        now=$(monotonic_seconds)
        (( survivors == 0 || now >= deadline )) && break
        "$SLEEP_COMMAND" 1
    done

    for index in "${!signaled_pgids[@]}"; do
        pid=${signaled_pids[$index]}
        pgid=${signaled_pgids[$index]}
        command=${signaled_commands[$index]}
        if awk -v pgid="$pgid" '$3 == pgid { found=1 } END { exit !found }' "$VERIFY_SNAPSHOT"; then
            record "$pid" "$pgid" survivor "$command"
        else
            record "$pid" "$pgid" exited "$command"
        fi
    done
fi

printf 'cleanup_log=%s\n' "$LOG_FILE"
