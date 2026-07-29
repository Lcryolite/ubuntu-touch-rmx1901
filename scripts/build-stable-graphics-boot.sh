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
patch_file="${repo_root}/patches/rmx1901-stable-graphics.patch"
userdata_patch="${repo_root}/patches/rmx1901-real-userdata.patch"
touch_bridge="${repo_root}/scripts/rmx1901-touch-bridge.py"

expected_base_sha256=693abe6f79dd7bc5ad65942a45a9a186275bf0c7982ce10b9cdb6852035f98a2
expected_libsdedrm_sha256=40911f7e86f077d75df653bd79e1f6f40c609a092f11fefe32931b699cabf5da
expected_allocator_sha256=c3945aafcddf01917ec37f57a68c6004eb6a82664d0d55fee2a0efdfe596f999
expected_systemd_logind_sha256=605d88720c7589213cd9f84299a1813dfc2087e4654e74657fba346b10c219b5
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

sh -n "$work_dir/ramdisk-root/init"
sh -n "$work_dir/ramdisk-root/compat/systemd249/apply-vendor-compat.sh"
grep -q 'libsdmcore.so libsdedrm.so libEGL_adreno.so' \
    "$work_dir/ramdisk-root/compat/systemd249/apply-vendor-compat.sh"
grep -q 'KERNEL=="hwbinder", MODE="0666"' "$work_dir/ramdisk-root/init"
grep -q 'rmx1901-user-session-ready.service' "$work_dir/ramdisk-root/init"
grep -q 'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/32011/bus' "$work_dir/ramdisk-root/init"
grep -q 'systemd-logind 249 bind failed' "$work_dir/ramdisk-root/init"
grep -q 'rmx1901-touch-bridge.service' "$work_dir/ramdisk-root/init"
grep -q 'ExecStart=/usr/bin/python3 /userdata/systemd249/rmx1901-touch-bridge.py' \
    "$work_dir/ramdisk-root/init"
grep -q 'Type=notify' "$work_dir/ramdisk-root/init"
grep -q 'NotifyAccess=main' "$work_dir/ramdisk-root/init"
grep -q 'userdata_mount=rw-validated type=f2fs' \
    "$work_dir/ramdisk-root/scripts/halium-userdata"
! grep -q 'userdata_mount=tmpfs-rescue' \
    "$work_dir/ramdisk-root/scripts/halium-userdata"

# Keep changed-entry timestamps deterministic while retaining all baseline metadata.
touch -h -d '@0' \
    "$work_dir/ramdisk-root/init" \
    "$work_dir/ramdisk-root/compat/systemd249/apply-vendor-compat.sh" \
    "$work_dir/ramdisk-root/scripts/halium-userdata" \
    "$work_dir/ramdisk-root/compat/systemd249/systemd-logind249" \
    "$work_dir/ramdisk-root/compat/systemd249/rmx1901-touch-bridge.py" \
    "$work_dir/ramdisk-root/compat/vendor-compat/lib64/libsdedrm.so"
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
