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
