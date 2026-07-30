#!/usr/bin/env bash
# Stage, hash-verify, and atomically publish the private API30 HIDL Wi-Fi
# cohort. This deliberately does not alter an Android mount or restart LXC.
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <complete-wifi-cohort.json>" >&2
    exit 64
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
manifest="$(realpath -e "$1")"
host="${RMX1901_SSH_HOST:-phablet@10.15.19.82}"
port="${RMX1901_SSH_PORT:-8022}"
known_hosts="${RMX1901_KNOWN_HOSTS:-/tmp/rmx1901-ssh-known-hosts}"
target=/userdata/rmx1901-hw/wifi
feature_root=/userdata/rmx1901-hw/wifi/

"$repo_root/scripts/verify-rmx1901-abi-cohort.py" "$manifest" >/dev/null
[[ "$(jq -r '.complete' "$manifest")" == true ]]
[[ "$(jq -r '.entries[].feature' "$manifest" | sort -u)" == wifi ]]

stage="$(mktemp -d "${TMPDIR:-/tmp}/rmx1901-wifi-stage.XXXXXXXX")"
cleanup() {
    find "$stage" -mindepth 1 -depth -delete 2>/dev/null || true
    rmdir "$stage" 2>/dev/null || true
}
trap cleanup EXIT

while IFS=$'\t' read -r release source_path destination expected; do
    source_root="$(jq -r --arg release "$release" '.source_roots[$release]' "$manifest")"
    [[ -n "$source_root" && "$source_root" != null ]]
    source="$source_root/${source_path#/}"
    relative="${destination#"$feature_root"}"
    [[ "$destination" == "$feature_root"* && -n "$relative" && "$relative" != *'..'* ]]
    [[ -f "$source" && ! -L "$source" ]]
    actual="$(sha256sum "$source" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]]
    mkdir -p "$stage/$(dirname "$relative")"
    cp -a "$source" "$stage/$relative"
done < <(jq -r '.entries[] | [.source_release, .source_path, .runtime_destination, .sha256] | @tsv' "$manifest")

remote_stage="/userdata/rmx1901-hw/.wifi-incoming-$$"
ssh -o ProxyCommand=none -o "UserKnownHostsFile=$known_hosts" \
    -o StrictHostKeyChecking=yes -o ConnectTimeout=8 -p "$port" "$host" \
    "printf '\\n' | sudo -S sh -ec 'test ! -e \"$target\"; test ! -e \"$remote_stage\"; install -d -o phablet -g phablet -m 0700 \"$remote_stage\"'"
scp -o ProxyCommand=none -o "UserKnownHostsFile=$known_hosts" \
    -o StrictHostKeyChecking=yes -o ConnectTimeout=8 -P "$port" \
    -r "$stage/." "$host:$remote_stage/"

expected_list="$stage/expected.sha256"
jq -r '.entries[] | [.sha256, (.runtime_destination | sub("^/userdata/rmx1901-hw/wifi/"; ""))] | @tsv' "$manifest" \
    | while IFS=$'\t' read -r hash relative; do printf '%s  %s\n' "$hash" "$relative"; done >"$expected_list"
scp -o ProxyCommand=none -o "UserKnownHostsFile=$known_hosts" \
    -o StrictHostKeyChecking=yes -o ConnectTimeout=8 -P "$port" \
    "$expected_list" "$host:$remote_stage/expected.sha256"
ssh -o ProxyCommand=none -o "UserKnownHostsFile=$known_hosts" \
    -o StrictHostKeyChecking=yes -o ConnectTimeout=8 -p "$port" "$host" \
    "printf '\\n' | sudo -S sh -ec 'cd \"$remote_stage\"; sha256sum -c expected.sha256; rm expected.sha256; chown -R root:root .; find . -type d -exec chmod 0755 {} +; find . -type f -exec chmod 0644 {} +; chmod 0755 bin/hw/android.hardware.wifi@1.0-service; mv \"$remote_stage\" \"$target\"; test -d \"$target\"'"

echo "staged complete Wi-Fi HIDL cohort at $host:$target"
