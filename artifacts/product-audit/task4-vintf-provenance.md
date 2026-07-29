# Task 4 VINTF provenance audit

## Failure and root cause

The Halium 11 product originally set
`DEVICE_FRAMEWORK_COMPATIBILITY_MATRIX_FILE` to both the RMX1901 device
framework matrix and
`hardware/qcom-caf/common/vendor_framework_compatibility_matrix.xml`.
`framework_compatibility_matrix.device.xml` therefore acquired a hard input on
that Qualcomm file.

The checked-out `hardware/qcom-caf/common` project is LineageOS 18.1 commit
`5bd19fac7133383aeebd8b601e1de3c0685bf240`. Neither that revision nor its
18.1 history contains `vendor_framework_compatibility_matrix.xml`; the file is
from newer Lineage platform branches. This was a source-generation mismatch,
not an optional missing dependency.

## Selected RUI 2 / Android 11 inputs

The Halium product now uses historical RMX1901 inputs already present in the
device repository history:

- `compatibility_matrix.xml` is byte-identical to
  `ab56e9e^:compatibility_matrix.xml`, originally based on Qualcomm
  `LA.UM.8.8.r1-07300-SDM710.0` and subsequently updated for secure element.
  SHA-256:
  `f1c34caf3355c19502844380261bc6348880d777ca0a9f455bc6dbedc376233b`.
- `manifest_halium.xml` derives from `fdf19ab:manifest.xml`, the device state
  labelled "Update audio configs from RUI 2.0 F06". The unused Lineage
  LiveDisplay HAL was removed with its service and policy. It remains a device
  manifest at target FCM level 4 with HIDL audio and audio-effect 6.0.
  SHA-256:
  `88481077da3aa47e5b221dacc27361a3d9a0b79cd71077f6b9a049f8c62526ff`.
- `framework_compatibility_matrix_halium.xml` is a minimal framework fragment
  declaring optional compatibility with the selected Android 11 HIDL USB
  gadget 1.0 service. SHA-256:
  `7da22914cfb51ee72a8cdbf28d411a973dcf23ddf053e6e18678c41cd3765798`.

The selection is guarded by `TARGET_PRODUCT == halium_RMX1901`. Existing
non-Halium declarations remain in the alternate branch, so this Android 11
compatibility selection does not silently change native products built from a
matching newer platform tree.

## Verification

The following focused Android build targets completed successfully:

- `m -j2 framework_compatibility_matrix.device.xml vendor_manifest.xml`
- `m -j2 check-vintf-all`

The complete compatibility result is `COMPATIBLE` in
`out/target/product/RMX1901/obj/PACKAGING/check_vintf_all_intermediates/check_vintf_compatible_log`.
The generated framework device matrix contains only the Halium HIDL USB gadget
1.0 requirement; the vendor manifest uses HIDL audio 6.0 and no LiveDisplay.

`tests/test-halium-vintf-contract.sh` pins the two source hashes and validates
the active Halium build variables and key schema/HAL properties.
