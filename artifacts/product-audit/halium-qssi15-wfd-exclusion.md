# Halium-only QSSI 15 Wi-Fi Display exclusion

## Decision

The RMX1901 Halium product excludes the complete system-side Wi-Fi Display
cohort extracted from `LA.QSSI.15.0.r1-13300-qssi.0`. This deliberately removes
Miracast from the first bootable Halium image. Wi-Fi Display is
non-boot-critical; display composition, HWC, SurfaceFlinger, the physical
screen, and the separate vendor display services remain selected.

The ordered path-to-module inventory is
`halium-qssi15-wfd-exclusion.tsv`. It records all 48 source entries: the first
six are the boot jar, service, and four configuration files; the remaining
audited WFD42 contains exactly **42 paths** for the 32/64 libraries, JNI payload,
and APK. Duplicate multilib paths collapse to 27 generated product modules.
Together with the obsolete Halium-only `libwfdservice_shim`, the product graph
removes exactly **28 modules**, four copy files, and the WfdCommon boot-jar edge.

## Failure evidence

Run 8 stopped at the real ELF check for the 32-bit `wfdservice`. The immutable
blob has SHA-256
`b70b444ebdc6f97ee6d9e81059a1ccf706b5ba9d0a9648a8523e18a9eac2c8e0`,
GNU build ID `947c1fdc8109d059a922a2c6ac2bc008`, and Android ELF note version 35.
Among its unresolved versioned imports were:

```
_ZN7android12ProcessState15startThreadPoolEv@LIBBINDER
_ZN7android12ProcessState4selfEv@LIBBINDER
_ZN7android14IPCThreadState14joinThreadPoolEb@LIBBINDER
_ZN7android14IPCThreadState4selfEv@LIBBINDER
backtrace@LIBC_T
backtrace_symbols@LIBC_T
```

The stack has further Android 15 versus Android 11 ABI gaps across its library
cohort. An older API 30 candidate is not a safe replacement: it retains missing
Skia dependencies and a damaged symlink relationship. Consequently this change
does not add shims, weaken ELF validation, replace blobs mechanically, or mix
parts from the two incompatible stacks.

## Product scoping

Android product inheritance records child products as `@inherit:` nodes and
merges them only after product files are parsed. A filter placed after the
inherits in `halium_RMX1901.mk` was therefore proven ineffective by the RED
contract: all 28 modules remained in the resolved graph.

The final implementation keeps the generated declarations intact and applies
the exact filters at the end of `RMX1901-vendor.mk`, guarded by
`TARGET_PRODUCT=halium_RMX1901`. The device tree removes only the shim that it
previously added exclusively for Halium. Ordinary Android product declarations
remain present and take the unfiltered branch. Neither `Android.bp`, any
proprietary file, nor the vendor-side Android 11 WFD/HW display cohort changes.

The independently published source pins are:

| Path | Repository | Branch | Base | Published commit |
| --- | --- | --- | --- | --- |
| `device/realme/RMX1901` | `Lcryolite/device_realme_RMX1901` | `cnb` | `9839ed0f966a674d8b83acc4b595fc387a90d721` | `f3aa149c70944bb08fb0b83f74e9022bf1147104` |
| `vendor/realme/RMX1901` | `Lcryolite/1vendor_realme_RMX1901` | `cnb` | `acde0a33dcc1a66dc5f0ca6c334e8cb1cf36582f` | `a67bd6fe9f968991e342e26ec3ba6969f45b1e5c` |

## Verification gate

`tests/test-halium-wfd-exclusion.py` derives the WFD42 mapping from the pinned
proprietary list and Blueprint modules, checks the exact 27/4/boot-jar filter,
requires the ordinary declarations to remain, and reads the resolved Halium
product variables. A focused `m nothing` must also finish without selecting the
excluded service. This only proves a clean product graph; Miracast remains an
explicitly unavailable feature until a matched stack is independently brought
up and runtime-tested.

On 2026-07-27, the focused `m -j8 nothing` regenerated the Make/Soong graph and
completed successfully in 2 minutes 57 seconds. Its log SHA-256 was
`c8640c444c9df8632df6d7b290778d6d31e80f7fb85d3601746f296a32c68841`.
The build cleanup explicitly removed previously installed WFD configuration,
32/64-bit libraries, AIDL library, and shim artifacts. A subsequent resolved
`PRODUCT_PACKAGES`/`PRODUCT_BOOT_JARS`/`PRODUCT_COPY_FILES` check and installed
product-path scan found none of the excluded cohort.
