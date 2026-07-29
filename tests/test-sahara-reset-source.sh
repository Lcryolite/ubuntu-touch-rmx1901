#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_file="$repo_root/scripts/sahara-reset.c"
test_root="$(mktemp -d -p "$repo_root/workdir" sahara-reset-test.XXXXXXXX)"
trap 'rm -rf -- "$test_root"' EXIT

test -f "$source_file"
cc -std=c11 -O2 -Wall -Wextra -Werror "$source_file" \
  -o "$test_root/sahara-reset" $(pkg-config --cflags --libs libusb-1.0)

grep -Fq 'struct sahara_packet packet = { 7, 8 };' "$source_file"
grep -Fq 'expected exactly one 05c6:900e device' "$source_file"
grep -Fq 'libusb_claim_interface(handle, 0)' "$source_file"
grep -Fq 'hello.command != 1 || hello.length != sizeof(hello)' "$source_file"
test "$(grep -Fc 'libusb_bulk_transfer(' "$source_file")" -eq 3
if grep -Ein 'firehose|programmer|partition|(^|[^[:alnum:]_])(flash|erase|format|wipe|blkdiscard)([^[:alnum:]_]|$)' \
    "$source_file"; then
  echo 'Sahara reset helper contains storage-programming vocabulary' >&2
  exit 1
fi

echo 'Sahara reset helper source gate passed'
