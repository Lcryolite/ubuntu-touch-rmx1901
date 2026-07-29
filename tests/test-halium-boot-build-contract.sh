#!/usr/bin/env bash
set -euo pipefail

: "${HALIUM_ROOT:=/home/lknife/android/rmx1901-halium11}"
android_mk="$HALIUM_ROOT/halium/halium-boot/Android.mk"

test -f "$android_mk" || {
  echo "halium-boot Android.mk is missing" >&2
  exit 1
}

python3 - "$android_mk" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")

target = re.search(r"^\$\(LOCAL_BUILT_MODULE\):(?P<deps>.*)$", text, re.MULTILINE)
if target is None:
    raise SystemExit("halium-boot image rule is missing")
if "$(MKBOOTIMG)" not in target.group("deps").split():
    raise SystemExit("halium-boot image rule does not declare $(MKBOOTIMG) as a file dependency")

if re.search(r"^\t@?mkbootimg(?:\s|$)", text, re.MULTILINE):
    raise SystemExit("halium-boot image rule invokes bare mkbootimg through PATH")

default_rule = re.search(
    r"^else\s*$\n(?P<recipe>\t[^\n]*--ramdisk[^\n]*)\n^endif\s*$",
    text,
    re.MULTILINE,
)
if default_rule is None or "$(MKBOOTIMG)" not in default_rule.group("recipe"):
    raise SystemExit("halium-boot default image recipe does not invoke the resolved $(MKBOOTIMG)")

if re.search(r"^halium-boot:\s+mkbootimg\s*$", text, re.MULTILINE):
    raise SystemExit("halium-boot retains a module-name dependency instead of its resolved host tool")
PY

echo "Halium boot build contract tests passed"
