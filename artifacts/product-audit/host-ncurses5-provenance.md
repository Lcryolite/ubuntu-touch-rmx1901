# Android clang ncurses 5 host compatibility provenance

The Android prebuilt
`prebuilts/clang/host/linux-x86/clang-3289846/bin/clang.real` has ELF
`DT_NEEDED` entries for both `libncurses.so.5` and `libtinfo.so.5`. The
CachyOS host supplies ncurses 6.6 but not those ABI-5 names.

The compatibility payload is the CachyOS official repository package:

- package: `ncurses5-compat-libs 6.6-2` (`x86_64`)
- URL: `https://mirrors.ustc.edu.cn/cachyos/repo/x86_64/cachyos/ncurses5-compat-libs-6.6-2-x86_64.pkg.tar.zst`
- package SHA-256: `8990074c34da5be32a5d383acd0630397da073f238b9d034a59cb575d5072357`
- detached-signature key: `882DCFE48E2051D48E2562ABF3B607488DB35A47`
- signer: `CachyOS <admin@cachyos.org>`
- `pacman-key --verify` result: good signature, full trust

The signed package archive, signature, `.PKGINFO`, and local provenance record
are retained under
`/var/tmp/rmx1901-host-compat/ncurses5-compat-libs-6.6-2`.

Both logical names resolve within that directory to the package's real ABI-5
ELF. Its properties are:

- SHA-256: `9cf046fdc0b3346768385ad2dc829f54e2624de933ac47f913133f6f40d016dc`
- ELF class: `ELF64`
- ELF type: `DYN (Shared object file)`
- machine: `Advanced Micro Devices X86-64`
- SONAME: `libncurses.so.5`

The package installs `libtinfo.so.5` as a compatibility link to
`libncurses.so.5`; the isolated layout changes its absolute system link to the
equivalent relative link inside the package directory. No ncurses ABI-6 file
is renamed or linked as ABI 5.

The build wrapper validates canonical path containment, all ELF properties,
SONAME, and the fixed library hash before use. `halium_RMX1901` narrowly
allowlists only `LD_LIBRARY_PATH` for Ninja; `ALLOW_NINJA_ENV` is not used.
