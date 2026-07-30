#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
probe="$repo_root/scripts/rmx1901-wifi-hidl-probe.cpp"
builder="$repo_root/scripts/build-rmx1901-wifi-hidl-probe.sh"

grep -Fq 'IWifi::getService("default")' "$probe"
grep -Fq 'wifi->start' "$probe"
grep -Fq 'wifi->getChipIds' "$probe"
bash -n "$builder"
echo 'Wi-Fi HIDL probe source test passed'
