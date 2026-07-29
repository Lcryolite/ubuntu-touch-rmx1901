#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# This test must fail if the production predicate accepts noatime as a proxy
# for read-only, or accepts an explicit rw token beside ro.
source "$repo_root/scripts/lib/recovery-mount-safety.sh"

assert_safe() {
  is_read_only_mount_options "$1"
}

assert_unsafe() {
  if is_read_only_mount_options "$1"; then
    printf 'unsafe mount options accepted: %s\n' "$1" >&2
    exit 1
  fi
}

assert_safe 'ro'
assert_safe 'ro,norecovery'
assert_safe 'nosuid,ro,nodev'
assert_unsafe ''
assert_unsafe 'noatime'
assert_unsafe 'rw,noatime'
assert_unsafe 'rw,ro'
assert_unsafe 'ro, rw'
assert_unsafe $'ro,\trw'
assert_unsafe 'ro,rw '
assert_unsafe 'ronly'

printf 'recovery_mount_read_only_predicate=pass\n'
