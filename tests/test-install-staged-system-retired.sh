#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
installer="$repo_root/scripts/install-staged-system-from-recovery.sh"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/rmx1901-system-installer-retired.XXXXXX")"
trap 'rm -rf -- "$tmp_root"' EXIT

mkdir -p "$tmp_root/tools"
adb_calls="$tmp_root/adb-calls"

cat >"$tmp_root/tools/adb" <<'EOF'
#!/usr/bin/env bash
printf 'unexpected adb invocation: %s\n' "$*" >>"$FAKE_ADB_CALLS"
exit 99
EOF
chmod 0755 "$tmp_root/tools/adb"

set +e
output="$(env EXECUTE=1 ADB_SERIAL=7b0c1c49 ADB="$tmp_root/tools/adb" \
  FAKE_ADB_CALLS="$adb_calls" "$installer" 2>&1)"
status=$?
set -e

test "$status" -ne 0
grep -Fqx 'mode=retired-no-system-writer' <<<"$output"
grep -Fqx 'result=refused' <<<"$output"
test ! -e "$adb_calls"

printf 'staged_system_installer_retired_runtime=pass\n'
