#!/bin/sh
# Execute after the existing display compatibility pre-start hook and before
# lxc-start. This keeps the complete API30 closure private to Wi-Fi.
set -eu

WIFI_ROOT=/userdata/rmx1901-hw/wifi
LOG=/run/rmxcache/rmx1901-wifi-hidl-prestart.log
TARGET_ROOTS="/android/vendor /var/lib/lxc/android/rootfs/vendor"

mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1

fatal() {
    echo "FATAL: $*" >&2
    exit 1
}

[ -d "$WIFI_ROOT/lib64" ] || fatal "missing API30 Wi-Fi library closure"
[ -x "$WIFI_ROOT/bin/hw/android.hardware.wifi@1.0-service" ] || fatal "missing API30 Wi-Fi HIDL service"
[ -f "$WIFI_ROOT/vendor/etc/init/android.hardware.wifi@1.0-service.rc" ] || fatal "missing API30 Wi-Fi init rc"
[ -f "$WIFI_ROOT/rmx1901-wifi-device-permissions.rc" ] || fatal "missing Wi-Fi node-permission rc"
[ -f "$WIFI_ROOT/rmx1901-wifi-hidl-service.rc" ] || fatal "missing private Wi-Fi HIDL init rc"
[ "$(find "$WIFI_ROOT/lib64" -maxdepth 1 -type f | wc -l)" -eq 26 ] || fatal "incomplete API30 Wi-Fi library closure"

for base in $TARGET_ROOTS; do
    [ -d "$base/lib64/hw" ] || fatal "missing private hw stage: $base/lib64/hw"
    [ -d "$base/bin/hw" ] || fatal "missing private bin stage: $base/bin/hw"
    cp -a "$WIFI_ROOT/lib64"/. "$base/lib64/hw"/ || fatal "failed to add private Wi-Fi libraries: $base"
    cp "$WIFI_ROOT/bin/hw/android.hardware.wifi@1.0-service" "$base/bin/hw/" || fatal "failed to add private Wi-Fi service: $base"
    chmod 0755 "$base/bin/hw/android.hardware.wifi@1.0-service"
done

INIT_STAGE=/userdata/rmx1901-wifi-init.$$
mkdir -p "$INIT_STAGE"
cp -a /android/vendor/etc/init/. "$INIT_STAGE"/ || fatal "failed to mirror current vendor init directory"
cp "$WIFI_ROOT/vendor/etc/init/android.hardware.wifi@1.0-service.rc" "$INIT_STAGE/android.hardware.wifi@1.0-service.rc"
cp "$WIFI_ROOT/rmx1901-wifi-device-permissions.rc" "$INIT_STAGE/"
cp "$WIFI_ROOT/rmx1901-wifi-hidl-service.rc" "$INIT_STAGE/"
WIFI_RC="$INIT_STAGE/android.hardware.wifi@1.0-service.rc"
[ "$(grep -Fxc 'service vendor.wifi_hal_legacy /vendor/bin/hw/android.hardware.wifi@1.0-service' "$WIFI_RC")" = 1 ] || fatal "unexpected API30 Wi-Fi service definition"
! grep -Fq 'setenv LD_LIBRARY_PATH' "$WIFI_RC" || fatal "unexpected Wi-Fi preload"
# This Halium LXC init cannot retain the RUI capability request for an
# unlabeled userdata-backed executable; it exits before registering IWifi.
# The proven wifi-UID probe registers with zero effective capabilities.
sed -i '/^    capabilities NET_ADMIN NET_RAW SYS_MODULE$/d' "$WIFI_RC" || fatal "failed to remove incompatible Wi-Fi capabilities"
! grep -Fq 'capabilities NET_ADMIN NET_RAW SYS_MODULE' "$WIFI_RC" || fatal "Wi-Fi capabilities removal verification failed"
sed -i '/^service vendor\.wifi_hal_legacy \/vendor\/bin\/hw\/android\.hardware\.wifi@1\.0-service$/a\    setenv LD_LIBRARY_PATH /vendor/lib64/hw' "$WIFI_RC" || fatal "failed to add Wi-Fi private search path"
grep -Fq 'setenv LD_LIBRARY_PATH /vendor/lib64/hw' "$WIFI_RC" || fatal "Wi-Fi private search-path verification failed"

for base in $TARGET_ROOTS; do
    mount --bind "$INIT_STAGE" "$base/etc/init" || fatal "failed to bind API30 Wi-Fi init stage: $base"
    cmp -s "$WIFI_RC" "$base/etc/init/android.hardware.wifi@1.0-service.rc" || fatal "Wi-Fi RC verification failed: $base"
    cmp -s "$WIFI_ROOT/rmx1901-wifi-hidl-service.rc" "$base/etc/init/rmx1901-wifi-hidl-service.rc" || fatal "private Wi-Fi HIDL RC verification failed: $base"
    cmp -s "$WIFI_ROOT/vendor/etc/vintf/manifest/android.hardware.wifi@1.0-service.xml" "$base/etc/vintf/manifest/android.hardware.wifi@1.0-service.xml" || fatal "Wi-Fi VINTF drift: $base"
done

echo "private API30 HIDL Wi-Fi closure and init replacement staged"
