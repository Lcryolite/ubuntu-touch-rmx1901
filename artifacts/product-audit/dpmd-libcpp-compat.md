# RMX1901 DPM libc++ compatibility provenance

## Failure and blob identity

The Halium 11 focused build originally stopped in Soong's `check_elf_file`
for `vendor/realme/RMX1901/proprietary/system_ext/bin/dpmd`. The immutable
input has SHA-256
`8f289a051a9917e998e813db8da01de6a519cacc7056338136a08f7093e92dd8`,
GNU build ID `ac862e9c1ae4f8f875dee312e6840d08`, and Android ELF note version 35.
Its undefined dynamic symbol is
`_ZNSt3__122__libcpp_verbose_abortEPKcz` and its `DT_NEEDED` entries are:

```
libdpmframework.so
libdiag_system.so
libhardware_legacy.so
libhidlbase.so
libcutils.so
libutils.so
com.qualcomm.qti.dpm.api@1.0.so
libc++.so
libc.so
libm.so
libdl.so
```

An exhaustive `readelf --dyn-syms -W` scan of the proprietary tree found
**45 consumers, 0 providers** for this symbol. The bundled vendor
`libc++_shared.so` neither exports it nor has the required `libc++.so` SONAME.
The Android 11 platform `libc++.so` was therefore the actual missing runtime
provider; disabling ELF checks would only hide a loader-time failure.

This result is deliberately scoped to the `verbose_abort` consumer cohort,
not to every newer blob. The device `proprietary-files.txt` identifies DPM,
IMS, WFD, and other groups as `LA.QSSI.15.0.r1-13300-qssi.0`; 63 proprietary
ELFs carry Android note version 35. In particular,
`proprietary/system_ext/lib64/lib-imsvt.so` also imports the Android 11-missing
filesystem symbol
`_ZNSt3__14__fs10filesystem8__statusERKNS1_4pathEPNS_10error_codeE`, while its
module currently has `check_elf_files: false`. That separate ABI gap remains a
required audit gate before a full image can be called runtime-compatible. It
is not papered over or expanded into this focused backport.

## Published compatibility source

The minimal backport adds a formatted diagnostic followed by `abort()` to the
Android 11 libc++ static source set, so the final platform shared library
exports the ABI used by the RUI2 blobs.

| Field | Value |
| --- | --- |
| Upstream source | `LineageOS/android_external_libcxx` |
| Upstream/base commit | `8e12f3ece5c809efb45393fb889beeb43a3280c5` |
| Upstream/base tree | `7a5ca5b6cd3185e888a937ee3b5e1025fff4f69f` |
| Published repository | `Lcryolite/android_external_libcxx` |
| Published branch | `lineage-18.1` |
| Published commit | `17c9d2048cf121a25b75e0117332261a9dec9f24` |
| Published tree | `f172ea73a94c619695bc88bab3f70e70d0ed45a7` |

## Focused verification

On 2026-07-27, `m -j8 dpmd` completed successfully in 3 minutes 23 seconds,
including the real `Check prebuilt ELF binary` action and installation to
`system/system_ext/bin/dpmd`. The log SHA-256 was
`90d9afa80bc4556bc663f8a95ab932302e96da30e8daa779e2aa8f3ef088f943`.
The resulting stripped arm64 platform libc++ SHA-256 was
`0fa18041007f32ff3955a67ff6b06bb32e615675a17eee98353900da41e8a444`;
its unstripped symbols copy was
`894b6a794b0dfdcd966a0d0d30ae893413d0e9b2a9f542673ae332aa68ee5ad6`.
The installed dpmd retained the audited input SHA-256.

A second focused `m -j8 libc++` completed successfully in 21 seconds and
rebuilt both target architectures (log SHA-256
`d21d899360c6c8afe10f17b0ca16fee00c44861d4ab3c13c08614c51bd068273`).
The stripped installed arm64 and arm libraries have SHA-256
`0fa18041007f32ff3955a67ff6b06bb32e615675a17eee98353900da41e8a444`
and `9b3afe54f404dd7319aea85c55759f94d73e3d6569ac229e0caf171da6483790`,
respectively. Each exports exactly one global definition of the required
symbol. The current vendor VNDK APEX copies were rebuilt in the same action
and also export it for both architectures.

No `allow_undefined_symbols` or `check_elf_files: false` escape hatch is used
for dpmd or for this focused `verbose_abort` compatibility fix.

## Subsequent API30 DPM closure

The later atomic DPM replacement superseded the original API35 dpmd with the
audited API30 blob whose SHA-256 is
`7ed535a997d679dc32406969f708f2ea2430c46b17927f96ecd1f63fb3138c52`.
That dpmd no longer imports `__libcpp_verbose_abort`; removal of the associated
late-generation DPM components reduced the current proprietary scan to
**37 consumers, 0 providers**. The libc++ backport remains required for those 37
other QSSI 15 consumers and continues to be tested in all installed runtime
copies. The historical 45-consumer dpmd failure evidence above is retained to
explain why the compatibility ABI was introduced.
