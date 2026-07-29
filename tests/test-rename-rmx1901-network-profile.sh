#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/scripts/rename-rmx1901-network-profile.sh"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/rmx1901-nm-test.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT
fake="$tmp_root/nmcli"

cat >"$fake" <<'PY'
#!/usr/bin/env python3
import json
import os
import sys

state_path = os.environ["FAKE_NM_STATE"]
log_path = os.environ["FAKE_NM_LOG"]
args = sys.argv[1:]
with open(log_path, "a", encoding="utf-8") as stream:
    stream.write(json.dumps(args, separators=(",", ":")) + "\n")
with open(state_path, encoding="utf-8") as stream:
    state = json.load(stream)


def save():
    with open(state_path, "w", encoding="utf-8") as stream:
        json.dump(state, stream, sort_keys=True)


def profile(uuid):
    for item in state["profiles"]:
        if item["uuid"] == uuid:
            return item
    raise SystemExit(10)

if args[:2] == ["-g", "GENERAL.CON-UUID"] and args[2:4] == ["device", "show"]:
    print(state.get("active", {}).get(args[4], ""))
elif args[:2] == ["-g", "connection.id,connection.uuid,connection.type,connection.interface-name"] and args[2:5] == ["connection", "show", "uuid"]:
    item = profile(args[5])
    value = item["id"]
    marker = os.environ.get("FAKE_FAIL_POST_MARKER")
    if marker and value == "RMX1901" and not os.path.exists(marker):
        open(marker, "w", encoding="utf-8").close()
        value = "verification-failure"
    print(value)
    print(item["uuid"])
    print(item["type"])
    print(item.get("interface", ""))
elif args == ["--escape", "no", "-t", "-f", "UUID,NAME,TYPE", "connection", "show"]:
    for item in state["profiles"]:
        print(f'{item["uuid"]}:{item["id"]}:{item["type"]}')
elif args[:2] == ["-g", "connection.interface-name"] and args[2:5] == ["connection", "show", "uuid"]:
    print(profile(args[5]).get("interface", ""))
elif args[:3] == ["connection", "modify", "uuid"] and args[4] == "connection.id":
    item = profile(args[3])
    item["id"] = args[5]
    save()
else:
    print("unexpected nmcli call: " + repr(args), file=sys.stderr)
    raise SystemExit(97)
PY
chmod +x "$fake" "$script"

uuid_a=11111111-2222-3333-4444-555555555555
uuid_b=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
write_state() {
    python3 - "$FAKE_NM_STATE" "$1" "$2" "${3:-}" <<'PY'
import json, sys
path, first_id, first_iface, conflict = sys.argv[1:]
profiles = [{"uuid": "11111111-2222-3333-4444-555555555555", "id": first_id,
             "type": "802-3-ethernet", "interface": first_iface}]
if conflict:
    profiles.append({"uuid": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "id": conflict,
                     "type": "802-3-ethernet", "interface": first_iface})
with open(path, "w", encoding="utf-8") as stream:
    json.dump({"active": {"usb0": profiles[0]["uuid"]}, "profiles": profiles}, stream)
PY
}
read_id() {
    python3 - "$FAKE_NM_STATE" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["profiles"][0]["id"])
PY
}

export NMCLI="$fake"
export FAKE_NM_STATE="$tmp_root/state.json"
export FAKE_NM_LOG="$tmp_root/calls.jsonl"

# Already-correct active profile is a no-op.
: >"$FAKE_NM_LOG"
write_state RMX1901 usb0
output="$($script --interface usb0)"
grep -Fxq "network_profile_uuid=$uuid_a" <<<"$output"
grep -Fxq 'network_profile_rename=noop' <<<"$output"
test "$(read_id)" = RMX1901
! grep -Fq '"modify"' "$FAKE_NM_LOG"

# Old profile is renamed by UUID and remains active without cycling the device.
: >"$FAKE_NM_LOG"
write_state rmx1901-bringup usb0
output="$($script --interface usb0)"
grep -Fxq 'network_profile_rename=changed' <<<"$output"
test "$(read_id)" = RMX1901
python3 - "$FAKE_NM_STATE" "$uuid_a" <<'PY'
import json, sys
state = json.load(open(sys.argv[1], encoding="utf-8"))
assert state["active"]["usb0"] == sys.argv[2]
assert state["profiles"][0]["uuid"] == sys.argv[2]
PY

# A conflicting applicable old/target profile fails closed.
: >"$FAKE_NM_LOG"
write_state rmx1901-bringup usb0 RMX1901
set +e
$script --interface usb0 >"$tmp_root/conflict.out" 2>"$tmp_root/conflict.err"
status=$?
set -e
test "$status" -eq 4
test "$(read_id)" = rmx1901-bringup

# Missing active UUID fails without creating or modifying a profile.
python3 - "$FAKE_NM_STATE" <<'PY'
import json, sys
json.dump({"active": {}, "profiles": []}, open(sys.argv[1], "w", encoding="utf-8"))
PY
: >"$FAKE_NM_LOG"
set +e
$script --interface usb0 >"$tmp_root/missing.out" 2>"$tmp_root/missing.err"
status=$?
set -e
test "$status" -eq 3
! grep -Fq '"modify"' "$FAKE_NM_LOG"

# Unexpected IDs require explicit override.
write_state custom-debug usb0
set +e
$script --interface usb0 >/dev/null 2>"$tmp_root/unexpected.err"
status=$?
set -e
test "$status" -eq 1
test "$(read_id)" = custom-debug
$script --interface usb0 --allow-id custom-debug >/dev/null
test "$(read_id)" = RMX1901

# A failed post-check restores the exact original ID by the same UUID.
write_state rmx1901-bringup usb0
marker="$tmp_root/fail-post.marker"
set +e
FAKE_FAIL_POST_MARKER="$marker" $script --uuid "$uuid_a" --interface usb0 \
    >"$tmp_root/rollback.out" 2>"$tmp_root/rollback.err"
status=$?
set -e
test "$status" -ne 0
test "$(read_id)" = rmx1901-bringup
grep -Fq 'restored original ID' "$tmp_root/rollback.err"

# Source-level safety: no connection activation/reload, device cycling, sudo, or UUID mutation.
if grep -E 'connection (up|down|reload)|device (connect|disconnect)|general reload|sudo|modify.*connection\.uuid' "$script"; then
    echo 'unsafe NetworkManager operation in rename script' >&2
    exit 1
fi

echo 'RMX1901 NetworkManager profile rename tests passed'
