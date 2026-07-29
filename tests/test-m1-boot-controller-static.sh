#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tool="$repo/scripts/m1-boot-controller.py"
test -x "$tool"
grep -Fqx 'ROOT = Path("/var/lib/rmx1901-m1-control")' "$tool"
grep -Fqx 'ADB = "/usr/bin/adb"' "$tool"
grep -Fq 'root invocation requires no arguments or the fixed sealed-write recovery command' "$tool"
grep -Fq 'dynamic caller environment is rejected' "$tool"
grep -Fq 'boot predecessor hash mismatch' "$tool"
grep -Fq 'device-side boot readback hash mismatch' "$tool"
grep -Fq 'host-stream boot readback hash mismatch' "$tool"
grep -Fq 'predecessor restored' "$tool"
grep -Fq 'PREDECESSOR = ROOT / "m1-predecessor.img"' "$tool"
grep -Fq -- '--seal-existing-complete-write' "$tool"
grep -Fq 'reboot=not-requested' "$tool"
grep -Fq 'candidate boot header does not meet the M1 cmdline contract' "$tool"
grep -Fq 'struct.unpack_from("<I", image, 16)[0]' "$tool"
if grep -Eq 'EXECUTE|--target|--image' "$tool"; then exit 1; fi
if grep -Fq 'os.environ.get("ADB"' "$tool" || grep -Fq "os.environ.get('ADB'" "$tool"; then exit 1; fi
echo 'test-m1-boot-controller-static: PASS'
