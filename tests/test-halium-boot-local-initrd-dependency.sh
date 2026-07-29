#!/usr/bin/env bash
set -euo pipefail

: "${HALIUM_ROOT:=/home/lknife/android/rmx1901-halium11}"
android_mk="$HALIUM_ROOT/halium/halium-boot/Android.mk"
test -f "$android_mk"

grep -Fq 'HALIUM_LOCAL_INITRD := $(firstword $(wildcard device/*/$(TARGET_DEVICE)/initramfs.gz))' \
  "$android_mk"
grep -Fq '$(HALIUM_BOOT_RAMDISK): $(HALIUM_LOCAL_INITRD)' "$android_mk"
grep -Fq '@cp $(HALIUM_LOCAL_INITRD) $@' "$android_mk"

if grep -Fqx '.PHONY: HALIUM_BOOT_RAMDISK' "$android_mk"; then
  echo 'halium-boot still declares the variable name rather than its target phony' >&2
  exit 1
fi

echo 'Halium local initrd dependency contract passed'
