# Halium boot mkbootimg host-tool provenance

## Failure

The Android 11 build stopped while assembling `halium-boot.img` because
`halium/halium-boot/Android.mk` invoked bare `mkbootimg` through `PATH`.
Android 11's path interposer correctly rejected that undeclared host-tool use.
The rule also depended on the `mkbootimg` module name only through a separate
phony edge, rather than declaring the resolved executable as an input of the
image file rule.

The platform's standard boot image rules use `$(MKBOOTIMG)` both as a file
prerequisite and as the recipe command. With no board-specific override,
Android 11 defines it as `$(HOST_OUT_EXECUTABLES)/mkbootimg`.

## Correction

Halium boot commit `d252df6d53f49181773fc4997b3cff4a6b50acb5` applies the same pattern:

- `$(LOCAL_BUILT_MODULE)` directly depends on `$(MKBOOTIMG)`;
- the recipe executes `$(MKBOOTIMG)`, never bare `mkbootimg`;
- the obsolete `halium-boot: mkbootimg` phony dependency is removed.

Successor commit `9295810bfdde5b50eaf38bbd9b4a7ea4de7ace10` also makes the
selected local device initrd an explicit input of the generated ramdisk target.
This prevents Ninja from repacking a new kernel with a stale initrd intermediate.

No PATH-policy escape, broken-build flag, network permission, device setting,
vendor source, or kernel source was changed.

The port manifest pins the successor commit from the published
`Lcryolite/halium-boot` repository while retaining the standard
`halium/halium-boot` checkout path.

The regenerated Ninja graph resolves both command and dependency to the host
output:

```text
command = ... out/host/linux-x86/bin/mkbootimg --ramdisk ... --output ...
build .../halium-boot.img: ... out/host/linux-x86/bin/mkbootimg ...
```

## Historical verification

The focused `m -j8 halium-boot` target completed successfully. Its first build
also built the previously absent declared host tool and its host dependencies;
it did not request `systemimage` or a full product build.

```text
build time: 07:00 (mm:ss)
image:      out/target/product/RMX1901/halium-boot.img
size:       20815872 bytes
sha256:     62b9362614716ec941d6bff3519c920fe2c2f5089fae790362a5ba62c3dedfb0
file:       Android bootimg, header version 1, page size 4096
```

That historical build embedded SHA-256
`0bbac4577f3567aec935c958216de5d30c7355452ca56248d6728f4f2634bdb6`.
It is now classified as the unsafe legacy initrd and is not an acceptable
release artifact. Current publication is gated on the safe initrd SHA-256
`ac74c1124cc5cab7b9b42c9a06ca8ff5e14fc2d6e0d7237deb42da8a6788ceca`.
