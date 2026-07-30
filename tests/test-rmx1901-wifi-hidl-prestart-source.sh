#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
prestart="$repo_root/systemd/rmx1901-wifi-hidl-prestart.sh"
dropin="$repo_root/systemd/lxc-android-config.service.d/zz-rmx1901-wifi-hidl.conf"
installer="$repo_root/scripts/install-rmx1901-wifi-hidl-prestart.sh"
service_rc="$repo_root/systemd/rmx1901-wifi-hidl-service.rc"

sh -n "$prestart"
bash -n "$installer"
grep -Fq 'setenv LD_LIBRARY_PATH /vendor/lib64/hw' "$prestart"
grep -Fq 'vendor.wifi_hal_legacy /vendor/bin/hw/android.hardware.wifi@1.0-service' "$prestart"
grep -Fq 'failed to remove incompatible Wi-Fi capabilities' "$prestart"
grep -Fq 'rmx1901-wifi-hidl-service.rc' "$prestart"
grep -Fq '"$WIFI_ROOT/lib64" -maxdepth 1 -type f | wc -l)" -eq 26' "$prestart"
grep -Fq 'mount --bind "$INIT_STAGE" "$base/etc/init"' "$prestart"
grep -Fq 'ExecStartPre=/userdata/rmx1901-hw/wifi/rmx1901-wifi-hidl-prestart.sh' "$dropin"
grep -Fq 'service vendor.rmx1901_wifi_hidl /vendor/bin/hw/android.hardware.wifi@1.0-service' "$service_rc"
grep -Fq 'stop vendor.wifi_hal_legacy' "$service_rc"
! grep -Eq 'systemctl (start|stop|restart)|lxc-stop|lxc-start' "$installer"
echo 'Wi-Fi HIDL pre-start source test passed'
