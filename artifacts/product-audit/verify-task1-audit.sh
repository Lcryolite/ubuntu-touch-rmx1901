#!/usr/bin/env bash
# Machine verifier for the metadata ledger in vendor-metadata-reconciliation.md.
set -euo pipefail

vendor_repo=${1:-/home/lknife/android/rmx1901-halium11/vendor/realme/RMX1901}
source_root=${SOURCE_ROOT:-/home/lknife/android/rmx1901-halium11}
lineage_compat_repo=${LINEAGE_COMPAT_REPO:-}
audit_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
commit=acde0a3

if ! git -C "$vendor_repo" rev-parse --verify "${commit}^{commit}" >/dev/null; then
    echo "missing vendor commit ${commit} in ${vendor_repo}" >&2
    exit 1
fi

if [[ $(git -C "$vendor_repo" diff-tree --no-commit-id --name-only -r "$commit") != Android.bp ]]; then
    echo "${commit} changed a file other than Android.bp" >&2
    exit 1
fi

numstat=$(git -C "$vendor_repo" diff --numstat "${commit}^" "$commit" -- Android.bp)
[[ $numstat == $'22\t82\tAndroid.bp' ]] || {
    echo "expected 22 insertions and 82 deletions, got: ${numstat}" >&2
    exit 1
}

patch=$(mktemp)
trap 'rm -f "$patch"' EXIT
git -C "$vendor_repo" show --format= --unified=0 "$commit" -- Android.bp >"$patch"

require_count() {
    local expected=$1 token=$2 actual
    actual=$(grep -F -- "$token" "$patch" | wc -l | tr -d ' ')
    [[ $actual == "$expected" ]] || {
        echo "expected ${expected} patch occurrence(s) of ${token}, got ${actual}" >&2
        exit 1
    }
}

require_count 1 '-        "hardware/qcom-caf/wlan",'
require_count 1 '-        "vendor/qcom/opensource/commonsys/display",'
require_count 1 '-        "vendor/qcom/opensource/display",'
require_count 12 '-                "libprotobuf-cpp-lite-3.9.1-vendorcompat",'
require_count 12 '+                "libprotobuf-cpp-lite",'
require_count 8 '-                "libprotobuf-cpp-full-3.9.1-vendorcompat",'
require_count 8 '+                "libprotobuf-cpp-full",'
require_count 1 '-    name: "libtinycompress",'
require_count 1 '+                "libhwbinder",'
require_count 1 '+                "libhidltransport",'

for token in \
    android.hardware.common-V2-ndk:3 \
    libOmxCore:2 \
    libclang_rt.ubsan_standalone:1 \
    libwfdaac_vendor:1 \
    libdisplayconfig.system.qti:2 \
    vendor.qti.hardware.display.config-V5-ndk:2 \
    android.hardware.graphics.allocator-V2-ndk:1 \
    audioclient-types-aidl-cpp:1 \
    android.media.audio.common.types-V4-cpp:1 \
    libdmabufheap:1 \
    libstdc++_vendor:1 \
    libwpa_client:4 \
    libjson:2 \
    libril:1 \
    libdrmutils:1 \
    libsdmutils:2 \
    libcld80211:1 \
    libdisplaydebug:5; do
    token_name=${token%:*}
    token_count=${token##*:}
    require_count "$token_count" "-                \"${token_name}\","
done

provenance="$audit_dir/task1-shim-provenance.md"
[[ -f $provenance ]] || {
    echo "missing provenance ledger: ${provenance}" >&2
    exit 1
}

trim() {
    local value=$1
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    printf '%s' "$value"
}

require_provenance_row() {
    local id=$1 expected_hash=$2 local_file=$3 line
    line=$(grep -F "| \`${id}\` |" "$provenance")
    [[ $(printf '%s\n' "$line" | wc -l | tr -d ' ') == 1 ]] || {
        echo "expected exactly one provenance row for ${id}" >&2
        exit 1
    }

    local _ row_id repository branch revision source_path target local_hash derivation _
    IFS='|' read -r _ row_id repository branch revision source_path target local_hash derivation _ <<<"$line"
    repository=$(trim "$repository")
    branch=$(trim "$branch")
    revision=$(trim "$revision")
    source_path=$(trim "$source_path")
    target=$(trim "$target")
    local_hash=$(trim "$local_hash")

    [[ $repository == \`https://*\` ]] || {
        echo "${id}: missing repository URL" >&2
        exit 1
    }
    [[ -n $branch ]] || { echo "${id}: missing branch or manifest revision" >&2; exit 1; }
    [[ $revision =~ [0-9a-f]{40} ]] || {
        echo "${id}: missing immutable source-tree commit" >&2
        exit 1
    }
    [[ -n $source_path && -n $target ]] || {
        echo "${id}: missing source path or local target" >&2
        exit 1
    }
    [[ $local_hash =~ ^\`[0-9a-f]{64}\`$ ]] || {
        echo "${id}: missing local content hash" >&2
        exit 1
    }
    [[ ${local_hash#\`} == "${expected_hash}\`" ]] || {
        echo "${id}: ledger hash does not match expected hash" >&2
        exit 1
    }
    [[ $(sha256sum "$source_root/$local_file" | awk '{print $1}') == "$expected_hash" ]] || {
        echo "${id}: local file content does not match ledger" >&2
        exit 1
    }
}

require_provenance_row libcrypto_shim \
    8830a360e6f4eab408c9e1612912f32d15a0be108f57dbda679ac60a55bf037a \
    device/realme/RMX1901/shims/libcrypto/cbs.c
require_provenance_row libcomparetf2_shim \
    bc3dc8308edd162cc90fc7a2e2965f3716f006adbe100257a36dda08ed804f7f \
    device/realme/RMX1901/shims/libcomparetf2/comparetf2.c
require_provenance_row libcamera_metadata_shim \
    a2ed2529e251c297d688ac34893821aea11134e556bf11da6904c616ceba328f \
    device/realme/RMX1901/shims/libcamera_metadata/camera_metadata.cpp
for id in android.hidl.base@1.0 libgui_shim libaudioclient_shim libwfdservice_shim; do
    require_provenance_row "$id" \
        06339c38e21efa6c636da2ce914482f78379261e3cc9396f52fbb77ea2dbbae0 \
        device/realme/RMX1901/shims/Android.bp
done
for id in install_symlink prebuilt_rfsa; do
    require_provenance_row "$id" \
        7093d6b345de1c7370e78c71aa2bfbf4fe0f7a4fb417fbd9548568c6f7f2706f \
        device/realme/RMX1901/soong/rmx1901_compat.go
done
require_provenance_row libstdc++_vendor_alias \
    5a49b9c312c707a70c78506cd5fd10f4e1e150b4f9fc2a8f958bd6cb5bf9ef28 \
    device/realme/RMX1901/Android.bp

visibility_row=$(grep -F '| HIDL vendor visibility bridge |' "$provenance")
[[ $(printf '%s\n' "$visibility_row" | wc -l | tr -d ' ') == 1 ]] || {
    echo "missing HIDL visibility bridge provenance row" >&2
    exit 1
}
IFS='|' read -r _ _ visibility_repository visibility_branch visibility_revision \
    visibility_source visibility_target visibility_hash _ _ <<<"$visibility_row"
visibility_repository=$(trim "$visibility_repository")
visibility_branch=$(trim "$visibility_branch")
visibility_revision=$(trim "$visibility_revision")
visibility_source=$(trim "$visibility_source")
visibility_target=$(trim "$visibility_target")
visibility_hash=$(trim "$visibility_hash")
[[ $visibility_repository == *https://* && -n $visibility_branch && \
   $visibility_revision =~ [0-9a-f]{40} && -n $visibility_source && \
   -n $visibility_target && $visibility_hash == \`not-applicable\` ]] || {
    echo "HIDL visibility bridge: missing branch/revision/path fields" >&2
    exit 1
}

grep -Fq 'EX-HIDL-LOCAL-FORWARDER' "$provenance" || {
    echo "missing required HIDL local-forwarder exception" >&2
    exit 1
}

require_git_object() {
    local repository=$1 revision=$2 git_path=$3 label=$4
    git -C "$repository" rev-parse --verify "${revision}^{commit}" >/dev/null || {
        echo "${label}: missing pinned Git commit ${revision} in ${repository}" >&2
        exit 1
    }
    git -C "$repository" cat-file -e "${revision}:${git_path}" || {
        echo "${label}: missing pinned Git object ${revision}:${git_path}" >&2
        exit 1
    }
}

[[ -n $lineage_compat_repo ]] || {
    echo 'set LINEAGE_COMPAT_REPO to the checked-out android_hardware_lineage_compat repository' >&2
    exit 1
}

# Each externally sourced/forwarded row must resolve its documented source
# path in the documented immutable Git object.  Local-only bridges below stay
# on the explicit hash/exception route already checked by require_provenance_row.
require_git_object "$source_root/external/boringssl" \
    4f3c98594811d05ec0c445a1203198525817f7c3 src/crypto/bytestring/cbs.c libcrypto_shim
require_git_object "$lineage_compat_repo" \
    015d90baa57a65c5bdeed20997dfdede50e65ca7 libcomparetf2/comparetf2.c libcomparetf2_shim
require_git_object "$lineage_compat_repo" \
    015d90baa57a65c5bdeed20997dfdede50e65ca7 libcamera_metadata/camera_metadata.cpp libcamera_metadata_shim
require_git_object "$source_root/system/libhidl" \
    1c4a769f74eb982b85fe5c22232454951e7b1524 Android.bp android.hidl.base@1.0-provider
require_git_object "$source_root/system/libhidl" \
    1c4a769f74eb982b85fe5c22232454951e7b1524 transport/base/1.0/Android.bp android.hidl.base@1.0-interface
require_git_object "$source_root/frameworks/native" \
    103c04dc9ff92585765f9076959be684351064c3 libs/gui/Android.bp libgui_shim
require_git_object "$source_root/frameworks/av" \
    18186d8f9b4dcaff242ae9ea9b74e6827f14a1cc media/libaudioclient/Android.bp libaudioclient_shim
require_git_object "$source_root/system/core" \
    d9e9c75fee6ff48a6cffbdfd727cb8f74ce39dd5 libutils/Android.bp libwfdservice_shim
require_git_object "$source_root/build/soong" \
    570eaae5ca6125203ebecc8795ab407e7d843bae android/module.go install_symlink
require_git_object "$source_root/build/soong" \
    570eaae5ca6125203ebecc8795ab407e7d843bae android/module.go prebuilt_rfsa
require_git_object "$source_root/system/libhidl" \
    1c4a769f74eb982b85fe5c22232454951e7b1524 Android.bp hidl-visibility
require_git_object "$source_root/system/libhwbinder" \
    02d1280bbc31e6a95f677a1ad8858778587c8102 Android.bp hwbinder-visibility

echo "verified acde0a3 metadata, provenance fields, and 12 pinned Git objects"
