#!/usr/bin/env bash
# Install the Wi-Fi pre-start hook and its systemd ordering. It does not
# restart the unit; the next full device boot is the sole activation point.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
host="${RMX1901_SSH_HOST:-phablet@10.15.19.82}"
port="${RMX1901_SSH_PORT:-8022}"
known_hosts="${RMX1901_KNOWN_HOSTS:-/tmp/rmx1901-ssh-known-hosts}"
prestart=/userdata/rmx1901-hw/wifi/rmx1901-wifi-hidl-prestart.sh
dropin=/etc/systemd/system/lxc-android-config.service.d/zz-rmx1901-wifi-hidl.conf

for path in \
    "$repo_root/systemd/rmx1901-wifi-hidl-prestart.sh" \
    "$repo_root/systemd/rmx1901-wifi-device-permissions.rc" \
    "$repo_root/systemd/rmx1901-wifi-hidl-service.rc" \
    "$repo_root/systemd/lxc-android-config.service.d/zz-rmx1901-wifi-hidl.conf"
do
    [[ -f "$path" ]]
done

scp -o ProxyCommand=none -o "UserKnownHostsFile=$known_hosts" \
    -o StrictHostKeyChecking=yes -o ConnectTimeout=8 -P "$port" \
    "$repo_root/systemd/rmx1901-wifi-hidl-prestart.sh" \
    "$repo_root/systemd/rmx1901-wifi-device-permissions.rc" \
    "$repo_root/systemd/rmx1901-wifi-hidl-service.rc" \
    "$repo_root/systemd/lxc-android-config.service.d/zz-rmx1901-wifi-hidl.conf" \
    "$host:/tmp/"
ssh -o ProxyCommand=none -o "UserKnownHostsFile=$known_hosts" \
    -o StrictHostKeyChecking=yes -o ConnectTimeout=8 -p "$port" "$host" \
    "printf '\\n' | sudo -S sh -ec 'test ! -e \"$prestart\"; test ! -e \"$dropin\"; install -m 0755 /tmp/rmx1901-wifi-hidl-prestart.sh \"$prestart\"; install -m 0644 /tmp/rmx1901-wifi-device-permissions.rc /userdata/rmx1901-hw/wifi/rmx1901-wifi-device-permissions.rc; install -m 0644 /tmp/rmx1901-wifi-hidl-service.rc /userdata/rmx1901-hw/wifi/rmx1901-wifi-hidl-service.rc; install -D -m 0644 /tmp/zz-rmx1901-wifi-hidl.conf \"$dropin\"; rm /tmp/rmx1901-wifi-hidl-prestart.sh /tmp/rmx1901-wifi-device-permissions.rc /tmp/rmx1901-wifi-hidl-service.rc /tmp/zz-rmx1901-wifi-hidl.conf; sh -n \"$prestart\"; systemctl daemon-reload; systemctl cat lxc-android-config.service'"
