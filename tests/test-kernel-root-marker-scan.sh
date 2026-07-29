#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scanner="$repo_root/scripts/check-kernel-root-markers.sh"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT

git -C "$fixture" init -q
git -C "$fixture" config user.name test
git -C "$fixture" config user.email test@example.invalid
mkdir -p "$fixture/tests" "$fixture/drivers"
printf '%s\n' "git grep -niE 'resukisu|sukisu'" >"$fixture/tests/test-ubuntu-touch-defconfig.sh"
printf '%s\n' 'clean kernel source' >"$fixture/drivers/example.c"
git -C "$fixture" add tests/test-ubuntu-touch-defconfig.sh drivers/example.c
git -C "$fixture" commit -qm fixture

"$scanner" "$fixture"

printf '%s\n' 'SukiSU forbidden source marker' >"$fixture/drivers/example.c"
git -C "$fixture" add drivers/example.c
git -C "$fixture" commit -qm forbidden
if "$scanner" "$fixture"; then
  printf 'error: scanner accepted a production kernel marker\n' >&2
  exit 1
fi

printf 'kernel_root_marker_scan=pass\n'
