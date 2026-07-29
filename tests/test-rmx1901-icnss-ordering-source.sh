#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
halium_root="${HALIUM_ROOT:-$repo_root/../rmx1901-halium11}"
kernel_root="${KERNEL_ROOT:-$repo_root/../kernel_realme_sdm710_ubuntu_touch}"
manifest="$repo_root/manifests/rmx1901-icnss-ordering.json"

test -s "$manifest"
python3 - "$manifest" "$halium_root" "$kernel_root" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

manifest_path = Path(sys.argv[1])
halium_root = Path(sys.argv[2])
kernel_root = Path(sys.argv[3])
with manifest_path.open(encoding="utf-8") as stream:
    data = json.load(stream)
assert data["schema"] == "rmx1901-icnss-ordering-v1"
assert data["status"] == "source-proven"
assert data["runtime_status"] != "pass"
assert [step["step"] for step in data["call_chain"]] == list(range(1, 12))
assert data["call_chain"][0]["symbol"] == "Wifi::startInternal"
assert data["call_chain"][-1]["symbol"] == "icnss_driver_event_fw_ready_ind"
assert "/dev/wlan" in data["conclusion"]["pre_hal_gate"]
assert "not HIDL service registration alone" in data["conclusion"]["trigger"]

for relative, expected in data["source_hashes"].items():
    if relative.startswith(("drivers/", "techpack/")):
        path = kernel_root / relative
    else:
        path = halium_root / relative
    assert path.is_file(), path
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    assert actual == expected, (path, expected, actual)
PY

board="$halium_root/device/realme/RMX1901/BoardConfig.mk"
framework="$halium_root/frameworks/opt/net/wifi/libwifi_hal/wifi_hal_common.cpp"
mode="$halium_root/hardware/interfaces/wifi/1.4/default/wifi_mode_controller.cpp"
hdd="$kernel_root/drivers/staging/qcacld-3.0/core/hdd/src/wlan_hdd_main.c"
icnss="$kernel_root/drivers/soc/qcom/icnss.c"

grep -Fq 'WIFI_DRIVER_STATE_CTRL_PARAM := "/dev/wlan"' "$board"
grep -Fq 'wifi_change_driver_state(WIFI_DRIVER_STATE_ON)' "$framework"
grep -Fq 'driver_tool_->LoadDriver()' "$mode"
grep -Fq 'if (!hdd_loaded)' "$hdd"
grep -Fq 'hdd_driver_load()' "$hdd"
grep -Fq 'ICNSS_DRIVER_EVENT_REGISTER_DRIVER' "$icnss"
grep -Fq 'if (!test_bit(ICNSS_FW_READY, &penv->state))' "$icnss"
grep -Fq 'ret = icnss_call_driver_probe(penv);' "$icnss"

echo 'RMX1901 ICNSS/Wi-Fi source ordering gate passed'
