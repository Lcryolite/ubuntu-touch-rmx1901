#!/usr/bin/env bash
set -euo pipefail

: "${HALIUM_ROOT:=/home/lknife/android/rmx1901-halium11}"
test -f "$HALIUM_ROOT/build/envsetup.sh" || {
  echo "Halium build environment is missing" >&2
  exit 1
}

packages="$(
  set +u
  cd "$HALIUM_ROOT"
  source build/envsetup.sh >/dev/null
  lunch halium_RMX1901-userdebug >/dev/null
  get_build_var PRODUCT_PACKAGES
)"

local_initrd="$(
  set +u
  cd "$HALIUM_ROOT"
  source build/envsetup.sh >/dev/null
  lunch halium_RMX1901-userdebug >/dev/null
  get_build_var BOARD_USE_LOCAL_INITRD
)"

ninja_env_vars="$(
  set +u
  cd "$HALIUM_ROOT"
  source build/envsetup.sh >/dev/null
  lunch halium_RMX1901-userdebug >/dev/null
  get_build_var BUILD_BROKEN_NINJA_USES_ENV_VARS
)"

kernel_clang_compile="$(
  set +u
  cd "$HALIUM_ROOT"
  source build/envsetup.sh >/dev/null
  lunch halium_RMX1901-userdebug >/dev/null
  get_build_var TARGET_KERNEL_CLANG_COMPILE
)"

test -n "$packages" || {
  echo "halium_RMX1901 package query returned no data" >&2
  exit 1
}

for package in \
  android.system.net.netd@1.1-service.stub \
  libdroidmedia \
  libui_compat_layer; do
  printf '%s\n' "$packages" | tr ' ' '\n' | grep -Fx "$package" >/dev/null || {
    echo "halium_RMX1901 is missing Halium package: $package" >&2
    exit 1
  }
done

test "$local_initrd" = true || {
  echo "halium_RMX1901 does not require the verified local initrd" >&2
  exit 1
}

test "$ninja_env_vars" = LD_LIBRARY_PATH || {
  echo "halium_RMX1901 does not narrowly allow the audited host library path" >&2
  exit 1
}

test "$kernel_clang_compile" = true || {
  echo "halium_RMX1901 does not enable its pinned Clang kernel compiler" >&2
  exit 1
}

python3 - "$HALIUM_ROOT/device/realme/RMX1901/BoardConfig.mk" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
guard = (
    r"ifeq \(\$\(TARGET_PRODUCT\),halium_RMX1901\)\s+"
    r"BUILD_BROKEN_NINJA_USES_ENV_VARS := LD_LIBRARY_PATH\s+endif"
)
if not re.search(guard, text):
    raise SystemExit("LD_LIBRARY_PATH Ninja allowlist is not Halium-product guarded")
clang_guard = (
    r"ifeq \(\$\(TARGET_PRODUCT\),halium_RMX1901\)\s+"
    r"TARGET_KERNEL_CLANG_COMPILE := true\s+endif"
)
if not re.search(clang_guard, text):
    raise SystemExit("Clang kernel compiler selection is not Halium-product guarded")
PY

echo "Halium product contract tests passed"
