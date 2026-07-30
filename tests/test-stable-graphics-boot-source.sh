#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
builder="$repo_root/scripts/build-stable-graphics-boot.sh"
patch_file="$repo_root/patches/rmx1901-stable-graphics.patch"
userdata_patch="$repo_root/patches/rmx1901-real-userdata.patch"
touch_bridge="$repo_root/scripts/rmx1901-touch-bridge.py"

test -x "$builder"
test -s "$patch_file"
test -s "$userdata_patch"
bash -n "$builder"
test -x "$touch_bridge"
python3 -c 'import pathlib, sys; compile(pathlib.Path(sys.argv[1]).read_bytes(), sys.argv[1], "exec")' "$touch_bridge"

grep -Fq 'expected_base_sha256=693abe6f79dd7bc5ad65942a45a9a186275bf0c7982ce10b9cdb6852035f98a2' "$builder"
grep -Fq 'expected_libsdedrm_sha256=40911f7e86f077d75df653bd79e1f6f40c609a092f11fefe32931b699cabf5da' "$builder"
grep -Fq 'expected_allocator_sha256=c3945aafcddf01917ec37f57a68c6004eb6a82664d0d55fee2a0efdfe596f999' "$builder"
grep -Fq 'expected_systemd_logind_sha256=605d88720c7589213cd9f84299a1813dfc2087e4654e74657fba346b10c219b5' "$builder"
grep -Fq 'expected_partition_size=67108864' "$builder"
grep -Fq 'avbtool verify_image' "$builder"
grep -Fq 'unpack_bootimg --boot_img "$out_dir/boot.img"' "$builder"
grep -Fq 'verify-rmx1901-dtb-chain.sh' "$builder"
grep -Fq 'cpio --null --owner=0:0 -o -H newc' "$builder"
grep -Fq 'rmx1901-touch-bridge.py' "$builder"
grep -Fq 'cmp "$touch_bridge"' "$builder"
grep -Fq 'kernel_image="${KERNEL_IMAGE:-}"' "$builder"
grep -Fq 'mkbootimg_args[index + 1]="$selected_kernel"' "$builder"
grep -Fq 'cmp "$selected_kernel" "$out_dir/verify/unpack/kernel"' "$builder"
grep -Fq 'kernel_override=' "$builder"
grep -Fq 'RMX1901_CANDIDATE_RECOVERY_TIMEOUT' "$builder"
grep -Fq 'candidate recovery timeout must be an integer in [120, 600] seconds' "$builder"
grep -Fq 'rmx1901-candidate-recovery-watchdog.sh' "$builder"
grep -Fq 'control=/userdata/rmx1901-autonomous/recovery-control' "$builder"
grep -Fq 'exec "$control" recovery' "$builder"
grep -Fq 'rmx1901-candidate-boot-ack.service' "$builder"
grep -Fq 'Requires=lightdm.service' "$builder"
grep -Fq 'After=lightdm.service' "$builder"
grep -Fq 'WantedBy=graphical.target' "$builder"
grep -Fq 'candidate-boot-ack.sh' "$builder"
grep -Fq 'watchdog_install="install -D -m 0755 \"\${rootmnt}\"/compat/systemd249/rmx1901-candidate-boot-ack.sh' "$builder"
grep -Fq 'install -D -m 0644 \"\${rootmnt}\"/compat/systemd249/rmx1901-candidate-boot-ack.service' "$builder"
grep -Fq 'candidate_watchdog=' "$builder"
grep -Fq 'camera_provider_rc=' "$builder"
grep -Fq 'RMX1901_CAMERA_VENDOR_DIR' "$builder"
grep -Fq 'RMX1901_BLUETOOTH_PRIVATE_LIBCPP' "$builder"
grep -Fq 'bluetooth private-libc++ mode must be 0 or 1' "$builder"
grep -Fq 'android.hardware.bluetooth@1.0-service-qti.rc' "$builder"
grep -Fq '86b0cf7fe04b1f415773ef410d627f14482a7826945c38ecfe0450dd569edb8c' "$builder"
grep -Fq 'cb118e98c74d3454858921123b9b51ba13df9cad7dfa141dd892c453661a4d78' "$builder"
grep -Fq 'setenv LD_PRELOAD /vendor/lib64/libc++.so' "$builder"
grep -Fq 'Bluetooth private libc++ verification failed' "$builder"
grep -Fq 'first_file() {' "$builder"
grep -Fq 'verified_bluetooth_compat=' "$builder"
grep -Fq 'bluetooth_insertion = r' "$builder"
grep -Fq 'bluetooth_private_libcpp=' "$builder"
grep -Fq 'camera_cohort_files=(' "$builder"
grep -Fq 'camera_cohort_hashes=(' "$builder"
grep -Fq 'camera pre-init property stage' "$builder"
grep -Fq 'camera vendor build.prop preimage=' "$builder"
grep -Fq 'vendor build.prop preimage mismatch' "$builder"
grep -Fq 'camera_prop_rows=$(grep -Ec' "$builder"
grep -Fq "grep -Fxc 'ro.hardware.camera=qcom'" "$builder"
grep -Fq 'rmx1901-camera-data-dir.rc' "$builder"
grep -Fq 'mkdir /data/vendor/camera 0770 camera camera' "$builder"
grep -Fq 'disabled' "$builder"
if grep -Fq 'setprop ro.hardware.camera qcom' "$builder"; then
    echo 'camera read-only property is still set from an imported late init RC' >&2
    exit 1
fi
grep -Fq 'bind_file \"$SRC/camera-a11/$rel\" \"$rel\" \"A11 camera cohort\"' "$builder"
grep -Fq 'camera_cohort=' "$builder"
grep -Fq 'setenv LD_LIBRARY_PATH /vendor/lib64/egl:/vendor/lib64:/system/lib64' "$builder"
grep -Fq 'camera init stage verification failed' "$builder"
grep -Fq "camera_provider_rc=''" "$builder"
grep -Fq 'disabled until an' "$builder"
grep -Fq 'if [[ -n "$camera_vendor_dir" ]]; then' "$builder"
grep -Fq 'fastrpc_device_rc=' "$builder"
grep -Fq 'rmx1901-fastrpc-device-permissions.rc' "$builder"
grep -Fq 'chown system system /dev/adsprpc-smd' "$builder"
grep -Fq 'chmod 0664 /dev/adsprpc-smd' "$builder"
grep -Fq 'chmod 0644 /dev/adsprpc-smd-secure' "$builder"
grep -Fq 'chown bluetooth net_bt /dev/ttyHS0' "$builder"
grep -Fq 'chmod 0660 /dev/ttyHS0' "$builder"
grep -Fq 'restart vendor.bluetooth-1-0-qti' "$builder"
grep -Fq 'on property:sys.boot_completed=1' "$builder"
grep -Fq 'restart vendor.adsprpcd_sensorspd' "$builder"
grep -Fq 'restart vendor.adsprpcd_audiopd' "$builder"
grep -Fq 'FastRPC device-permission init stage' "$builder"
grep -Fq 'INIT_STAGE=/userdata/rmx1901-vendor-init.$$' "$builder"
grep -Fq 'bind_directory \"$INIT_STAGE\" etc/init' "$builder"
if grep -Fq 'bind_file "$SRC/etc/init/rmx1901-fastrpc-device-permissions.rc"' "$builder"; then
    echo 'FastRPC init RC still requires a nonexistent vendor target file' >&2
    exit 1
fi
grep -Fq 'fastrpc_device_permissions=enabled' "$builder"

grep -Fq 'libhwc2on1adapter.so libsdmcore.so libsdedrm.so libEGL_adreno.so' "$patch_file"
grep -Fq 'KERNEL=="hwbinder", MODE="0666"' "$patch_file"
grep -Fq 'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/32011/bus' "$patch_file"
grep -Fq 'rmx1901-user-session-ready.service' "$patch_file"
grep -Fq 'mount -n -o bind "${rootmnt}/userdata/rmx1901-linger" "$var_systemd_dir/linger"' "$patch_file"
grep -Fq 'systemd-logind 249 bind failed' "$patch_file"
grep -Fq 'rmx1901-touch-bridge.service' "$patch_file"
grep -Fq 'Requires=rmx1901-graphics-hal-ready.service rmx1901-user-session-ready.service rmx1901-touch-bridge.service' "$patch_file"
grep -Fq 'Type=notify' "$patch_file"
grep -Fq 'NotifyAccess=main' "$patch_file"
grep -Fq 'userdata_recovery=replayed path=$userdata_canonical' "$userdata_patch"
grep -Fq 'userdata_mount=rw-validated type=f2fs path=$userdata_canonical' "$userdata_patch"
grep -Fq 'Could not mount validated RMX1901 userdata writable' "$userdata_patch"
if grep -Eq '^\+.*userdata_mount=tmpfs-rescue' "$userdata_patch"; then
    echo 'stable graphics patch still adds a tmpfs physical-userdata rescue' >&2
    exit 1
fi

if grep -Ein 'password|passwd|sudo[[:space:]]+-S|(^|[^[:alnum:]_])(wipe|erase|blkdiscard)([^[:alnum:]_]|$)' \
    "$builder" "$patch_file" "$userdata_patch" "$touch_bridge"; then
    echo 'stable graphics builder contains a credential or destructive-storage operation' >&2
    exit 1
fi

echo 'stable graphics boot source gate passed'
