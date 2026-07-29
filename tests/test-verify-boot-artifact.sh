#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
verifier="$repo_root/scripts/verify-boot-artifact.sh"
real_build="$repo_root/workdir"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

test -x "$verifier"
safe_initrd_sha="$(python3 -c 'import json; print(json.load(open("safe-initrd-release.json"))["sha256"])')"
grep -Fqx "pinned_ramdisk_sha256='$safe_initrd_sha'" "$verifier"

mkdir -p "$tmp_dir/bin"
for command_name in adb fastboot; do
  cat >"$tmp_dir/bin/$command_name" <<'EOF'
#!/usr/bin/env bash
touch "$RMX1901_DEVICE_TOOL_SENTINEL"
exit 99
EOF
  chmod +x "$tmp_dir/bin/$command_name"
done

export RMX1901_DEVICE_TOOL_SENTINEL="$tmp_dir/device-tool-called"
PATH="$tmp_dir/bin:$PATH" "$verifier" "$real_build"
test ! -e "$RMX1901_DEVICE_TOOL_SENTINEL"

make_fixture() {
  local destination="$1"
  mkdir -p "$destination/tmp/partitions" "$destination/downloads"
  ln -s "$real_build/downloads/KERNEL_OBJ" "$destination/downloads/KERNEL_OBJ"
  ln -s "$real_build/downloads/halium-boot-ramdisk.img" \
    "$destination/downloads/halium-boot-ramdisk.img"
  cp --reflink=auto "$real_build/tmp/partitions/boot.img" \
    "$destination/tmp/partitions/boot.img"
}

extra_partition="$tmp_dir/extra-partition"
make_fixture "$extra_partition"
touch "$extra_partition/tmp/partitions/system.img"
if "$verifier" "$extra_partition" >"$tmp_dir/extra.out" 2>&1; then
  echo 'verifier accepted an unexpected partition artifact' >&2
  exit 1
fi
grep -Fq 'partition output directory must contain only boot.img' "$tmp_dir/extra.out"

wrong_size="$tmp_dir/wrong-size"
make_fixture "$wrong_size"
truncate -s 67108863 "$wrong_size/tmp/partitions/boot.img"
if "$verifier" "$wrong_size" >"$tmp_dir/size.out" 2>&1; then
  echo 'verifier accepted a boot image with the wrong size' >&2
  exit 1
fi
grep -Fq 'boot image size mismatch' "$tmp_dir/size.out"

broken_avb="$tmp_dir/broken-avb"
make_fixture "$broken_avb"
printf '\001' | dd of="$broken_avb/tmp/partitions/boot.img" bs=1 seek=67108800 \
  conv=notrunc status=none
if "$verifier" "$broken_avb" >"$tmp_dir/avb.out" 2>&1; then
  echo 'verifier accepted a boot image with a corrupt AVB footer' >&2
  exit 1
fi

echo 'boot artifact verification behavior tests passed'
