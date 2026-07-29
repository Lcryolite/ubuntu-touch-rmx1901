#!/usr/bin/env bash
set -euo pipefail

: "${HALIUM_ROOT:?set HALIUM_ROOT}"
test -d "$HALIUM_ROOT" || {
  echo "Halium build root is missing" >&2
  exit 1
}
: "${PORT_ROOT:?set PORT_ROOT}"
test -d "$PORT_ROOT" || {
  echo "Port repository root is missing" >&2
  exit 1
}
test -f "$HALIUM_ROOT/build/envsetup.sh" || {
  echo "Halium build environment is missing" >&2
  exit 1
}
test -f "$HALIUM_ROOT/halium/halium-boot/Android.mk" || {
  echo "Halium boot source component is missing" >&2
  exit 1
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if test -n "${HALIUM_INITRD_FETCHER+x}" || \
   test -n "${HALIUM_BOOT_INITRD_VERIFIER+x}"; then
  echo "Initrd gate overrides are not supported" >&2
  exit 2
fi
HALIUM_INITRD_FETCHER="$repo_root/scripts/fetch-verified-halium-initrd.sh"
HALIUM_BOOT_INITRD_VERIFIER="$repo_root/scripts/verify-halium-boot-initrd.sh"
: "${ANDROID_HOST_COMPAT_LIBDIR:=/var/tmp/rmx1901-host-compat/ncurses5-compat-libs-6.6-2/usr/lib}"
: "${HALIUM_BUILD_SCOPE:=full}"
case "$HALIUM_BUILD_SCOPE" in
  full)
    build_targets=(halium-boot systemimage)
    images=(halium-boot.img system.img)
    artifact_dir="$PORT_ROOT/artifacts/build"
    ;;
  safe-boot-only)
    build_targets=(halium-boot)
    images=(halium-boot.img)
    artifact_dir="$PORT_ROOT/artifacts/build-safe-initrd/560d8b34-ac74c112"
    ;;
  *)
    echo "Unsupported HALIUM_BUILD_SCOPE: $HALIUM_BUILD_SCOPE" >&2
    exit 2
    ;;
esac
test -x "$HALIUM_INITRD_FETCHER" || {
  echo "Halium initrd fetch gate is missing" >&2
  exit 1
}
test -x "$HALIUM_BOOT_INITRD_VERIFIER" || {
  echo "Halium boot initrd verifier is missing" >&2
  exit 1
}
: "${TMPDIR:=/home/lknife/android/.tmp-rmx1901-build}"
export TMPDIR
mkdir -p -- "$TMPDIR"
compat_library_sha256=9cf046fdc0b3346768385ad2dc829f54e2624de933ac47f913133f6f40d016dc
compat_root="$(realpath -e -- "$ANDROID_HOST_COMPAT_LIBDIR" 2>/dev/null)" || {
  echo "Android host compatibility library directory is missing: $ANDROID_HOST_COMPAT_LIBDIR" >&2
  exit 1
}
for compat_library in libncurses.so.5 libtinfo.so.5; do
  compat_path="$ANDROID_HOST_COMPAT_LIBDIR/$compat_library"
  test -e "$compat_path" || {
    echo "Android host compatibility library is missing: $compat_path" >&2
    exit 1
  }
  resolved_compat_path="$(realpath -e -- "$compat_path" 2>/dev/null)" || resolved_compat_path=
  case "$resolved_compat_path" in
    "$compat_root"/*) ;;
    *)
      echo "Android host compatibility library failed validation: $compat_path" >&2
      exit 1
      ;;
  esac
  test -f "$resolved_compat_path" && \
    LC_ALL=C readelf -h "$resolved_compat_path" 2>/dev/null | grep -Eq 'Class:[[:space:]]+ELF64' && \
    LC_ALL=C readelf -h "$resolved_compat_path" 2>/dev/null | grep -Eq 'Type:[[:space:]]+DYN ' && \
    LC_ALL=C readelf -h "$resolved_compat_path" 2>/dev/null | grep -Eq 'Machine:[[:space:]]+Advanced Micro Devices X86-64' && \
    LC_ALL=C readelf -d "$resolved_compat_path" 2>/dev/null | grep -Fq 'Library soname: [libncurses.so.5]' && \
    test "$(sha256sum "$resolved_compat_path" | awk '{print $1}')" = "$compat_library_sha256" || {
      echo "Android host compatibility library failed validation: $compat_path" >&2
      exit 1
  }
done

if test "$HALIUM_BUILD_SCOPE" = full; then
  webview_apk="$HALIUM_ROOT/external/chromium-webview/prebuilt/arm64/webview.apk"
  test -f "$webview_apk" || {
    echo "Chromium WebView APK is missing: $webview_apk" >&2
    exit 1
  }
  if LC_ALL=C grep -Fqx 'version https://git-lfs.github.com/spec/v1' "$webview_apk"; then
    echo "Chromium WebView APK is an unmaterialized Git LFS pointer: $webview_apk" >&2
    exit 1
  fi
fi

"$HALIUM_INITRD_FETCHER"

: "${HALIUM_JOBS:=4}"
: "${NINJA_LOAD_LIMIT:=6}"
: "${CCACHE_TEMPDIR:=/var/tmp/rmx1901-ccache-tmp}"
export USE_CCACHE=1
export CCACHE_EXEC=/usr/bin/ccache
export CCACHE_DIRECT=true
export CCACHE_TEMPDIR TMPDIR
mkdir -p -- "$CCACHE_TEMPDIR" "$TMPDIR"
ulimit -n 65535 2>/dev/null || ulimit -n 8192 2>/dev/null || true
export NINJA_ARGS="-l${NINJA_LOAD_LIMIT}"

build_log="$artifact_dir/build.log"
mkdir -p "$artifact_dir"

(
  set -eo pipefail
  set +u
  cd "$HALIUM_ROOT"
  source build/envsetup.sh
  lunch halium_RMX1901-userdebug
  unset ALLOW_NINJA_ENV
  export LD_LIBRARY_PATH="$ANDROID_HOST_COMPAT_LIBDIR"
  m "-j${HALIUM_JOBS}" "${build_targets[@]}"
) 2>&1 | tee "$build_log"

product_out="$HALIUM_ROOT/out/target/product/RMX1901"
for image in "${images[@]}"; do
  test -s "$product_out/$image" || {
    echo "Missing build artifact: $image" >&2
    exit 1
  }
done

"$HALIUM_BOOT_INITRD_VERIFIER" "$product_out/halium-boot.img"
for image in "${images[@]}"; do
  cp -- "$product_out/$image" "$artifact_dir/$image"
done

(
  cd "$artifact_dir"
  sha256sum "${images[@]}" >manifest.sha256
)
