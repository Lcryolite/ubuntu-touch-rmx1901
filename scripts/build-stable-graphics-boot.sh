#!/usr/bin/env bash
# Build the cold-boot-validated RMX1901 graphics/session image as a fail-closed
# derivative of the pinned QTI allocator image.
set -euo pipefail

usage() {
    echo "usage: KERNEL_IMAGE=/path/to/Image.gz-dtb $0 BASE_QTI_BOOT A11_LIBSDEDRM SYSTEMD249_LOGIND OUTPUT_DIR [DTS_OUTPUT_DIR]" >&2
    exit 2
}

[[ $# -ge 4 && $# -le 5 ]] || usage

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
base_boot="$(realpath -e "$1")"
libsdedrm="$(realpath -e "$2")"
systemd_logind="$(realpath -e "$3")"
out_dir="$4"
dts_output="${5:-}"
kernel_image="${KERNEL_IMAGE:-}"
if [[ -n "$kernel_image" ]]; then
    kernel_image="$(realpath -e "$kernel_image")"
    [[ -s "$kernel_image" ]] || { echo "error: empty kernel override: $kernel_image" >&2; exit 1; }
fi
candidate_recovery_timeout="${RMX1901_CANDIDATE_RECOVERY_TIMEOUT:-}"
if [[ -n "$candidate_recovery_timeout" ]]; then
    [[ "$candidate_recovery_timeout" =~ ^[0-9]+$ ]] && \
        (( candidate_recovery_timeout >= 120 && candidate_recovery_timeout <= 600 )) || {
        echo 'error: candidate recovery timeout must be an integer in [120, 600] seconds' >&2
        exit 1
    }
fi
camera_vendor_dir="${RMX1901_CAMERA_VENDOR_DIR:-}"
if [[ -n "$camera_vendor_dir" ]]; then
    camera_vendor_dir="$(realpath -e "$camera_vendor_dir")"
    [[ -d "$camera_vendor_dir" ]] || {
        echo "error: camera vendor directory is not a directory: $camera_vendor_dir" >&2
        exit 1
    }
fi
bluetooth_private_libcpp="${RMX1901_BLUETOOTH_PRIVATE_LIBCPP:-0}"
[[ "$bluetooth_private_libcpp" == 0 || "$bluetooth_private_libcpp" == 1 ]] || {
    echo 'error: bluetooth private-libc++ mode must be 0 or 1' >&2
    exit 1
}
patch_file="${repo_root}/patches/rmx1901-stable-graphics.patch"
userdata_patch="${repo_root}/patches/rmx1901-real-userdata.patch"
touch_bridge="${repo_root}/scripts/rmx1901-touch-bridge.py"

expected_base_sha256=693abe6f79dd7bc5ad65942a45a9a186275bf0c7982ce10b9cdb6852035f98a2
expected_libsdedrm_sha256=40911f7e86f077d75df653bd79e1f6f40c609a092f11fefe32931b699cabf5da
expected_allocator_sha256=c3945aafcddf01917ec37f57a68c6004eb6a82664d0d55fee2a0efdfe596f999
expected_systemd_logind_sha256=605d88720c7589213cd9f84299a1813dfc2087e4654e74657fba346b10c219b5
expected_bluetooth_rc_sha256=86b0cf7fe04b1f415773ef410d627f14482a7826945c38ecfe0450dd569edb8c
expected_bluetooth_libcpp_sha256=cb118e98c74d3454858921123b9b51ba13df9cad7dfa141dd892c453661a4d78
expected_partition_size=67108864
avb_salt=a5cc69c8b42844b7f93b6685e722a10ae0451e7aa0ae3fb745f502ecebf7732b

for tool in avbtool cpio gzip mkbootimg patch python3 sha256sum unpack_bootimg; do
    command -v "$tool" >/dev/null || { echo "error: missing required tool: $tool" >&2; exit 1; }
done
[[ -s "$patch_file" ]] || { echo "error: missing persistence patch: $patch_file" >&2; exit 1; }
[[ -s "$userdata_patch" ]] || { echo "error: missing userdata patch: $userdata_patch" >&2; exit 1; }
[[ -s "$touch_bridge" ]] || { echo "error: missing touch bridge: $touch_bridge" >&2; exit 1; }
python3 -c 'import pathlib, sys; compile(pathlib.Path(sys.argv[1]).read_bytes(), sys.argv[1], "exec")' "$touch_bridge"

sha256_of() {
    sha256sum "$1" | awk '{print $1}'
}

require_hash() {
    local path="$1" expected="$2" label="$3" actual
    actual="$(sha256_of "$path")"
    [[ "$actual" == "$expected" ]] || {
        echo "error: $label hash mismatch: expected $expected, got $actual" >&2
        exit 1
    }
}

require_hash "$base_boot" "$expected_base_sha256" "base QTI boot image"
require_hash "$libsdedrm" "$expected_libsdedrm_sha256" "A11 libsdedrm.so"
require_hash "$systemd_logind" "$expected_systemd_logind_sha256" "systemd 249 logind"
[[ "$(stat -c %s "$base_boot")" -eq "$expected_partition_size" ]] || {
    echo "error: base QTI boot image is not exactly ${expected_partition_size} bytes" >&2
    exit 1
}

camera_cohort_files=(
    bin/hw/android.hardware.camera.provider@2.4-service_64
    lib64/android.hardware.camera.provider@2.4-external.so
    lib64/android.hardware.camera.provider@2.4-legacy.so
    lib64/camera.device@1.0-impl.so
    lib64/camera.device@3.2-impl.so
    lib64/camera.device@3.3-impl.so
    lib64/camera.device@3.4-external-impl.so
    lib64/camera.device@3.4-impl.so
    lib64/camera.device@3.5-external-impl.so
    lib64/camera.device@3.5-impl.so
    lib64/camera.device@3.6-external-impl.so
    lib64/hw/android.hardware.camera.provider@2.4-impl.so
)
camera_cohort_hashes=(
    7c45b6f43ecfdc70da5d19d3e02caa2a3af7a9d38924288827d8ce70e4821173
    5d975e63a9699c2b096bc588b35f4eb1896d5309cbf91cf98016a83e497d0c34
    65c88cec1dd7faa587461f88d4ba84e111355acc314f16a5ae0f7784ccfd0a03
    2117f8d19f043b72879ec599d309b9152edf8fcce9110b0b901c22656bad0992
    c2a94df8423db7079f1aad7eabee7dedc859456b7dc52490361115d55ac8ba9f
    416c5c74dabf0fd0fae61acef264c84cd48d67c707ca436cd514a970757af688
    4bd841231afcf98724890707c3c237d2052320f6b8a84a4f4fdd2c67686c8096
    7780374ad5729146887062386c3a6ae5fa67727b67ec29134eafbb1dc5a5c51c
    ef11e957a1758d15e1063f39370d5fe8aecc778796dbc1563e48775b04caf67c
    bd19c88dbc093e3cb78841c9d4436c6a4031394d56ff617cc039b5bbae1d8d7f
    b409677341dad568f29854cd48c2a6c788aead5b24e07a29d0eee802ffc41f0d
    dde482cb0149bb182674106910898657e8c530134d42af8e530ecb5092ff67f0
)
[[ "${#camera_cohort_files[@]}" -eq "${#camera_cohort_hashes[@]}" ]] || {
    echo 'error: camera cohort manifest is malformed' >&2
    exit 1
}
if [[ -n "$camera_vendor_dir" ]]; then
    for index in "${!camera_cohort_files[@]}"; do
        require_hash "$camera_vendor_dir/${camera_cohort_files[index]}" \
            "${camera_cohort_hashes[index]}" "A11 camera cohort ${camera_cohort_files[index]}"
    done
fi

mkdir -p "$out_dir"
out_dir="$(realpath "$out_dir")"
[[ -z "$(find "$out_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]] || {
    echo "error: output directory is not empty: $out_dir" >&2
    exit 1
}
work_dir="$(mktemp -d "${out_dir}/.build.XXXXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
mkdir -p "$work_dir/base-verify" "$work_dir/unpack" "$work_dir/ramdisk-root"
cp --reflink=auto "$base_boot" "$work_dir/base-verify/boot.img"
avbtool verify_image --image "$work_dir/base-verify/boot.img" >"$out_dir/base-avb-verify.txt"

unpack_bootimg --boot_img "$base_boot" --out "$work_dir/unpack" --format=mkbootimg -0 \
    >"$work_dir/base-mkbootimg-args.bin"
[[ -s "$work_dir/unpack/kernel" && -s "$work_dir/unpack/ramdisk" ]] || {
    echo "error: unpacked base image is missing kernel or ramdisk" >&2
    exit 1
}
gzip -t "$work_dir/unpack/ramdisk"
selected_kernel="$work_dir/unpack/kernel"
if [[ -n "$kernel_image" ]]; then
    install -m 0644 "$kernel_image" "$work_dir/kernel-override"
    selected_kernel="$work_dir/kernel-override"
fi
(
    cd "$work_dir/ramdisk-root"
    gzip -dc "$work_dir/unpack/ramdisk" | cpio -idm --no-absolute-filenames \
        >"$out_dir/base-cpio-extract.txt" 2>&1
)

allocator="$work_dir/ramdisk-root/compat/vendor-compat/bin/hw/android.hardware.graphics.allocator@2.0-service"
require_hash "$allocator" "$expected_allocator_sha256" "embedded QTI allocator"
patch -d "$work_dir/ramdisk-root" -p1 --fuzz=0 <"$patch_file" \
    >"$out_dir/persistence-patch.txt"
patch -d "$work_dir/ramdisk-root" -p1 --fuzz=0 <"$userdata_patch" \
    >"$out_dir/userdata-patch.txt"
install -m 0644 "$libsdedrm" \
    "$work_dir/ramdisk-root/compat/vendor-compat/lib64/libsdedrm.so"
install -m 0755 "$systemd_logind" \
    "$work_dir/ramdisk-root/compat/systemd249/systemd-logind249"
install -m 0755 "$touch_bridge" \
    "$work_dir/ramdisk-root/compat/systemd249/rmx1901-touch-bridge.py"

# Android's ueventd has the correct RMX1901 FastRPC ownership rules, but the
# LXC Android /dev tmpfs can miss the boot-time event for these two nodes.
# Repair only those nodes from Android init and retry the affected DSP service
# after boot; this deliberately has no LightDM, graphics, or camera dependency.
fastrpc_device_rc="$work_dir/ramdisk-root/compat/vendor-compat/etc/init/rmx1901-fastrpc-device-permissions.rc"
mkdir -p "$(dirname "$fastrpc_device_rc")"
cat >"$fastrpc_device_rc" <<'EOF'
# Match device/realme/RMX1901/rootdir/ueventd.qcom.rc when the LXC device
# namespace has missed the original uevent for these already-present nodes.
on post-fs-data
    chown system system /dev/adsprpc-smd
    chmod 0664 /dev/adsprpc-smd
    chown system system /dev/adsprpc-smd-secure
    chmod 0644 /dev/adsprpc-smd-secure
    # device/realme/RMX1901/rootdir/etc/init.qcom.rc: the QTI Bluetooth
    # service owns the WCN3990 UART. LXC misses this Android init action.
    chown bluetooth net_bt /dev/ttyHS0
    chmod 0660 /dev/ttyHS0

# adsprpcd can have entered its retry loop before post-fs-data. Repeat the
# idempotent repair after Android is fully booted, then restart the two
# source-declared FastRPC process domains.  A failure here must not hold up
# the graphical session.
on property:sys.boot_completed=1
    chown system system /dev/adsprpc-smd
    chmod 0664 /dev/adsprpc-smd
    chown system system /dev/adsprpc-smd-secure
    chmod 0644 /dev/adsprpc-smd-secure
    chown bluetooth net_bt /dev/ttyHS0
    chmod 0660 /dev/ttyHS0
    restart vendor.adsprpcd_sensorspd
    restart vendor.adsprpcd_audiopd
    restart vendor.bluetooth-1-0-qti
EOF

compat_script="$work_dir/ramdisk-root/compat/systemd249/apply-vendor-compat.sh"
python3 - "$compat_script" "$bluetooth_private_libcpp" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
bluetooth_private_libcpp = sys.argv[2]
sentinel = 'echo "isolated vendor compatibility overlay complete (A11 vndsm + allocator2 + mapper2 + Hybris cohort)"\n'
insertion = """# LXC can miss the boot-time uevent for FastRPC nodes.  The vendor
# partition has no pre-existing target for this new RC, so stage a full copy of
# its init directory, add only the source-backed repair, then bind that staged
# directory.  This preserves every original vendor init action.
first_file() {
    rel=$1
    for base in $TARGET_ROOTS; do
        if [ -f "$base/$rel" ]; then
            printf '%s\\n' "$base/$rel"
            return 0
        fi
    done
    return 1
}

INIT_STAGE=/userdata/rmx1901-vendor-init.$$
mkdir -p \"$INIT_STAGE\"
init_seed=$(first_directory etc/init) || fatal \"no physical vendor etc/init directory\"
cp -a \"$init_seed\"/. \"$INIT_STAGE\"/ || fatal \"failed to mirror physical vendor init directory\"
cp \"$SRC/etc/init/rmx1901-fastrpc-device-permissions.rc\" \"$INIT_STAGE\"/ || fatal \"failed to stage FastRPC device-permission init rc\"
chmod 0644 \"$INIT_STAGE/rmx1901-fastrpc-device-permissions.rc\"
bind_directory \"$INIT_STAGE\" etc/init \"FastRPC device-permission init stage\"
for base in $TARGET_ROOTS; do
    [ -d \"$base/etc/init\" ] || continue
    cmp -s \"$SRC/etc/init/rmx1901-fastrpc-device-permissions.rc\" \"$base/etc/init/rmx1901-fastrpc-device-permissions.rc\" || fatal \"FastRPC device-permission init verification failed: $base/etc/init/rmx1901-fastrpc-device-permissions.rc\"
done
"""
bluetooth_insertion = r'''# The QTI Bluetooth HIDL service is ABI-compatible only with its own
# vendor libc++. Verify both physical vendor inputs before adding this one
# service-local preload; never replace Android's global C++ runtime.
bt_rc="$INIT_STAGE/android.hardware.bluetooth@1.0-service-qti.rc"
[ -f "$bt_rc" ] || fatal "missing QTI Bluetooth init rc"
[ "$(sha256sum "$bt_rc" | awk '{print $1}')" = "86b0cf7fe04b1f415773ef410d627f14482a7826945c38ecfe0450dd569edb8c" ] || fatal "unexpected QTI Bluetooth init rc"
bt_libcpp=$(first_file lib64/libc++.so) || fatal "missing vendor Bluetooth libc++"
[ "$(sha256sum "$bt_libcpp" | awk '{print $1}')" = "cb118e98c74d3454858921123b9b51ba13df9cad7dfa141dd892c453661a4d78" ] || fatal "unexpected vendor Bluetooth libc++"
[ "$(grep -Fxc 'service vendor.bluetooth-1-0-qti /vendor/bin/hw/android.hardware.bluetooth@1.0-service-qti' "$bt_rc")" = 1 ] || fatal "unexpected QTI Bluetooth service definition"
! grep -Fq 'setenv LD_PRELOAD /vendor/lib64/libc++.so' "$bt_rc" || fatal "Bluetooth private libc++ already injected"
sed -i '/^service vendor\.bluetooth-1-0-qti \/vendor\/bin\/hw\/android\.hardware\.bluetooth@1\.0-service-qti$/a\\    setenv LD_PRELOAD /vendor/lib64/libc++.so' "$bt_rc" || fatal "failed to add Bluetooth private libc++"
grep -Fq 'setenv LD_PRELOAD /vendor/lib64/libc++.so' "$bt_rc" || fatal "Bluetooth private libc++ verification failed"
''' if bluetooth_private_libcpp == "1" else ""
contents = path.read_text()
if contents.count(sentinel) != 1:
    raise SystemExit(f"error: expected one FastRPC vendor compatibility completion sentinel, got {contents.count(sentinel)}")
path.write_text(contents.replace(sentinel, insertion + bluetooth_insertion + sentinel))
PY

if false; then # Bluetooth insertion is composed with the FastRPC insertion above.
    python3 - "$compat_script" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
sentinel = 'echo "isolated vendor compatibility overlay complete (A11 vndsm + allocator2 + Hybris cohort)"\n'
insertion = r'''# The QTI Bluetooth HIDL service is ABI-compatible only with its own
# vendor libc++. Verify both physical vendor inputs before adding this one
# service-local preload; never replace Android's global C++ runtime.
bt_rc="$INIT_STAGE/android.hardware.bluetooth@1.0-service-qti.rc"
[ -f "$bt_rc" ] || fatal "missing QTI Bluetooth init rc"
[ "$(sha256sum "$bt_rc" | awk '{print $1}')" = "86b0cf7fe04b1f415773ef410d627f14482a7826945c38ecfe0450dd569edb8c" ] || fatal "unexpected QTI Bluetooth init rc"
bt_libcpp=$(first_file lib64/libc++.so) || fatal "missing vendor Bluetooth libc++"
[ "$(sha256sum "$bt_libcpp" | awk '{print $1}')" = "cb118e98c74d3454858921123b9b51ba13df9cad7dfa141dd892c453661a4d78" ] || fatal "unexpected vendor Bluetooth libc++"
[ "$(grep -Fxc 'service vendor.bluetooth-1-0-qti /vendor/bin/hw/android.hardware.bluetooth@1.0-service-qti' "$bt_rc")" = 1 ] || fatal "unexpected QTI Bluetooth service definition"
! grep -Fq 'setenv LD_PRELOAD /vendor/lib64/libc++.so' "$bt_rc" || fatal "Bluetooth private libc++ already injected"
sed -i '/^service vendor\.bluetooth-1-0-qti \/vendor\/bin\/hw\/android\.hardware\.bluetooth@1\.0-service-qti$/a\\    setenv LD_PRELOAD /vendor/lib64/libc++.so' "$bt_rc" || fatal "failed to add Bluetooth private libc++"
grep -Fq 'setenv LD_PRELOAD /vendor/lib64/libc++.so' "$bt_rc" || fatal "Bluetooth private libc++ verification failed"
'''
contents = path.read_text()
if contents.count(sentinel) != 1:
    raise SystemExit(f"error: expected one Bluetooth vendor compatibility completion sentinel, got {contents.count(sentinel)}")
path.write_text(contents.replace(sentinel, insertion + sentinel))
PY
fi

camera_cohort_dir="$work_dir/ramdisk-root/compat/vendor-compat/camera-a11"
if [[ -n "$camera_vendor_dir" ]]; then
    for index in "${!camera_cohort_files[@]}"; do
        rel="${camera_cohort_files[index]}"
        mode=0644
        [[ "$rel" == bin/* ]] && mode=0755
        install -D -m "$mode" "$camera_vendor_dir/$rel" "$camera_cohort_dir/$rel"
        require_hash "$camera_cohort_dir/$rel" "${camera_cohort_hashes[index]}" \
            "staged A11 camera cohort $rel"
    done
fi

camera_directory_rc=''
camera_provider_rc=''
if [[ -n "$camera_vendor_dir" ]]; then
    # Android imports vendor init RC files after its early `on init` trigger.
    # Keep the mutable calibration directory contract in a late-safe, separate
    # RC; it intentionally has no camera service stanza.
    camera_directory_rc="$work_dir/ramdisk-root/compat/vendor-compat/etc/init/rmx1901-camera-data-dir.rc"
    mkdir -p "$(dirname "$camera_directory_rc")"
    cat >"$camera_directory_rc" <<'EOF'
on post-fs-data
    mkdir /data/vendor/camera 0770 camera camera

on property:sys.boot_completed=1
    mkdir /data/vendor/camera 0770 camera camera
EOF

    # The provider's A11 ABI closure is private.  It is disabled until an
    # explicit runtime probe has checked the preloaded property and directory.
    camera_provider_rc="$work_dir/ramdisk-root/compat/vendor-compat/etc/init/android.hardware.camera.provider@2.4-service_64.rc"
    mkdir -p "$(dirname "$camera_provider_rc")"
    cat >"$camera_provider_rc" <<'EOF'
service vendor.camera-provider-2-4 /vendor/bin/hw/android.hardware.camera.provider@2.4-service_64
    interface android.hardware.camera.provider@2.4::ICameraProvider legacy/0
    class hal
    disabled
    user cameraserver
    group audio camera input drmrpc
    ioprio rt 4
    capabilities SYS_NICE
    task_profiles CameraServiceCapacity MaxPerformance
    setenv LD_LIBRARY_PATH /vendor/lib64/egl:/vendor/lib64:/system/lib64
EOF

    compat_script="$work_dir/ramdisk-root/compat/systemd249/apply-vendor-compat.sh"
    python3 - "$compat_script" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
sentinel = 'echo "isolated vendor compatibility overlay complete (A11 vndsm + allocator2 + mapper2 + Hybris cohort)"\n'
insertion = """# Android imports vendor init RC files after its `on init` trigger, so
# ro.hardware.camera must be present in vendor/build.prop before container init.
# Require both LXC roots to have the same source file, then bind a single-line,
# audited extension over both targets.
camera_prop_seed=$(first_file build.prop) || fatal \"no physical vendor build.prop\"
for base in $TARGET_ROOTS; do
    [ -f \"$base/build.prop\" ] || continue
    cmp -s \"$camera_prop_seed\" \"$base/build.prop\" || fatal \"vendor build.prop preimage mismatch: $base/build.prop\"
done
CAMERA_PROP_STAGE=/userdata/rmx1901-camera-vendor-build.prop.$$
cp \"$camera_prop_seed\" \"$CAMERA_PROP_STAGE\" || fatal \"failed to stage vendor build.prop\"
camera_prop_rows=$(grep -Ec '^ro\\.hardware\\.camera=' \"$CAMERA_PROP_STAGE\" || true)
case \"$camera_prop_rows\" in
    0) printf '\\nro.hardware.camera=qcom\\n' >>\"$CAMERA_PROP_STAGE\" ;;
    1) grep -Fxq 'ro.hardware.camera=qcom' \"$CAMERA_PROP_STAGE\" || fatal \"unexpected existing ro.hardware.camera value\" ;;
    *) fatal \"duplicate ro.hardware.camera entries in vendor build.prop\" ;;
esac
[ \"$(grep -Fxc 'ro.hardware.camera=qcom' \"$CAMERA_PROP_STAGE\")\" = 1 ] || fatal \"camera property stage verification failed\"
echo \"camera vendor build.prop preimage=$(sha256sum \"$camera_prop_seed\" | awk '{print $1}')\"
bind_file \"$CAMERA_PROP_STAGE\" build.prop \"camera pre-init property stage\"

# The full init directory is already privately staged.  Add both camera RCs
# there, rather than assuming these new filenames exist on the physical vendor.
for camera_rc in rmx1901-camera-data-dir.rc android.hardware.camera.provider@2.4-service_64.rc; do
    cp \"$SRC/etc/init/$camera_rc\" \"$INIT_STAGE/$camera_rc\" || fatal \"failed to stage $camera_rc\"
    chmod 0644 \"$INIT_STAGE/$camera_rc\"
    cmp -s \"$SRC/etc/init/$camera_rc\" \"$INIT_STAGE/$camera_rc\" || fatal \"camera init stage verification failed: $camera_rc\"
done
"""
contents = path.read_text()
if contents.count(sentinel) != 1:
    raise SystemExit("error: expected one vendor compatibility completion sentinel")
path.write_text(contents.replace(sentinel, insertion + sentinel))
PY
    python3 - "$compat_script" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
sentinel = 'echo "isolated vendor compatibility overlay complete (A11 vndsm + allocator2 + mapper2 + Hybris cohort)"\n'
insertion = """# The camera provider closure is version-locked to Android 11.  Do not
# replace global vendor C++ libraries: bind only the provider's own files.
for rel in \\
    bin/hw/android.hardware.camera.provider@2.4-service_64 \\
    lib64/android.hardware.camera.provider@2.4-external.so \\
    lib64/android.hardware.camera.provider@2.4-legacy.so \\
    lib64/camera.device@1.0-impl.so \\
    lib64/camera.device@3.2-impl.so \\
    lib64/camera.device@3.3-impl.so \\
    lib64/camera.device@3.4-external-impl.so \\
    lib64/camera.device@3.4-impl.so \\
    lib64/camera.device@3.5-external-impl.so \\
    lib64/camera.device@3.5-impl.so \\
    lib64/camera.device@3.6-external-impl.so \\
    lib64/hw/android.hardware.camera.provider@2.4-impl.so
do
    bind_file \"$SRC/camera-a11/$rel\" \"$rel\" \"A11 camera cohort\"
done
"""
contents = path.read_text()
if contents.count(sentinel) != 1:
    raise SystemExit("error: expected one vendor compatibility completion sentinel")
path.write_text(contents.replace(sentinel, insertion + sentinel))
PY
fi

sh -n "$work_dir/ramdisk-root/init"
sh -n "$compat_script"
grep -q 'libsdmcore.so libsdedrm.so libEGL_adreno.so' \
    "$work_dir/ramdisk-root/compat/systemd249/apply-vendor-compat.sh"
grep -q 'KERNEL=="hwbinder", MODE="0666"' "$work_dir/ramdisk-root/init"
grep -q 'rmx1901-user-session-ready.service' "$work_dir/ramdisk-root/init"
grep -q 'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/32011/bus' "$work_dir/ramdisk-root/init"
grep -q 'systemd-logind 249 bind failed' "$work_dir/ramdisk-root/init"
grep -q 'rmx1901-touch-bridge.service' "$work_dir/ramdisk-root/init"
grep -Fq 'chown system system /dev/adsprpc-smd' "$fastrpc_device_rc"
grep -Fq 'chmod 0664 /dev/adsprpc-smd' "$fastrpc_device_rc"
grep -Fq 'chmod 0644 /dev/adsprpc-smd-secure' "$fastrpc_device_rc"
grep -Fq 'on property:sys.boot_completed=1' "$fastrpc_device_rc"
grep -Fq 'restart vendor.adsprpcd_sensorspd' "$fastrpc_device_rc"
if [[ "$bluetooth_private_libcpp" == 1 ]]; then
    grep -Fq 'setenv LD_PRELOAD /vendor/lib64/libc++.so' "$compat_script"
    grep -Fq 'unexpected QTI Bluetooth init rc' "$compat_script"
fi
grep -Fq 'FastRPC device-permission init stage' "$compat_script"
if [[ -n "$camera_vendor_dir" ]]; then
    ! grep -Fq 'setprop ro.hardware.camera' "$camera_provider_rc"
    grep -Fq 'disabled' "$camera_provider_rc"
    test "$(grep -Fc 'mkdir /data/vendor/camera 0770 camera camera' "$camera_directory_rc")" -eq 2
    grep -Fq 'setenv LD_LIBRARY_PATH /vendor/lib64/egl:/vendor/lib64:/system/lib64' \
        "$camera_provider_rc"
    grep -Fq 'camera pre-init property stage' "$compat_script"
    grep -Fq 'camera vendor build.prop preimage=' "$compat_script"
    grep -Fq 'rmx1901-camera-data-dir.rc' "$compat_script"
    grep -Fq 'A11 camera cohort' "$compat_script"
fi
grep -q 'ExecStart=/usr/bin/python3 /userdata/systemd249/rmx1901-touch-bridge.py' \
    "$work_dir/ramdisk-root/init"
grep -q 'Type=notify' "$work_dir/ramdisk-root/init"
grep -q 'NotifyAccess=main' "$work_dir/ramdisk-root/init"
grep -q 'userdata_mount=rw-validated type=f2fs' \
    "$work_dir/ramdisk-root/scripts/halium-userdata"
! grep -q 'userdata_mount=tmpfs-rescue' \
    "$work_dir/ramdisk-root/scripts/halium-userdata"

if [[ -n "$candidate_recovery_timeout" ]]; then
    watchdog="$work_dir/ramdisk-root/compat/systemd249/rmx1901-candidate-recovery-watchdog.sh"
    watchdog_ack="$work_dir/ramdisk-root/compat/systemd249/rmx1901-candidate-boot-ack.sh"
    watchdog_ack_unit="$work_dir/ramdisk-root/compat/systemd249/rmx1901-candidate-boot-ack.service"
    cat >"$watchdog" <<'EOF'
#!/bin/sh
set -eu

timeout_seconds=${1:?missing candidate recovery timeout}
ack=/userdata/rmx1901-autonomous/candidate-boot-ack
control=/userdata/rmx1901-autonomous/recovery-control

rm -f "$ack"
sleep "$timeout_seconds"
if [ -e "$ack" ]; then
    exit 0
fi
printf '%s\n' 'RMX1901 candidate boot acknowledgement timed out; requesting Recovery' \
    >/dev/kmsg 2>/dev/null || true
sync
if [ -x "$control" ]; then
    exec "$control" recovery
fi
exec /sbin/reboot recovery
EOF
    chmod 0755 "$watchdog"
    touch -h -d '@0' "$watchdog"
    cat >"$watchdog_ack" <<'EOF'
#!/bin/sh
set -eu

# This unit is ordered after a successful LightDM start.  It is deliberately
# narrower than a bare PID1 or SSH check: a candidate that cannot reach the
# graphical session must remain eligible for Recovery fallback.
touch /userdata/rmx1901-autonomous/candidate-boot-ack
sync
EOF
    cat >"$watchdog_ack_unit" <<'EOF'
[Unit]
Description=Acknowledge successful RMX1901 candidate graphical boot
Requires=lightdm.service
After=lightdm.service

[Service]
Type=oneshot
ExecStart=/userdata/systemd249/rmx1901-candidate-boot-ack.sh

[Install]
WantedBy=graphical.target
EOF
    chmod 0755 "$watchdog_ack"
    chmod 0644 "$watchdog_ack_unit"
    touch -h -d '@0' "$watchdog_ack" "$watchdog_ack_unit"
    watchdog_start="chroot \"\${rootmnt}\" /usr/bin/setsid /compat/systemd249/rmx1901-candidate-recovery-watchdog.sh ${candidate_recovery_timeout} &"
    # init executes before pivot_root.  Source the generated files through
    # rootmnt as well: /compat is not guaranteed to be visible in the
    # initramfs namespace at this point, whereas rootmnt/compat is the exact
    # tree that will become the system root.
    watchdog_install="install -D -m 0755 \"\${rootmnt}\"/compat/systemd249/rmx1901-candidate-boot-ack.sh \"\${rootmnt}\"/userdata/systemd249/rmx1901-candidate-boot-ack.sh; install -D -m 0644 \"\${rootmnt}\"/compat/systemd249/rmx1901-candidate-boot-ack.service \"\${rootmnt}\"/etc/systemd/system/rmx1901-candidate-boot-ack.service; mkdir -p \"\${rootmnt}\"/etc/systemd/system/graphical.target.wants; ln -sf ../rmx1901-candidate-boot-ack.service \"\${rootmnt}\"/etc/systemd/system/graphical.target.wants/rmx1901-candidate-boot-ack.service"
    sed -i "/^exec run-init /i ${watchdog_install}\n${watchdog_start}" "$work_dir/ramdisk-root/init"
    grep -Fq 'rmx1901-candidate-recovery-watchdog.sh' "$work_dir/ramdisk-root/init"
    grep -Fq 'rmx1901-candidate-boot-ack.service' "$work_dir/ramdisk-root/init"
fi

# Keep changed-entry timestamps deterministic while retaining all baseline metadata.
changed_entries=(
    "$work_dir/ramdisk-root/init" \
    "$work_dir/ramdisk-root/compat/systemd249/apply-vendor-compat.sh" \
    "$work_dir/ramdisk-root/scripts/halium-userdata" \
    "$work_dir/ramdisk-root/compat/systemd249/systemd-logind249" \
    "$work_dir/ramdisk-root/compat/systemd249/rmx1901-touch-bridge.py" \
    "$work_dir/ramdisk-root/compat/vendor-compat/lib64/libsdedrm.so" \
    "$fastrpc_device_rc"
)
if [[ -n "$candidate_recovery_timeout" ]]; then
    changed_entries+=("$watchdog" "$watchdog_ack" "$watchdog_ack_unit")
fi
if [[ -n "$camera_vendor_dir" ]]; then
    changed_entries+=("$camera_directory_rc" "$camera_provider_rc")
    while IFS= read -r -d '' staged_file; do
        changed_entries+=("$staged_file")
    done < <(find "$camera_cohort_dir" -type f -print0)
fi
touch -h -d '@0' "${changed_entries[@]}"
(
    cd "$work_dir/ramdisk-root"
    find . -print0 | LC_ALL=C sort -z | \
        cpio --null --owner=0:0 -o -H newc 2>"$out_dir/cpio-pack.txt" | \
        gzip -9 >"$work_dir/ramdisk.img"
)

mkbootimg_args=()
while IFS= read -r -d '' argument; do
    mkbootimg_args+=("$argument")
done <"$work_dir/base-mkbootimg-args.bin"
for ((index = 0; index < ${#mkbootimg_args[@]}; index++)); do
    case "${mkbootimg_args[index]}" in
        --kernel)
            mkbootimg_args[index + 1]="$selected_kernel"
            ;;
        --ramdisk)
            mkbootimg_args[index + 1]="$work_dir/ramdisk.img"
            ;;
    esac
done
mkbootimg "${mkbootimg_args[@]}" --output "$work_dir/boot.img"
avbtool add_hash_footer \
    --image "$work_dir/boot.img" \
    --partition_name boot \
    --partition_size "$expected_partition_size" \
    --hash_algorithm sha256 \
    --salt "$avb_salt"
[[ "$(stat -c %s "$work_dir/boot.img")" -eq "$expected_partition_size" ]]
cp "$work_dir/boot.img" "$out_dir/boot.img"

mkdir -p "$out_dir/verify/avb" "$out_dir/verify/unpack" "$out_dir/verify/ramdisk-root"
cp --reflink=auto "$out_dir/boot.img" "$out_dir/verify/avb/boot.img"
avbtool verify_image --image "$out_dir/verify/avb/boot.img" >"$out_dir/verify/avb.txt"
unpack_bootimg --boot_img "$out_dir/boot.img" --out "$out_dir/verify/unpack" \
    --format=mkbootimg -0 >"$out_dir/verify/mkbootimg-args.bin"
gzip -dc "$out_dir/verify/unpack/ramdisk" | cpio -itv \
    >"$out_dir/verify/cpio-list.txt" 2>"$out_dir/verify/cpio-list.err"
(
    cd "$out_dir/verify/ramdisk-root"
    gzip -dc "$out_dir/verify/unpack/ramdisk" | cpio -idm --no-absolute-filenames \
        >"$out_dir/verify/cpio-extract.txt" 2>&1
)
require_hash "$out_dir/verify/ramdisk-root/compat/vendor-compat/lib64/libsdedrm.so" \
    "$expected_libsdedrm_sha256" "reverse-unpacked A11 libsdedrm.so"
require_hash "$out_dir/verify/ramdisk-root/compat/vendor-compat/bin/hw/android.hardware.graphics.allocator@2.0-service" \
    "$expected_allocator_sha256" "reverse-unpacked QTI allocator"
require_hash "$out_dir/verify/ramdisk-root/compat/systemd249/systemd-logind249" \
    "$expected_systemd_logind_sha256" "reverse-unpacked systemd 249 logind"
cmp "$touch_bridge" \
    "$out_dir/verify/ramdisk-root/compat/systemd249/rmx1901-touch-bridge.py"
verified_fastrpc_device_rc="$out_dir/verify/ramdisk-root/compat/vendor-compat/etc/init/rmx1901-fastrpc-device-permissions.rc"
grep -Fq 'chown system system /dev/adsprpc-smd' "$verified_fastrpc_device_rc"
grep -Fq 'chmod 0664 /dev/adsprpc-smd' "$verified_fastrpc_device_rc"
grep -Fq 'chmod 0644 /dev/adsprpc-smd-secure' "$verified_fastrpc_device_rc"
grep -Fq 'on property:sys.boot_completed=1' "$verified_fastrpc_device_rc"
grep -Fq 'restart vendor.adsprpcd_sensorspd' "$verified_fastrpc_device_rc"
grep -Fq 'FastRPC device-permission init rc' \
    "$out_dir/verify/ramdisk-root/compat/systemd249/apply-vendor-compat.sh"
if [[ "$bluetooth_private_libcpp" == 1 ]]; then
    verified_bluetooth_compat="$out_dir/verify/ramdisk-root/compat/systemd249/apply-vendor-compat.sh"
    grep -Fq '86b0cf7fe04b1f415773ef410d627f14482a7826945c38ecfe0450dd569edb8c' \
        "$verified_bluetooth_compat"
    grep -Fq 'cb118e98c74d3454858921123b9b51ba13df9cad7dfa141dd892c453661a4d78' \
        "$verified_bluetooth_compat"
    grep -Fq 'setenv LD_PRELOAD /vendor/lib64/libc++.so' \
        "$verified_bluetooth_compat"
    grep -Fq 'Bluetooth private libc++ verification failed' \
        "$verified_bluetooth_compat"
fi
if [[ -n "$camera_vendor_dir" ]]; then
    verified_camera_rc="$out_dir/verify/ramdisk-root/compat/vendor-compat/etc/init/android.hardware.camera.provider@2.4-service_64.rc"
    verified_camera_directory_rc="$out_dir/verify/ramdisk-root/compat/vendor-compat/etc/init/rmx1901-camera-data-dir.rc"
    ! grep -Fq 'setprop ro.hardware.camera' "$verified_camera_rc"
    grep -Fq 'disabled' "$verified_camera_rc"
    test "$(grep -Fc 'mkdir /data/vendor/camera 0770 camera camera' "$verified_camera_directory_rc")" -eq 2
    grep -Fq 'setenv LD_LIBRARY_PATH /vendor/lib64/egl:/vendor/lib64:/system/lib64' \
        "$verified_camera_rc"
    grep -Fq 'camera pre-init property stage' \
        "$out_dir/verify/ramdisk-root/compat/systemd249/apply-vendor-compat.sh"
    grep -Fq 'camera vendor build.prop preimage=' \
        "$out_dir/verify/ramdisk-root/compat/systemd249/apply-vendor-compat.sh"
    grep -Fq 'rmx1901-camera-data-dir.rc' \
        "$out_dir/verify/ramdisk-root/compat/systemd249/apply-vendor-compat.sh"
    grep -Fq 'A11 camera cohort' \
        "$out_dir/verify/ramdisk-root/compat/systemd249/apply-vendor-compat.sh"
    for index in "${!camera_cohort_files[@]}"; do
        rel="${camera_cohort_files[index]}"
        require_hash "$out_dir/verify/ramdisk-root/compat/vendor-compat/camera-a11/$rel" \
            "${camera_cohort_hashes[index]}" "reverse-unpacked A11 camera cohort $rel"
    done
fi
sh -n "$out_dir/verify/ramdisk-root/scripts/halium-userdata"
grep -q 'userdata_mount=rw-validated type=f2fs' \
    "$out_dir/verify/ramdisk-root/scripts/halium-userdata"
! grep -q 'userdata_mount=tmpfs-rescue' \
    "$out_dir/verify/ramdisk-root/scripts/halium-userdata"

python3 - "$work_dir/base-mkbootimg-args.bin" "$out_dir/verify/mkbootimg-args.bin" <<'PY' \
    >"$out_dir/verify/header-compare.txt"
from pathlib import Path
import difflib
import sys

def load(path):
    return Path(path).read_bytes().split(b"\0")

base, built = load(sys.argv[1]), load(sys.argv[2])
for arguments in (base, built):
    for index, value in enumerate(arguments[:-1]):
        if value in (b"--kernel", b"--ramdisk"):
            arguments[index + 1] = b"<PAYLOAD>"
if base != built:
    left = [value.decode(errors="replace") for value in base]
    right = [value.decode(errors="replace") for value in built]
    print("\n".join(difflib.unified_diff(left, right, fromfile="base", tofile="built")))
    raise SystemExit(1)
print("header_args_match=pass")
PY
cmp "$selected_kernel" "$out_dir/verify/unpack/kernel"

if [[ -n "$dts_output" ]]; then
    dts_output="$(realpath -e "$dts_output")"
    "$repo_root/../kernel_realme_sdm710_ubuntu_touch/scripts/verify-rmx1901-dtb-chain.sh" \
        "$out_dir/verify/unpack/kernel" "$dts_output" >"$out_dir/verify/dtb-chain.txt"
else
    echo 'rmx1901_dtb_chain=not-run (DTS_OUTPUT_DIR not supplied)' \
        >"$out_dir/verify/dtb-chain.txt"
fi

{
    echo "base_boot_sha256=$(sha256_of "$base_boot")"
    echo "kernel_sha256=$(sha256_of "$selected_kernel")"
    echo "kernel_override=$([[ -n "$kernel_image" ]] && echo yes || echo no)"
    echo "candidate_watchdog=$([[ -n "$candidate_recovery_timeout" ]] && echo "${candidate_recovery_timeout}s" || echo disabled)"
    echo "camera_cohort=$([[ -n "$camera_vendor_dir" ]] && echo enabled || echo disabled)"
    echo "bluetooth_private_libcpp=$([[ "$bluetooth_private_libcpp" == 1 ]] && echo enabled || echo disabled)"
    echo 'fastrpc_device_permissions=enabled'
    echo "libsdedrm_sha256=$(sha256_of "$libsdedrm")"
    echo "systemd_logind_sha256=$(sha256_of "$systemd_logind")"
    echo "touch_bridge_sha256=$(sha256_of "$touch_bridge")"
    echo "allocator_sha256=$(sha256_of "$allocator")"
    echo "boot_sha256=$(sha256_of "$out_dir/boot.img")"
    echo "boot_size=$(stat -c %s "$out_dir/boot.img")"
    cat "$out_dir/verify/header-compare.txt"
    cat "$out_dir/verify/dtb-chain.txt"
    echo 'build_stable_graphics_boot=pass'
} | tee "$out_dir/summary.txt"
