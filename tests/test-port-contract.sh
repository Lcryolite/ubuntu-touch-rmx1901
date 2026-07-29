#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

test -f "$repo_root/deviceinfo"
test -x "$repo_root/build.sh"
test -x "$repo_root/scripts/verify-source-pins.sh"
test -x "$repo_root/scripts/require-safe-initrd-release.py"
test -x "$repo_root/scripts/check-kernel-root-markers.sh"
test -x "$repo_root/scripts/stage-build-inputs.sh"
test -x "$repo_root/scripts/prepare-unprivileged-system-image-script.sh"
test -x "$repo_root/scripts/run-unprivileged-system-image-script.sh"
test -x "$repo_root/scripts/system-image-from-ota-unprivileged.sh"
test -x "$repo_root/scripts/install-staged-system-from-recovery.sh"
test -x "$repo_root/scripts/lib/recovery-mount-safety.sh"
test -x "$repo_root/scripts/verify-rootfs-overlay-applicability.sh"
test -f "$repo_root/scripts/sahara-reset.c"
test -f "$repo_root/scripts/configure-build-environment.sh"
test -x "$repo_root/scripts/build-tools/nproc"
test -f "$repo_root/.github/workflows/fetch-official-inputs.yml"

# shellcheck disable=SC1091
source "$repo_root/deviceinfo"

test "$deviceinfo_name" = 'realme X'
test "$deviceinfo_manufacturer" = 'realme'
test "$deviceinfo_codename" = 'RMX1901'
test "$deviceinfo_arch" = 'aarch64'
test "$deviceinfo_kernel_arch" = 'aarch64'
test "$deviceinfo_halium_version" = '11'
test "$deviceinfo_ubuntu_touch_release" = '24.04-1.x'

test "$deviceinfo_kernel_source" = 'https://github.com/Lcryolite/kernel_realme_sdm710_ubuntu_touch.git'
test "$deviceinfo_kernel_source_branch" = 'master'
test "$deviceinfo_kernel_defconfig" = 'sdm670-perf_defconfig'
test "$deviceinfo_kernel_clang_compile" = 'true'
test "$deviceinfo_kernel_clang_branch" = 'android-11.0.0_r46'
test "$deviceinfo_kernel_clang_revision" = 'r383902b1'
test "$deviceinfo_kernel_image_name" = 'Image.gz-dtb'
test "$deviceinfo_kernel_disable_modules" = 'false'

test "$deviceinfo_bootimg_header_version" = '1'
test "$deviceinfo_bootimg_os_version" = '11'
test "$deviceinfo_bootimg_os_patch_level" = '2000-01-01'
test "$deviceinfo_flash_pagesize" = '4096'
test "$deviceinfo_flash_offset_base" = '0x00000000'
test "$deviceinfo_flash_offset_kernel" = '0x00008000'
test "$deviceinfo_flash_offset_ramdisk" = '0x01000000'
test "$deviceinfo_flash_offset_second" = '0x00000000'
test "$deviceinfo_flash_offset_tags" = '0x00000100'
test "$deviceinfo_bootimg_partition_size" = '67108864'
test "$deviceinfo_system_partition_size" = '5213519872'
test "$deviceinfo_skip_dtbo_partition" = 'true'
test "$deviceinfo_bootimg_append_vbmeta" = 'false'
test "$deviceinfo_has_recovery_partition" = 'false'
test -z "${deviceinfo_dtbo+x}"
test -z "${deviceinfo_prebuilt_dtbo+x}"
test -z "${deviceinfo_recovery_partition_size+x}"

grep -Fq 'loop.max_part=7' <<<"$deviceinfo_kernel_cmdline"
grep -Fq 'androidboot.usbcontroller=a600000.dwc3' <<<"$deviceinfo_kernel_cmdline"
grep -Fq 'systempart=/dev/disk/by-partlabel/system' <<<"$deviceinfo_kernel_cmdline"

grep -Fq "ADAPTATION_TOOLS_COMMIT='d5838d5c4cf90c7dbece749a451fb14271847dc9'" "$repo_root/build.sh"
grep -Fq "KERNEL_COMMIT='a0b817e2e6929cc7e60feeba0f271dd07e7bfa01'" "$repo_root/build.sh"
grep -Fq 'require-safe-initrd-release.py' "$repo_root/build.sh"
! grep -Fq 'b3582e99c21eab2dd2912fc2e1c8c128d9c03fab7147452569d0b2da6bf44e6a' "$repo_root/build.sh"
! grep -Fq 'ac74c1124cc5cab7b9b42c9a06ca8ff5e14fc2d6e0d7237deb42da8a6788ceca' "$repo_root/build.sh"
"$repo_root/scripts/require-safe-initrd-release.py" >/dev/null
grep -Fq "test -z \"\$(git -C \"\$destination\" status --porcelain --untracked-files=all)\"" \
  "$repo_root/build.sh"
grep -Fq 'expected_tools_url=' "$repo_root/scripts/verify-source-pins.sh"
grep -Fq 'status --porcelain --untracked-files=all' "$repo_root/scripts/verify-source-pins.sh"
test "$(PATH="$repo_root/scripts/build-tools:$PATH" nproc --all)" -le 4
test "$(RMX1901_BUILD_JOBS=12 PATH="$repo_root/scripts/build-tools:$PATH" nproc --all)" -le 12
grep -Fq 'scripts/build-tools' "$repo_root/build.sh"
grep -Fq 'https://ci.ubports.com/job/ubuntu-touch-rootfs/job/ubports%252F24.04-1.x/lastSuccessfulBuild/artifact/ubuntu-touch-android9plus-rootfs-arm64.tar.gz' \
  "$repo_root/.github/workflows/fetch-official-inputs.yml"
grep -Fq 'halium-11.0/lastSuccessfulBuild/artifact/halium_halium_arm64.tar.xz' \
  "$repo_root/.github/workflows/fetch-official-inputs.yml"
test "$(grep -Fc 'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02' \
  "$repo_root/.github/workflows/fetch-official-inputs.yml")" -eq 2
grep -Fq 'retention-days: 1' "$repo_root/.github/workflows/fetch-official-inputs.yml"
grep -Fq 'tar -tzf official-inputs/ubuntu-touch-rootfs-arm64.tar.gz' \
  "$repo_root/.github/workflows/fetch-official-inputs.yml"
grep -Fq 'tar -tJf official-inputs/halium-11.0-arm64.tar.xz' \
  "$repo_root/.github/workflows/fetch-official-inputs.yml"
test "$(grep -Ec 'tar --t(z|J)f' "$repo_root/.github/workflows/fetch-official-inputs.yml")" -eq 0
grep -Fq 'retired for M0--M3' "$repo_root/README.md"
! grep -Fq 'EXECUTE=1 ADB_SERIAL=7b0c1c49' "$repo_root/README.md"
! grep -Fq './scripts/install-staged-system-from-recovery.sh' "$repo_root/README.md"

bash "$repo_root/tests/test-kernel-root-marker-scan.sh"
bash "$repo_root/tests/test-safe-initrd-release.sh"
bash "$repo_root/tests/test-stage-build-inputs.sh"
bash "$repo_root/tests/test-build-environment.sh"
bash "$repo_root/tests/test-unprivileged-system-image.sh"
bash "$repo_root/tests/test-rootfs-overlay-applicability.sh"
bash "$repo_root/tests/test-install-staged-system.sh"
bash "$repo_root/tests/test-install-staged-system-runtime.sh"
bash "$repo_root/tests/test-install-staged-system-retired.sh"
bash "$repo_root/tests/test-recovery-mount-read-only.sh"
bash "$repo_root/tests/test-preflight-staged-install.sh"
bash "$repo_root/tests/test-sahara-reset-source.sh"
bash "$repo_root/tests/test-secure-bringup-overlay.sh"

echo 'RMX1901 Ubuntu Touch adaptation contract tests passed'
