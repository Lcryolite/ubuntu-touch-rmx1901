#!/usr/bin/env bash
# Capture sensitive RMX1901 failure evidence from Recovery without writing a
# partition.  The caller may perform a separately hash-pinned rollback only
# after this script reports success.
set -euo pipefail
umask 077

usage() {
    cat >&2 <<'EOF'
usage: rmx1901-capture-recovery-evidence.sh --out DIR [--serial SERIAL] [--timeout SECONDS]

DIR must not already exist. Captured block images can contain private memory
and key material; the directory is created mode 0700 and files mode 0600.
EOF
    exit 2
}

serial=7b0c1c49
out=''
timeout_seconds=1800
while (($#)); do
    case "$1" in
        --out) (($# >= 2)) || usage; out=$2; shift 2 ;;
        --serial) (($# >= 2)) || usage; serial=$2; shift 2 ;;
        --timeout) (($# >= 2)) || usage; timeout_seconds=$2; shift 2 ;;
        -h|--help) usage ;;
        *) usage ;;
    esac
done

[[ -n "$out" && "$serial" =~ ^[A-Za-z0-9._-]+$ ]] || usage
[[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || usage
[[ ! -e "$out" ]] || { echo "error: evidence directory exists: $out" >&2; exit 2; }
command -v adb >/dev/null
command -v sha256sum >/dev/null
command -v timeout >/dev/null

[[ "$(adb -s "$serial" get-state 2>/dev/null || true)" == recovery ]] || {
    echo "error: $serial is not in Recovery ADB" >&2
    exit 1
}

mkdir -m 0700 -- "$out"
out="$(cd "$out" && pwd -P)"
mkdir -m 0700 -- "$out/blocks" "$out/runtime"
manifest="$out/manifest.env"
blocks="$out/blocks.tsv"
printf 'label\tby_name\tresolved\tmajor_minor\tbytes\timage\tsha256\n' >"$blocks"
{
    echo 'schema=rmx1901-recovery-evidence-v1'
    echo "capture_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "serial=$serial"
    echo "adb_state=$(adb -s "$serial" get-state)"
} >"$manifest"

adb -s "$serial" shell 'ls -l /dev/block/by-name; find /sys/fs/pstore -maxdepth 1 -type f -printf "%f %s\n" 2>/dev/null || :' \
    >"$out/runtime/recovery-state.txt" 2>&1 || true

resolve_block() {
    local label=$1 raw path bytes major_minor
    raw="$(adb -s "$serial" shell "readlink -f /dev/block/by-name/$label" 2>/dev/null | tr -d '\r' | tail -n 1)"
    [[ "$raw" =~ ^/dev/block/[A-Za-z0-9._/-]+$ ]] || return 1
    path="$raw"
    bytes="$(adb -s "$serial" shell "blockdev --getsize64 '$path'" 2>/dev/null | tr -d '\r' | tail -n 1)"
    [[ "$bytes" =~ ^[1-9][0-9]*$ ]] || return 1
    major_minor="$(adb -s "$serial" shell "stat -c '%t:%T' '$path'" 2>/dev/null | tr -d '\r' | tail -n 1)"
    [[ "$major_minor" =~ ^[0-9a-fA-F]+:[0-9a-fA-F]+$ ]] || return 1
    printf '%s\t%s\t%s\t%s\n' "/dev/block/by-name/$label" "$path" "$major_minor" "$bytes"
}

capture_block() {
    local label=$1 required=$2 info by_name path major_minor bytes image actual digest
    if ! info="$(resolve_block "$label")"; then
        if [[ "$required" == required ]]; then
            echo "error: required Recovery block is unavailable: $label" >&2
            return 1
        fi
        printf '%s\tmissing\tmissing\tmissing\tmissing\tmissing\tmissing\n' "$label" >>"$blocks"
        return 0
    fi
    IFS=$'\t' read -r by_name path major_minor bytes <<<"$info"
    image="$out/blocks/$label.img"
    # adb exec-out truncates long Recovery streams on this device.  The adb
    # sync protocol used by pull transferred a verified 128 MiB rawdump, so
    # use it for every block image.  This opens the device only for reading.
    if ! timeout "$timeout_seconds" adb -s "$serial" pull "$path" "$image"; then
        rm -f -- "$image"
        if [[ "$required" == required ]]; then
            echo "error: required Recovery block pull failed: $label" >&2
            return 1
        fi
        echo "warning: optional Recovery block pull failed: $label" >&2
        printf '%s\tpull-failed\tpull-failed\tpull-failed\tpull-failed\tmissing\tmissing\n' "$label" >>"$blocks"
        return 0
    fi
    actual="$(stat -c %s "$image")"
    [[ "$actual" == "$bytes" ]] || {
        rm -f -- "$image"
        if [[ "$required" == required ]]; then
            echo "error: $label capture size mismatch: expected $bytes got $actual" >&2
            return 1
        fi
        echo "warning: optional Recovery block size mismatch: $label expected $bytes got $actual" >&2
        printf '%s\tsize-mismatch\tsize-mismatch\tsize-mismatch\tsize-mismatch\tmissing\tmissing\n' "$label" >>"$blocks"
        return 0
    }
    digest="$(sha256sum "$image" | awk '{print $1}')"
    chmod 0600 "$image"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$label" "$by_name" "$path" "$major_minor" "$bytes" "blocks/$label.img" "$digest" >>"$blocks"
}

# rawdump is first: a later rollback/reboot must never precede preservation.
capture_block rawdump required
dd if="$out/blocks/rawdump.img" of="$out/blocks/rawdump-header-4k.bin" bs=4096 count=1 status=none
chmod 0600 "$out/blocks/rawdump-header-4k.bin"
capture_block logdump optional
capture_block logfs optional
capture_block boot required
capture_block misc required

adb -s "$serial" shell 'find /sys/fs/pstore -maxdepth 1 -type f -exec sh -c '\''echo ===$1; cat "$1"'\'' sh {} \; 2>/dev/null || :' \
    >"$out/runtime/pstore.txt" 2>&1 || true
chmod 0600 "$out/runtime"/*
(
    cd "$out"
    find . -type f -printf '%P\0' | LC_ALL=C sort -z | xargs -0 sha256sum
) >"$out/sha256sums.txt"
chmod 0600 "$out/sha256sums.txt"
echo 'capture_status=complete' >>"$manifest"
sync -f "$out/sha256sums.txt" 2>/dev/null || sync
printf 'evidence_dir=%s\n' "$out"
