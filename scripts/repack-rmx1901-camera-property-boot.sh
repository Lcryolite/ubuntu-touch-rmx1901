#!/usr/bin/env bash
# Derive a first camera-property test image from the accepted Service Locator
# boot image.  It deliberately changes only apply-vendor-compat.sh in the
# ramdisk and stages ro.hardware.camera=qcom before Android init starts.
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 BASE_SERVICE_LOCATOR_BOOT EMPTY_OUTPUT_DIR" >&2
    exit 2
fi

base_boot="$(realpath -e "$1")"
out_dir="$2"
expected_base_sha256='0cfbb492763b1886a124dbc2eb3a9023bd6f3baa22d68bf33d33ceb6fdb7e7b0'
expected_helper_sha256='7a938fb042a557063873067d39aa9290e640ecf5330e2aff472214ed9fa5c51d'
expected_partition_size=67108864
avb_salt='a5cc69c8b42844b7f93b6685e722a10ae0451e7aa0ae3fb745f502ecebf7732b'
helper_rel='compat/systemd249/apply-vendor-compat.sh'

for tool in avbtool cpio gzip mkbootimg unpack_bootimg sha256sum cmp python3; do
    command -v "$tool" >/dev/null || { echo "error: missing required tool: $tool" >&2; exit 1; }
done
[[ -f "$base_boot" ]] || { echo "error: base boot image is not a file" >&2; exit 1; }
[[ ! -e "$out_dir" ]] || { echo "error: output directory already exists" >&2; exit 1; }
[[ "$(sha256sum "$base_boot" | awk '{print $1}')" == "$expected_base_sha256" ]] || {
    echo 'error: base image is not the accepted Service Locator image' >&2; exit 1;
}
[[ "$(stat -c %s "$base_boot")" -eq "$expected_partition_size" ]] || {
    echo 'error: unexpected boot partition size' >&2; exit 1;
}

mkdir -p "$out_dir"
out_dir="$(realpath -e "$out_dir")"
work_dir="$(mktemp -d "$out_dir/.work.XXXXXXXX")"
cleanup() { find "$work_dir" -depth -delete; }
trap cleanup EXIT
mkdir -p "$work_dir/unpack" "$work_dir/base-root" "$work_dir/root" "$out_dir/verify/unpack" "$out_dir/verify/root"

unpack_bootimg --boot_img "$base_boot" --out "$work_dir/unpack" --format=mkbootimg -0 \
    >"$work_dir/base-mkbootimg-args.bin"
gzip -t "$work_dir/unpack/ramdisk"
(
    cd "$work_dir/base-root"
    gzip -dc "$work_dir/unpack/ramdisk" | cpio -idm --no-absolute-filenames >/dev/null 2>&1
)
cp -a "$work_dir/base-root/." "$work_dir/root/"
helper="$work_dir/root/$helper_rel"
[[ "$(sha256sum "$helper" | awk '{print $1}')" == "$expected_helper_sha256" ]] || {
    echo 'error: unexpected compatibility helper preimage' >&2; exit 1;
}

python3 - "$helper" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
needle = "# Keep the A11 dependency cohort private to HWC and libhybris. Global binds of\n"
insert = '''# Android init freezes ro.* properties after loading /vendor/build.prop. This
# helper is ExecStartPre for lxc-android-config, so stage the one-line overlay
# before Android init exists; never write the physical vendor partition.
camera_prop_seed=''
for base in $TARGET_ROOTS; do
    candidate="$base/build.prop"
    [ -f "$candidate" ] || continue
    if [ -z "$camera_prop_seed" ]; then
        camera_prop_seed="$candidate"
    else
        cmp -s "$camera_prop_seed" "$candidate" || fatal "vendor build.prop preimage mismatch: $candidate"
    fi
done
[ -n "$camera_prop_seed" ] || fatal "no physical vendor build.prop"
CAMERA_PROP_STAGE=/run/rmxcache/rmx1901-camera-vendor-build.prop
cp "$camera_prop_seed" "$CAMERA_PROP_STAGE" || fatal "camera property stage copy failed"
camera_prop_rows=$(grep -Ec '^ro\\.hardware\\.camera=' "$CAMERA_PROP_STAGE" || true)
case "$camera_prop_rows" in
    0) printf '\\nro.hardware.camera=qcom\\n' >>"$CAMERA_PROP_STAGE" ;;
    1) grep -Fxq 'ro.hardware.camera=qcom' "$CAMERA_PROP_STAGE" || fatal "unexpected ro.hardware.camera value" ;;
    *) fatal "duplicate ro.hardware.camera properties" ;;
esac
[ "$(grep -Fxc 'ro.hardware.camera=qcom' "$CAMERA_PROP_STAGE")" = 1 ] || fatal "camera property stage verification failed"
bind_file "$CAMERA_PROP_STAGE" build.prop "camera pre-init property stage"

'''
if text.count(needle) != 1 or 'ro.hardware.camera=qcom' in text:
    raise SystemExit('error: compatibility helper is not the expected camera-property preimage')
path.write_text(text.replace(needle, insert + needle), encoding="utf-8")
PY
chmod 0755 "$helper"

(
    cd "$work_dir/root"
    find . -print0 | sort -z | cpio --null -o -H newc 2>/dev/null | gzip -n -9 >"$work_dir/ramdisk"
)

mkbootimg_args=()
while IFS= read -r -d '' argument; do mkbootimg_args+=("$argument"); done <"$work_dir/base-mkbootimg-args.bin"
for ((index = 0; index < ${#mkbootimg_args[@]}; index++)); do
    case "${mkbootimg_args[index]}" in
        --kernel) mkbootimg_args[index + 1]="$work_dir/unpack/kernel" ;;
        --ramdisk) mkbootimg_args[index + 1]="$work_dir/ramdisk" ;;
    esac
done
mkbootimg "${mkbootimg_args[@]}" --output "$work_dir/boot.img"
avbtool add_hash_footer --image "$work_dir/boot.img" --partition_name boot \
    --partition_size "$expected_partition_size" --hash_algorithm sha256 --salt "$avb_salt"
cp --reflink=auto "$work_dir/boot.img" "$out_dir/boot.img"

avbtool verify_image --image "$out_dir/boot.img" >"$out_dir/verify/avb.txt"
unpack_bootimg --boot_img "$out_dir/boot.img" --out "$out_dir/verify/unpack" --format=mkbootimg -0 \
    >"$out_dir/verify/mkbootimg-args.bin"
cmp "$work_dir/unpack/kernel" "$out_dir/verify/unpack/kernel"
(
    cd "$out_dir/verify/root"
    gzip -dc "$out_dir/verify/unpack/ramdisk" | cpio -idm --no-absolute-filenames >/dev/null 2>&1
)
diff -qr "$work_dir/root" "$out_dir/verify/root" >/dev/null
grep -Fq 'ro.hardware.camera=qcom' "$out_dir/verify/root/$helper_rel"
python3 - "$work_dir/base-root" "$out_dir/verify/root" "$helper_rel" <<'PY'
from hashlib import sha256
from pathlib import Path
import sys

baseline, candidate, allowed = map(Path, sys.argv[1:])
baseline_files = {p.relative_to(baseline): p for p in baseline.rglob('*') if p.is_file()}
candidate_files = {p.relative_to(candidate): p for p in candidate.rglob('*') if p.is_file()}
if baseline_files.keys() != candidate_files.keys():
    raise SystemExit('ramdisk file set changed')
changed = [rel for rel in baseline_files if sha256(baseline_files[rel].read_bytes()).digest() != sha256(candidate_files[rel].read_bytes()).digest()]
if changed != [allowed]:
    raise SystemExit('unexpected ramdisk content delta: ' + ', '.join(map(str, changed)))
PY

{
    echo "base_boot_sha256=$expected_base_sha256"
    echo "candidate_boot_sha256=$(sha256sum "$out_dir/boot.img" | awk '{print $1}')"
    echo "kernel_sha256=$(sha256sum "$out_dir/verify/unpack/kernel" | awk '{print $1}')"
    echo 'header_delta=ramdisk_only'
    echo "ramdisk_content_delta=$helper_rel only"
    echo 'camera_property_overlay=ro.hardware.camera=qcom'
    echo 'camera_property_repack=pass'
} >"$out_dir/summary.txt"
