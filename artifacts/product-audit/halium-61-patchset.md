# Halium 11 official patchset provenance

## Source and scope

The Android tree uses `Halium/hybris-patches` revision
`0b07bd1d2f0a8468b2b101bddfc9c4cba14edde0`. Its `apply-patches.sh`
selects every `*.patch` in sorted order. At that revision this is exactly 61
patches across 14 platform repositories.

Each patch was imported as one commit with `git am`, in its official filename
order. `frameworks/av` was reconstructed in a temporary worktree because its
first import had the same final tree but the wrong commit order; the audited
head below is strictly `0001` through `0011`. The existing
`system/libhwbinder` commit `02d1280bbc31e6a95f677a1ad8858778587c8102`
was retained as that repository's base.

| Path | Base | Patched head | Patches |
| --- | --- | --- | ---: |
| `art` | `7f2b48980eaa3e9ebeb3fe2df55ae4beb96f8248` | `70edec040ae3fcee67de5f497614f7110a195fb3` | 2 |
| `bionic` | `3a003876ad043c5280e0fbb334e8d17c3d941bfc` | `f0abd0b66ae263d4b12018a285c5c447e1150d48` | 9 |
| `build/make` | `4fdba55d8946e7ede6d54422770b9bce45590924` | `7a4350d43dacffa104d0e870d49748d4ef5c77da` | 2 |
| `build/soong` | `570eaae5ca6125203ebecc8795ab407e7d843bae` | `a1d78590189fe5c8edd6c0c690b983d0acc8dbf7` | 1 |
| `external/e2fsprogs` | `f6638bb5b7e01259e02112744c08ed6874f4e470` | `c03900b3f7247981f4f0e768cfd5bdf288964143` | 1 |
| `frameworks/av` | `18186d8f9b4dcaff242ae9ea9b74e6827f14a1cc` | `d386f41c90b53de58db814f3afdce48acae649af` | 11 |
| `frameworks/base` | `557ec5dffbd8464d054931f890c1b51a0b76039b` | `d2d1d34403aa92a1f2a31364f2bae12ea72679c2` | 1 |
| `frameworks/native` | `103c04dc9ff92585765f9076959be684351064c3` | `3804c142675cdc6fb3c7dbfc3df907433881bfcf` | 9 |
| `hardware/libhardware` | `90e3ce2014c258736729a8da929f76d50dc19255` | `9ac5435fac5e2a607909f73813bb9693896af0f4` | 3 |
| `system/core` | `d9e9c75fee6ff48a6cffbdfd727cb8f74ce39dd5` | `0e5b3ab86ac24f358e11f5369ecc73dde56f70a9` | 17 |
| `system/hwservicemanager` | `9ed41f25fd3be8b51fd31b5d0c1223c754d437c4` | `9160d7ccf6cbf82bf217fb439dbb477cc6dd0c5b` | 1 |
| `system/libhwbinder` | `02d1280bbc31e6a95f677a1ad8858778587c8102` | `e161180057bc9f838f0219d85feadc09b7a97ed0` | 1 |
| `system/linkerconfig` | `935f98a97b2e225cc515f2c4fcfec978ea2fa523` | `37321b97a57bf25bb6691c9489949b72ed7cbfd1` | 1 |
| `system/vold` | `85ffd688e91103bdfad15353bc807d1133def876` | `48a323c23fd3d722005ac01390df09e5a47d536c` | 2 |

The machine-readable lock beside this document records the same inputs. The
patchset contract test reads patch paths and bytes from the fixed source
revision and verifies clean worktrees, the exact repository set, heads,
direct linear bases, counts, order, and stable patch ID of every commit.

## Camera recording failure chain

The first focused `m -j8 camera_service` build reached the new
`camera_record_service.cpp`, proving that the missing-header failure was
removed. It then stopped at `IMPLEMENT_META_INTERFACE` because Android 11
rejects unlisted manual Binder interfaces. The official
`frameworks/native/0007` patch adds
`android.media.ICameraRecordService` to that allowlist, so this failure is a
cross-repository dependency and is evidence that applying only the
`frameworks/av` subset is insufficient.

After all 61 patches were present, the same `m -j8 camera_service` command
completed successfully in 7:27. It compiled and linked both target
architectures and installed the recording-aware `libaudioclient` libraries:

| Installed artifact | Size | SHA-256 |
| --- | ---: | --- |
| `system/bin/camera_service` (ARM32) | 4,544 | `e382d16634e6365141c2583cb53f0c107e9db364857919c17ed6e98611bf4b9c` |
| `system/bin/camera_service_64` (ARM64) | 11,584 | `6868d3692643a4f0a4b56b49a3ffadbdd17d9ffea5961eaecc00864e0dda409c` |
| `system/lib/libaudioclient.so` (ARM32) | 503,824 | `61ccb6554dcef9fdc30099a88d3c7773901e616aeefccc1845d8045d56d1e89d` |
| `system/lib64/libaudioclient.so` (ARM64) | 899,240 | `f72ff78e66ca9f72d55fa9be17cb9197856b30afb0dceeef09d3fdd5a611e1ce` |

This is a focused component build, not a claim that the complete Halium
product build or device runtime bring-up has passed.

## Published repositories

Each patched platform project is published in a separate `Lcryolite`
repository and the port manifest pins the remote commit by its full SHA. The
machine-readable `halium-published-pins.tsv` joins each manifest pin to the
original patchset lock. The manifest also pins the patch source itself to
`Halium/hybris-patches@0b07bd1d2f0a8468b2b101bddfc9c4cba14edde0`.

Twelve published heads are the original final commits. Two large-history
repositories use audited tree-equivalent publication histories.

`frameworks/base` exceeded GitHub's 2 GiB pack limit. Its published history is
a two-commit baseline snapshot plus the same official Halium patch. Original
final `d2d1d34403aa92a1f2a31364f2bae12ea72679c2` maps to published final
`d46b623b60d9dcf1496b0e131433d92f09853c89`; both final trees are
`7961e45d94b8859066be3f1f03b4f95bf10d93e3`, and the patch ID remains
`281195f81060e3b8fbd6d7e1359c4b3df66a5370`. The two-commit mapping and the
byte-exact source audit files are retained under `frameworks-base-snapshot/`.

`system/core` required a history-only filter because its old reachable
history contained the 229,696,508-byte blob
`70352dbb7a51e338096bb1305ea63641a39200cd` at
`libunwindstack/tests/files/offline/jit_debug_x86_32/libartd.so`. The filter
changed the final commit from `0e5b3ab86ac24f358e11f5369ecc73dde56f70a9`
to `2aedd07dfd2c6321b87b37d3ec3911f9d626c155`, while both final tree IDs remain
`bd57f1e43379a75c56761a1f68d77e3ecd875ff0` and all 17 Halium stable patch IDs
remain unchanged.

The compact evidence under `system-core-filter/` includes the complete
17-commit original-to-published Halium mapping and full stable patch IDs. The
60,022-line filter-repo commit map is not duplicated; its 4,921,767-byte
content has SHA-256
`590393e700361626c8192de6e59d817c88be372e23bf56751607ca0dc537d073`.
Static pin consistency is checked offline. Remote ref reachability is kept in
a separate live verifier so network availability cannot make the static
contract nondeterministic.
