#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repacker="$repo_root/scripts/repack-m1-predecessor-boot.sh"
verifier="$repo_root/scripts/verify-m1-predecessor-boot.sh"
halium_root="${HALIUM_ROOT:-/home/lknife/android/rmx1901-halium11}"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/m1-predecessor-boot-test.XXXXXX")"
cleanup_test() {
  if test "${M1_TEST_KEEP_TMP:-0}" = 1; then
    printf 'kept_test_tmp=%s\n' "$tmp_root" >&2
  else
    rm -rf -- "$tmp_root"
  fi
}
trap cleanup_test EXIT

mkbootimg="$halium_root/out/host/linux-x86/bin/mkbootimg"
avbtool="$halium_root/out/host/linux-x86/bin/avbtool"
test_avb_salt='1111111111111111111111111111111111111111111111111111111111111111'
test_avb_release='avbtool 1.3.0'
test -x "$mkbootimg"
test -x "$avbtool"

# Run the production scripts from an isolated repository-shaped fixture so the
# test can exercise provenance changes without depending on a cached release
# asset.  The real provenance validator remains in the path under test.
fixture_port="$tmp_root/port"
mkdir -p "$fixture_port/scripts" "$fixture_port/config" \
  "$fixture_port/artifacts/supply-chain"
cp -- "$repacker" "$verifier" \
  "$repo_root/scripts/validate-safe-halium-initrd-provenance.py" \
  "$repo_root/scripts/m1-safe-file.py" \
  "$fixture_port/scripts/"
cp -- "$repo_root/config/m1-cmdline-v1.json" "$fixture_port/config/"

released_initrd="$tmp_root/released-initrd.img"
printf 'synthetic immutable M1 initrd fixture\n' >"$released_initrd"
initrd_size="$(stat -c %s "$released_initrd")"
initrd_sha="$(sha256sum "$released_initrd" | awk '{print $1}')"
python3 - "$fixture_port/artifacts/supply-chain/rmx1901-safe-initrd-arm64.provenance.json" \
  "$initrd_size" "$initrd_sha" <<'PY'
import json
import pathlib
import sys

path, size, digest = pathlib.Path(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
commit = "1234567890abcdef1234567890abcdef12345678"
release_id = 101
asset_id = 202
repo = "Lcryolite/initramfs-tools-halium-rmx1901"
path.write_text(json.dumps({
    "repository": repo,
    "source_branch": "main",
    "source_commit": commit,
    "production_status": "released",
    "release_id": release_id,
    "release_tag": "rmx1901-m1-test",
    "release_target_commitish": commit,
    "release_api_url": f"https://api.github.com/repos/{repo}/releases/{release_id}",
    "release_immutable": True,
    "asset_id": asset_id,
    "asset_name": "initrd.img-touch-arm64-rmx1901-safe",
    "asset_api_url": f"https://api.github.com/repos/{repo}/releases/assets/{asset_id}",
    "asset_size": size,
    "asset_digest": "sha256:" + digest,
    "sha256": digest,
}), encoding="utf-8")
PY

kernel="$tmp_root/predecessor-kernel"
old_ramdisk="$tmp_root/predecessor-ramdisk"
printf 'known Linux 4.9 predecessor kernel payload\n' >"$kernel"
printf 'old predecessor ramdisk\n' >"$old_ramdisk"

make_full_boot() {
  local kernel_path="$1"
  local ramdisk_path="$2"
  local cmdline="$3"
  local output_path="$4"
  local -a mkboot_args=(
    --kernel "$kernel_path"
    --ramdisk "$ramdisk_path"
    --cmdline "$cmdline"
    --base 0
    --kernel_offset 0x8000
    --ramdisk_offset 0x1000000
    --second_offset 0
    --tags_offset 0x100
    --pagesize 4096
    --board ''
    --os_version 17.0.0
    --os_patch_level 2026-07
    --header_version 1
    --output "$output_path"
  )
  "$mkbootimg" "${mkboot_args[@]}"
  "$avbtool" add_hash_footer --image "$output_path" --partition_name boot \
    --partition_size 67108864 --algorithm NONE --salt "$test_avb_salt" \
    --internal_release_string "$test_avb_release"
}

predecessor="$tmp_root/predecessor-boot.img"
make_full_boot "$kernel" "$old_ramdisk" \
  'console=ttyMSM0,115200n8 androidboot.hardware=qcom' "$predecessor"
test "$(stat -c %s "$predecessor")" -eq 67108864
predecessor_sha="$(sha256sum "$predecessor" | awk '{print $1}')"
kernel_sha="$(sha256sum "$kernel" | awk '{print $1}')"

write_predecessor_lock() {
  python3 - "$fixture_port/config/m1-predecessor-v1.json" "$1" "$2" <<'PY'
import json
import pathlib
import sys

path, boot_sha, kernel_sha = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
path.write_text(json.dumps({
    "schema": "rmx1901-m1-predecessor-v1",
    "device": "RMX1901",
    "boot_partition_size": 67108864,
    "boot_sha256": boot_sha,
    "kernel_payload_sha256": kernel_sha,
}), encoding="utf-8")
PY
}
write_predecessor_lock "$predecessor_sha" "$kernel_sha"

candidate="$tmp_root/m1-candidate.img"
HALIUM_ROOT="$halium_root" \
  "$fixture_port/scripts/repack-m1-predecessor-boot.sh" \
  "$predecessor" "$released_initrd" "$candidate"
HALIUM_ROOT="$halium_root" \
  "$fixture_port/scripts/verify-m1-predecessor-boot.sh" \
  "$predecessor" "$candidate"
test "$(stat -c %s "$candidate")" -eq 67108864

# Repacking identical locked inputs is byte-for-byte reproducible, including
# AVB salt and release metadata inherited from the predecessor.
candidate_2="$tmp_root/m1-candidate-2.img"
HALIUM_ROOT="$halium_root" \
  "$fixture_port/scripts/repack-m1-predecessor-boot.sh" \
  "$predecessor" "$released_initrd" "$candidate_2"
cmp -s "$candidate" "$candidate_2"

mkdir -p "$tmp_root/predecessor-avb-info" "$tmp_root/candidate-avb-info"
cp -- "$predecessor" "$tmp_root/predecessor-avb-info/boot.img"
cp -- "$candidate" "$tmp_root/candidate-avb-info/boot.img"
chmod u+rw "$tmp_root/predecessor-avb-info/boot.img" \
  "$tmp_root/candidate-avb-info/boot.img"
"$avbtool" info_image --image "$tmp_root/predecessor-avb-info/boot.img" \
  >"$tmp_root/predecessor-avb-info.txt"
"$avbtool" info_image --image "$tmp_root/candidate-avb-info/boot.img" \
  >"$tmp_root/candidate-avb-info.txt"
grep -Fq "Release String:           '$test_avb_release'" \
  "$tmp_root/candidate-avb-info.txt"
grep -Fq "Salt:                  $test_avb_salt" \
  "$tmp_root/candidate-avb-info.txt"

unpacked="$tmp_root/unpacked-candidate"
mkdir -p "$unpacked"
python3 "$halium_root/system/tools/mkbootimg/unpack_bootimg.py" \
  --boot_img "$candidate" --out "$unpacked" >"$tmp_root/unpack-candidate.txt"
cmp -s "$unpacked/kernel" "$kernel"
cmp -s "$unpacked/ramdisk" "$released_initrd"
expected_cmdline="$(python3 - "$fixture_port/config/m1-cmdline-v1.json" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(" ".join(data["tokens"]))
PY
)"
grep -Fx "command line args: $expected_cmdline" "$tmp_root/unpack-candidate.txt" >/dev/null
grep -Fx 'additional command line args: ' "$tmp_root/unpack-candidate.txt" >/dev/null
mkdir -p "$tmp_root/direct-avb-check"
cp -- "$candidate" "$tmp_root/direct-avb-check/boot.img"
chmod u+rw "$tmp_root/direct-avb-check/boot.img"
"$avbtool" verify_image --image "$tmp_root/direct-avb-check/boot.img" >/dev/null

expect_rejected() {
  local name="$1"
  shift
  set +e
  "$@" >"$tmp_root/$name.log" 2>&1
  local status=$?
  set -e
  if test "$status" -eq 0; then
    echo "M1 boot contract accepted invalid fixture: $name" >&2
    exit 1
  fi
}

# A caller cannot replace an existing output, even with a valid candidate.
existing="$tmp_root/existing-output.img"
printf 'do not replace\n' >"$existing"
existing_sha="$(sha256sum "$existing" | awk '{print $1}')"
expect_rejected existing-output env HALIUM_ROOT="$halium_root" \
  "$fixture_port/scripts/repack-m1-predecessor-boot.sh" \
  "$predecessor" "$released_initrd" "$existing"
test "$(sha256sum "$existing" | awk '{print $1}')" = "$existing_sha"

# The full predecessor must be an exact, regular, non-symlink 64 MiB image.
ln -s "$predecessor" "$tmp_root/predecessor-link.img"
expect_rejected predecessor-symlink env HALIUM_ROOT="$halium_root" \
  "$fixture_port/scripts/repack-m1-predecessor-boot.sh" \
  "$tmp_root/predecessor-link.img" "$released_initrd" "$tmp_root/link-output.img"
head -c 4096 "$predecessor" >"$tmp_root/short-predecessor.img"
expect_rejected short-predecessor env HALIUM_ROOT="$halium_root" \
  "$fixture_port/scripts/repack-m1-predecessor-boot.sh" \
  "$tmp_root/short-predecessor.img" "$released_initrd" "$tmp_root/short-output.img"

# A shape-compatible 64 MiB image with the same kernel is still not the
# observed predecessor from spec section 4.
other_ramdisk="$tmp_root/other-predecessor-ramdisk"
printf 'new predecessor ramdisk\n' >"$other_ramdisk"
test "$(stat -c %s "$other_ramdisk")" -eq "$(stat -c %s "$old_ramdisk")"
wrong_full_predecessor="$tmp_root/wrong-full-predecessor.img"
make_full_boot "$kernel" "$other_ramdisk" \
  'console=ttyMSM0,115200n8 androidboot.hardware=qcom' "$wrong_full_predecessor"
expect_rejected wrong-full-predecessor env HALIUM_ROOT="$halium_root" \
  "$fixture_port/scripts/repack-m1-predecessor-boot.sh" \
  "$wrong_full_predecessor" "$released_initrd" "$tmp_root/wrong-full-output.img"
grep -Fx 'error: predecessor SHA-256 does not match M1 lock' \
  "$tmp_root/wrong-full-predecessor.log" >/dev/null
expect_rejected wrong-full-predecessor-verifier env HALIUM_ROOT="$halium_root" \
  "$fixture_port/scripts/verify-m1-predecessor-boot.sh" \
  "$wrong_full_predecessor" "$candidate"
grep -Fx 'error: predecessor SHA-256 does not match M1 lock' \
  "$tmp_root/wrong-full-predecessor-verifier.log" >/dev/null

# Path replacement after the safe snapshot must never redirect repacking to
# attacker-selected predecessor, initrd, or internally generated candidate
# bytes.  Test hooks perform one precise atomic replacement at each boundary.
toctou_predecessor="$tmp_root/toctou-predecessor.img"
cp -- "$predecessor" "$toctou_predecessor"
expect_rejected replaced-predecessor env HALIUM_ROOT="$halium_root" \
  M1_REPACK_TEST_HOOKS=1 \
  M1_REPACK_TEST_REPLACE_PREDECESSOR_WITH="$wrong_full_predecessor" \
  "$fixture_port/scripts/repack-m1-predecessor-boot.sh" \
  "$toctou_predecessor" "$released_initrd" "$tmp_root/replaced-predecessor-output.img"
grep -F 'source SHA-256 does not match expected value' \
  "$tmp_root/replaced-predecessor.log" >/dev/null
test ! -e "$tmp_root/replaced-predecessor-output.img"

toctou_initrd="$tmp_root/toctou-initrd.img"
replacement_initrd="$tmp_root/replacement-initrd.img"
cp -- "$released_initrd" "$toctou_initrd"
python3 - "$released_initrd" "$replacement_initrd" <<'PY'
import pathlib, sys
data = bytearray(pathlib.Path(sys.argv[1]).read_bytes())
data[0] ^= 1
pathlib.Path(sys.argv[2]).write_bytes(data)
PY
expect_rejected replaced-initrd env HALIUM_ROOT="$halium_root" \
  M1_REPACK_TEST_HOOKS=1 \
  M1_REPACK_TEST_REPLACE_INITRD_WITH="$replacement_initrd" \
  "$fixture_port/scripts/repack-m1-predecessor-boot.sh" \
  "$predecessor" "$toctou_initrd" "$tmp_root/replaced-initrd-output.img"
grep -F 'source SHA-256 does not match expected value' \
  "$tmp_root/replaced-initrd.log" >/dev/null
test ! -e "$tmp_root/replaced-initrd-output.img"

expect_rejected replaced-candidate-source env HALIUM_ROOT="$halium_root" \
  M1_REPACK_TEST_HOOKS=1 \
  M1_REPACK_TEST_REPLACE_CANDIDATE_WITH="$wrong_full_predecessor" \
  "$fixture_port/scripts/repack-m1-predecessor-boot.sh" \
  "$predecessor" "$released_initrd" "$tmp_root/replaced-candidate-output.img"
grep -F 'source SHA-256 does not match expected value' \
  "$tmp_root/replaced-candidate-source.log" >/dev/null
test ! -e "$tmp_root/replaced-candidate-output.img"

destination_race_source="$tmp_root/destination-race-source"
destination_race_output="$tmp_root/destination-race-output.img"
printf 'destination race must survive\n' >"$destination_race_source"
destination_race_sha="$(sha256sum "$destination_race_source" | awk '{print $1}')"
expect_rejected destination-race env HALIUM_ROOT="$halium_root" \
  M1_REPACK_TEST_HOOKS=1 \
  M1_REPACK_TEST_CREATE_DESTINATION_FROM="$destination_race_source" \
  "$fixture_port/scripts/repack-m1-predecessor-boot.sh" \
  "$predecessor" "$released_initrd" "$destination_race_output"
grep -F 'cannot publish destination without overwrite' \
  "$tmp_root/destination-race.log" >/dev/null
test "$(sha256sum "$destination_race_output" | awk '{print $1}')" = \
  "$destination_race_sha"

post_publish_output="$tmp_root/post-publish-replacement.img"
wrong_full_sha="$(sha256sum "$wrong_full_predecessor" | awk '{print $1}')"
expect_rejected post-publish-replacement env HALIUM_ROOT="$halium_root" \
  M1_REPACK_TEST_HOOKS=1 \
  M1_REPACK_TEST_REPLACE_PUBLISHED_WITH="$wrong_full_predecessor" \
  "$fixture_port/scripts/repack-m1-predecessor-boot.sh" \
  "$predecessor" "$released_initrd" "$post_publish_output"
grep -F 'source SHA-256 does not match expected value' \
  "$tmp_root/post-publish-replacement.log" >/dev/null
test "$(sha256sum "$post_publish_output" | awk '{print $1}')" = "$wrong_full_sha"

# Lock an actual spilling predecessor so the candidate reaches the explicit
# additional_cmdline gate instead of failing earlier at full-image identity.
long_cmdline="$(printf 'x%.0s' {1..520})"
extra_predecessor="$tmp_root/extra-cmdline-predecessor.img"
make_full_boot "$kernel" "$old_ramdisk" "$long_cmdline" "$extra_predecessor"
write_predecessor_lock "$(sha256sum "$extra_predecessor" | awk '{print $1}')" \
  "$kernel_sha"
expect_rejected nonempty-extra-cmdline env HALIUM_ROOT="$halium_root" \
  "$fixture_port/scripts/verify-m1-predecessor-boot.sh" \
  "$extra_predecessor" "$extra_predecessor"
grep -F 'M1 candidate additional cmdline is not empty' \
  "$tmp_root/nonempty-extra-cmdline.log" >/dev/null
write_predecessor_lock "$predecessor_sha" "$kernel_sha"

# Candidate verification is provenance-bound, not merely header-shaped.
wrong_initrd="$tmp_root/wrong-initrd"
printf 'wrong ramdisk\n' >"$wrong_initrd"
expect_rejected wrong-initrd env HALIUM_ROOT="$halium_root" \
  "$fixture_port/scripts/repack-m1-predecessor-boot.sh" \
  "$predecessor" "$wrong_initrd" "$tmp_root/wrong-initrd-output.img"

# The verifier must detect a different kernel even when every other header
# field and the released initrd are valid.
other_kernel="$tmp_root/other-kernel"
printf 'other Linux 4.9 predecessor kernel payload\n' >"$other_kernel"
other_predecessor="$tmp_root/other-predecessor.img"
make_full_boot "$other_kernel" "$old_ramdisk" \
  'console=ttyMSM0,115200n8 androidboot.hardware=qcom' "$other_predecessor"
expect_rejected changed-kernel env HALIUM_ROOT="$halium_root" \
  "$fixture_port/scripts/verify-m1-predecessor-boot.sh" \
  "$other_predecessor" "$candidate"
grep -Fx 'error: predecessor SHA-256 does not match M1 lock' \
  "$tmp_root/changed-kernel.log" >/dev/null

# Prove the inner payload lock is independent of the full-image lock: make the
# fixture lock accept the alternate full image while retaining the known
# predecessor kernel digest.  It must now fail specifically at kernel payload.
other_predecessor_sha="$(sha256sum "$other_predecessor" | awk '{print $1}')"
write_predecessor_lock "$other_predecessor_sha" "$kernel_sha"
expect_rejected wrong-locked-kernel env HALIUM_ROOT="$halium_root" \
  "$fixture_port/scripts/repack-m1-predecessor-boot.sh" \
  "$other_predecessor" "$released_initrd" "$tmp_root/wrong-kernel-output.img"
grep -Fx 'error: predecessor kernel payload SHA-256 does not match M1 lock' \
  "$tmp_root/wrong-locked-kernel.log" >/dev/null
expect_rejected wrong-locked-kernel-verifier env HALIUM_ROOT="$halium_root" \
  "$fixture_port/scripts/verify-m1-predecessor-boot.sh" \
  "$other_predecessor" "$candidate"
grep -Fx 'error: predecessor kernel payload SHA-256 does not match M1 lock' \
  "$tmp_root/wrong-locked-kernel-verifier.log" >/dev/null
write_predecessor_lock "$predecessor_sha" "$kernel_sha"

# A valid Android header without an AVB footer is not a flash candidate.
no_avb="$tmp_root/no-avb.img"
cp -- "$candidate" "$no_avb"
chmod u+rw "$no_avb"
"$avbtool" erase_footer --image "$no_avb"
truncate -s 67108864 "$no_avb"
test "$(stat -c %s "$no_avb")" -eq 67108864
expect_rejected no-avb env HALIUM_ROOT="$halium_root" \
  "$fixture_port/scripts/verify-m1-predecessor-boot.sh" \
  "$predecessor" "$no_avb"
grep -Fx 'error: M1 candidate boot AVB verification failed' \
  "$tmp_root/no-avb.log" >/dev/null

# AVB verification alone is insufficient: a self-consistent candidate with a
# changed non-digest field must fail the predecessor metadata comparison.
bad_avb="$tmp_root/bad-avb-flags.img"
cp -- "$candidate" "$bad_avb"
chmod u+rw "$bad_avb"
"$avbtool" erase_footer --image "$bad_avb"
"$avbtool" add_hash_footer --image "$bad_avb" --partition_name boot \
  --partition_size 67108864 --algorithm NONE --hash_algorithm sha256 \
  --salt "$test_avb_salt" --rollback_index 0 --flags 1 \
  --internal_release_string "$test_avb_release"
expect_rejected changed-avb-flags env HALIUM_ROOT="$halium_root" \
  "$fixture_port/scripts/verify-m1-predecessor-boot.sh" \
  "$predecessor" "$bad_avb"
grep -F 'candidate AVB differs from predecessor' \
  "$tmp_root/changed-avb-flags.log" >/dev/null

echo 'M1 predecessor boot repack/verification contract tests passed'
