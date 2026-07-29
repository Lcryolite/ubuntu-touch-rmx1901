#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
kernel_root="${KERNEL_ROOT:-$repo_root/../kernel_realme_sdm710_ubuntu_touch}"
manifest="$repo_root/manifests/rmx1901-bluetooth-ownership.json"
defconfig="$kernel_root/arch/arm64/configs/sdm670-perf_defconfig"
driver="$kernel_root/drivers/bluetooth/hci_vhci.c"

test -s "$manifest"
test -s "$defconfig"
test -s "$driver"
python3 - "$manifest" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
assert data["schema"] == "rmx1901-bluetooth-ownership-v1"
assert data["status"]["architecture"] == "source-proven"
assert data["status"]["runtime"] != "pass"
assert data["kernel"]["required_config"] == "CONFIG_BT_HCIVHCI=y"
assert data["kernel"]["direct_uart_config"] == "CONFIG_BT_HCIUART is not enabled"
assert data["ownership"]["physical_transport_owner"] == "android.hardware.bluetooth@1.0-service-qti"
assert data["ownership"]["binder_proxy"] == "bluebinder"
assert data["ownership"]["linux_stack_owner"] == "bluetoothd"
assert data["runtime_gate"]["current_result"] != "pass"
PY

test "$(grep -Fxc 'CONFIG_BT_HCIVHCI=y' "$defconfig")" -eq 1
if grep -Eq '^CONFIG_BT_HCIUART(=| )' "$defconfig"; then
    echo 'direct kernel HCI UART ownership conflicts with the bluebinder design' >&2
    exit 1
fi
grep -Fq 'static struct miscdevice vhci_miscdev' "$driver"
grep -Fq '.name' "$driver"
grep -Fq '"vhci"' "$driver"
grep -Fq 'module_misc_device(vhci_miscdev);' "$driver"

echo 'RMX1901 bluebinder/VHCI ownership source gate passed'
