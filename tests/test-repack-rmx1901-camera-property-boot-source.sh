#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tool="$repo_root/scripts/repack-rmx1901-camera-property-boot.sh"

test -x "$tool"
grep -Fq "expected_base_sha256='0cfbb492763b1886a124dbc2eb3a9023bd6f3baa22d68bf33d33ceb6fdb7e7b0'" "$tool"
grep -Fq "expected_helper_sha256='7a938fb042a557063873067d39aa9290e640ecf5330e2aff472214ed9fa5c51d'" "$tool"
grep -Fq 'ro.hardware.camera=qcom' "$tool"
grep -Fq 'bind_file "$CAMERA_PROP_STAGE" build.prop "camera pre-init property stage"' "$tool"
grep -Fq 'cmp "$work_dir/unpack/kernel" "$out_dir/verify/unpack/kernel"' "$tool"
grep -Fq 'avbtool verify_image --image "$out_dir/boot.img"' "$tool"
echo 'camera property boot repack source test passed'
