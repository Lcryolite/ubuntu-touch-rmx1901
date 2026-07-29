#!/usr/bin/env bash
# Bounded, read-only RMX1901 hardware evidence collector.
set -uo pipefail
export LC_ALL=C
umask 077

usage() {
    cat >&2 <<'EOF'
usage: collect-rmx1901-hardware-evidence.sh --out DIR --phase NAME \
       [--ssh-target USER@HOST --ssh-port PORT --known-hosts FILE] \
       [--identity FILE] [--bind-address ADDRESS] [--host-key-evidence FILE] \
       [--timeout SECONDS] [--offline]

The output directory must not exist. Without --offline, strict public-key SSH is
mandatory. Collection is read-only and every command is bounded and recorded.
EOF
    exit 2
}

out=""
phase=""
ssh_target=""
ssh_port=22
known_hosts=""
identity=""
bind_address=""
host_key_evidence=""
command_timeout=15
offline=0
while (($#)); do
    case "$1" in
        --out) (($# >= 2)) || usage; out="$2"; shift 2 ;;
        --phase) (($# >= 2)) || usage; phase="$2"; shift 2 ;;
        --ssh-target) (($# >= 2)) || usage; ssh_target="$2"; shift 2 ;;
        --ssh-port) (($# >= 2)) || usage; ssh_port="$2"; shift 2 ;;
        --known-hosts) (($# >= 2)) || usage; known_hosts="$2"; shift 2 ;;
        --identity) (($# >= 2)) || usage; identity="$2"; shift 2 ;;
        --bind-address) (($# >= 2)) || usage; bind_address="$2"; shift 2 ;;
        --host-key-evidence) (($# >= 2)) || usage; host_key_evidence="$2"; shift 2 ;;
        --timeout) (($# >= 2)) || usage; command_timeout="$2"; shift 2 ;;
        --offline) offline=1; shift ;;
        -h|--help) usage ;;
        *) usage ;;
    esac
done

[[ -n "$out" && -n "$phase" ]] || usage
[[ "$phase" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo 'error: unsafe phase name' >&2; exit 2; }
[[ "$ssh_port" =~ ^[0-9]+$ && "$ssh_port" -ge 1 && "$ssh_port" -le 65535 ]] || { echo 'error: invalid SSH port' >&2; exit 2; }
[[ "$command_timeout" =~ ^[1-9][0-9]*$ && "$command_timeout" -le 300 ]] || { echo 'error: invalid timeout' >&2; exit 2; }
[[ ! -e "$out" ]] || { echo "error: output path already exists: $out" >&2; exit 2; }

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

for tool in date find git ip nmcli python3 sha256sum ssh ssh-keygen sync timeout; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "error: missing required tool: $tool" >&2
        exit 1
    }
done

if ((offline == 0)); then
    [[ -n "$ssh_target" && -n "$known_hosts" ]] || {
        echo 'error: strict SSH target and known-hosts file are required' >&2
        exit 2
    }
    [[ -f "$known_hosts" && ! -L "$known_hosts" ]] || {
        echo 'error: known-hosts must be a regular non-symlink file' >&2
        exit 2
    }
    if [[ -n "$identity" ]]; then
        [[ -f "$identity" && ! -L "$identity" ]] || {
            echo 'error: identity must be a regular non-symlink file' >&2
            exit 2
        }
    fi
fi
if [[ -n "$host_key_evidence" ]]; then
    [[ -f "$host_key_evidence" && ! -L "$host_key_evidence" ]] || {
        echo 'error: host-key evidence must be a regular non-symlink file' >&2
        exit 2
    }
fi

out_parent="$(dirname "$out")"
mkdir -p -- "$out_parent"
out_parent="$(cd "$out_parent" && pwd -P)"
out="$out_parent/$(basename "$out")"
mkdir -m 0700 -- "$out"
mkdir -m 0700 -- "$out/pre-state" "$out/runtime" "$out/logs"
commands="$out/commands.tsv"
printf 'id\tscope\ttimeout_s\texit_code\tstart_monotonic_s\tend_monotonic_s\toutput\tcommand\tgate\n' >"$commands"
if [[ -n "$host_key_evidence" ]]; then
    install -m 0600 -- "$host_key_evidence" "$out/pre-state/ssh-host-key-verification.txt"
fi

monotonic() {
    awk '{print $1}' /proc/uptime
}

sanitize_field() {
    tr '\t\r\n' '   '
}

overall_status=0
run_recorded() {
    local id="$1" scope="$2" output="$3"
    shift 3
    local gate=critical
    if [[ "${1:-}" == --noncritical ]]; then
        gate=observed
        shift
    fi
    local start end status command_text
    start="$(monotonic)"
    command_text="$(printf '%q ' "$@" | sanitize_field)"
    timeout --signal=TERM --kill-after=2 "$command_timeout" "$@" >"$out/$output" 2>&1
    status=$?
    end="$(monotonic)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$id" "$scope" "$command_timeout" "$status" "$start" "$end" "$output" "$command_text" "$gate" >>"$commands"
    if ((status != 0)) && [[ "$gate" == critical ]]; then
        overall_status=1
    fi
    return 0
}

ssh_base=(ssh -p "$ssh_port" -o BatchMode=yes -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$known_hosts" \
    -o PreferredAuthentications=publickey -o PasswordAuthentication=no \
    -o KbdInteractiveAuthentication=no -o ForwardAgent=no \
    -o ClearAllForwardings=yes -o RequestTTY=no)
[[ -z "$identity" ]] || ssh_base+=(-o IdentitiesOnly=yes -i "$identity")
[[ -z "$bind_address" ]] || ssh_base+=(-b "$bind_address")
ssh_base+=("$ssh_target")

run_remote() {
    local id="$1" output="$2" remote_command="$3" gate="${4:-critical}"
    if [[ "$gate" == observed ]]; then
        run_recorded "$id" device "$output" --noncritical "${ssh_base[@]}" "set -eu; $remote_command"
    else
        run_recorded "$id" device "$output" "${ssh_base[@]}" "set -eu; $remote_command"
    fi
}

host_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
host_boot_id="$(cat /proc/sys/kernel/random/boot_id)"
{
    echo 'schema=rmx1901-hardware-evidence-v1'
    echo "phase=$phase"
    echo "host_utc=$host_utc"
    echo "host_boot_id=$host_boot_id"
    echo "collector_sha256=$(sha256sum "$0" | awk '{print $1}')"
    echo "offline=$offline"
} >"$out/manifest.env"

# Host-side provenance and immutable baseline pointers.
{
    echo "adaptation_head=$(git -C "$repo_root" rev-parse HEAD)"
    echo "adaptation_origin=$(git -C "$repo_root" remote get-url origin 2>/dev/null || true)"
    echo 'adaptation_status_begin'
    git -C "$repo_root" status --porcelain=v1
    echo 'adaptation_status_end'
    for candidate in \
        "$repo_root/workdir/downloads/kernel_realme_sdm710_ubuntu_touch" \
        "$repo_root/../kernel_realme_sdm710_ubuntu_touch" \
        "$repo_root/../rmx1901-halium11"; do
        if [[ -d "$candidate/.git" ]]; then
            echo "repo=$candidate"
            echo "head=$(git -C "$candidate" rev-parse HEAD)"
            echo 'status_begin'
            git -C "$candidate" status --porcelain=v1
            echo 'status_end'
        fi
    done
} >"$out/source-state.txt"
run_recorded source-pins host runtime/source-pins.txt "$repo_root/scripts/verify-source-pins.sh" "$repo_root/workdir"
run_recorded host-route host pre-state/host-route.txt ip route show table all
host_link_command='ip -br link | awk "{print \$1, \$2}"'
run_recorded host-links host pre-state/host-links.txt bash -c "$host_link_command"
run_recorded host-nm-devices host pre-state/host-nm-devices.txt nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device
run_recorded host-nm-profiles host pre-state/host-nm-profiles.txt nmcli -t -f UUID,NAME,TYPE,DEVICE connection show

if ((offline == 0)); then
    run_recorded ssh-host-fingerprint host pre-state/ssh-host-fingerprint.txt ssh-keygen -lf "$known_hosts"
    run_remote auth runtime/auth.txt 'id; printf "boot_id="; cat /proc/sys/kernel/random/boot_id; printf "pid1="; tr "\0" " " </proc/1/cmdline; echo'
    run_remote kernel runtime/kernel.txt 'uname -a; cat /proc/cmdline; cat /proc/uptime; cat /proc/sys/kernel/random/boot_id'
    run_remote mounts pre-state/mounts.txt 'findmnt /userdata; findmnt /android; findmnt /run'
    run_remote boot-hash runtime/boot-sha256.txt 'sudo -n sha256sum /dev/sde10; sudo -n blockdev --getsize64 /dev/sde10'
    run_remote units pre-state/units.txt 'systemctl show lxc-android-config lightdm rmx1901-touch-bridge -p Id -p ActiveState -p SubState -p NRestarts; systemctl --failed --no-pager'
    run_remote android runtime/android.txt 'sudo -n lxc-info -n android; sudo -n lxc-attach -n android -- /system/bin/getprop sys.boot_completed'
    run_remote network runtime/network.txt 'nmcli -t -f STATE,CONNECTIVITY general; nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device; ip -br link | awk '\''{print $1, $2}'\''; ip rule; ip route show table all; rfkill list'
    run_remote audio runtime/audio.txt 'cat /proc/asound/cards; pactl_u() { if [ "$(id -u)" -eq 0 ]; then runuser -u phablet -- env XDG_RUNTIME_DIR=/run/user/32011 PULSE_SERVER=unix:/run/user/32011/pulse/native pactl "$@"; else env XDG_RUNTIME_DIR=/run/user/32011 PULSE_SERVER=unix:/run/user/32011/pulse/native pactl "$@"; fi; }; pactl_u list short cards; pactl_u list short sinks; pactl_u list short sources' observed
    run_remote channels runtime/channels.txt 'sudo -n cat /sys/kernel/debug/glink/channel/channels; echo __ICNSS__; sudo -n cat /sys/kernel/debug/icnss/stats' observed
    run_remote android-properties runtime/android-properties.txt 'sudo -n lxc-attach -n android -- /system/bin/getprop sys.boot_completed; sudo -n lxc-attach -n android -- /system/bin/getprop ro.build.version.release; sudo -n lxc-attach -n android -- /system/bin/getprop ro.build.version.sdk; sudo -n lxc-attach -n android -- /system/bin/getprop ro.product.device'
    run_remote android-hal runtime/android-hal.txt 'sudo -n lxc-attach -n android -- /system/bin/lshal -l' observed
    run_remote devices runtime/devices.txt 'ls -ld /dev/adsprpc-smd* /dev/snd /dev/video* /dev/media* 2>&1 || :; sudo -n lxc-attach -n android -- sh -c "ls -ld /dev/adsprpc-smd* /dev/snd /dev/video* /dev/media* 2>&1 || :"' observed
    run_remote endpoint-ownership pre-state/endpoint-ownership.txt 'systemctl show bluetooth bluebinder -p Id -p LoadState -p ActiveState -p SubState -p NRestarts 2>&1 || :; ps -A -o user,pid,ppid,comm,args | grep -E "(bluebinder|bluetoothd|android.hardware.bluetooth|adsprpcd|pd-mapper|camera.provider|wifi.*service)" | grep -v grep || :; ls -l /dev/vhci /dev/wlan /dev/ttyHS* 2>&1 || :' observed
    run_remote dsp-services runtime/dsp-services.txt 'printf "boot_adsp="; cat /sys/kernel/boot_adsp/boot 2>&1 || :; for prop in init.svc.vendor.pd_mapper init.svc.vendor.adsprpcd init.svc.vendor.adsprpcd_audiopd init.svc.vendor.adsprpcd_sensorspd; do printf "%s=" "$prop"; sudo -n lxc-attach -n android -- /system/bin/getprop "$prop"; done' observed
    run_remote radio-devices runtime/radio-devices.txt 'iw dev 2>&1 || :; hciconfig -a 2>&1 || :; btmgmt info 2>&1 || :; rfkill list bluetooth 2>&1 || :' observed
    run_remote journal logs/journal.txt 'journalctl -b --no-pager -n 3000' observed
    run_remote dmesg logs/dmesg.txt 'sudo -n dmesg' observed
    run_remote android-log logs/logcat.txt 'sudo -n lxc-attach -n android -- /system/bin/logcat -b all -d' observed
    run_remote boot-history runtime/boot-history.txt 'journalctl --list-boots --no-pager; last -x | head -100' observed
else
    overall_status=3
    printf 'requirement\tstatus\tevidence\nP0-SSH-AUTH\tBLOCKED\truntime/auth.txt\n' >"$out/acceptance.tsv"
    printf 'offline collection: authenticated device state not attempted\n' >"$out/runtime/auth.txt"
fi

if [[ ! -f "$out/acceptance.tsv" ]]; then
    {
        printf 'requirement\tstatus\tevidence\n'
        if grep -Fxq 'source_pins=pass' "$out/runtime/source-pins.txt"; then
            printf 'P0-SOURCE-PINS\tPASS\truntime/source-pins.txt\n'
        else
            printf 'P0-SOURCE-PINS\tFAIL\truntime/source-pins.txt\n'
        fi
        if grep -Eq '^uid=(32011\(phablet\)|0\(root\))' "$out/runtime/auth.txt"; then
            printf 'P0-SSH-AUTH\tPASS\truntime/auth.txt\n'
        else
            printf 'P0-SSH-AUTH\tFAIL\truntime/auth.txt\n'
        fi
        if grep -Eq '^[0-9a-f]{64}  /dev/sde10$' "$out/runtime/boot-sha256.txt" && grep -Fxq '67108864' "$out/runtime/boot-sha256.txt"; then
            printf 'P0-BOOT-IDENTITY\tPASS\truntime/boot-sha256.txt\n'
        else
            printf 'P0-BOOT-IDENTITY\tFAIL\truntime/boot-sha256.txt\n'
        fi
    } >"$out/acceptance.tsv"
fi
if grep -Eq $'\t(FAIL|BLOCKED)\t' "$out/acceptance.tsv"; then
    ((overall_status == 3)) || overall_status=1
fi

printf 'exit_status=%s\n' "$overall_status" >>"$out/manifest.env"
sync -f "$out" 2>/dev/null || sync
python3 - "$out" <<'PY'
import os
import sys
root = sys.argv[1]
for directory, _, files in os.walk(root):
    for name in files:
        path = os.path.join(directory, name)
        with open(path, "rb") as stream:
            os.fsync(stream.fileno())
    descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
PY
(
    cd "$out"
    find . -type f ! -name sha256sums.txt -printf '%P\0' | LC_ALL=C sort -z | xargs -0 -r sha256sum
) >"$out/sha256sums.txt"
sync -f "$out/sha256sums.txt" 2>/dev/null || sync

printf 'evidence_dir=%s\n' "$out"
printf 'evidence_exit_status=%s\n' "$overall_status"
exit "$overall_status"
