#!/usr/bin/env bash
set -euo pipefail

expected_tools='d5838d5c4cf90c7dbece749a451fb14271847dc9'
expected_kernel='a0b817e2e6929cc7e60feeba0f271dd07e7bfa01'
expected_ramdisk='3f02a6379313dd14b596d15049130f3a2ba98f3799757c4918515ece6befb5da'
expected_tools_url='https://gitlab.com/ubports/porting/community-ports/halium-generic-adaptation-build-tools.git'
expected_kernel_url='https://github.com/Lcryolite/kernel_realme_sdm710_ubuntu_touch.git'
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${1:-$repo_root/workdir}"

case "$build_dir" in
  /*) ;;
  *) build_dir="$repo_root/$build_dir" ;;
esac

test "$(git -C "$repo_root/build" rev-parse HEAD)" = "$expected_tools"
test "$(git -C "$build_dir/downloads/kernel_realme_sdm710_ubuntu_touch" rev-parse HEAD)" = "$expected_kernel"
test "$(git -C "$repo_root/build" remote get-url origin)" = "$expected_tools_url"
test "$(git -C "$build_dir/downloads/kernel_realme_sdm710_ubuntu_touch" remote get-url origin)" = "$expected_kernel_url"
test -z "$(git -C "$repo_root/build" status --porcelain --untracked-files=all)"
git -C "$build_dir/downloads/kernel_realme_sdm710_ubuntu_touch" diff --quiet
git -C "$build_dir/downloads/kernel_realme_sdm710_ubuntu_touch" diff --cached --quiet
test -z "$(git -C "$build_dir/downloads/kernel_realme_sdm710_ubuntu_touch" status --porcelain --untracked-files=all)"
"$repo_root/scripts/check-kernel-root-markers.sh" \
  "$build_dir/downloads/kernel_realme_sdm710_ubuntu_touch"
printf '%s  %s\n' "$expected_ramdisk" \
  "$build_dir/downloads/halium-boot-ramdisk.img" | sha256sum --check --status

printf 'source_pins=pass\n'
