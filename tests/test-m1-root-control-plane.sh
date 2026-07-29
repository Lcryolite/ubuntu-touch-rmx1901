#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
installer="$repo_root/scripts/install-m1-root-control-plane.sh"
witness_source="$repo_root/scripts/m1-root-control-witness.py"
unit_source="$repo_root/systemd/rmx1901-m1-control.service"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/m1-root-control.XXXXXX")"
trap 'rm -rf -- "$tmp_root"' EXIT

test -x "$installer"
test -x "$witness_source"
test -f "$unit_source"

stage="$tmp_root/stage"
"$installer" --stage "$stage"

for path in \
  "$stage/usr/local/libexec/rmx1901-m1-control/capture-witness" \
  "$stage/usr/local/libexec/rmx1901-m1-control/runtime-adapter" \
  "$stage/usr/local/libexec/rmx1901-m1-control/seal-preboot-profile" \
  "$stage/usr/local/libexec/rmx1901-m1-control/stage-m1-candidate" \
  "$stage/usr/local/libexec/rmx1901-m1-control/stage-m1-predecessor" \
  "$stage/usr/local/libexec/rmx1901-m1-control/boot-controller" \
  "$stage/var/lib/rmx1901-m1-control/m1-deployment-v1.json" \
  "$stage/etc/systemd/system/rmx1901-m1-control.service" \
  "$stage/var/lib/rmx1901-m1-control/README"; do
  test -e "$path" || { printf 'missing staged control-plane path: %s\n' "$path" >&2; exit 1; }
done

test ! -e "$stage/var/lib/rmx1901-m1-control/capture-witness"
test -x "$stage/usr/local/libexec/rmx1901-m1-control/runtime-adapter"
test -x "$stage/usr/local/libexec/rmx1901-m1-control/seal-preboot-profile"
test -x "$stage/usr/local/libexec/rmx1901-m1-control/stage-m1-candidate"
test -x "$stage/usr/local/libexec/rmx1901-m1-control/stage-m1-predecessor"
test -x "$stage/usr/local/libexec/rmx1901-m1-control/boot-controller"
test "$(stat -c %a "$stage/var/lib/rmx1901-m1-control/m1-deployment-v1.json")" = 400
grep -Fxq 'User=root' "$stage/etc/systemd/system/rmx1901-m1-control.service"
grep -Fxq 'Environment=PATH=/usr/bin:/bin' "$stage/etc/systemd/system/rmx1901-m1-control.service"
grep -Fxq 'ExecStart=/usr/bin/env -i PATH=/usr/bin:/bin HOME=/nonexistent LANG=C LC_ALL=C /usr/local/libexec/rmx1901-m1-control/capture-witness --health' \
  "$stage/etc/systemd/system/rmx1901-m1-control.service"
grep -Fq 'does not install keys, state, registry, or a witness' \
  "$stage/var/lib/rmx1901-m1-control/README"
grep -Fq 'PRIVATE_KEY = ROOT / "witness-ed25519.pem"' "$repo_root/scripts/m1-fixed-trust.py"
grep -Fq 'trusted(PRIVATE_KEY, "file", exact_mode=0o400)' "$repo_root/scripts/m1-fixed-trust.py"
grep -Fq 'trusted(REGISTRY, "directory", exact_mode=0o700)' "$repo_root/scripts/m1-fixed-trust.py"
grep -Fq 'trusted(RECEIPTS, "directory", exact_mode=0o700)' "$repo_root/scripts/m1-fixed-trust.py"
grep -Fq 'trusted(STATE, "directory", exact_mode=0o700)' "$repo_root/scripts/m1-fixed-trust.py"
grep -Fq 'WITNESS = Path("/usr/local/libexec/rmx1901-m1-control/capture-witness")' "$repo_root/scripts/m1-fixed-trust.py"
grep -Fq 'ADAPTER = Path("/usr/local/libexec/rmx1901-m1-control/runtime-adapter")' "$repo_root/scripts/m1-fixed-trust.py"
grep -Fq 'ADAPTER_SHA = ROOT / "runtime-adapter.sha256"' "$repo_root/scripts/m1-fixed-trust.py"
grep -Fq 'fixed_trust=/usr/local/libexec/rmx1901-m1-control/fixed-trust' "$repo_root/scripts/capture-m1-attempt.sh"
grep -Fq 'fixed_trust=/usr/local/libexec/rmx1901-m1-control/fixed-trust' "$repo_root/scripts/validate-m1-attempt.sh"
grep -Fq 'fixed_trust=/usr/local/libexec/rmx1901-m1-control/fixed-trust' "$repo_root/scripts/compare-m1-attempts.sh"
grep -Fq -- '--upgrade-writer requires the reviewed env -i root launcher' "$repo_root/scripts/install-m1-root-control-plane.sh"
grep -Fq 'fixed-trust check || die' "$repo_root/scripts/install-m1-root-control-plane.sh"
grep -Fq 'upgraded the fixed M1 writer only; no device operation was performed' "$repo_root/scripts/install-m1-root-control-plane.sh"
grep -Fq -- '--upgrade-panic-adapter requires the reviewed env -i root launcher' "$repo_root/scripts/install-m1-root-control-plane.sh"
grep -Fq 'upgraded the fixed M1 panic adapter only; no device operation was performed' "$repo_root/scripts/install-m1-root-control-plane.sh"
grep -Fq -- '--upgrade-witness requires the reviewed env -i root launcher' "$repo_root/scripts/install-m1-root-control-plane.sh"
grep -Fq 'upgraded the fixed M1 witness only; no device operation was performed' "$repo_root/scripts/install-m1-root-control-plane.sh"
grep -Fq 'trust_root=/var/lib/rmx1901-m1-control' "$repo_root/scripts/validate-m1-attempt.sh"

set +e
"$witness_source" bad-arity >"$tmp_root/arity.out" 2>&1
arity_status=$?
"$witness_source" --self-check >"$tmp_root/check.out" 2>&1
check_status=$?
"$witness_source" --health >"$tmp_root/health.out" 2>&1
health_status=$?
set -e
test "$arity_status" -eq 20
test "$check_status" -eq 20
test "$health_status" -eq 20
grep -Fq 'fixed M1 control plane is unavailable' "$tmp_root/check.out"
# An uninstalled control plane must fail closed for both integrity and health;
# it must never be reported healthy merely because the witness executable is
# present in the checkout.
grep -Fq 'fixed M1 control plane is unavailable' "$tmp_root/health.out"

set +e
"$installer" --stage "$stage" >"$tmp_root/repeat.out" 2>&1
repeat_status=$?
set -e
test "$repeat_status" -ne 0
grep -Fq 'stage destination already exists' "$tmp_root/repeat.out"

set +e
"$installer" --install >"$tmp_root/install.out" 2>&1
install_status=$?
set -e
test "$install_status" -ne 0
grep -Fq -- '--install requires host root' "$tmp_root/install.out"

set +e
"$installer" >"$tmp_root/no-args.out" 2>&1
no_args_status=$?
set -e
test "$no_args_status" -ne 0
grep -Fq 'usage:' "$tmp_root/no-args.out"

unsafe_root="$tmp_root/unsafe-root"
mkdir "$unsafe_root"
ln -s "$unsafe_root" "$tmp_root/symlink-parent"
set +e
"$installer" --stage "$tmp_root/symlink-parent/child" >"$tmp_root/symlink.out" 2>&1
symlink_status=$?
set -e
test "$symlink_status" -ne 0
grep -Fq 'stage parent contains a symlink' "$tmp_root/symlink.out"

printf 'ok - M1 root control-plane package stages without installing trust material\n'
printf 'ok - service executes the exact pinned witness in a clean environment and fails unavailable selector health\n'
printf 'ok - uninstalled witness fails closed and cannot emit raw evidence\n'
