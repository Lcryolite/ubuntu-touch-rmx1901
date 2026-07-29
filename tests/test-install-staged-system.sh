#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
installer="$repo_root/scripts/install-staged-system-from-recovery.sh"

test -x "$installer"
bash -n "$installer"

assert_refused() {
  local output status
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e
  test "$status" -ne 0
  grep -Fqx 'mode=retired-no-system-writer' <<<"$output"
  grep -Fqx 'result=refused' <<<"$output"
  grep -Fqx 'error=staged system partition writes are permanently disabled' <<<"$output"
}

assert_refused "$installer"
assert_refused env EXECUTE=1 ADB_SERIAL=7b0c1c49 "$installer"

if rg -n '/dev/block/sda11|(^|[^[:alnum:]_])dd([^[:alnum:]_]|$)|(^|[^[:alnum:]_])adb([^[:alnum:]_]|$)' "$installer"; then
  printf 'retired installer still contains device-write or transport code\n' >&2
  exit 1
fi

printf 'staged_system_installer_source_gate=pass\n'
