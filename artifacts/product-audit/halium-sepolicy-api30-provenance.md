# RMX1901 Halium 11 API30 sepolicy provenance

## Published source pins

| Path | Repository | Branch | Full revision |
| --- | --- | --- | --- |
| `device/realme/RMX1901` | `Lcryolite/device_realme_RMX1901` | `cnb` | `629a71f00b2f8d1d9a4ce3fb232203b17bc55e5e` |
| `device/lineage/sepolicy` | `Lcryolite/android_device_lineage_sepolicy` | `lineage-18.1` | `04ab50816e0ab9ae7ed5aa094c70e276e1175479` |

The Lineage sepolicy repository is a fork of
`LineageOS/android_device_lineage_sepolicy`. Its default branch was set to
`lineage-18.1`. Live `git ls-remote` checks returned the exact revisions above
for `refs/heads/cnb` and `refs/heads/lineage-18.1` before this manifest was
updated.

## Scope and rationale

The Halium product excludes the unused Lineage LiveDisplay service, manifest
entry, and only the corresponding QCOM policy directories. Ordinary Lineage
products retain the original LiveDisplay policy graph. RMX1901's remaining
post-API30 policy references are either mapped to the exact Android 11 semantic
type or omitted only where the associated newer feature is not selected.

The USB product graph uses Android 11 HIDL services
`android.hardware.usb@1.0-service` and
`android.hardware.usb.gadget@1.0-service-qti`. Its Halium framework matrix
fragment declares optional compatibility with HIDL
`android.hardware.usb.gadget@1.0`; the ordinary product
continues to select its newer USB service pair.

The watermark proc node has an exact vendor-owned type and genfs label for
`/proc/sys/vm/watermark_scale_factor`; it does not broaden access to generic
`proc`. No SELinux ignore switch, neverallow bypass, dummy attribute, or broad
policy deletion was used.

## Verification evidence

- `m -j8 sepolicy_neverallows`: success; attempt9 log SHA-256
  `3d6fa41ac6640aba36ec0b68231a1ed08818860da42a9d50763007ed053e58da`.
- Fresh `m -j8 sepolicy_neverallows vendor_sepolicy.cil` after moving the
  watermark type to vendor ownership: success; log SHA-256
  `56ef5527371482b3488f7d96a5550f32f49f946115f91b250dfd5e391c947812`.
- Seven focused source/generated-policy contracts: success; combined log
  SHA-256
  `6bf32b71de2047964a6abf38dbad8f27cf56fa35e712e8e172508d2274f267a0`.
- Focused generated USB VINTF matrix target: success; log SHA-256
  `baa607e4e659bf8556cff4cb61d05ffa1f837cdedee3134ae1f579d0deb9404b`.

These hashes identify local verification logs without adding generated Android
build outputs to this repository.
