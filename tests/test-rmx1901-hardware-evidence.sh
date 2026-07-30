#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
collector="$repo_root/scripts/collect-rmx1901-hardware-evidence.sh"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/rmx1901-hw-evidence-test.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT
fake_bin="$tmp_root/bin"
mkdir "$fake_bin"

cat >"$fake_bin/ip" <<'EOF'
#!/usr/bin/env bash
printf 'usb0 UP\n'
EOF
cat >"$fake_bin/nmcli" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *UUID,NAME,TYPE,DEVICE*) printf '11111111-2222-3333-4444-555555555555:RMX1901:802-3-ethernet:usb0\n' ;;
  *) printf 'usb0:ethernet:connected:RMX1901\n' ;;
esac
EOF
cat >"$fake_bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
command_text="${!#}"
printf '%s\n' "$command_text" >>"$FAKE_SSH_LOG"
if [[ -n "${FAKE_SSH_FAIL_MATCH:-}" && "$command_text" == *"$FAKE_SSH_FAIL_MATCH"* ]]; then
    printf 'injected SSH failure\n' >&2
    exit 42
fi
case "$command_text" in
  *'id; printf "boot_id="'*)
    printf 'uid=32011(phablet) gid=32011(phablet) groups=32011(phablet)\n'
    printf 'boot_id=00000000-1111-2222-3333-444444444444\n'
    printf 'pid1=/sbin/init \n'
    ;;
  *'sha256sum /dev/sde10'*)
    if [[ "${FAKE_BAD_BOOT:-0}" == 1 ]]; then
      printf 'not-a-hash  /dev/sde10\n67108864\n'
    else
      printf '%064d  /dev/sde10\n67108864\n' 0
    fi
    ;;
  *)
    printf 'fixture for %s\n' "$command_text"
    ;;
esac
EOF
chmod +x "$fake_bin/ip" "$fake_bin/nmcli" "$fake_bin/ssh" "$collector"

ssh-keygen -q -t ed25519 -N '' -f "$tmp_root/host" >/dev/null
awk '{print "[fixture]:22 " $1 " " $2}' "$tmp_root/host.pub" >"$tmp_root/known-hosts"
printf 'transport=physical-usb\nfingerprint=fixture-verified-out-of-band\n' >"$tmp_root/host-key-evidence.txt"
export PATH="$fake_bin:$PATH"
export FAKE_SSH_LOG="$tmp_root/ssh.log"
: >"$FAKE_SSH_LOG"

success="$tmp_root/success"
"$collector" --out "$success" --phase baseline-test --ssh-target phablet@fixture \
    --known-hosts "$tmp_root/known-hosts" --host-key-evidence "$tmp_root/host-key-evidence.txt" --timeout 5

grep -Fxq 'schema=rmx1901-hardware-evidence-v1' "$success/manifest.env"
grep -Fxq 'exit_status=0' "$success/manifest.env"
grep -Fq $'P0-SOURCE-PINS\tPASS\t' "$success/acceptance.tsv"
grep -Fq $'P0-SSH-AUTH\tPASS\t' "$success/acceptance.tsv"
grep -Fq $'P0-BOOT-IDENTITY\tPASS\t' "$success/acceptance.tsv"
test -s "$success/source-state.txt"
test -s "$success/commands.tsv"
test -s "$success/pre-state/ssh-host-key-verification.txt"
test -s "$success/logs/journal.txt"
test -s "$success/pre-state/endpoint-ownership.txt"
test -s "$success/runtime/dsp-services.txt"
test -s "$success/runtime/radio-devices.txt"
test -s "$success/runtime/camera-lifecycle.txt"
grep -Fq $'endpoint-ownership\tdevice\t' "$success/commands.tsv"
grep -Fq $'dsp-services\tdevice\t' "$success/commands.tsv"
grep -Fq $'radio-devices\tdevice\t' "$success/commands.tsv"
grep -Fq $'camera-lifecycle\tdevice\t' "$success/commands.tsv"
! grep -Fq 'sha256sums.txt' "$success/sha256sums.txt"
(cd "$success" && sha256sum --strict -c sha256sums.txt >/dev/null)
awk -F '\t' 'NR > 1 && $4 != 0 {exit 1}' "$success/commands.tsv"

# Existing output is rejected without changing its sentinel.
printf 'keep\n' >"$tmp_root/existing"
set +e
"$collector" --out "$tmp_root/existing" --phase existing --offline >/dev/null 2>"$tmp_root/existing.err"
status=$?
set -e
test "$status" -eq 2
test "$(cat "$tmp_root/existing")" = keep

# Offline evidence is explicit BLOCKED and returns 3 with valid checksums.
offline="$tmp_root/offline"
set +e
"$collector" --out "$offline" --phase offline --offline --timeout 5 >"$tmp_root/offline.stdout"
status=$?
set -e
test "$status" -eq 3
grep -Fq $'requirement\tstatus\tevidence' "$offline/acceptance.tsv"
grep -Fq $'P0-SSH-AUTH\tBLOCKED\t' "$offline/acceptance.tsv"
grep -Fxq 'exit_status=3' "$offline/manifest.env"
(cd "$offline" && sha256sum --strict -c sha256sums.txt >/dev/null)

# A successful command with false boot content cannot pass the acceptance gate.
bad_boot="$tmp_root/bad-boot"
set +e
FAKE_BAD_BOOT=1 "$collector" --out "$bad_boot" --phase bad-boot --ssh-target phablet@fixture \
    --known-hosts "$tmp_root/known-hosts" --timeout 5 >/dev/null
status=$?
set -e
test "$status" -eq 1
grep -Fq $'P0-BOOT-IDENTITY\tFAIL\t' "$bad_boot/acceptance.tsv"
grep -Fxq 'exit_status=1' "$bad_boot/manifest.env"
(cd "$bad_boot" && sha256sum --strict -c sha256sums.txt >/dev/null)

# A remote timeout/failure is recorded, fails the bundle, and still seals evidence.
failed="$tmp_root/failed"
set +e
FAKE_SSH_FAIL_MATCH='sha256sum /dev/sde10' "$collector" --out "$failed" --phase failed --ssh-target phablet@fixture \
    --known-hosts "$tmp_root/known-hosts" --timeout 5 >/dev/null
status=$?
set -e
test "$status" -eq 1
awk -F '\t' '$1 == "boot-hash" && $4 == 42 && $9 == "critical" {found=1} END {exit !found}' "$failed/commands.tsv"
grep -Fxq 'exit_status=1' "$failed/manifest.env"
(cd "$failed" && sha256sum --strict -c sha256sums.txt >/dev/null)

# Source-level read-only contract and secret hygiene.
if grep -E 'nmcli .*connection (up|down|modify|delete)|systemctl (start|stop|restart|enable)|rfkill (block|unblock)|setenforce|sudo -S|StrictHostKeyChecking=no' "$collector"; then
    echo 'state-changing or insecure operation in hardware collector' >&2
    exit 1
fi
if grep -E 'getprop($|[^ ]*(serial|imei|mac|bluetooth))' "$collector"; then
    echo 'collector requests an unredacted device identifier' >&2
    exit 1
fi

echo 'RMX1901 hardware evidence collector tests passed'
