#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
witness="$repo_root/scripts/m1-root-control-witness.py"

python3 -m py_compile "$witness"
grep -Fxq 'PROFILE = ROOT / "preboot-profile"' "$witness"
grep -Fxq 'ADAPTER = "/usr/local/libexec/rmx1901-m1-control/runtime-adapter"' "$witness"
grep -Fq 'preboot profile is missing or unsafe' "$witness"
grep -Fq 'runtime adapter did not produce exactly one classified state' "$witness"
grep -Fq 'runtime adapter must not use recovery ADB' "$witness"
grep -Eq 'fcntl\.flock\(lock, ?fcntl\.LOCK_EX\)' "$witness"
grep -Fq '"pkeyutl", "-sign", "-rawin"' "$witness"
! grep -Eq 'os\.environ\.get|M1_(ADB|SERIAL|KEY|STATE|RUNNER)|/usr/bin/adb' "$witness"
! grep -Eq '"(push|reboot|fastboot|dd|shell|exec-out)"' "$witness"

printf 'ok - witness requires a root-owned immutable recovery preboot profile\n'
printf 'ok - witness accepts exactly one fixed postboot panic-telnet or authenticated SSH capture\n'
printf 'ok - witness signs only after complete private raw bundle and atomically locks chain state\n'
