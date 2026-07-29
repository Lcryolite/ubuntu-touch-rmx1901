#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_script="$repo_root/scripts/build-halium.sh"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/build-halium-test.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

run_expect_failure() {
  local expected_status="$1"
  local expected_message="$2"
  shift 2
  local output
  local status

  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e

  test "$status" -eq "$expected_status"
  case "$output" in
    *"$expected_message"*) ;;
    *)
      printf 'expected failure containing: %s\nactual output: %s\n' \
        "$expected_message" "$output" >&2
      return 1
      ;;
  esac
}

gate_rejection_failures=0
expect_gate_rejection() {
  local name="$1"
  local compat_dir="$2"
  local output
  local status

  set +e
  output="$(HALIUM_ROOT="$fake_halium" PORT_ROOT="$fake_port" \
    FAKE_BUILD_CALLS="$calls" ANDROID_HOST_COMPAT_LIBDIR="$compat_dir" \
    "$build_script" 2>&1)"
  status=$?
  set -e
  if test "$status" -eq 0 || [[ "$output" != *'Android host compatibility library failed validation:'* ]]; then
    echo "host compatibility gate accepted $name" >&2
    gate_rejection_failures=$((gate_rejection_failures + 1))
  fi
}

run_expect_failure 1 'Halium build root is missing' \
  env HALIUM_ROOT=/nonexistent PORT_ROOT="$repo_root" "$build_script"
run_expect_failure 1 'HALIUM_ROOT: set HALIUM_ROOT' \
  env -u HALIUM_ROOT PORT_ROOT="$repo_root" "$build_script"

fake_halium="$tmp_root/Halium checkout"
fake_port="$tmp_root/port checkout"
mkdir -p "$fake_halium/build" "$fake_port"

lifecycle="$tmp_root/build-lifecycle.txt"
fake_fetcher="$tmp_root/fake-fetcher"
cat >"$fake_fetcher" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'fetch\n' >>"$FAKE_BUILD_LIFECYCLE"
mkdir -p "$HALIUM_ROOT/device/realme/RMX1901"
printf 'verified initrd fixture\n' >"$HALIUM_ROOT/device/realme/RMX1901/initramfs.gz"
EOF
chmod +x "$fake_fetcher"

fake_verifier="$tmp_root/fake-verifier"
cat >"$fake_verifier" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'verify:%s\n' "$1" >>"$FAKE_BUILD_LIFECYCLE"
test -z "${FAKE_VERIFY_STATUS:-}" || exit "$FAKE_VERIFY_STATUS"
EOF
chmod +x "$fake_verifier"
export FAKE_BUILD_LIFECYCLE="$lifecycle"

safe_initrd="${SAFE_INITRD_FIXTURE:-/home/lknife/android/rmx1901-halium11-artifacts/initrd-91cad41-20260728T/a/initrd.img-touch-arm64-rmx1901-safe}"
test -f "$safe_initrd"
safe_downloader="$tmp_root/safe-downloader"
cat >"$safe_downloader" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'fetch\n' >>"$FAKE_BUILD_LIFECYCLE"
cp -- "$SAFE_INITRD_FIXTURE" "$2"
EOF
chmod +x "$safe_downloader"
export SAFE_INITRD_FIXTURE="$safe_initrd"
export HALIUM_INITRD_DOWNLOADER="$safe_downloader"
export HALIUM_INITRD_CACHE_DIR="$tmp_root/safe initrd cache"

run_expect_failure 1 'PORT_ROOT: set PORT_ROOT' \
  env -u PORT_ROOT HALIUM_ROOT="$fake_halium" "$build_script"
run_expect_failure 1 'Port repository root is missing' \
  env HALIUM_ROOT="$fake_halium" PORT_ROOT="$tmp_root/missing-port" "$build_script"
run_expect_failure 1 'Halium build environment is missing' \
  env HALIUM_ROOT="$fake_halium" PORT_ROOT="$fake_port" "$build_script"

calls="$tmp_root/build-calls.txt"
cat >"$fake_halium/build/envsetup.sh" <<'EOF'
# Android 11 envsetup.sh reads this optional shell variable without a default.
: "$ZSH_VERSION"

lunch() {
  printf 'lunch:%s\n' "$*" >>"$FAKE_BUILD_CALLS"
  printf 'fake lunch output\n'
}

m() {
  printf 'm\n' >>"$FAKE_BUILD_LIFECYCLE"
  printf 'm:%s\n' "$*" >>"$FAKE_BUILD_CALLS"
  printf 'USE_CCACHE:%s\n' "${USE_CCACHE-}" >>"$FAKE_BUILD_CALLS"
  printf 'CCACHE_EXEC:%s\n' "${CCACHE_EXEC-}" >>"$FAKE_BUILD_CALLS"
  printf 'CCACHE_DIRECT:%s\n' "${CCACHE_DIRECT-}" >>"$FAKE_BUILD_CALLS"
  printf 'CCACHE_TEMPDIR:%s\n' "${CCACHE_TEMPDIR-}" >>"$FAKE_BUILD_CALLS"
  printf 'TMPDIR:%s\n' "${TMPDIR-}" >>"$FAKE_BUILD_CALLS"
  printf 'NINJA_ARGS:%s\n' "${NINJA_ARGS-}" >>"$FAKE_BUILD_CALLS"
  printf 'LD_LIBRARY_PATH:%s\n' "${LD_LIBRARY_PATH-}" >>"$FAKE_BUILD_CALLS"
  printf 'ALLOW_NINJA_ENV:%s\n' "${ALLOW_NINJA_ENV-}" >>"$FAKE_BUILD_CALLS"
  printf 'NOFILE:%s\n' "$(ulimit -n)" >>"$FAKE_BUILD_CALLS"
  if test -n "${FAKE_BUILD_STATUS:-}"; then
    printf 'fake build failed with status %s\n' "$FAKE_BUILD_STATUS"
    return "$FAKE_BUILD_STATUS"
  fi
  printf 'fake build output\n'
  mkdir -p "$HALIUM_ROOT/out/target/product/RMX1901"
  case " $* " in
    *' halium-boot '*)
      printf 'halium fixture\n' >"$HALIUM_ROOT/out/target/product/RMX1901/halium-boot.img"
      ;;
  esac
  case " $* " in
    *' systemimage '*)
      printf 'system fixture\n' >"$HALIUM_ROOT/out/target/product/RMX1901/system.img"
      ;;
  esac
}
EOF

run_expect_failure 1 'Halium boot source component is missing' \
  env HALIUM_ROOT="$fake_halium" PORT_ROOT="$fake_port" FAKE_BUILD_CALLS="$calls" \
    "$build_script"
mkdir -p "$fake_halium/halium/halium-boot"
printf 'LOCAL_MODULE := halium-boot\n' >"$fake_halium/halium/halium-boot/Android.mk"
run_expect_failure 2 'Initrd gate overrides are not supported' \
  env HALIUM_BUILD_TEST_HOOKS=1 HALIUM_ROOT="$fake_halium" PORT_ROOT="$fake_port" \
    HALIUM_INITRD_FETCHER="$fake_fetcher" \
    HALIUM_BOOT_INITRD_VERIFIER="$fake_verifier" "$build_script"
run_expect_failure 2 'Initrd gate overrides are not supported' \
  env -u HALIUM_BUILD_TEST_HOOKS HALIUM_ROOT="$fake_halium" PORT_ROOT="$fake_port" \
    HALIUM_INITRD_FETCHER="$fake_fetcher" \
    HALIUM_BOOT_INITRD_VERIFIER="$fake_verifier" "$build_script"
mkdir -p "$fake_halium/device/realme/RMX1901" \
  "$fake_halium/out/host/linux-x86/bin"
tree_unpacker="$fake_halium/out/host/linux-x86/bin/unpack_bootimg"
cat >"$tree_unpacker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'verify:%s\n' "$2" >>"$FAKE_BUILD_LIFECYCLE"
test -z "${FAKE_VERIFY_STATUS:-}" || exit "$FAKE_VERIFY_STATUS"
test "$1" = --boot_img
test "$3" = --out
mkdir -p "$4"
cp -- "$HALIUM_ROOT/device/realme/RMX1901/initramfs.gz" "$4/ramdisk"
printf '%s\n' \
  'boot_magic: ANDROID!' \
  'kernel load address: 0x8000' \
  'ramdisk size: 3949738' \
  'ramdisk load address: 0x1000000' \
  'second bootloader size: 0' \
  'kernel tags load address: 0x100' \
  'page size: 4096' \
  'boot image header version: 1'
EOF
chmod +x "$tree_unpacker"
host_compat_lib="$tmp_root/host compat/usr/lib"
audited_compat_lib=/var/tmp/rmx1901-host-compat/ncurses5-compat-libs-6.6-2/usr/lib
mkdir -p "$host_compat_lib"
run_expect_failure 1 "Android host compatibility library is missing: $host_compat_lib/libncurses.so.5" \
  env HALIUM_ROOT="$fake_halium" PORT_ROOT="$fake_port" FAKE_BUILD_CALLS="$calls" \
    ANDROID_HOST_COMPAT_LIBDIR="$host_compat_lib" "$build_script"
cp "$audited_compat_lib/libncurses.so.5.9" "$host_compat_lib/libncurses.so.5.9"
ln -s libncurses.so.5.9 "$host_compat_lib/libncurses.so.5"
run_expect_failure 1 "Android host compatibility library is missing: $host_compat_lib/libtinfo.so.5" \
  env HALIUM_ROOT="$fake_halium" PORT_ROOT="$fake_port" FAKE_BUILD_CALLS="$calls" \
    ANDROID_HOST_COMPAT_LIBDIR="$host_compat_lib" "$build_script"
rm "$host_compat_lib/libncurses.so.5" "$host_compat_lib/libncurses.so.5.9"
printf 'ABI 5 fixture\n' >"$host_compat_lib/libncurses.so.5"
printf 'ABI 5 fixture\n' >"$host_compat_lib/libtinfo.so.5"
expect_gate_rejection 'plain-text files' "$host_compat_lib"

escape_compat_lib="$tmp_root/escape compat/usr/lib"
mkdir -p "$escape_compat_lib"
ln -s "$audited_compat_lib/libncurses.so.5.9" "$escape_compat_lib/libncurses.so.5"
ln -s "$audited_compat_lib/libncurses.so.5.9" "$escape_compat_lib/libtinfo.so.5"
expect_gate_rejection 'escaping symlinks' "$escape_compat_lib"

wrong_hash_compat_lib="$tmp_root/wrong hash compat/usr/lib"
mkdir -p "$wrong_hash_compat_lib"
cp "$audited_compat_lib/libncurses.so.5.9" "$wrong_hash_compat_lib/libncurses.so.5.9"
printf 'tampered\n' >>"$wrong_hash_compat_lib/libncurses.so.5.9"
ln -s libncurses.so.5.9 "$wrong_hash_compat_lib/libncurses.so.5"
ln -s libncurses.so.5.9 "$wrong_hash_compat_lib/libtinfo.so.5"
expect_gate_rejection 'wrong library hash' "$wrong_hash_compat_lib"
test "$gate_rejection_failures" -eq 0

rm "$host_compat_lib/libncurses.so.5" "$host_compat_lib/libtinfo.so.5"
cp "$audited_compat_lib/libncurses.so.5.9" "$host_compat_lib/libncurses.so.5.9"
ln -s libncurses.so.5.9 "$host_compat_lib/libncurses.so.5"
ln -s libncurses.so.5.9 "$host_compat_lib/libtinfo.so.5"
export ANDROID_HOST_COMPAT_LIBDIR="$host_compat_lib"

# Full builds must reject an unmaterialized Git LFS WebView pointer before
# starting the expensive Android build.
webview_apk="$fake_halium/external/chromium-webview/prebuilt/arm64/webview.apk"
mkdir -p "$(dirname "$webview_apk")"
cat >"$webview_apk" <<'EOF'
version https://git-lfs.github.com/spec/v1
oid sha256:1319b1e76b4e1cb32d7019b6f7566ebb048e3c09bd0f344124122e58390b5939
size 262187199
EOF
run_expect_failure 1 'Chromium WebView APK is an unmaterialized Git LFS pointer' \
  env HALIUM_ROOT="$fake_halium" PORT_ROOT="$fake_port" FAKE_BUILD_CALLS="$calls" \
    ANDROID_HOST_COMPAT_LIBDIR="$host_compat_lib" "$build_script"
printf 'materialized webview fixture\n' >"$webview_apk"
mkdir -p "$tmp_root/non-source nvme/build tmp"

HALIUM_ROOT="$fake_halium" \
PORT_ROOT="$fake_port" \
FAKE_BUILD_CALLS="$calls" \
CCACHE_TEMPDIR="$tmp_root/non-source nvme/ccache tmp" \
TMPDIR="$tmp_root/non-source nvme/build tmp" \
ANDROID_HOST_COMPAT_LIBDIR="$host_compat_lib" \
LD_LIBRARY_PATH=/untrusted/caller/lib ALLOW_NINJA_ENV=true \
  "$build_script"

expected_calls="$tmp_root/expected-calls.txt"
printf '%s\n' \
  'lunch:halium_RMX1901-userdebug' \
  'm:-j16 halium-boot systemimage' \
  'USE_CCACHE:1' \
  'CCACHE_EXEC:/usr/bin/ccache' \
  'CCACHE_DIRECT:true' \
  "CCACHE_TEMPDIR:$tmp_root/non-source nvme/ccache tmp" \
  "TMPDIR:$tmp_root/non-source nvme/build tmp" \
  'NINJA_ARGS:-l20' \
  "LD_LIBRARY_PATH:$host_compat_lib" \
  'ALLOW_NINJA_ENV:' >"$expected_calls"
if ! head -n 10 "$calls" | cmp "$expected_calls" -; then
  echo 'actual build environment:' >&2
  sed -n '1,10p' "$calls" >&2
  exit 1
fi
nofile_limit="$(sed -n 's/^NOFILE://p' "$calls")"
test "$nofile_limit" -ge 8192

artifact_dir="$fake_port/artifacts/build"
test "$(cat "$artifact_dir/halium-boot.img")" = 'halium fixture'
test "$(cat "$artifact_dir/system.img")" = 'system fixture'
(cd "$artifact_dir" && sha256sum -c manifest.sha256)
test "$(sed -n '1p' "$lifecycle")" = fetch
test "$(sed -n '2p' "$lifecycle")" = m
test "$(sed -n '3p' "$lifecycle")" = \
  "verify:$fake_halium/out/target/product/RMX1901/halium-boot.img"
grep -Fx 'fake lunch output' "$artifact_dir/build.log" >/dev/null
grep -Fx 'fake build output' "$artifact_dir/build.log" >/dev/null

# A focused safe-initrd rebuild requests and publishes only halium-boot.
: >"$lifecycle"
: >"$calls"
rm -f -- "$fake_halium/out/target/product/RMX1901/system.img"
HALIUM_ROOT="$fake_halium" PORT_ROOT="$fake_port" FAKE_BUILD_CALLS="$calls" \
HALIUM_BUILD_SCOPE=safe-boot-only CCACHE_TEMPDIR="$tmp_root/safe ccache" \
  "$build_script"
test "$(sed -n '1p' "$lifecycle")" = m
test "$(sed -n '2p' "$lifecycle")" = \
  "verify:$fake_halium/out/target/product/RMX1901/halium-boot.img"
grep -Fx 'm:-j16 halium-boot' "$calls" >/dev/null
if grep -Fq systemimage "$calls"; then
  echo 'safe-boot-only requested systemimage' >&2
  exit 1
fi
safe_artifact_dir="$fake_port/artifacts/build-safe-initrd/560d8b34-ac74c112"
test "$(cat "$safe_artifact_dir/halium-boot.img")" = 'halium fixture'
test ! -e "$safe_artifact_dir/system.img"
test "$(awk '{print $2}' "$safe_artifact_dir/manifest.sha256")" = halium-boot.img
(cd "$safe_artifact_dir" && sha256sum -c manifest.sha256)

# Invalid/free-form scopes are rejected rather than becoming arbitrary m targets.
run_expect_failure 2 'Unsupported HALIUM_BUILD_SCOPE' \
  env HALIUM_ROOT="$fake_halium" PORT_ROOT="$fake_port" \
    HALIUM_BUILD_SCOPE='halium-boot systemimage' "$build_script"

printf 'stale manifest must remain untouched\n' >"$artifact_dir/manifest.sha256"
set +e
HALIUM_ROOT="$fake_halium" PORT_ROOT="$fake_port" FAKE_BUILD_CALLS="$tmp_root/failing-calls" \
FAKE_BUILD_STATUS=23 CCACHE_TEMPDIR="$tmp_root/failing ccache" \
  "$build_script" >/dev/null 2>&1
failed_status=$?
set -e
test "$failed_status" -eq 23
grep -Fx 'fake build failed with status 23' "$artifact_dir/build.log" >/dev/null
test "$(cat "$artifact_dir/manifest.sha256")" = 'stale manifest must remain untouched'

tampered_port="$tmp_root/tampered port"
mkdir -p "$tampered_port"
set +e
HALIUM_ROOT="$fake_halium" PORT_ROOT="$tampered_port" FAKE_BUILD_CALLS="$tmp_root/tampered-calls" \
FAKE_VERIFY_STATUS=66 CCACHE_TEMPDIR="$tmp_root/tampered ccache" \
  "$build_script" >/dev/null 2>&1
tampered_status=$?
set -e
test "$tampered_status" -eq 66
test ! -e "$tampered_port/artifacts/build/manifest.sha256"
test ! -e "$tampered_port/artifacts/build/halium-boot.img"

missing_image_halium="$tmp_root/missing image checkout"
mkdir -p "$missing_image_halium/build" "$missing_image_halium/halium/halium-boot" \
  "$missing_image_halium/device/realme/RMX1901" \
  "$missing_image_halium/external/chromium-webview/prebuilt/arm64"
printf 'LOCAL_MODULE := halium-boot\n' >"$missing_image_halium/halium/halium-boot/Android.mk"
printf 'materialized webview fixture\n' \
  >"$missing_image_halium/external/chromium-webview/prebuilt/arm64/webview.apk"
cat >"$missing_image_halium/build/envsetup.sh" <<'EOF'
lunch() { :; }
m() { :; }
EOF
run_expect_failure 1 'Missing build artifact: halium-boot.img' \
  env HALIUM_ROOT="$missing_image_halium" PORT_ROOT="$fake_port" "$build_script"

echo "build wrapper behavior tests passed"
