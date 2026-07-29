#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
installer="$repo_root/scripts/install-staged-system-from-recovery.sh"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/rmx1901-system-install-runtime.XXXXXX")"
trap 'rm -rf -- "$tmp_root"' EXIT

mkdir -p "$tmp_root/tools"
cat >"$tmp_root/tools/adb" <<'EOF'
#!/usr/bin/env bash
printf 'ADB must not be called by the retired installer\n' >&2
exit 99
EOF
chmod 0755 "$tmp_root/tools/adb"

set +e
output="$(env EXECUTE=1 ADB_SERIAL=7b0c1c49 ADB="$tmp_root/tools/adb" "$installer" 2>&1)"
status=$?
set -e
test "$status" -ne 0
grep -Fqx 'mode=retired-no-system-writer' <<<"$output"
grep -Fqx 'result=refused' <<<"$output"
! grep -Fq 'ADB must not be called' <<<"$output"

printf 'staged_system_installer_runtime=pass\n'
