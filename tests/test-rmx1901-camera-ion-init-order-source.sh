#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
kernel_root="${KERNEL_ROOT:-$repo_root/../kernel_realme_sdm710_ubuntu_touch}"
memory_manager="$kernel_root/drivers/media/platform/msm/camera/cam_req_mgr/cam_mem_mgr.c"
memory_manager_header="$kernel_root/drivers/media/platform/msm/camera/cam_req_mgr/cam_mem_mgr.h"
request_manager="$kernel_root/drivers/media/platform/msm/camera/cam_req_mgr/cam_req_mgr_dev.c"
icp_manager="$kernel_root/drivers/media/platform/msm/camera/cam_icp/icp_hw/icp_hw_mgr/cam_icp_hw_mgr.c"

test -s "$memory_manager"
test -s "$memory_manager_header"
test -s "$request_manager"
test -s "$icp_manager"

python3 - "$memory_manager" "$memory_manager_header" "$request_manager" "$icp_manager" <<'PY'
import sys
from pathlib import Path

memory_manager = Path(sys.argv[1]).read_text(encoding="utf-8")
memory_manager_header = Path(sys.argv[2]).read_text(encoding="utf-8")
request_manager = Path(sys.argv[3]).read_text(encoding="utf-8")
icp_manager = Path(sys.argv[4]).read_text(encoding="utf-8")

def body(source: str, signature: str) -> str:
    start = source.find(signature)
    if start < 0:
        raise SystemExit(f"missing function signature: {signature}")
    open_brace = source.find("{", start)
    if open_brace < 0:
        raise SystemExit(f"missing function body: {signature}")
    depth = 0
    for index in range(open_brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[open_brace : index + 1]
    raise SystemExit(f"unterminated function: {signature}")

for signature in (
    "static int cam_mem_util_get_dma_buf(",
    "static int cam_mem_util_get_dma_buf_fd(",
):
    allocation = body(memory_manager, signature)
    if "tbl.client" not in allocation or "tbl.bitmap" not in allocation:
        raise SystemExit(f"{signature} has no readiness check")
    if "-EAGAIN" not in allocation:
        raise SystemExit(f"{signature} does not fail safely while uninitialised")
    allocation_call = allocation.find("*hdl = ion_alloc(")
    if allocation_call < 0:
        raise SystemExit(f"{signature} no longer allocates through ION")
    if allocation.find("tbl.client") > allocation_call:
        raise SystemExit(f"{signature} checks the ION client after allocation")
    if allocation.find("tbl.bitmap") > allocation_call:
        raise SystemExit(f"{signature} checks the memory table after allocation")

if "static int cam_icp_alloc_shared_mem(" not in icp_manager:
    raise SystemExit("ICP shared-memory allocator is missing")
if "cam_mem_mgr_request_mem(&alloc, &out)" not in icp_manager:
    raise SystemExit("ICP shared-memory allocation no longer reaches camera memory manager")

request = body(memory_manager, "int cam_mem_mgr_request_mem(")
if "cam_mem_util_get_dma_buf(" not in request:
    raise SystemExit("camera memory request bypasses the guarded ION allocator")

open_body = body(request_manager, "static int cam_req_mgr_open(")
if "cam_mem_mgr_init(" in open_body:
    raise SystemExit("CRM open reinitializes the driver-lifetime camera memory manager")

close_body = body(request_manager, "static int cam_req_mgr_close(")
if "cam_mem_mgr_cleanup();" not in close_body:
    raise SystemExit("CRM close does not clean allocations while preserving the ION client")
if "cam_mem_mgr_deinit(" in close_body:
    raise SystemExit("CRM close destroys the camera memory manager needed by ICP discovery")

if "void cam_mem_mgr_cleanup(void);" not in memory_manager_header:
    raise SystemExit("camera memory cleanup API is not declared")

cleanup = body(memory_manager, "void cam_mem_mgr_cleanup(void)")
if "cam_mem_mgr_cleanup_table();" not in cleanup:
    raise SystemExit("public cleanup API does not release session allocations")

deinit = body(memory_manager, "void cam_mem_mgr_deinit(void)")
if "cam_mem_mgr_cleanup();" not in deinit:
    raise SystemExit("driver teardown bypasses session cleanup")
PY

echo 'RMX1901 camera ION initialization-order source test passed'
