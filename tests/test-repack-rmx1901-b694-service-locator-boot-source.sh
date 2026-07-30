#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tool="$repo_root/scripts/repack-rmx1901-b694-service-locator-boot.sh"

test -x "$tool"
grep -Fq "expected_base_sha256='b694646c8035f59ade00548bda3c192eaf4787c1f72c9985601b1005e665e24b'" "$tool"
grep -Fq "service_locator_token='service_locator.enable=1'" "$tool"
grep -Fq 'cmp "$work_dir/unpack/kernel" "$out_dir/verify/unpack/kernel"' "$tool"
grep -Fq 'cmp "$work_dir/unpack/ramdisk" "$out_dir/verify/unpack/ramdisk"' "$tool"
grep -Fq 'avbtool verify_image --image "$out_dir/boot.img"' "$tool"
grep -Fq 'output directory already exists' "$tool"
echo 'b694 Service Locator boot repack source test passed'
