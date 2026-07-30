#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tool="$repo_root/scripts/generate-rmx1901-wifi-api30-closure.py"

python3 -m py_compile "$tool"
grep -Fq '"libc.so", "libdl.so", "libm.so"' "$tool"
grep -Fq 'libcld80211.so' "$tool"
grep -Fq 'WriteStringToFd' "$tool"
grep -Fq 'android.hardware.wifi@1.0-service.rc' "$tool"
grep -Fq 'android.hardware.wifi@1.0-service.xml' "$tool"
grep -Fq '"complete": True' "$tool"
grep -Fq 'def destination(' "$tool"
grep -Fq '/userdata/rmx1901-hw/wifi/lib64/' "$tool"
grep -Fq 'refusing to overwrite existing output' "$tool"
echo 'Wi-Fi API30 closure generator source test passed'
