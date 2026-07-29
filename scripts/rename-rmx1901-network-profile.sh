#!/usr/bin/env bash
# Idempotently rename one existing RMX1901 USB Ethernet profile by UUID.
set -euo pipefail
export LC_ALL=C

usage() {
    cat >&2 <<'EOF'
usage: rename-rmx1901-network-profile.sh [--interface IFACE] [--uuid UUID] [--allow-id ID]

At least --interface or --uuid is required. The script changes only connection.id;
it never creates, activates, reloads, disconnects, or reconnects a profile.
EOF
    exit 2
}

iface=""
uuid=""
allow_id=""
while (($#)); do
    case "$1" in
        --interface)
            (($# >= 2)) || usage
            iface="$2"
            shift 2
            ;;
        --uuid)
            (($# >= 2)) || usage
            uuid="$2"
            shift 2
            ;;
        --allow-id)
            (($# >= 2)) || usage
            allow_id="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            usage
            ;;
    esac
done

[[ -n "$iface" || -n "$uuid" ]] || usage
nmcli_bin="${NMCLI:-nmcli}"
command -v "$nmcli_bin" >/dev/null 2>&1 || {
    echo "error: nmcli executable is missing" >&2
    exit 1
}

valid_uuid() {
    [[ "$1" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]
}

if [[ -z "$uuid" ]]; then
    uuid="$($nmcli_bin -g GENERAL.CON-UUID device show "$iface")"
    if [[ -z "$uuid" || "$uuid" == "--" ]]; then
        echo "error: target interface has no active connection UUID: $iface" >&2
        exit 3
    fi
fi
valid_uuid "$uuid" || {
    echo "error: invalid connection UUID" >&2
    exit 2
}

mapfile -t properties < <($nmcli_bin -g connection.id,connection.uuid,connection.type,connection.interface-name connection show uuid "$uuid")
[[ ${#properties[@]} -eq 4 ]] || {
    echo "error: unable to read exactly four connection properties for UUID $uuid" >&2
    exit 3
}
old_id="${properties[0]}"
actual_uuid="${properties[1]}"
connection_type="${properties[2]}"
bound_iface="${properties[3]}"

[[ "$actual_uuid" == "$uuid" ]] || {
    echo "error: NetworkManager returned a different UUID" >&2
    exit 3
}
[[ "$connection_type" == "802-3-ethernet" ]] || {
    echo "error: target profile is not 802-3-ethernet" >&2
    exit 1
}
if [[ -n "$iface" && -n "$bound_iface" && "$bound_iface" != "$iface" ]]; then
    echo "error: target profile is bound to another interface" >&2
    exit 1
fi

# Reject another old/target-named Ethernet profile that could apply to this interface.
while IFS=: read -r other_uuid other_name other_type; do
    [[ -n "$other_uuid" ]] || continue
    [[ "$other_uuid" != "$uuid" ]] || continue
    [[ "$other_name" == "RMX1901" || "$other_name" == "rmx1901-bringup" ]] || continue
    [[ "$other_type" == "802-3-ethernet" ]] || continue
    other_iface="$($nmcli_bin -g connection.interface-name connection show uuid "$other_uuid")"
    if [[ -z "$iface" || -z "$other_iface" || "$other_iface" == "$iface" ]]; then
        echo "error: conflicting applicable RMX1901 profile: $other_uuid" >&2
        exit 4
    fi
done < <($nmcli_bin --escape no -t -f UUID,NAME,TYPE connection show)

case "$old_id" in
    RMX1901)
        echo "network_profile_uuid=$uuid"
        echo "network_profile_id=RMX1901"
        echo "network_profile_rename=noop"
        exit 0
        ;;
    rmx1901-bringup)
        ;;
    *)
        if [[ -z "$allow_id" || "$old_id" != "$allow_id" ]]; then
            echo "error: refusing unexpected connection ID: $old_id" >&2
            exit 1
        fi
        ;;
esac

rollback() {
    local status=$?
    trap - EXIT
    if ! "$nmcli_bin" connection modify uuid "$uuid" connection.id "$old_id"; then
        echo "error: rename failed and rollback also failed for UUID $uuid" >&2
        exit 70
    fi
    echo "error: rename verification failed; restored original ID" >&2
    exit "$status"
}
trap rollback EXIT
"$nmcli_bin" connection modify uuid "$uuid" connection.id RMX1901
mapfile -t post < <($nmcli_bin -g connection.id,connection.uuid,connection.type,connection.interface-name connection show uuid "$uuid")
[[ ${#post[@]} -eq 4 ]]
[[ "${post[0]}" == "RMX1901" ]]
[[ "${post[1]}" == "$uuid" ]]
[[ "${post[2]}" == "802-3-ethernet" ]]
[[ -z "$iface" || -z "${post[3]}" || "${post[3]}" == "$iface" ]]
trap - EXIT

echo "network_profile_uuid=$uuid"
echo "network_profile_id=RMX1901"
echo "network_profile_rename=changed"
