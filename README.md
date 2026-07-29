# Ubuntu Touch 24.04 bring-up for realme X (RMX1901)

This repository is the standalone Ubuntu Touch adaptation for RMX1901. It is
separate from the Android device, vendor, kernel, and Halium source repositories.

The first bring-up target is Halium 11 with Ubuntu Touch 24.04-1.x. Source and
ramdisk inputs are pinned by SHA-1/SHA-256 in `build.sh`. The dedicated Ubuntu
Touch kernel repository is derived from the verified working tree and enables
the appended-DTB image required by this header-v1 device. Its pinned tree is
verified to contain no ReSukiSU/SukiSU marker before every build.

Run `./build.sh -b workdir -o out` to build the device tarball. The official
`prepare-fake-ota.sh` and `system-image-from-ota.sh` stages are intentionally not
invoked by this wrapper until their downloaded inputs and final install plan have
been independently audited.

After `prepare-fake-ota.sh` has produced an audited `ota/ubuntu_command`, build
the sparse system image without host root privileges with:

```sh
./scripts/system-image-from-ota-unprivileged.sh ota/ubuntu_command images
```

This wrapper accepts only the clean pinned adaptation-tools checkout. It makes
a temporary copy of the upstream converter under this repository's `workdir/`,
rejects an unexpected upstream script shape, redirects its fixed scratch path
to that directory, and forces its no-loop-device path without invoking `sudo`.
The transformed fallback formats the already-sized image instead of treating
its byte size as an ext4 block count. It runs inside an unprivileged user
namespace with the current user's subordinate UID/GID ranges, allowing tar and
`mke2fs -d` to preserve numeric ownership and traverse mode-0111 directories.

The former staged-system Recovery installer is retired for M0--M3. It always
refuses execution and performs no system-partition writes; do not invoke it as
an installation mechanism. The surviving Recovery preflight is read-only: it
verifies image and device identity facts and reports userdata persistent-log
eligibility only when `/proc/mounts` contains an unambiguous, independently
tokenized `ro` option with no `rw` option. It neither mounts, repairs, resizes,
formats, nor writes any filesystem.

The pinned custom ramdisk supports both the legacy userdata-rootfs layout and
the modern RMX1901 system-partition layout. For the latter, it accepts only the
exact system alias that resolves to the early-udev node `/dev/sda11`, revalidates that binding
immediately before mounting the canonical block device, and preserves the
ext4/F2FS read-only userdata probe. It never repairs, resizes, or formats a
filesystem. Boot and install artifacts still require their own final verifier
before use on a device.

## Cold-boot-validated graphics derivative

After producing the exact pinned QTI allocator baseline,
apply the cold-boot-validated HWC and user-session fixes with:

```sh
./scripts/build-stable-graphics-boot.sh \
  path/to/qti-baseline-boot.img \
  path/to/a11/vendor/lib64/libsdedrm.so \
  path/to/systemd-249/lib/systemd/systemd-logind \
  workdir/stable-graphics \
  path/to/KERNEL_OBJ/arch/arm64/boot/dts
```

The builder fails unless the baseline boot image, QTI allocator,
`libsdedrm.so`, matching systemd 249 logind, and 64 MiB partition contract
match their pinned hashes. It rebuilds the ramdisk with root ownership,
restores the AVB hash footer, then reverse-verifies the header, payload hashes,
kernel, and six-DTB suffix.

The RMX1901 derivative mounts the existing `/dev/sda13` F2FS volume only after
fail-closed device-size and `system-data`/`user-data` layout checks. It does not
format, repair, or wipe userdata.

The RUI2 stock boot security patch level has not yet been recovered from a
matching stock image. `deviceinfo` therefore uses the minimum date accepted by
the official `mkbootimg` frontend (`2000-01-01`) rather than claiming an
unverified vendor patch month.
