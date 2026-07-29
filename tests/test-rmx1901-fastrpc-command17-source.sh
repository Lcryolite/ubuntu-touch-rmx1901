#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
kernel_root="${KERNEL_ROOT:-$repo_root/../kernel_realme_sdm710_ubuntu_touch}"
shared="$kernel_root/drivers/char/adsprpc_shared.h"
driver="$kernel_root/drivers/char/adsprpc.c"
compat="$kernel_root/drivers/char/adsprpc_compat.c"
for path in "$shared" "$driver" "$compat"; do test -s "$path"; done

# Confirm the old command-16 ABI remains and API30 command 17 is exactly 12 bytes.
grep -Fq "_IOWR('R', 16, struct fastrpc_ioctl_dsp_capabilities)" "$shared"
grep -Fq "_IOWR('R', 17, struct fastrpc_ioctl_capability)" "$shared"
grep -Fq 'FASTRPC_MAX_DSP_ATTRIBUTES	(7)' "$shared"
grep -Fq 'FASTRPC_MAX_DSP_CAPABILITY_ATTRIBUTES	(256)' "$shared"
grep -Fq 'FASTRPC_MAX_CAPABILITY_ATTRIBUTES	(258)' "$shared"

work="$(mktemp -d "${TMPDIR:-/tmp}/rmx1901-fastrpc-uapi.XXXXXX")"
trap 'rm -rf "$work"' EXIT
cat >"$work/uapi.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>
#include <sys/ioctl.h>
struct legacy { uint32_t domain; uint32_t attributes[7]; };
struct capability { uint32_t domain; uint32_t attribute_ID; uint32_t capability; };
int main(void) {
    unsigned long old_cmd = _IOWR('R', 16, struct legacy);
    unsigned long new_cmd = _IOWR('R', 17, struct capability);
    printf("legacy_size=%zu legacy_cmd=0x%lx\n", sizeof(struct legacy), old_cmd);
    printf("capability_size=%zu capability_cmd=0x%lx\n", sizeof(struct capability), new_cmd);
    return !(sizeof(struct legacy) == 32 && old_cmd == 0xc0205210UL &&
             sizeof(struct capability) == 12 && new_cmd == 0xc00c5211UL);
}
EOF
cc -std=c11 -Wall -Wextra -Werror "$work/uapi.c" -o "$work/uapi"
"$work/uapi" >"$work/result.txt"
grep -Fxq 'legacy_size=32 legacy_cmd=0xc0205210' "$work/result.txt"
grep -Fxq 'capability_size=12 capability_cmd=0xc00c5211' "$work/result.txt"

# Native path validates domain/attribute bounds, supports kernel attributes 256/257,
# queries the DSP for extended attributes, and copies back only the output field.
grep -Fq 'case FASTRPC_IOCTL_GET_DSP_CAPABILITY:' "$driver"
grep -Fq 'if (cap->domain >= NUM_CHANNELS)' "$driver"
grep -Fq 'if (attribute_id >= FASTRPC_MAX_CAPABILITY_ATTRIBUTES)' "$driver"
grep -Fq 'FASTRPC_MAX_DSP_CAPABILITY_ATTRIBUTES - 1' "$driver"
grep -Fq 'param)->capability, &cap->capability, sizeof(cap->capability)' "$driver"
grep -Fq '(1U << 1), /* performance capability */' "$driver"
grep -Fq '1U,        /* performance logging v2 */' "$driver"

# Keep command 16 on its original seven-word DSP request and isolate command 17
# in its own 256-attribute cache. Reject cross-domain file/cache poisoning and
# fail a query that spans subsystem restart rather than returning zero as valid.
grep -Fq 'uint32_t dsp_attributes[FASTRPC_MAX_DSP_ATTRIBUTES];' "$driver"
grep -Fq 'struct fastrpc_dsp_capability_cache {' "$driver"
test "$(grep -Fc 'FASTRPC_MAX_DSP_ATTRIBUTES - 1' "$driver")" -eq 1
test "$(grep -Fc 'FASTRPC_MAX_DSP_CAPABILITY_ATTRIBUTES - 1' "$driver")" -eq 1
grep -Fq 'if (!fl || fl->cid != domain)' "$driver"
grep -Fq 'if (generation != cache->generation)' "$driver"
grep -Fq 'ctx->dsp_cap_cache.generation++;' "$driver"
grep -Fq 'struct mutex fill_lock;' "$driver"
grep -Fq 'mutex_lock(&cache->fill_lock);' "$driver"
test "$(grep -Fc 'if (!fl || fl->cid != cap->domain)' "$driver")" -eq 1

# Compat payload is also three u32 values and translates command 17 explicitly.
grep -Fq "_IOWR('R', 17, struct compat_fastrpc_ioctl_capability)" "$compat"
grep -Fq 'case COMPAT_FASTRPC_IOCTL_GET_DSP_CAPABILITY:' "$compat"
grep -Fq 'FASTRPC_IOCTL_GET_DSP_CAPABILITY,' "$compat"
grep -Fq 'put_user(value, &cap32->capability)' "$compat"

# Unknown native and compat commands still fail closed.
grep -Fq 'err = -ENOTTY;' "$driver"
grep -Fq 'return -ENOIOCTLCMD;' "$compat"

# Provenance must name command 17 exactly while keeping runtime status fail-closed.
python3 - "$repo_root/manifests/rmx1901-fastrpc-command17.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
assert data["schema"] == "rmx1901-fastrpc-command17-provenance-v1"
assert data["decoded_abi"] == {
    "direction": 3,
    "size": 12,
    "type": 82,
    "number": 17,
    "fields": [
        {"name": "domain", "type": "uint32_t", "offset": 0},
        {"name": "attribute_ID", "type": "uint32_t", "offset": 4},
        {"name": "capability", "type": "uint32_t", "offset": 8},
    ],
}
source = data["matching_vendor_source"]
assert source["command_name"] == "FASTRPC_IOCTL_GET_DSP_INFO"
assert source["commit"] == "8050fa5150de3697e54e1366e968a3af0a6911ec"
assert source["dsp_attribute_count"] == 256
assert source["total_attribute_count"] == 258
assert data["candidate"]["observed_attribute_ids"] == [128, 256, 257]
assert data["local_implementation"]["legacy_command16_preserved"] is True
assert data["status"]["source_reconciliation"] == "pass"
assert data["status"]["native_compat_build"] == "pass"
assert data["status"]["runtime_postcondition"] != "pass"
assert data["status"]["p3_exit_gate"] == "blocked"
PY

echo 'RMX1901 FastRPC command-17 source and UAPI tests passed'
