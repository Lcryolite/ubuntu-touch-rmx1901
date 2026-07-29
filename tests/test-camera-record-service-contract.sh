#!/usr/bin/env bash
set -euo pipefail

: "${HALIUM_ROOT:=/home/lknife/android/rmx1901-halium11}"
av="$HALIUM_ROOT/frameworks/av"
hybris="$HALIUM_ROOT/vendor/halium/libhybris"

python3 - "$av" "$hybris" <<'PY'
import re
import sys
from pathlib import Path

av = Path(sys.argv[1])
hybris = Path(sys.argv[2])
header = av / "media/libaudioclient/include/media/camera_record_service.h"
implementation = av / "media/libaudioclient/camera_record_service.cpp"
blueprint = av / "media/libaudioclient/Android.bp"
consumer = hybris / "compat/media/camera_service.cpp"

if not header.is_file():
    raise SystemExit("libaudioclient does not export camera_record_service.h")
if not implementation.is_file():
    raise SystemExit("libaudioclient is missing the CameraRecordService implementation")

bp = blueprint.read_text(encoding="utf-8")

def module_block(text: str, name: str) -> str:
    marker = f'name: "{name}"'
    marker_at = text.find(marker)
    if marker_at < 0:
        raise SystemExit(f"Android.bp is missing module {name}")
    start = text.rfind("{", 0, marker_at)
    if start < 0:
        raise SystemExit(f"Android.bp module {name} has no opening brace")
    depth = 0
    for index in range(start, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[start : index + 1]
    raise SystemExit(f"Android.bp module {name} has no closing brace")


client_module = module_block(bp, "libaudioclient")
headers_module = module_block(bp, "libaudioclient_headers")
if '"camera_record_service.cpp"' not in client_module:
    raise SystemExit("libaudioclient does not compile camera_record_service.cpp")
if re.search(r'export_include_dirs\s*:\s*\[[^]]*"include"', headers_module, re.S) is None:
    raise SystemExit("libaudioclient does not export its public include directory")

source = consumer.read_text(encoding="utf-8")
if "#include <media/camera_record_service.h>" not in source:
    raise SystemExit("libhybris camera service does not consume the recording API")
if "CameraRecordService::instantiate();" not in source:
    raise SystemExit("libhybris camera service no longer instantiates recording support")
PY

echo "Camera recording service contract tests passed"
