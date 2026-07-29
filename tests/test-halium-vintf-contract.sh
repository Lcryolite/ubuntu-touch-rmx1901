#!/usr/bin/env bash
set -euo pipefail

: "${HALIUM_ROOT:=/home/lknife/android/rmx1901-halium11}"
test -f "$HALIUM_ROOT/build/envsetup.sh" || {
  echo "Halium build environment is missing" >&2
  exit 1
}

matrix_files="$(
  set +u
  cd "$HALIUM_ROOT"
  source build/envsetup.sh >/dev/null
  lunch halium_RMX1901-userdebug >/dev/null
  get_build_var DEVICE_FRAMEWORK_COMPATIBILITY_MATRIX_FILE
)"
for matrix in $matrix_files; do
  test -f "$HALIUM_ROOT/$matrix" || {
    echo "Halium product references missing VINTF matrix: $matrix" >&2
    exit 1
  }
done

test "$matrix_files" = device/realme/RMX1901/framework_compatibility_matrix_halium.xml || {
  echo "Halium A11 product does not select its USB HIDL compatibility fragment" >&2
  exit 1
}
test "$(sha256sum "$HALIUM_ROOT/$matrix_files" | awk '{print $1}')" = \
  7da22914cfb51ee72a8cdbf28d411a973dcf23ddf053e6e18678c41cd3765798 || {
  echo "Halium USB compatibility fragment content has drifted" >&2
  exit 1
}
python3 - "$HALIUM_ROOT/$matrix_files" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
hals = root.findall("hal")
if len(hals) != 1 or hals[0].get("format") != "hidl" or hals[0].get("optional") != "true":
    raise SystemExit("Halium USB compatibility fragment must contain one HIDL HAL")
hal = hals[0]
actual = (
    hal.findtext("name"),
    hal.findtext("version"),
    hal.findtext("interface/name"),
    hal.findtext("interface/instance"),
)
if actual != ("android.hardware.usb.gadget", "1.0", "IUsbGadget", "default"):
    raise SystemExit(f"Halium USB compatibility fragment is wrong: {actual!r}")
PY

device_matrix="$(
  set +u
  cd "$HALIUM_ROOT"
  source build/envsetup.sh >/dev/null
  lunch halium_RMX1901-userdebug >/dev/null
  get_build_var DEVICE_MATRIX_FILE
)"
test "$device_matrix" = device/realme/RMX1901/compatibility_matrix.xml || {
  echo "Halium product does not select the audited SDM710 device matrix" >&2
  exit 1
}
test -f "$HALIUM_ROOT/$device_matrix"
test "$(sha256sum "$HALIUM_ROOT/$device_matrix" | awk '{print $1}')" = \
  f1c34caf3355c19502844380261bc6348880d777ca0a9f455bc6dbedc376233b || {
  echo "Audited SDM710 device matrix content has drifted" >&2
  exit 1
}
python3 - "$HALIUM_ROOT/$device_matrix" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
if root.get("type") != "device" or root.get("version") != "1.0":
    raise SystemExit("historical SDM710 compatibility matrix schema is incorrect")
names = {hal.findtext("name") for hal in root.findall("hal")}
required = {
    "android.frameworks.schedulerservice",
    "android.frameworks.sensorservice",
    "android.hidl.allocator",
    "android.hidl.manager",
    "android.hidl.memory",
    "android.hidl.token",
    "android.system.wifi.keystore",
    "android.hardware.secure_element",
}
missing = required - names
if missing:
    raise SystemExit("historical SDM710 matrix is missing: " + ", ".join(sorted(missing)))
PY

device_manifest="$(
  set +u
  cd "$HALIUM_ROOT"
  source build/envsetup.sh >/dev/null
  lunch halium_RMX1901-userdebug >/dev/null
  get_build_var DEVICE_MANIFEST_FILE
)"
test "$device_manifest" = device/realme/RMX1901/manifest_halium.xml || {
  echo "Halium product does not select the audited RUI 2 / A11 manifest" >&2
  exit 1
}
test -f "$HALIUM_ROOT/$device_manifest"
test "$(sha256sum "$HALIUM_ROOT/$device_manifest" | awk '{print $1}')" = \
  88481077da3aa47e5b221dacc27361a3d9a0b79cd71077f6b9a049f8c62526ff || {
  echo "Audited RUI 2 / A11 manifest content has drifted" >&2
  exit 1
}
python3 - "$HALIUM_ROOT/$device_manifest" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
if root.get("version") != "2.0" or root.get("type") != "device":
    raise SystemExit("RUI 2 manifest has the wrong schema")
if root.get("target-level") != "4":
    raise SystemExit("RUI 2 manifest has the wrong target FCM level")
audio = {}
for hal in root.findall("hal"):
    name = hal.findtext("name")
    if name == "vendor.lineage.livedisplay":
        raise SystemExit("Halium manifest advertises an excluded LiveDisplay HAL")
    if hal.get("format") == "aidl":
        raise SystemExit(f"RUI 2 manifest unexpectedly contains AIDL HAL: {name}")
    if name in {"android.hardware.audio", "android.hardware.audio.effect"}:
        audio[name] = hal.findtext("version")
expected = {
    "android.hardware.audio": "6.0",
    "android.hardware.audio.effect": "6.0",
}
if audio != expected:
    raise SystemExit(f"RUI 2 audio HAL versions are wrong: {audio!r}")
PY

# The non-Halium product declarations stay in their guarded native-platform
# branches rather than being made unconditional by a future edit.
python3 - "$HALIUM_ROOT/device/realme/RMX1901/BoardConfig.mk" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
guards = (
    r"ifneq \(\$\(TARGET_PRODUCT\),halium_RMX1901\)\s+"
    r"DEVICE_FRAMEWORK_COMPATIBILITY_MATRIX_FILE \+=.*?"
    r"hardware/qcom-caf/common/vendor_framework_compatibility_matrix\.xml\s+else\s+"
    r"DEVICE_FRAMEWORK_COMPATIBILITY_MATRIX_FILE \+=.*?"
    r"framework_compatibility_matrix_halium\.xml\s+endif",
    r"ifeq \(\$\(TARGET_PRODUCT\),halium_RMX1901\)\s+"
    r"DEVICE_MANIFEST_FILE \+= \$\(DEVICE_PATH\)/manifest_halium\.xml\s+else\s+"
    r"DEVICE_MANIFEST_FILE \+= \$\(DEVICE_PATH\)/manifest\.xml\s+endif",
    r"ifeq \(\$\(TARGET_PRODUCT\),halium_RMX1901\)\s+"
    r"DEVICE_MATRIX_FILE := \$\(DEVICE_PATH\)/compatibility_matrix\.xml\s+else\s+"
    r"DEVICE_MATRIX_FILE := hardware/qcom-caf/common/compatibility_matrix\.xml\s+endif",
)
for guard in guards:
    if not re.search(guard, text, re.DOTALL):
        raise SystemExit("Halium VINTF selection no longer preserves a guarded native-product branch")
PY

echo 'Halium VINTF source contract tests passed'
