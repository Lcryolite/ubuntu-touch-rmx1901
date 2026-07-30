#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
script="$repo_root/scripts/stage-rmx1901-wifi-hidl-cohort.sh"

bash -n "$script"
grep -Fq 'verify-rmx1901-abi-cohort.py' "$script"
grep -Fq 'test ! -e' "$script"
grep -Fq 'sha256sum -c expected.sha256' "$script"
grep -Fq 'mv ' "$script"
! grep -Eq 'systemctl (start|stop|restart)|lxc-stop|lxc-start' "$script"
echo 'Wi-Fi HIDL cohort staging source test passed'
