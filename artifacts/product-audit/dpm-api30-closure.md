# RMX1901 API30 DPM closure provenance

## Source decision

The DPM userspace is an atomic Android R/API30 closure taken from the audited
RMX1901 RUI2 candidate repository
`https://github.com/Vendor-Blobs/android_vendor_tree_realme_RMX1901.git` at
commit `f97fae29e34e28c7f06c47802d168e2cf81216ef`. The ordinary RMX1901 product
metadata and build fingerprint are also RUI2/Android 11; the replaced QSSI 15
DPM files were an incompatible mixed-generation import rather than a working
Android 17 product contract.

The published sources are pinned independently:

| Path | Repository/branch | Base | Published commit |
| --- | --- | --- | --- |
| `device/realme/RMX1901` | `Lcryolite/device_realme_RMX1901:cnb` | `f3aa149c70944bb08fb0b83f74e9022bf1147104` | `629a71f00b2f8d1d9a4ce3fb232203b17bc55e5e` |
| `vendor/realme/RMX1901` | `Lcryolite/1vendor_realme_RMX1901:cnb` | `a67bd6fe9f968991e342e26ec3ba6969f45b1e5c` | `1de6c5364d6ac44ae205276bc43c425a6ee946e5` |

## Selected closure

The **5 replacements** are all API30, ELF64/AArch64 and remain 64-bit-only:

| Installed path | SHA-256 |
| --- | --- |
| `system_ext/bin/dpmd` | `7ed535a997d679dc32406969f708f2ea2430c46b17927f96ecd1f63fb3138c52` |
| `system_ext/lib64/com.qualcomm.qti.dpm.api@1.0.so` | `2d1f9e8ab7dcf0a386ac9aeb6a4678a7230fce6699ecb7e5c10c8c5159b531d5` |
| `system_ext/lib64/libdpmframework.so` | `7870d098b618a166e62bc0b081c6ede6c375a0d8e47059b1f6099111bdb3aed2` |
| `system_ext/lib64/libdiag_system.so` | `587eee086464f3c6cb0559a3b34721bfcf278aa66bfeb0d608a2590ac8de0d1a` |
| `system_ext/lib64/vendor.qti.diaghal@1.0.so` | `f160ade4076c305bfedf67ae7fcffe532c284238940a6af0cda66bc3680c5693` |

The **9 byte-identical keeps** are `dpm.conf`, `dpmd.rc`, `dpmQmiMgr`,
`dpmQmiMgr.rc`, the vendor API library, `libdpmqmihal`, and the three DPM
firmware files. Their hashes are enforced by the pinned device verifier.
The verifier's reduced closure TSV is tracked alongside the verifier, so a
clean checkout of the published device/vendor pins is the complete oracle; it
does not require the mutable candidate working tree.

Eight late-generation modules and ten associated APK/JAR/SO/XML paths were
removed as one checkpoint. The five retained module declarations use the exact
candidate `DT_NEEDED` closure, keep real ELF checking enabled, and have
**missing0** against the current 64-bit A11 provider union. There is **no 32-bit import**
because both selected daemon entrypoints are ELF64.

The privileged-permission change is Halium-scoped: Halium selects a copy that
only omits the removed `com.qti.dpmserviceapp` grant, while the ordinary product
continues selecting the original permission file. The verifier compares both
XML files structurally to prevent unrelated permission drift.

The ordinary `lineage_RMX1901` product inherits the same API30 vendor closure,
which matches its Android 11/RUI2 fingerprint. Its local inheritance,
fingerprint and original permission branch are enforced structurally. A live
ordinary-product `lunch` remains blocked by the pre-existing incomplete
Lineage base (`build/make/target/product/non_ab_device.mk` is absent), so this
is explicitly static non-regression coverage rather than claimed build proof.

## Focused build evidence

On 2026-07-27 the focused command built all eight retained DPM modules with
`-j8` and completed successfully in 3 minutes 24 seconds. The log SHA-256 is
`9e5aa0cb6bd4a6efc167f0a4890494da349920ddf161d40166204e29686a22bb`.
The log contains real `Check prebuilt ELF binary` actions for all five replaced
system modules, `dpmd`, and `dpmQmiMgr`; no undefined-symbol allowance or ELF
checker bypass was used.

A subsequent `m -j8 nothing` completed successfully in four seconds with log
SHA-256
`70c69a03496af895632a4967c060cd5338124773bb04bec46ef55673fe05263d`.
The final installed hashes of the five replacements and three retained vendor
executables/libraries exactly matched the closure. Searches for all ten
forbidden installed paths returned zero.

The complete focused and `nothing` logs are tracked at
`artifacts/product-audit/logs/dpm-api30-focused.log` and
`artifacts/product-audit/logs/dpm-api30-nothing.log`; the published contract
rehashes both files, requires their success markers and real prebuilt ELF-check
actions, and the device verifier requires every replacement in `PRODUCT_OUT`.

## Explicit boundary

**IMS remains unresolved**: four API35 IMS libraries still load the shared
API30 `libdiag_system.so`. They are recorded in
`tests/dpm-api30-ims-boundary.txt` and must remain excluded or quiescent during
this phase. DPM build success is not IMS validation, and no private-library
rename, binary patch, or unsupported mixed namespace was introduced.

Runtime service stability and mobile-data transitions remain post-flash gates;
this checkpoint intentionally did not run a new full build, change initrd, or
flash the device.
