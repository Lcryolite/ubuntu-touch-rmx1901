#!/usr/bin/env bash
# Repack the known-good b694 boot image with exactly one header-level change:
# enable Qualcomm Service Locator before Android/PDR services start.  The
# kernel and compressed ramdisk are copied byte-for-byte from the baseline.
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 BASE_B694_BOOT_IMG EMPTY_OUTPUT_DIR" >&2
    exit 2
fi

base_boot="$1"
out_dir="$2"
expected_base_sha256='b694646c8035f59ade00548bda3c192eaf4787c1f72c9985601b1005e665e24b'
expected_partition_size=67108864
service_locator_token='service_locator.enable=1'
avb_salt='a5cc69c8b42844b7f93b6685e722a10ae0451e7aa0ae3fb745f502ecebf7732b'

for tool in avbtool mkbootimg unpack_bootimg sha256sum cmp gzip; do
    command -v "$tool" >/dev/null || {
        echo "error: missing required tool: $tool" >&2
        exit 1
    }
done
[[ -f "$base_boot" ]] || { echo "error: base boot image is not a file" >&2; exit 1; }
[[ ! -e "$out_dir" ]] || { echo "error: output directory already exists" >&2; exit 1; }
[[ "$(sha256sum "$base_boot" | awk '{print $1}')" == "$expected_base_sha256" ]] || {
    echo "error: base image is not the b694 baseline" >&2
    exit 1
}
[[ "$(stat -c %s "$base_boot")" -eq "$expected_partition_size" ]] || {
    echo "error: b694 baseline has an unexpected partition size" >&2
    exit 1
}

mkdir -p "$out_dir"
work_dir="$(mktemp -d "$out_dir/.work.XXXXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
mkdir -p "$work_dir/unpack" "$out_dir/verify/unpack"

unpack_bootimg --boot_img "$base_boot" --out "$work_dir/unpack" --format=mkbootimg -0 \
    >"$work_dir/base-mkbootimg-args.bin"
[[ -s "$work_dir/unpack/kernel" && -s "$work_dir/unpack/ramdisk" ]] || {
    echo "error: b694 unpack missed kernel or ramdisk" >&2
    exit 1
}
# The kernel is Image.gz-dtb: gzip correctly reports the appended DTB as
# trailing data, so byte-for-byte reverse-unpack comparison below is the
# integrity check for it.  The ramdisk is a standalone gzip stream.
gzip -t "$work_dir/unpack/ramdisk"

mkbootimg_args=()
while IFS= read -r -d '' argument; do
    mkbootimg_args+=("$argument")
done <"$work_dir/base-mkbootimg-args.bin"

found_cmdline=0
for ((index = 0; index < ${#mkbootimg_args[@]}; index++)); do
    case "${mkbootimg_args[index]}" in
        --kernel)
            mkbootimg_args[index + 1]="$work_dir/unpack/kernel"
            ;;
        --ramdisk)
            mkbootimg_args[index + 1]="$work_dir/unpack/ramdisk"
            ;;
        --cmdline)
            found_cmdline=1
            original_cmdline="${mkbootimg_args[index + 1]}"
            case " $original_cmdline " in
                *" $service_locator_token "*)
                    echo "error: b694 baseline unexpectedly already enables Service Locator" >&2
                    exit 1
                    ;;
            esac
            mkbootimg_args[index + 1]="$original_cmdline $service_locator_token"
            ;;
    esac
done
[[ "$found_cmdline" -eq 1 ]] || { echo "error: b694 header has no main cmdline" >&2; exit 1; }

mkbootimg "${mkbootimg_args[@]}" --output "$work_dir/boot.img"
avbtool add_hash_footer \
    --image "$work_dir/boot.img" \
    --partition_name boot \
    --partition_size "$expected_partition_size" \
    --hash_algorithm sha256 \
    --salt "$avb_salt"
[[ "$(stat -c %s "$work_dir/boot.img")" -eq "$expected_partition_size" ]] || {
    echo "error: candidate does not fit boot partition" >&2
    exit 1
}
cp --reflink=auto "$work_dir/boot.img" "$out_dir/boot.img"

avbtool verify_image --image "$out_dir/boot.img" >"$out_dir/verify/avb.txt"
unpack_bootimg --boot_img "$out_dir/boot.img" --out "$out_dir/verify/unpack" --format=mkbootimg -0 \
    >"$out_dir/verify/mkbootimg-args.bin"
cmp "$work_dir/unpack/kernel" "$out_dir/verify/unpack/kernel"
cmp "$work_dir/unpack/ramdisk" "$out_dir/verify/unpack/ramdisk"
tr '\0' '\n' <"$out_dir/verify/mkbootimg-args.bin" >"$out_dir/verify/mkbootimg-args.txt"
python3 - "$work_dir/base-mkbootimg-args.bin" "$out_dir/verify/mkbootimg-args.bin" \
    "$original_cmdline" "$service_locator_token" <<'PY'
import sys

base_path, candidate_path, original_cmdline, token = sys.argv[1:]

def parse(path):
    values = open(path, "rb").read().split(b"\0")
    if values[-1] == b"":
        values.pop()
    if len(values) % 2:
        raise SystemExit("mkbootimg argument list has a dangling value")
    return dict(zip(values[::2], values[1::2]))

base = parse(base_path)
candidate = parse(candidate_path)
expected = (original_cmdline + " " + token).encode()
if candidate.get(b"--cmdline") != expected:
    raise SystemExit("candidate main cmdline is not the b694 cmdline plus Service Locator")
for key in set(base) | set(candidate):
    if key in (b"--kernel", b"--ramdisk", b"--cmdline"):
        continue
    if base.get(key) != candidate.get(key):
        raise SystemExit("unrelated boot-header field changed: " + key.decode(errors="replace"))
print("header_delta=cmdline_only")
PY

{
    echo "base_boot_sha256=$expected_base_sha256"
    echo "candidate_boot_sha256=$(sha256sum "$out_dir/boot.img" | awk '{print $1}')"
    echo "kernel_sha256=$(sha256sum "$out_dir/verify/unpack/kernel" | awk '{print $1}')"
    echo "ramdisk_sha256=$(sha256sum "$out_dir/verify/unpack/ramdisk" | awk '{print $1}')"
    echo "original_cmdline=$original_cmdline"
    echo "candidate_cmdline=$original_cmdline $service_locator_token"
    echo 'payload_bytes_match_b694=pass'
    echo 'service_locator_header_repack=pass'
} >"$out_dir/summary.txt"
