# Task 1 compatibility-provider provenance

This ledger is deliberately revision-complete.  A branch identifies the
release line; the accompanying 40-hex source-tree commit is the immutable
reproduction point.  `m/halium-11.0` is the checked-out manifest alias for the
Android 11 projects whose manifest default is `refs/heads/lineage-18.1`.

| ID / provider | Repository URL | Branch or manifest revision | Immutable source-tree commit | Precise source path | Local file / module | Local SHA-256 | Derivation and retention |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `libcrypto_shim` | `https://github.com/LineageOS/android_external_boringssl` | `lineage-18.1` (`m/halium-11.0`) | `4f3c98594811d05ec0c445a1203198525817f7c3` | `src/crypto/bytestring/cbs.c` (file history: `4c22c5fad19b2a554bcb056ca25ca4cc2ef6a45c`) | `device/realme/RMX1901/shims/libcrypto/cbs.c`; `shims/Android.bp:libcrypto_shim` | `8830a360e6f4eab408c9e1612912f32d15a0be108f57dbda679ac60a55bf037a` | Hand-reduced derivation of `CBS_init`, `CBS_data`, and `CBS_len` from the pinned checkout; required by vendor blobs without replacing the platform crypto provider. |
| `libcomparetf2_shim` | `https://github.com/LineageOS/android_hardware_lineage_compat` | `lineage-20.0` | `015d90baa57a65c5bdeed20997dfdede50e65ca7` | `libcomparetf2/comparetf2.c` (introduced by `bfad08e532a07ee28f5be4979019c499d6996bde`) | `device/realme/RMX1901/shims/libcomparetf2/comparetf2.c`; `shims/Android.bp:libcomparetf2_shim` | `bc3dc8308edd162cc90fc7a2e2965f3716f006adbe100257a36dda08ed804f7f` | Direct source derivation; comparison against the pinned source found only indentation/comment elision.  Supplies the 64-bit helper required by the proprietary binary. |
| `libcamera_metadata_shim` | `https://github.com/LineageOS/android_hardware_lineage_compat` | `lineage-20.0` | `015d90baa57a65c5bdeed20997dfdede50e65ca7` | `libcamera_metadata/camera_metadata.cpp` (introduced by `e386376f9c3ce006f2c5e4d8f91432624caf238a`) | `device/realme/RMX1901/shims/libcamera_metadata/camera_metadata.cpp`; `shims/Android.bp:libcamera_metadata_shim` | `a2ed2529e251c297d688ac34893821aea11134e556bf11da6904c616ceba328f` | Byte-identical copy at the pinned revision.  Filters `SYSTEM_CAMERA` capability while retaining A11 `libcamera_metadata`. |
| `android.hidl.base@1.0` | `https://github.com/LineageOS/android_system_libhidl` | manifest `refs/heads/lineage-18.1` (`m/halium-11.0`) | `1c4a769f74eb982b85fe5c22232454951e7b1524` | provider `Android.bp:libhidlbase`; canonical interface `transport/base/1.0/Android.bp` (file history `fd83b6b8cb5d6fb39220944c97e92323a20e28ca`) | `device/realme/RMX1901/shims/Android.bp:android.hidl.base@1.0` | `06339c38e21efa6c636da2ce914482f78379261e3cc9396f52fbb77ea2dbbae0` | Local forwarding module over pinned `libhidlbase`, retained for legacy vendor metadata.  It is **not** a copied Lineage compatibility file; exception `EX-HIDL-LOCAL-FORWARDER` below governs that corrected fact. |
| `libgui_shim` | `https://github.com/LineageOS/android_frameworks_native` | `lineage-18.1` (`m/halium-11.0`) | `103c04dc9ff92585765f9076959be684351064c3` | `libs/gui/Android.bp` (file history `2bd85a006f345eb64cc239b7705404cc36cc3b6e`) | `device/realme/RMX1901/shims/Android.bp:libgui_shim` | `06339c38e21efa6c636da2ce914482f78379261e3cc9396f52fbb77ea2dbbae0` | Local forwarding module to the pinned `libgui` provider; no external source file was copied. |
| `libaudioclient_shim` | `https://github.com/LineageOS/android_frameworks_av` | `lineage-18.1` (`m/halium-11.0`) | `18186d8f9b4dcaff242ae9ea9b74e6827f14a1cc` | `media/libaudioclient/Android.bp` (file history `2a45115039163601f30e9b87b9ea8f1674713dce`) | `device/realme/RMX1901/shims/Android.bp:libaudioclient_shim` | `06339c38e21efa6c636da2ce914482f78379261e3cc9396f52fbb77ea2dbbae0` | Local forwarding module to pinned `libaudioclient`, `liblog`, `libutils`, and `libmedia_headers`; no external source file was copied. |
| `libwfdservice_shim` | `https://github.com/LineageOS/android_system_core` | `lineage-18.1` (`m/halium-11.0`) | `d9e9c75fee6ff48a6cffbdfd727cb8f74ce39dd5` | `libutils/Android.bp` (file history `fb60e6c9aed973759e1fbd66a1dfbfc5b7cdaef6`) | `device/realme/RMX1901/shims/Android.bp:libwfdservice_shim` | `06339c38e21efa6c636da2ce914482f78379261e3cc9396f52fbb77ea2dbbae0` | Local forwarding/empty ABI bridge to pinned `libutils`; graph-compatible only, WFD runtime unverified. |
| `install_symlink` | `https://github.com/LineageOS/android_build_soong` | `lineage-18.1` (`m/halium-11.0`) | `570eaae5ca6125203ebecc8795ab407e7d843bae` | `android/module.go` and AndroidMk interfaces (file history `620313c837b9fe25c4f68908e7553eb9e578184c`) | `device/realme/RMX1901/soong/rmx1901_compat.go:install_symlink`; `soong/Android.bp` | `7093d6b345de1c7370e78c71aa2bfbf4fe0f7a4fb417fbd9548568c6f7f2706f` | Local A11 API implementation, not copied code.  Emits the Kati-visible install action retained for 12 packaged links. |
| `prebuilt_rfsa` | `https://github.com/LineageOS/android_build_soong` | `lineage-18.1` (`m/halium-11.0`) | `570eaae5ca6125203ebecc8795ab407e7d843bae` | `android/module.go` and `etc` prebuilt interfaces (file history `620313c837b9fe25c4f68908e7553eb9e578184c`) | `device/realme/RMX1901/soong/rmx1901_compat.go:prebuiltRFSAFactory`; `soong/Android.bp` | `7093d6b345de1c7370e78c71aa2bfbf4fe0f7a4fb417fbd9548568c6f7f2706f` | Local A11 API implementation, not copied code; retained for 33 RFSA declarations. |
| `libstdc++_vendor_alias` | `https://github.com/Lcryolite/device_realme_RMX1901.git` | `cnb` | `57ec42fd67d743b7f785b958d8e1916fba25eeb1` | `Android.bp` `install_symlink` declaration | `device/realme/RMX1901/Android.bp:libstdc++_vendor_alias` | `5a49b9c312c707a70c78506cd5fd10f4e1e150b4f9fc2a8f958bd6cb5bf9ef28` | Local product compatibility alias to the packaged platform `libstdc++`; no runtime library was copied or forked. |
| HIDL vendor visibility bridge | `https://github.com/LineageOS/android_system_libhidl`; `https://android.googlesource.com/platform/system/libhwbinder` | `lineage-18.1` / Android 11 manifest | `1c4a769f74eb982b85fe5c22232454951e7b1524`; `02d1280bbc31e6a95f677a1ad8858778587c8102` | `system/libhidl/Android.bp`; `system/libhwbinder/Android.bp` | those two committed platform `Android.bp` files | `not-applicable` | Visibility-only compatibility change: exposes real A11 providers `libhidltransport` and `libhwbinder`; no local copied shim content. |

## `EX-HIDL-LOCAL-FORWARDER` — authorized provenance exception

The original plan described `android.hidl.base@1.0` as an “upstream Lineage
implementation.”  Recovery disproved that: `git ls-tree -r
015d90baa57a65c5bdeed20997dfdede50e65ca7` in
`android_hardware_lineage_compat` contains only the camera and comparetf2
Task-1 shim paths, not an HIDL forwarding module; `git log --all --
device/realme/RMX1901/shims/Android.bp` has only Task-1 commit
`57ec42fd67d743b7f785b958d8e1916fba25eeb1`.

The user-directed audit exception authorizes this item to be recorded as a
local forwarder rather than a guessed external copy.  Its replacement
reproducibility key is the local `shims/Android.bp` SHA-256 above plus the
exact source-provider commit `1c4a769f74eb982b85fe5c22232454951e7b1524`.
This exception changes documentation only and grants no authority to alter the
functional module.

## Recovery commands and acceptance rule

The recovery used `git remote -v`, `git branch -a --contains HEAD`,
`git rev-parse HEAD`, `git log --all --follow -- <path>`, `git show`, and
`sha256sum` in the local Android tree.  For the two Lineage compatibility
files, `git ls-remote --heads` plus a temporary no-checkout clone verified the
published `lineage-20.0` tree and byte hashes.  The verifier rejects a row
without a repository URL, branch/manifest revision, immutable commit,
source path, local target, or a valid local content hash (except the explicit
visibility-only `not-applicable` row).
