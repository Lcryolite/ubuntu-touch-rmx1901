#!/bin/sh
set -eu

mkdir -p ./out
./prepare-fake-ota --output ./out/fake-ota.zip
./system-image-from-ota --output ./out
test -f ./rootfs.img
test -f ./system.img
adb push ./rootfs.img /data/rootfs.img
adb push ./system.img /data/system.img
fastboot boot ./halium-boot.img
