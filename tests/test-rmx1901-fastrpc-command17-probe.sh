#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source_file="$repo_root/scripts/rmx1901-fastrpc-command17-probe.c"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/rmx1901-fastrpc-probe-test.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

cc -std=c11 -D_GNU_SOURCE -Wall -Wextra -Werror -O2 \
    "$source_file" -o "$tmp_root/probe-host"
set +e
"$tmp_root/probe-host" >"$tmp_root/stdout" 2>"$tmp_root/stderr"
status=$?
set -e
test "$status" -eq 1
grep -Fxq 'uapi getinfo=0xc0045208 command17=0xc00c5211 struct_size=12' "$tmp_root/stdout"
grep -Fq 'open device=/dev/adsprpc-smd failed' "$tmp_root/stderr"

grep -Fq 'const uint32_t attributes[] = {0x80U, 0x100U, 0x101U};' "$source_file"
grep -Fq 'first[1] != 2U' "$source_file"
grep -Fq 'first[2] != 1U' "$source_file"
grep -Fq 'errno != EINVAL' "$source_file"
grep -Fq 'errno != EOVERFLOW' "$source_file"
grep -Fq 'first[i] != second[i]' "$source_file"
grep -Fq 'overall=PASS' "$source_file"

if command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    aarch64-linux-gnu-gcc -std=c11 -D_GNU_SOURCE -Wall -Wextra -Werror -O2 \
        -static -s "$source_file" -o "$tmp_root/probe-aarch64"
    file "$tmp_root/probe-aarch64" | grep -Fq 'ARM aarch64'
    file "$tmp_root/probe-aarch64" | grep -Fq 'statically linked'
    if readelf -l "$tmp_root/probe-aarch64" | grep -Fq INTERP; then
        echo 'device probe unexpectedly requires a dynamic ELF interpreter' >&2
        exit 1
    fi
fi

echo 'RMX1901 FastRPC command-17 device-probe source tests passed'
