#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
capture="$repo_root/scripts/capture-m1-attempt.sh"
compare="$repo_root/scripts/compare-m1-attempts.sh"
fixed_trust="$repo_root/scripts/m1-fixed-trust.py"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/m1-trusted-witness.XXXXXX")"
trap 'rm -rf -- "$tmp_root"' EXIT

metadata="$tmp_root/metadata.env"
cat >"$metadata" <<'EOF'
SPEC_VERSION=RMX1901-M1-EVIDENCE-V1
ATTEMPT_ID=oracle-clone
UNIQUE_VARIABLE=diagnostic=handoff-v1
SOURCE_COMMIT=0123456789abcdef0123456789abcdef01234567
INITRD_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
BOOT_SHA256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
TOOLCHAIN_SHA256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
SOURCE_TREE_SHA256=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
SOURCE_DIRTY=NO
INPUT_SHA256=1111111111111111111111111111111111111111111111111111111111111111
OUTPUT_SHA256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
PREDECESSOR_SHA256=1111111111111111111111111111111111111111111111111111111111111111
EOF

# These two commands deliberately model the rejected architecture: the caller
# supplies arbitrary raw bytes and then asks a separate signer to authenticate
# the caller-authored request.  A production change that accepts either legacy
# variable makes this test fail.
legacy_runner="$tmp_root/legacy-runner"
legacy_signer="$tmp_root/legacy-signer"
attacker_private="$tmp_root/attacker-private.pem"
attacker_public="$tmp_root/attacker-public.pem"
attacker_registry="$tmp_root/attacker-registry"
printf '#!/bin/sh\nexit 0\n' >"$legacy_runner"
printf '#!/bin/sh\nexit 0\n' >"$legacy_signer"
chmod +x "$legacy_runner" "$legacy_signer"
openssl genpkey -algorithm ED25519 -out "$attacker_private" >/dev/null 2>&1
openssl pkey -in "$attacker_private" -pubout -out "$attacker_public" >/dev/null 2>&1
mkdir -p "$attacker_registry/receipts"

set +e
output="$(env \
  M1_READONLY_RUNNER="$legacy_runner" \
  M1_RECEIPT_SIGNER="$legacy_signer" \
  M1_CAPTURE_WITNESS="$legacy_runner" \
  M1_WITNESS_PUBLIC_KEY="$attacker_public" \
  M1_RECEIPT_REGISTRY="$attacker_registry" \
  M1_CAPTURE_METADATA="$metadata" \
  "$capture" "$tmp_root/20260728T030000Z-oracle-clone" 2>&1)"
status=$?
set -e

test "$status" -eq 20 || {
  printf 'expected missing trusted witness status 20, got %s: %s\n' "$status" "$output" >&2
  exit 1
}
printf '%s\n' "$output" | grep -Fq 'caller-selectable witness trust bootstrap is forbidden'
test ! -e "$tmp_root/20260728T030000Z-oracle-clone"

printf 'ok - caller runner plus signer cannot replace the trusted capture witness\n'

fake_bin="$tmp_root/fake-bin"
fake_marker="$tmp_root/fake-path-command-ran"
mkdir "$fake_bin"
for fake_name in python3 openssl env dirname realpath mktemp; do
  printf '#!/bin/sh\nprintf "%%s\\n" "$0" >>%q\nexit 0\n' "$fake_marker" \
    >"$fake_bin/$fake_name"
  chmod +x "$fake_bin/$fake_name"
done
set +e
path_output="$(/usr/bin/env PATH="$fake_bin:/usr/bin:/bin" \
  M1_CAPTURE_METADATA="$metadata" \
  "$capture" "$tmp_root/20260728T030010Z-path-injection" 2>&1)"
path_status=$?
set -e
test "$path_status" -eq 20 || {
  printf 'expected fixed-PATH status 20, got %s: %s\n' "$path_status" "$path_output" >&2
  exit 1
}
test ! -e "$fake_marker"
printf 'ok - caller PATH cannot replace python, openssl, env or shell utilities\n'

bash_env_marker="$tmp_root/bash-env-ran"
bash_env_file="$tmp_root/bash-env"
printf 'printf "BASH_ENV_RAN\\n" >>%q\n' "$bash_env_marker" >"$bash_env_file"
set +e
/usr/bin/env BASH_ENV="$bash_env_file" "$capture" \
  >"$tmp_root/bash-env-argc.out" 2>&1
bash_env_argc_status=$?
/usr/bin/env BASH_ENV="$bash_env_file" M1_CAPTURE_METADATA="$metadata" \
  "$capture" "$tmp_root/20260728T030020Z-bash-env" \
  >"$tmp_root/bash-env-trust.out" 2>&1
bash_env_trust_status=$?
/usr/bin/env BASH_ENV="$bash_env_file" "$compare" a b c extra \
  >"$tmp_root/bash-env-compare.out" 2>&1
bash_env_compare_status=$?
set -e
test "$bash_env_argc_status" -eq 10
test "$bash_env_trust_status" -eq 20
test "$bash_env_compare_status" -eq 10
test ! -e "$bash_env_marker"
printf 'ok - privileged shell entrypoints never source caller BASH_ENV\n'

set +e
compare_output="$("$compare" a b c forbidden-extra-argument 2>&1)"
compare_status=$?
set -e
test "$compare_status" -eq 10 || {
  printf 'expected compare argument status 10, got %s: %s\n' "$compare_status" "$compare_output" >&2
  exit 1
}
printf '%s\n' "$compare_output" | grep -Fq 'invalid compare argument count'
printf 'ok - compare rejects extra arguments with input status 10\n'

# A private /run owned by namespace UID 0 is still caller-controlled.  The
# fixed trust check must reject it before inspecting any fake control-plane
# object.
set +e
namespace_output="$(bwrap --unshare-user --uid 0 --gid 0 --unshare-pid --die-with-parent \
  --ro-bind /usr /usr --ro-bind /bin /bin --ro-bind /lib /lib \
  --ro-bind /lib64 /lib64 --ro-bind /etc /etc --bind /home /home \
  --proc /proc --dev /dev --tmpfs /run --tmpfs /tmp \
  "$fixed_trust" check 2>&1)"
namespace_status=$?
set -e
test "$namespace_status" -eq 20 || {
  printf 'expected fake-root namespace status 20, got %s: %s\n' \
    "$namespace_status" "$namespace_output" >&2
  exit 1
}
printf '%s\n' "$namespace_output" | grep -Fq 'rejects a non-initial user namespace'
printf 'ok - user-namespace UID 0 cannot manufacture fixed M1 trust\n'
