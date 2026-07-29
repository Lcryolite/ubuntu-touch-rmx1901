#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT

# shellcheck disable=SC1091
source "$repo_root/scripts/configure-build-environment.sh" "$fixture/workdir"

test "$TMPDIR" = "$fixture/workdir/compiler-tmp"
test -d "$TMPDIR"
test -w "$TMPDIR"

printf 'build_environment=pass\n'
