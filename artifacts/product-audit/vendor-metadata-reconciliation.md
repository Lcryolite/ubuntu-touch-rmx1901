# Vendor `Android.bp` reconciliation — `acde0a3`

Scope: the only vendor source change is `vendor/realme/RMX1901@acde0a3`,
`Android.bp`.  `git diff --numstat acde0a3^ acde0a3 -- Android.bp` is **22
insertions / 82 deletions**, for 104 changed metadata lines.  No file under
`proprietary/` changed.

The following ledger accounts for every one of those 104 lines.  “Old line” is
the line number in `acde0a3^:Android.bp`, so it is independently recoverable;
the companion verifier checks the exact count and all dependency tokens from
the zero-context patch.

| Category | Old line(s), metadata action | Lines | Reason | Provider retained / replacement |
| --- | --- | ---: | --- | --- |
| Namespace imports | 9 `hardware/qcom-caf/wlan`; 11 `vendor/qcom/opensource/commonsys/display`; 13 `vendor/qcom/opensource/display` removed | 3 del | The generated vendor namespace imported unavailable/duplicate trees. | Actual CAF/device packages remain selected through `PRODUCT_SOONG_NAMESPACES`; no blob was removed. |
| Protobuf ABI names | lite: 2323, 2340, 2371, 2390, 2423, 2443, 2785, 2814, 12823, 18600, 18631, 20715; full: 6181, 6224, 7444, 9608, 12406, 12859, 13626, 19561. Each `*-3.9.1-vendorcompat` replaced with the A11 base name | 20 del + 20 add | Android 11 exposes the base protobuf providers, not the old compatibility aliases. | `libprotobuf-cpp-lite` (12) and `libprotobuf-cpp-full` (8), the system-provided modules. |
| Duplicate tinycompress prebuilt | 4202–4228 complete `libtinycompress` prebuilt module removed | 27 del | Its generated, preferred 32-bit prebuilt would collide with the platform tinycompress provider. | Platform/existing tinycompress provider; proprietary `vendor/lib/libtinycompress.so` was not changed. |
| Required legacy HIDL edges | at 4337/4338 add `libhwbinder`, `libhidltransport` | 2 add | A vendor blob genuinely declares these A11 legacy HIDL dependencies. | Real system providers, made legally visible by `system/libhwbinder@02d1280` and `system/libhidl@1c4a769`. |
| Unavailable generated ABI edges | 31, 17579, 18126 `android.hardware.common-V2-ndk`; 3422, 3456 `libOmxCore`; 4405 `libclang_rt.ubsan_standalone`; 4499 `libwfdaac_vendor`; 16879, 16898 `libdisplayconfig.system.qti`; 16881, 16900 `vendor.qti.hardware.display.config-V5-ndk`; 17502 `android.hardware.graphics.allocator-V2-ndk`; 17544 `audioclient-types-aidl-cpp`, 17545 `android.media.audio.common.types-V4-cpp`; 17731 `libdmabufheap` removed | 15 del | These are stale generated metadata edges to modules unavailable in this Android 11 product graph. | Runtime blobs stay in place.  Where a Task 1 compatibility provider exists (`libwfdservice_shim`, `libaudioclient_shim`), it is retained in the device product; WFD runtime remains explicitly unverified. |
| Legacy Make provider edges | 9347 `libstdc++_vendor`; 9914, 13435, 19994, 20178 `libwpa_client`; 11835, 20344 `libjson`; 12530 `libril`; 12612 `libdrmutils`; 12671, 12730 `libsdmutils`; 19221 `libcld80211` removed | 12 del | These names are supplied by existing Make/product providers, not by independently visible Soong modules. | `libstdc++_vendor_alias` replaces the vendor-named compatibility link; `libjson`, `libdrmutils`, `libsdmutils`, and `libcld80211` are retained in the Task 1 `PRODUCT_PACKAGES`; the Wi-Fi/RIL providers remain their existing Make providers. |
| CAF display Make edge | 12612, 12643, 12673, 12699, 12730 `libdisplaydebug` removed | 5 del | Five generated Soong-only edges incorrectly attempted to resolve a Make-provided CAF display module in Soong. | CAF sdm845 Make `libdisplaydebug` remains in `PRODUCT_PACKAGES`; no display source changed. |

Totals: 3 + 40 + 27 + 2 + 15 + 12 + 5 = **104** changed metadata
lines (82 deletions, 22 insertions).

## Machine verification

Run from this port worktree (or pass the vendor repository as the first
argument):

```bash
bash artifacts/product-audit/verify-task1-audit.sh \
  /home/lknife/android/rmx1901-halium11/vendor/realme/RMX1901
```

The verifier rejects a non-`22/82` patch, validates every grouped token and
its occurrence count in the actual zero-context patch, and confirms that the
commit touched `Android.bp` only.
