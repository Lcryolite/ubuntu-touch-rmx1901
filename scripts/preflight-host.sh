#!/usr/bin/env bash
set -euo pipefail

for cmd in repo git python3 sha256sum adb fastboot; do
  command -v "$cmd" >/dev/null || { echo "missing required command: $cmd" >&2; exit 1; }
done

: "${HALIUM_ROOT:?set HALIUM_ROOT to the dedicated Halium checkout}"
: "${PORT_ROOT:?set PORT_ROOT to the rmx1901-halium11-port checkout}"

case "$HALIUM_ROOT" in
  */rmx1901-halium11) ;;
  *) echo "HALIUM_ROOT must end in /rmx1901-halium11" >&2; exit 1 ;;
esac

test -d "$HALIUM_ROOT/.repo" || {
  echo "HALIUM_ROOT is not a Repo checkout" >&2
  exit 1
}
(cd "$HALIUM_ROOT" && repo manifest -r -o /dev/null) >/dev/null 2>&1 || {
  echo "HALIUM_ROOT Repo manifest cannot be resolved" >&2
  exit 1
}
test -d "$PORT_ROOT/.git" || { echo "PORT_ROOT is not a git repository" >&2; exit 1; }
port_git_root="$(git -C "$PORT_ROOT" rev-parse --show-toplevel)"
halium_real_root="$(realpath -e -- "$HALIUM_ROOT")"
port_real_root="$(realpath -e -- "$port_git_root")"
test "$halium_real_root" != "$port_real_root" || {
  echo "HALIUM_ROOT and PORT_ROOT must be separate worktrees" >&2
  exit 1
}
echo "host preflight passed"
