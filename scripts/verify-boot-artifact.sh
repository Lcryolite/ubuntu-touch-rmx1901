#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${1:-$repo_root/workdir}"
case "$build_dir" in
  /*) ;;
  *) build_dir="$repo_root/$build_dir" ;;
esac

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_exact_line() {
  local file="$1" line="$2" expected_count="${3:-1}"
  local count
  count="$(grep -Fxc -- "$line" "$file" || true)"
  test "$count" -eq "$expected_count" || \
    die "expected metadata exactly $expected_count time(s): $line"
}

require_regex_line() {
  local file="$1" expression="$2"
  local count
  count="$(grep -Exc -- "$expression" "$file" || true)"
  test "$count" -eq 1 || die "expected one metadata line matching: $expression"
}

require_command unpack_bootimg
require_command avbtool
require_command cmp
require_command od

# shellcheck disable=SC1091
source "$repo_root/deviceinfo"

partition_dir="$build_dir/tmp/partitions"
boot_image="$partition_dir/boot.img"
kernel_obj="$build_dir/downloads/KERNEL_OBJ"
kernel_image="$kernel_obj/arch/arm64/boot/Image.gz-dtb"
base_kernel="$kernel_obj/arch/arm64/boot/Image.gz"
downloaded_ramdisk="$build_dir/downloads/halium-boot-ramdisk.img"
pinned_ramdisk="$repo_root/halium-boot-ramdisk.img"
pinned_ramdisk_sha256='3f02a6379313dd14b596d15049130f3a2ba98f3799757c4918515ece6befb5da'

test -d "$partition_dir" || die "partition output directory is missing: $partition_dir"
mapfile -t partition_entries < <(
  find "$partition_dir" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort
)
test "${#partition_entries[@]}" -eq 1 && test "${partition_entries[0]}" = boot.img || \
  die 'partition output directory must contain only boot.img'
test -f "$boot_image" || die "boot image is missing: $boot_image"

boot_size="$(stat -c '%s' "$boot_image")"
test "$boot_size" = "$deviceinfo_bootimg_partition_size" || \
  die "boot image size mismatch: got $boot_size, expected $deviceinfo_bootimg_partition_size"

for required_file in "$kernel_image" "$base_kernel" "$downloaded_ramdisk" "$pinned_ramdisk"; do
  test -f "$required_file" || die "required build input is missing: $required_file"
done
printf '%s  %s\n' "$pinned_ramdisk_sha256" "$downloaded_ramdisk" | \
  sha256sum --check --status || die 'downloaded ramdisk digest does not match its pin'
printf '%s  %s\n' "$pinned_ramdisk_sha256" "$pinned_ramdisk" | \
  sha256sum --check --status || die 'repository ramdisk digest does not match its pin'
cmp -s "$downloaded_ramdisk" "$pinned_ramdisk" || \
  die 'downloaded ramdisk differs from repository pinned ramdisk'

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
unpack_log="$tmp_dir/unpack.log"
unpack_bootimg --boot_img "$boot_image" --out "$tmp_dir/unpacked" >"$unpack_log" 2>&1 || \
  die 'unpack_bootimg rejected boot.img'

expected_os_version="$deviceinfo_bootimg_os_version"
case "$expected_os_version" in
  *.*) ;;
  *) expected_os_version="$expected_os_version.0.0" ;;
esac
expected_patch_level="${deviceinfo_bootimg_os_patch_level%-*}"
printf -v expected_kernel_address '0x%08x' \
  "$((deviceinfo_flash_offset_base + deviceinfo_flash_offset_kernel))"
printf -v expected_ramdisk_address '0x%08x' \
  "$((deviceinfo_flash_offset_base + deviceinfo_flash_offset_ramdisk))"
printf -v expected_second_address '0x%08x' \
  "$((deviceinfo_flash_offset_base + deviceinfo_flash_offset_second))"
printf -v expected_tags_address '0x%08x' \
  "$((deviceinfo_flash_offset_base + deviceinfo_flash_offset_tags))"

require_exact_line "$unpack_log" "boot magic: ANDROID!"
require_exact_line "$unpack_log" "kernel load address: $expected_kernel_address"
require_exact_line "$unpack_log" "ramdisk load address: $expected_ramdisk_address"
require_exact_line "$unpack_log" 'second bootloader size: 0'
require_exact_line "$unpack_log" "second bootloader load address: $expected_second_address"
require_exact_line "$unpack_log" "kernel tags load address: $expected_tags_address"
require_exact_line "$unpack_log" "page size: $deviceinfo_flash_pagesize"
require_exact_line "$unpack_log" "os version: $expected_os_version"
require_exact_line "$unpack_log" "os patch level: $expected_patch_level"
require_exact_line "$unpack_log" "boot image header version: $deviceinfo_bootimg_header_version"
require_exact_line "$unpack_log" "command line args: $deviceinfo_kernel_cmdline"
require_exact_line "$unpack_log" 'additional command line args: '
require_exact_line "$unpack_log" 'recovery dtbo size: 0'
require_exact_line "$unpack_log" 'recovery dtbo offset: 0x0000000000000000'

unpacked_kernel="$tmp_dir/unpacked/kernel"
unpacked_ramdisk="$tmp_dir/unpacked/ramdisk"
test -f "$unpacked_kernel" && test -f "$unpacked_ramdisk" || \
  die 'unpack_bootimg did not produce kernel and ramdisk'
require_exact_line "$unpack_log" "kernel_size: $(stat -c '%s' "$unpacked_kernel")"
require_exact_line "$unpack_log" "ramdisk size: $(stat -c '%s' "$unpacked_ramdisk")"
cmp -s "$unpacked_kernel" "$kernel_image" || \
  die 'unpacked kernel differs from KERNEL_OBJ Image.gz-dtb'
cmp -s "$unpacked_ramdisk" "$downloaded_ramdisk" || \
  die 'unpacked ramdisk differs from pinned download'

dtbs=(
  'arch/arm64/boot/dts/18621/sdm710.dtb'
  'arch/arm64/boot/dts/19651/sdm710.dtb'
  'arch/arm64/boot/dts/18097/sdm710.dtb'
  'arch/arm64/boot/dts/18097/sdm670.dtb'
  'arch/arm64/boot/dts/19601/sdm710.dtb'
  'arch/arm64/boot/dts/qcom/sdm710.dtb'
)
test "${#dtbs[@]}" -eq 6 || die 'internal DTB manifest must contain exactly six entries'

kernel_size="$(stat -c '%s' "$kernel_image")"
offset="$(stat -c '%s' "$base_kernel")"
test "$offset" -lt "$kernel_size" || die 'Image.gz-dtb has no appended DTBs'
dtb_count=0
for relative_dtb in "${dtbs[@]}"; do
  dtb="$kernel_obj/$relative_dtb"
  test -f "$dtb" || die "expected DTB is missing: $relative_dtb"
  dtb_size="$(stat -c '%s' "$dtb")"
  test "$dtb_size" -ge 40 || die "DTB is too small: $relative_dtb"
  test $((offset + dtb_size)) -le "$kernel_size" || \
    die "appended DTB exceeds kernel boundary: $relative_dtb"

  magic="$(od -An -tx1 -j "$offset" -N 4 "$kernel_image" | tr -d ' \n')"
  test "$magic" = d00dfeed || die "invalid appended DTB magic at index $dtb_count"
  read -r size_b1 size_b2 size_b3 size_b4 < <(
    od -An -tu1 -j $((offset + 4)) -N 4 "$kernel_image"
  )
  encoded_size=$((size_b1 * 16777216 + size_b2 * 65536 + size_b3 * 256 + size_b4))
  test "$encoded_size" -eq "$dtb_size" || \
    die "appended DTB totalsize mismatch at index $dtb_count"
  cmp -s -n "$dtb_size" -i "$offset":0 "$kernel_image" "$dtb" || \
    die "appended DTB content/order mismatch at index $dtb_count: $relative_dtb"
  offset=$((offset + dtb_size))
  dtb_count=$((dtb_count + 1))
done
test "$dtb_count" -eq 6 || die "appended DTB count mismatch: $dtb_count"
test "$offset" -eq "$kernel_size" || die 'unexpected trailing data or additional DTB after DTB manifest'

page_size="$deviceinfo_flash_pagesize"
kernel_payload_size="$(stat -c '%s' "$unpacked_kernel")"
ramdisk_payload_size="$(stat -c '%s' "$unpacked_ramdisk")"
original_image_size=$((
  page_size +
  ((kernel_payload_size + page_size - 1) / page_size) * page_size +
  ((ramdisk_payload_size + page_size - 1) / page_size) * page_size
))

avb_info_raw="$tmp_dir/avb-info.raw"
avb_info="$tmp_dir/avb-info"
avbtool info_image --image "$boot_image" >"$avb_info_raw" 2>&1 || \
  die 'avbtool info_image rejected boot.img'
sed 's/^[[:space:]]*//' "$avb_info_raw" >"$avb_info"
require_exact_line "$avb_info" 'Footer version:           1.0'
require_exact_line "$avb_info" "Image size:               $deviceinfo_bootimg_partition_size bytes"
require_exact_line "$avb_info" "Original image size:      $original_image_size bytes"
require_exact_line "$avb_info" "VBMeta offset:            $original_image_size"
require_exact_line "$avb_info" 'VBMeta size:              512 bytes'
require_exact_line "$avb_info" 'Minimum libavb version:   1.0'
require_exact_line "$avb_info" 'Header Block:             256 bytes'
require_exact_line "$avb_info" 'Authentication Block:     0 bytes'
require_exact_line "$avb_info" 'Auxiliary Block:          256 bytes'
require_exact_line "$avb_info" 'Algorithm:                NONE'
require_exact_line "$avb_info" 'Rollback Index:           0'
require_exact_line "$avb_info" 'Flags:                    0'
require_exact_line "$avb_info" 'Rollback Index Location:  0'
require_exact_line "$avb_info" "Release String:           'avbtool 1.2.0'"
require_exact_line "$avb_info" 'Descriptors:'
require_exact_line "$avb_info" 'Hash descriptor:'
require_exact_line "$avb_info" "Image Size:            $original_image_size bytes"
require_exact_line "$avb_info" 'Hash Algorithm:        sha256'
require_exact_line "$avb_info" 'Partition Name:        boot'
require_regex_line "$avb_info" 'Salt:                  [0-9a-f]{64}'
require_regex_line "$avb_info" 'Digest:                [0-9a-f]{64}'
require_exact_line "$avb_info" 'Flags:                 0'

avbtool verify_image --image "$boot_image" >"$tmp_dir/avb-verify.log" 2>&1 || \
  die 'avbtool verify_image rejected boot.img'

printf 'boot_artifact_gate=pass\n'
