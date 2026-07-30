#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
android_root="${RMX1901_ANDROID_ROOT:-/home/lknife/android/rmx1901-halium11}"
product="$android_root/out/target/product/RMX1901"
clang="$android_root/prebuilts/clang/host/linux-x86/clang-r383902b1/bin/clang++"
sysroot="$android_root/prebuilts/ndk/r21/platforms/android-29/arch-arm64"
output="${1:?usage: $0 <output-file>}"

test -x "$clang"
test -d "$sysroot"
mkdir -p "$(dirname "$output")"
"$clang" --target=aarch64-linux-android29 --sysroot="$sysroot" -fuse-ld=lld -rtlib=compiler-rt -std=c++17 -O2 -fno-exceptions -fno-rtti -fPIE -pie \
    -include "$repo_root/scripts/rmx1901-wifi-hidl-probe-prefix.h" \
    -isystem "$android_root/prebuilts/clang/host/linux-x86/clang-r383902b1/include/c++/v1" \
    -I"$repo_root/scripts/android-headers" \
    -isystem "$android_root/bionic/libc/include" \
    -isystem "$android_root/bionic/libc/kernel/uapi" \
    -isystem "$android_root/bionic/libc/kernel/android/uapi" \
    -isystem "$android_root/bionic/libc/kernel/uapi/asm-arm64" \
    -I"$android_root/out/soong/.intermediates/hardware/interfaces/wifi/1.0/android.hardware.wifi@1.0_genc++_headers/gen" \
    -I"$android_root/out/soong/.intermediates/system/libhidl/transport/base/1.0/android.hidl.base@1.0_genc++_headers/gen" \
    -I"$android_root/out/soong/.intermediates/system/libhidl/transport/manager/1.0/android.hidl.manager@1.0_genc++_headers/gen" \
    -I"$android_root/system/libhidl/base/include" \
    -I"$android_root/system/libhidl/transport/include" \
    -I"$android_root/system/libhwbinder/include" \
    -I"$android_root/system/core/libutils/include" \
    -I"$android_root/system/core/libcutils/include" \
    -I"$android_root/frameworks/native/libs/binder/include" \
    "$repo_root/scripts/rmx1901-wifi-hidl-probe.cpp" \
    -L"$product/system/lib64" -L"$product/system/apex/com.android.vndk.current/lib64" \
    -Wl,-rpath,/system/lib64 -Wl,-rpath,/system/apex/com.android.vndk.current/lib64 \
    -l:android.hardware.wifi@1.0.so -lhidlbase -lhidltransport -lhwbinder -lutils -lcutils -llog -lc++ \
    "$product/system/apex/com.android.runtime/lib64/bionic/libc.so" -lm -ldl \
    -o "$output"
file "$output"
