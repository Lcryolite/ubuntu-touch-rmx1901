#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
preflight="$repo_root/scripts/preflight-host.sh"
port_root="$(dirname "$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir)")"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/preflight-host-test.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

test -x "$preflight"
test -d "$port_root/.git"

assert_invalid_halium_root() {
  local halium_root="$1"
  local output
  local status

  set +e
  output="$(HALIUM_ROOT="$halium_root" PORT_ROOT="$port_root" "$preflight" 2>&1)"
  status=$?
  set -e

  test "$status" -eq 1
  test "$output" = 'HALIUM_ROOT is not a Repo checkout'
}

assert_invalid_halium_root "$tmp_root/nonexistent/rmx1901-halium11"

git_root="$tmp_root/git/rmx1901-halium11"
mkdir -p "$(dirname "$git_root")"
git init --quiet "$git_root"
assert_invalid_halium_root "$git_root"

echo "preflight invalid-HALIUM_ROOT regressions passed"
