#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if test "${M1_TEST_LOGIC_NAMESPACE:-0}" != 1; then
  command -v bwrap >/dev/null
  exec bwrap --unshare-user --uid 0 --gid 0 --unshare-pid --die-with-parent \
    --ro-bind /usr /usr --ro-bind /bin /bin --ro-bind /lib /lib \
    --ro-bind /lib64 /lib64 --ro-bind /etc /etc --bind /home /home \
    --proc /proc --dev /dev --tmpfs /run --tmpfs /tmp --chdir "$repo_root" \
    --setenv M1_TEST_LOGIC_NAMESPACE 1 /bin/bash "$repo_root/tests/test-m1-attempt-evidence.sh"
fi
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/m1-attempt-evidence.XXXXXX")"
cleanup() {
  chmod -R u+w "$tmp_root" 2>/dev/null || true
  rm -rf -- "$tmp_root"
  if test -f /run/rmx1901-m1-control/.m1-test-owned; then
    rm -rf -- /run/rmx1901-m1-control
  fi
}
trap cleanup EXIT

# Pure gate-logic harness only.  It copies the production programs and replaces
# their fixed-root preflight helper inside the disposable copy.  This is not a
# production trust override and must never be reported as a trusted happy-path:
# the real helper's user-namespace rejection is tested separately.
logic_repo="$tmp_root/logic-repo"
mkdir -p "$logic_repo/scripts"
cp -- "$repo_root/scripts/capture-m1-attempt.sh" \
  "$repo_root/scripts/validate-m1-attempt.sh" \
  "$repo_root/scripts/compare-m1-attempts.sh" \
  "$repo_root/scripts/m1-safe-file.py" \
  "$repo_root/scripts/m1-evidence-snapshot.py" "$logic_repo/scripts/"
printf '#!/bin/sh\nexit 0\n' >"$logic_repo/scripts/m1-fixed-trust.py"
chmod +x "$logic_repo/scripts/"*
# The copied gate cannot bind the production persistent root inside a
# user-namespace-only fixture.  Its fixed persistent paths are therefore
# redirected solely inside this disposable logic harness; production scripts
# retain /var/lib + /usr/local fixed trust paths and are separately required to
# reject the fake-root namespace.
/usr/bin/python3 - "$logic_repo/scripts/capture-m1-attempt.sh" "$logic_repo/scripts/compare-m1-attempts.sh" "$logic_repo/scripts/validate-m1-attempt.sh" <<'PY'
import sys
for name in sys.argv[1:]:
    raw = open(name, encoding="utf-8").read()
    raw = raw.replace("/var/lib/rmx1901-m1-control", "/run/rmx1901-m1-control")
    raw = raw.replace("/usr/local/libexec/rmx1901-m1-control/capture-witness", "/run/rmx1901-m1-control/capture-witness")
    raw = raw.replace("/usr/local/libexec/rmx1901-m1-control/fixed-trust", "$repo_root/scripts/m1-fixed-trust.py")
    with open(name, "w", encoding="utf-8", newline="") as output:
        output.write(raw)
PY
capture="$logic_repo/scripts/capture-m1-attempt.sh"
validate="$logic_repo/scripts/validate-m1-attempt.sh"
compare="$logic_repo/scripts/compare-m1-attempts.sh"

test -x "$capture"
test -x "$validate"
test -x "$compare"
command -v openssl >/dev/null
command -v flock >/dev/null

trust_root=/run/rmx1901-m1-control
test ! -e "$trust_root" || {
  echo 'refusing to replace an installed M1 control plane' >&2
  exit 1
}
registry="$trust_root/registry"
signer_state="$trust_root/state"
private_key="$trust_root/witness-private.pem"
public_key="$trust_root/witness-ed25519.pub"
mkdir -m 700 -p "$registry/receipts" "$signer_state"
touch "$trust_root/.m1-test-owned"
chmod 400 "$trust_root/.m1-test-owned"
openssl genpkey -algorithm ED25519 -out "$private_key" >/dev/null 2>&1
openssl pkey -in "$private_key" -pubout -out "$public_key" >/dev/null 2>&1
chmod 400 "$private_key" "$public_key"

new_trust_context() {
  test -n "$1"
  find "$signer_state" -mindepth 1 -maxdepth 1 -delete
}
new_trust_context main

metadata_for() {
  local destination="$1" attempt_id="$2"
  local predecessor="${3:-1111111111111111111111111111111111111111111111111111111111111111}"
  local source_tree="${4:-dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd}"
  cat >"$destination" <<EOF
SPEC_VERSION=RMX1901-M1-EVIDENCE-V1
ATTEMPT_ID=$attempt_id
UNIQUE_VARIABLE=diagnostic=handoff-v1
SOURCE_COMMIT=0123456789abcdef0123456789abcdef01234567
INITRD_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
BOOT_SHA256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
TOOLCHAIN_SHA256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
SOURCE_TREE_SHA256=$source_tree
SOURCE_DIRTY=NO
INPUT_SHA256=$predecessor
OUTPUT_SHA256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
PREDECESSOR_SHA256=$predecessor
EOF
}

metadata="$tmp_root/metadata-a.env"
metadata_for "$metadata" attempt-a

expected="$tmp_root/expected-tokens.txt"
cat >"$expected" <<'EOF'
console=tty0
systempart=/dev/disk/by-partlabel/system
systemd.unified_cgroup_hierarchy=0
rmx1901.debug_rndis=1
EOF

fake_runner="$trust_root/selector-runner"
cat >"$fake_runner" <<'RUNNER'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$#:$1" >>"$M1_TEST_CALLS"

emit_canonical() {
  cat <<'EVENTS'
RMX1901_HANDOFF sequence=1 stage=CMDLINE_PARSED systempart=valid cgroup=valid console=valid diagnostic_rndis=valid
RMX1901_HANDOFF sequence=2 stage=ROOT_DEVICE_RESOLVED root=/dev/sda11 root_mm=8:b system=/dev/sda11 system_mm=8:b userdata=/dev/sda13 userdata_mm=8:d
RMX1901_HANDOFF sequence=3 stage=USERDATA_PROBED path=/dev/sda13 major_minor=8:d fstype=f2fs readonly=yes norecovery=yes rw=absent dmesg=readable recovery_fsync=absent unmounted=yes result=safe
RMX1901_HANDOFF sequence=4 stage=ROOTFS_MOUNTED requested_source=/dev/sda11 source=/dev/sda11 fstype=ext4 options=ro:relatime
RMX1901_HANDOFF sequence=5 stage=DEV_MOVE_BEGIN rootmnt=/root
RMX1901_HANDOFF sequence=6 stage=DEV_MOVE_DONE rootmnt=/root
RMX1901_HANDOFF sequence=7 stage=CONSOLE_OPEN_OK path=/root/dev/console
RMX1901_HANDOFF sequence=8 stage=RUN_MOVE_BEGIN from=/run to=/root/run
RMX1901_HANDOFF sequence=9 stage=RUN_MOVE_DONE path=/root/run/rmx1901-handoff.events
RMX1901_HANDOFF sequence=10 stage=HANDOFF_MARKER_VISIBLE path=/root/run/rmx1901-handoff.events
RMX1901_HANDOFF sequence=11 stage=RUN_INIT_EXEC init=/sbin/init inode=42 type=regular_file
EVENTS
}

emit_events() {
  case "${M1_TEST_EVENT_VARIANT:-canonical}" in
    canonical) emit_canonical ;;
    inverse-order)
      cat <<'EVENTS'
RMX1901_HANDOFF sequence=1 stage=CMDLINE_PARSED systempart=valid cgroup=valid console=valid diagnostic_rndis=valid
RMX1901_HANDOFF sequence=2 stage=ROOT_DEVICE_RESOLVED root=/dev/sda11 root_mm=8:b system=/dev/sda11 system_mm=8:b userdata=/dev/sda13 userdata_mm=8:d
RMX1901_HANDOFF sequence=3 stage=ROOTFS_MOUNTED requested_source=/dev/sda11 source=/dev/sda11 fstype=ext4 options=ro:relatime
RMX1901_HANDOFF sequence=4 stage=USERDATA_PROBED path=/dev/sda13 major_minor=8:d fstype=f2fs readonly=yes norecovery=yes rw=absent dmesg=readable recovery_fsync=absent unmounted=yes result=safe
EVENTS
      ;;
    missing-cmdline-proof)
      emit_canonical | sed 's/ diagnostic_rndis=valid//' ;;
    bad-root-device)
      emit_canonical | sed 's/root_mm=8:b/root_mm=missing/' ;;
    unsafe-userdata)
      emit_canonical | sed 's/readonly=yes norecovery=yes rw=absent dmesg=readable recovery_fsync=absent/readonly=yes norecovery=no rw=present dmesg=readable recovery_fsync=present/' ;;
    unsafe-rootfs)
      emit_canonical | sed 's/options=ro:relatime/options=rw:relatime/' ;;
    terminal-trailing)
      emit_canonical | sed 's/stage=CONSOLE_OPEN_OK path=\/root\/dev\/console/stage=CONSOLE_OPEN_FAILED path=\/root\/dev\/console open_status=1/'
      printf '%s' 'RMX1901_HANDOFF sequence=8 stage=RUN_MOVE_BEGIN from=/run to=/root/run'
      ;;
    *) exit 98 ;;
  esac
}

case "$1" in
  boot-unpack)
    cmdline='console=tty0 systempart=/dev/disk/by-partlabel/system systemd.unified_cgroup_hierarchy=0 rmx1901.debug_rndis=1'
    test "${M1_TEST_CMDLINE_VARIANT:-canonical}" != weak || cmdline='console=tty0 systempart=/dev/disk/by-partlabel/system systemd.unified_cgroup_hierarchy=0'
    printf '%s\n' 'boot image header version: 1' 'additional command line args: ' "command line args: $cmdline" 'kernel size: 8388608' 'ramdisk size: 3947268'
    ;;
  proc-cmdline)
    cmdline='console=tty0 systempart=/dev/disk/by-partlabel/system systemd.unified_cgroup_hierarchy=0 rmx1901.debug_rndis=1'
    test "${M1_TEST_CMDLINE_VARIANT:-canonical}" != weak || cmdline='console=tty0 systempart=/dev/disk/by-partlabel/system systemd.unified_cgroup_hierarchy=0'
    printf '%s\n' "$cmdline"
    ;;
  handoff-events)
    test "${M1_TEST_HANDOFF_MISSING:-0}" != 1 || exit 42
    emit_events
    ;;
  kmsg)
    if test "${M1_TEST_KMSG_MALFORMED:-0}" = 1; then
      printf '%s\n' '<6>initrd: bogus RMX1901_HANDOFF evidence'
    elif test "${M1_TEST_KMSG_MISMATCH:-0}" = 1; then
      emit_events | sed 's/console=valid/console=missing/' | sed 's/^/<6>initrd: /'
    elif test "${M1_TEST_KMSG_EXTRA_MALFORMED:-0}" = 1; then
      emit_events | sed 's/^/<6>initrd: /'
      printf '%s\n' '<6>initrd: RMX1901_HANDOFF forged-noncanonical-event'
    else
      emit_events | sed 's/^/<6>initrd: /'
    fi
    ;;
  pid1-comm) printf '%s\n' "${M1_TEST_PID1_COMM:-init}" ;;
  pid1-exe) printf '%s\n' "${M1_TEST_PID1_EXE:-/bin/sh}" ;;
  pid1-cmdline) printf '%s\n' "${M1_TEST_PID1_CMDLINE:-/bin/sh /init}" ;;
  boot-id) printf '%s\n' "${M1_TEST_BOOT_ID:?}" ;;
  runtime-mounts) printf '%s\n' "${M1_TEST_RUNTIME_MOUNTS:-rootfs / rootfs ro 0 0}" ;;
  runtime-journal)
    if test -n "${M1_TEST_RUNTIME_JOURNAL_FILE:-}"; then
      cat -- "$M1_TEST_RUNTIME_JOURNAL_FILE"
    else
      printf '%s\n' "${M1_TEST_RUNTIME_JOURNAL:-journal unavailable in initramfs}"
    fi
    ;;
  runtime-failed-units) printf '%s\n' 'systemd unavailable in initramfs' ;;
  runtime-configfs) printf '%s\n' 'configfs unavailable in initramfs' ;;
  runtime-netdev) printf '%s\n' 'rndis.usb0' ;;
  runtime-systemd-confirmed)
    test "${M1_TEST_TRANSPORT_VARIANT:-panic}" = systemd && value=YES || value=NO
    printf 'SYSTEMD_CONFIRMED=%s\n' "$value"
    ;;
  transport)
    case "${M1_TEST_TRANSPORT_VARIANT:-panic}" in
      panic) printf '%s\n' 'TRANSPORT=panic' 'PRODUCT=Failed to boot' 'TCP22=CLOSED' 'TCP23=OPEN' 'BANNER=NONE' 'HOSTKEY=NONE' 'AUTH=NONE' 'PID1_COMM=init' 'PID1_EXE=/bin/sh' 'PID1_CMDLINE=/bin/sh /init' ;;
      diagnostic) printf '%s\n' 'TRANSPORT=diagnostic-ssh' 'PRODUCT=RMX1901 diagnostic bridge' 'TCP22=OPEN' 'TCP23=CLOSED' 'BANNER=SSH-2.0-OpenSSH_9.6' 'HOSTKEY=SHA256:YWJjZA==' 'AUTH=PUBLICKEY_OK' 'PID1_COMM=sh' 'PID1_EXE=/init' 'PID1_CMDLINE=/bin/sh /init' ;;
      systemd) printf '%s\n' 'TRANSPORT=systemd-ssh' 'PRODUCT=RMX1901 diagnostic bridge' 'TCP22=OPEN' 'TCP23=CLOSED' 'BANNER=SSH-2.0-OpenSSH_9.6' 'HOSTKEY=SHA256:YWJjZA==' 'AUTH=PUBLICKEY_OK' 'PID1_COMM=systemd' 'PID1_EXE=/usr/lib/systemd/systemd' 'PID1_CMDLINE=/usr/lib/systemd/systemd' ;;
      diagnostic-bad-product) printf '%s\n' 'TRANSPORT=diagnostic-ssh' 'PRODUCT=rmx1901-ut-diagnostic' 'TCP22=OPEN' 'TCP23=CLOSED' 'BANNER=SSH-2.0-OpenSSH_9.6' 'HOSTKEY=SHA256:YWJjZA==' 'AUTH=PUBLICKEY_OK' 'PID1_COMM=systemd' 'PID1_EXE=/lib/systemd/systemd' 'PID1_CMDLINE=/sbin/init' ;;
      shell-product) printf '%s\n' 'TRANSPORT=panic-telnet' 'PRODUCT=$(id)' 'TCP22=CLOSED' 'TCP23=OPEN' 'BANNER=NONE' 'HOSTKEY=NONE' 'AUTH=NONE' 'PID1_COMM=init' 'PID1_EXE=/init' 'PID1_CMDLINE=/init' ;;
    esac
    ;;
  usb-state)
    case "${M1_TEST_TRANSPORT_VARIANT:-panic}" in
      panic) printf '%s\n' 'CLASSIFICATION=panic' 'VIDPID=18d1:d001' 'PRODUCT=Failed to boot' 'NETDEV=rndis.usb0' 'IP=192.168.2.15' 'TCP22=CLOSED' 'TCP23=OPEN' ;;
      diagnostic) printf '%s\n' 'CLASSIFICATION=diagnostic-ssh' 'VIDPID=18d1:d001' 'PRODUCT=RMX1901 diagnostic bridge' 'NETDEV=rndis.usb0' 'IP=192.168.2.15' 'TCP22=OPEN' 'TCP23=CLOSED' ;;
      systemd) printf '%s\n' 'CLASSIFICATION=systemd-ssh' 'VIDPID=18d1:d001' 'PRODUCT=RMX1901 diagnostic bridge' 'NETDEV=rndis.usb0' 'IP=192.168.2.15' 'TCP22=OPEN' 'TCP23=CLOSED' ;;
      diagnostic-bad-product) printf '%s\n' 'CLASSIFICATION=diagnostic-ssh' 'VIDPID=18d1:d001' 'PRODUCT=rmx1901-ut-diagnostic' 'NETDEV=rndis.usb0' 'IP=192.168.2.15' 'TCP22=OPEN' 'TCP23=CLOSED' ;;
      shell-product) printf '%s\n' 'CLASSIFICATION=panic-telnet' 'VIDPID=18d1:d001' 'PRODUCT=$(id)' 'NETDEV=rndis.usb0' 'IP=192.168.2.15' 'TCP22=CLOSED' 'TCP23=OPEN' ;;
    esac
    ;;
  preflight)
    case "${M1_TEST_PREFLIGHT_VARIANT:-canonical}" in
      canonical) product=fox_RMX1901; model=RMX1901; device=RMX1901; mm=8:4a; battery=80 ;;
      bringup) product=fox_RMX1901; model=RMX1901-Bringup; device=RMX1901; mm=8:4a; battery=80 ;;
      bad-product) product=RMX1901; model=RMX1901; device=RMX1901; mm=8:4a; battery=80 ;;
      bad-device) product=fox_RMX1901; model=RMX1901; device=RMX1901-Bringup; mm=8:4a; battery=80 ;;
      bad-mm) product=fox_RMX1901; model=RMX1901; device=RMX1901; mm=8:4; battery=80 ;;
      battery-90) product=fox_RMX1901; model=RMX1901; device=RMX1901; mm=8:4a; battery=90 ;;
    esac
    printf '%s\n' 'ADB_STATE=recovery' 'ADB_SERIAL=7b0c1c49' "ADB_PRODUCT=$product" "ADB_MODEL=$model" "ADB_DEVICE=$device" 'UNLOCKED=YES' 'BOOT_PATH=/dev/block/sde10' 'BOOT_SIZE=67108864' "BOOT_MAJOR_MINOR=$mm" "BATTERY_PERCENT=$battery" 'SAFETY_GATE=PASS'
    ;;
  write-readback)
    predecessor="${M1_TEST_PREDECESSOR:-1111111111111111111111111111111111111111111111111111111111111111}"
    device="${M1_TEST_DEVICE_READBACK:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}"
    host="${M1_TEST_HOST_READBACK:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}"
    printf '%s\n' "PREDECESSOR_SHA256=$predecessor" "DEVICE_READBACK_SHA256=$device" "HOST_READBACK_SHA256=$host"
    ;;
  *) echo "unsafe selector $1" >&2; exit 97 ;;
esac
RUNNER
chmod +x "$fake_runner"

# The only production-facing capture dependency is this witness command.  It
# owns selector execution, freshness/chain state and the private key, and
# returns one signed raw bundle.  The capture program never receives a runner
# or signer argv of its own.
witness="$trust_root/capture-witness"
cat >"$witness" <<'WITNESS'
#!/usr/bin/env bash
set -euo pipefail
metadata="${1:?metadata snapshot}"
capture_directory="${2:?capture directory}"
bundle="${3:?private bundle output}"
test "$#" -eq 3
runner=/run/rmx1901-m1-control/selector-runner
private_key=/run/rmx1901-m1-control/witness-private.pem
state=/run/rmx1901-m1-control/state
registry=/run/rmx1901-m1-control/registry
test -f "$state/test-environment"
set -a
. "$state/test-environment"
set +a
if test "${M1_TEST_REJECT_LEGACY_ENV:-0}" = 1 && \
   { test -n "${M1_READONLY_RUNNER:-}" || test -n "${M1_RECEIPT_SIGNER:-}"; }; then
  exit 76
fi
attempt="$bundle/attempt"
mkdir -m 700 -p "$attempt/runtime"
cp -- "$metadata" "$attempt/attempt.env"
nonce="$(od -An -N16 -tx1 /dev/urandom | tr -d '[:space:]')"
timestamp="$(date -u +%Y%m%dT%H%M%S.%NZ)"
session="m1-$nonce"
printf 'CAPTURE_NONCE=%s\nCAPTURE_TIMESTAMP=%s\n' "$nonce" "$timestamp" >>"$attempt/attempt.env"
printf 'CAPTURE_DIRECTORY=%s\nCAPTURE_SESSION=%s\n' "$capture_directory" "$session" >"$attempt/capture-session.env"

capture() {
  "$runner" "$1" >"$attempt/$2"
  test -s "$attempt/$2"
}
capture boot-unpack boot-unpack.txt
capture proc-cmdline proc-cmdline.txt
capture kmsg handoff-kmsg.log
capture handoff-events handoff-events.log
capture pid1-comm runtime/pid1-comm.txt
capture pid1-exe runtime/pid1-exe.txt
capture pid1-cmdline runtime/pid1-cmdline.txt
capture boot-id runtime/boot-id.txt
capture runtime-mounts runtime/mounts.txt
capture runtime-journal runtime/journal.txt
capture runtime-failed-units runtime/failed-units.txt
capture runtime-configfs runtime/configfs.txt
capture runtime-netdev runtime/netdev.txt
capture runtime-systemd-confirmed runtime/systemd-confirmed.env
capture transport transport.env
capture usb-state usb-state.env
capture preflight preflight.env
capture write-readback write-readback.env
printf 'RESULT=PASS\nFAILURE_PHASE=NONE\nREASON=SIGNED_RAW_CAPTURE_COMPLETED\n' >"$attempt/result.env"

(cd "$attempt" && find . -type f \
  ! -name SHA256SUMS ! -name capture-SHA256SUMS \
  -printf '%P\0' | LC_ALL=C sort -z | xargs -0 -r sha256sum >capture-SHA256SUMS)
manifest_sha="$(sha256sum "$attempt/capture-SHA256SUMS" | awk '{print $1}')"
boot_id="$(cat "$attempt/runtime/boot-id.txt")"
request="$bundle/request.env"
printf 'ATTEMPT_ID=%s\nCAPTURE_DIRECTORY=%s\nCAPTURE_SESSION=%s\nCAPTURE_NONCE=%s\nCAPTURE_TIMESTAMP=%s\nBOOT_ID=%s\nCAPTURE_MANIFEST_SHA256=%s\n' \
  "${capture_directory#*-}" "$capture_directory" "$session" "$nonce" \
  "$timestamp" "$boot_id" "$manifest_sha" >"$request"
exec 9>"$state/lock"
flock -x 9
if test -f "$state/boot-ids" && grep -Fxq "$boot_id" "$state/boot-ids"; then
  exit 75
fi
sequence=1
previous=GENESIS
if test -s "$state/sequence"; then
  sequence=$(( $(cat "$state/sequence") + 1 ))
  previous="$(cat "$state/head")"
fi
{
  printf 'RECEIPT_SCHEMA=RMX1901-M1-SIGNED-RECEIPT-V1\n'
  printf 'SIGNER_SEQUENCE=%s\n' "$sequence"
  printf 'SIGNER_PREVIOUS_SHA256=%s\n' "$previous"
  cat "$request"
} >"$bundle/receipt.env"
openssl pkeyutl -sign -rawin -inkey "$private_key" \
  -in "$bundle/receipt.env" -out "$bundle/receipt.sig"
test ! -e "$registry/receipts/$session.receipt" && test ! -e "$registry/receipts/$session.sig"
install -m 400 "$bundle/receipt.env" "$registry/receipts/$session.receipt"
install -m 400 "$bundle/receipt.sig" "$registry/receipts/$session.sig"
sha256sum "$bundle/receipt.env" | awk '{print $1}' >"$state/head"
printf '%s\n' "$sequence" >"$state/sequence"
printf '%s\n' "$boot_id" >>"$state/boot-ids"
rm -f -- "$request"
if test "${M1_TEST_BUNDLE_FORGE:-}" = raw-after-sign; then
  printf 'caller-forged-token=1\n' >>"$attempt/proc-cmdline.txt"
  (cd "$attempt" && find . -type f \
    ! -name SHA256SUMS ! -name capture-SHA256SUMS \
    -printf '%P\0' | LC_ALL=C sort -z | xargs -0 -r sha256sum >capture-SHA256SUMS)
fi
if test "${M1_TEST_BUNDLE_SPECIAL:-}" = symlink; then
  ln -s /etc/passwd "$attempt/runtime/hidden-link"
fi
(cd "$attempt" && find . -type f ! -name SHA256SUMS \
  -printf '%P\0' | LC_ALL=C sort -z | xargs -0 -r sha256sum >SHA256SUMS)
WITNESS
chmod 500 "$witness" "$fake_runner"
sha256sum "$witness" | awk '{print $1}' >"$trust_root/capture-witness.sha256"
sha256sum "$public_key" | awk '{print $1}' >"$trust_root/witness-ed25519.sha256"
chmod 400 "$trust_root/capture-witness.sha256" "$trust_root/witness-ed25519.sha256"

capture_attempt() {
  local metadata_file="$1" attempt_dir="$2"; shift 2
  local boot_hex boot_id assignment
  boot_hex="$(printf '%s' "$attempt_dir" | sha256sum | awk '{print substr($1,1,32)}')"
  boot_id="${boot_hex:0:8}-${boot_hex:8:4}-4${boot_hex:13:3}-8${boot_hex:17:3}-${boot_hex:20:12}"
  test ! -e "$signer_state/test-environment" || chmod 600 "$signer_state/test-environment"
  {
    printf '%q\n' "M1_TEST_CALLS=$calls"
    printf '%q\n' "M1_TEST_BOOT_ID=$boot_id"
    for assignment in "$@"; do
      [[ "$assignment" =~ ^M1_TEST_[A-Z0-9_]+= ]] || {
        echo "invalid pure-logic witness setting: $assignment" >&2
        return 1
      }
      printf '%q\n' "$assignment"
    done
  } >"$signer_state/test-environment"
  chmod 400 "$signer_state/test-environment"
  M1_CAPTURE_METADATA="$metadata_file" "$capture" "$attempt_dir"
}

validate_attempt() {
  "$validate" "$1" "$expected"
}

compare_attempts() {
  "$compare" "$1" "$2" "$expected"
}

assert_status() {
  local wanted="$1" needle="$2"; shift 2
  set +e
  status_output="$("$@" 2>&1)"
  status_value=$?
  set -e
  test "$status_value" -eq "$wanted" || {
    printf 'wanted status %s, got %s: %s\n' "$wanted" "$status_value" "$status_output" >&2
    return 1
  }
  printf '%s\n' "$status_output" | grep -Fq "$needle"
}

calls="$tmp_root/calls.txt"

# No caller runner/signer pair can replace a trusted external witness.
missing_trust="$tmp_root/20260728T000000Z-attempt-a"
assert_status 20 'caller-selectable witness trust bootstrap is forbidden' env M1_READONLY_RUNNER="$fake_runner" \
  M1_RECEIPT_SIGNER=/bin/false M1_CAPTURE_METADATA="$metadata" \
  M1_TEST_CALLS="$calls" "$capture" "$missing_trust"

# Two signed, directly chained capture sessions form the only valid M1 pair.
attempt_a="$tmp_root/20260728T000100Z-attempt-a"
capture_attempt "$metadata" "$attempt_a"
validate_attempt "$attempt_a"
test -s "$attempt_a/capture-SHA256SUMS"
session_a="$(sed -n 's/^CAPTURE_SESSION=//p' "$attempt_a/capture-session.env")"
test -s "$registry/receipts/$session_a.receipt"
test -s "$registry/receipts/$session_a.sig"
openssl pkeyutl -verify -rawin -pubin -inkey "$public_key" \
  -in "$registry/receipts/$session_a.receipt" \
  -sigfile "$registry/receipts/$session_a.sig" >/dev/null

metadata_b="$tmp_root/metadata-b.env"
metadata_for "$metadata_b" attempt-b
attempt_b="$tmp_root/20260728T000200Z-attempt-b"
capture_attempt "$metadata_b" "$attempt_b"
validate_attempt "$attempt_b"
# Comparison must work from private verified snapshots and must not reopen or
# mutate caller-owned attempt files after validation.
chmod -R a-w "$attempt_a" "$attempt_b"
compare_attempts "$attempt_a" "$attempt_b" | grep -Fxq 'M1_ATTEMPTS_EQUIVALENT=YES'
chmod -R u+w "$attempt_a" "$attempt_b"

# Once descriptor snapshots are complete, replacing a caller-owned attempt
# path cannot affect validation or final comparison.  Watching the first open
# of B gives a deterministic boundary: A has already been fully snapshotted.
saved_registry="$registry"
saved_signer_state="$signer_state"
new_trust_context post-validation-replacement
large_journal="$tmp_root/large-journal.log"
dd if=/dev/zero of="$large_journal" bs=1M count=8 status=none
race_meta_a="$tmp_root/race-a.env"; metadata_for "$race_meta_a" race-a
race_meta_b="$tmp_root/race-b.env"; metadata_for "$race_meta_b" race-b
race_a="$tmp_root/20260728T000210Z-race-a"
race_b="$tmp_root/20260728T000220Z-race-b"
capture_attempt "$race_meta_a" "$race_a" M1_TEST_RUNTIME_JOURNAL_FILE="$large_journal"
capture_attempt "$race_meta_b" "$race_b" M1_TEST_RUNTIME_JOURNAL_FILE="$large_journal"
watch_output="$tmp_root/race-watch.out"
watch_ready="$tmp_root/race-watch.ready"
inotifywait -e open --format '%e' "$race_b" >"$watch_output" 2>"$watch_ready" &
watch_pid=$!
for _ in $(seq 1 100); do
  grep -Fq 'Watches established' "$watch_ready" 2>/dev/null && break
  sleep 0.01
done
grep -Fq 'Watches established' "$watch_ready"
compare_attempts "$race_a" "$race_b" >"$tmp_root/race-compare.out" 2>"$tmp_root/race-compare.err" &
compare_pid=$!
wait "$watch_pid"
mv -- "$race_a" "$race_a.snapshot-source"
mkdir -- "$race_a"
printf 'replaced-after-A-snapshot\n' >"$race_a/attacker.txt"
set +e
wait "$compare_pid"
race_status=$?
set -e
test "$race_status" -eq 0 || {
  cat "$tmp_root/race-compare.err" >&2
  exit 1
}
grep -Fxq 'M1_ATTEMPTS_EQUIVALENT=YES' "$tmp_root/race-compare.out"
rm -- "$race_a/attacker.txt"
rmdir -- "$race_a"
mv -- "$race_a.snapshot-source" "$race_a"
registry="$saved_registry"
signer_state="$saved_signer_state"

# Trust is pinned to an Ed25519 public key, not merely any parseable PEM key.
rsa_private="$tmp_root/rsa-private.pem"
rsa_public="$tmp_root/rsa-public.pem"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$rsa_private" >/dev/null 2>&1
openssl pkey -in "$rsa_private" -pubout -out "$rsa_public" >/dev/null 2>&1
cp -- "$public_key" "$tmp_root/ed25519-public.pem"
chmod 600 "$public_key" "$trust_root/witness-ed25519.sha256"
cp -- "$rsa_public" "$public_key"
sha256sum "$public_key" | awk '{print $1}' >"$trust_root/witness-ed25519.sha256"
chmod 400 "$public_key" "$trust_root/witness-ed25519.sha256"
assert_status 20 'public key is not Ed25519' "$validate" "$attempt_a" "$expected"
chmod 600 "$public_key" "$trust_root/witness-ed25519.sha256"
cp -- "$tmp_root/ed25519-public.pem" "$public_key"
sha256sum "$public_key" | awk '{print $1}' >"$trust_root/witness-ed25519.sha256"
chmod 400 "$public_key" "$trust_root/witness-ed25519.sha256"

# Unknown symlinks/special entries are outside both checksum manifests and may
# not hide in an otherwise valid signed attempt directory.
ln -s /etc/passwd "$attempt_a/runtime/unknown-link"
assert_status 20 'unsafe attempt entry' validate_attempt "$attempt_a"
rm "$attempt_a/runtime/unknown-link"

# Rewriting every self-authored identity field and both local manifests cannot
# manufacture a signed external receipt for a cloned attempt.
attempt_forged="$tmp_root/20260728T000300Z-attempt-forged"
cp -a "$attempt_a" "$attempt_forged"
sed -i \
  -e 's/^ATTEMPT_ID=.*/ATTEMPT_ID=attempt-forged/' \
  -e 's/^CAPTURE_NONCE=.*/CAPTURE_NONCE=33333333333333333333333333333333/' \
  -e 's/^CAPTURE_TIMESTAMP=.*/CAPTURE_TIMESTAMP=20260728T000300.000000000Z/' \
  "$attempt_forged/attempt.env"
sed -i \
  -e "s/^CAPTURE_DIRECTORY=.*/CAPTURE_DIRECTORY=$(basename "$attempt_forged")/" \
  -e 's/^CAPTURE_SESSION=.*/CAPTURE_SESSION=m1-33333333333333333333333333333333/' \
  "$attempt_forged/capture-session.env"
(cd "$attempt_forged" && find . -type f \
  ! -name SHA256SUMS ! -name capture-SHA256SUMS ! -name result.env ! -name m1-validation.env \
  -printf '%P\0' | LC_ALL=C sort -z | xargs -0 -r sha256sum >capture-SHA256SUMS)
(cd "$attempt_forged" && find . -type f ! -name SHA256SUMS -printf '%P\0' | LC_ALL=C sort -z | xargs -0 -r sha256sum >SHA256SUMS)
assert_status 20 'trusted capture receipt' compare_attempts "$attempt_a" "$attempt_forged"

# The two event sinks are independent evidence; neither a missing tmpfs copy
# nor a divergent kmsg copy may be normalized into success.
metadata_forged_bundle="$tmp_root/metadata-forged-bundle.env"; metadata_for "$metadata_forged_bundle" forged-bundle
assert_status 20 'trusted witness receipt binding mismatch: CAPTURE_MANIFEST_SHA256' \
  capture_attempt "$metadata_forged_bundle" \
  "$tmp_root/20260728T000350Z-forged-bundle" M1_TEST_BUNDLE_FORGE=raw-after-sign
metadata_special_bundle="$tmp_root/metadata-special-bundle.env"; metadata_for "$metadata_special_bundle" special-bundle
assert_status 20 'trusted witness bundle snapshot failed' \
  capture_attempt "$metadata_special_bundle" \
  "$tmp_root/20260728T000355Z-special-bundle" M1_TEST_BUNDLE_SPECIAL=symlink

metadata_cross="$tmp_root/metadata-cross.env"; metadata_for "$metadata_cross" cross
assert_status 20 'trusted capture witness failed' capture_attempt "$metadata_cross" \
  "$tmp_root/20260728T000400Z-cross" M1_TEST_HANDOFF_MISSING=1
metadata_kmsg="$tmp_root/metadata-kmsg.env"; metadata_for "$metadata_kmsg" kmsg
assert_status 20 'trusted witness bundle validation failed' capture_attempt "$metadata_kmsg" \
  "$tmp_root/20260728T000410Z-kmsg" M1_TEST_KMSG_MISMATCH=1
metadata_kmsg_extra="$tmp_root/metadata-kmsg-extra.env"; metadata_for "$metadata_kmsg_extra" kmsg-extra
assert_status 20 'trusted witness bundle validation failed' capture_attempt "$metadata_kmsg_extra" \
  "$tmp_root/20260728T000415Z-kmsg-extra" M1_TEST_KMSG_EXTRA_MALFORMED=1
metadata_newline="$tmp_root/metadata-newline.env"; metadata_for "$metadata_newline" no-newline
assert_status 20 'trusted witness bundle validation failed' capture_attempt "$metadata_newline" \
  "$tmp_root/20260728T000420Z-no-newline" M1_TEST_EVENT_VARIANT=terminal-trailing

# Rootfs selection causally follows the safe userdata probe.  The former prose
# order is now an explicit BLOCKED condition and must never be reconstructed by
# reordering captured events.
metadata_order="$tmp_root/metadata-order.env"; metadata_for "$metadata_order" inverse-order
attempt_order="$tmp_root/20260728T000500Z-inverse-order"
capture_attempt "$metadata_order" "$attempt_order" M1_TEST_EVENT_VARIANT=inverse-order
assert_status 20 'event order conflicts with spec' validate_attempt "$attempt_order"
grep -Fxq 'RESULT=PASS' "$attempt_order/result.env"
grep -Fxq 'FAILURE_PHASE=NONE' "$attempt_order/result.env"
grep -Fxq 'REASON=SIGNED_RAW_CAPTURE_COMPLETED' "$attempt_order/result.env"

# Every §9 semantic proof is required, not just stage names and sequence IDs.
for variant in missing-cmdline-proof bad-root-device unsafe-userdata unsafe-rootfs; do
  metadata_sem="$tmp_root/metadata-$variant.env"; metadata_for "$metadata_sem" "$variant"
  attempt_sem="$tmp_root/20260728T001000Z-$variant"
  capture_attempt "$metadata_sem" "$attempt_sem" M1_TEST_EVENT_VARIANT="$variant"
  assert_status 20 'handoff semantic proof' validate_attempt "$attempt_sem"
done

# The expected-token file is a trusted full-array input, but it may not weaken
# the four mandatory M1 observation tokens.
weak_expected="$tmp_root/weak-expected.txt"
grep -v '^rmx1901.debug_rndis=1$' "$expected" >"$weak_expected"
metadata_weak="$tmp_root/metadata-weak.env"; metadata_for "$metadata_weak" weak-cmdline
attempt_weak="$tmp_root/20260728T001050Z-weak-cmdline"
capture_attempt "$metadata_weak" "$attempt_weak" M1_TEST_CMDLINE_VARIANT=weak
assert_status 30 'required observation token' "$validate" "$attempt_weak" "$weak_expected"

# Recovery identity and boot partition facts use §6's exact observed values.
metadata_identity="$tmp_root/metadata-identity.env"; metadata_for "$metadata_identity" identity
attempt_identity="$tmp_root/20260728T001100Z-identity"
capture_attempt "$metadata_identity" "$attempt_identity" M1_TEST_PREFLIGHT_VARIANT=bringup
assert_status 50 'device identity' validate_attempt "$attempt_identity"
for variant in bad-product bad-device; do
  metadata_identity_bad="$tmp_root/metadata-$variant.env"; metadata_for "$metadata_identity_bad" "$variant"
  attempt_identity_bad="$tmp_root/20260728T001105Z-$variant"
  capture_attempt "$metadata_identity_bad" "$attempt_identity_bad" M1_TEST_PREFLIGHT_VARIANT="$variant"
  assert_status 50 'device identity' validate_attempt "$attempt_identity_bad"
done
metadata_mm="$tmp_root/metadata-mm.env"; metadata_for "$metadata_mm" bad-mm
attempt_mm="$tmp_root/20260728T001110Z-bad-mm"
capture_attempt "$metadata_mm" "$attempt_mm" M1_TEST_PREFLIGHT_VARIANT=bad-mm
assert_status 50 'boot partition' validate_attempt "$attempt_mm"

# Diagnostic SSH product is the spec string, not an implementation nickname.
metadata_diag_bad="$tmp_root/metadata-diag-bad.env"; metadata_for "$metadata_diag_bad" diag-bad
attempt_diag_bad="$tmp_root/20260728T001200Z-diag-bad"
capture_attempt "$metadata_diag_bad" "$attempt_diag_bad" \
  M1_TEST_TRANSPORT_VARIANT=diagnostic-bad-product M1_TEST_PID1_COMM=systemd \
  M1_TEST_PID1_EXE=/lib/systemd/systemd M1_TEST_PID1_CMDLINE=/sbin/init
assert_status 40 'diagnostic product' validate_attempt "$attempt_diag_bad"
metadata_diag="$tmp_root/metadata-diag.env"; metadata_for "$metadata_diag" diagnostic
attempt_diag="$tmp_root/20260728T001210Z-diagnostic"
capture_attempt "$metadata_diag" "$attempt_diag" \
  M1_TEST_TRANSPORT_VARIANT=diagnostic M1_TEST_PID1_COMM=sh \
  M1_TEST_PID1_EXE=/init M1_TEST_PID1_CMDLINE='/bin/sh /init'
validate_attempt "$attempt_diag" | grep -Fxq 'SYSTEMD_CONFIRMED=NO'

metadata_systemd="$tmp_root/metadata-systemd.env"; metadata_for "$metadata_systemd" systemd
attempt_systemd="$tmp_root/20260728T001220Z-systemd"
capture_attempt "$metadata_systemd" "$attempt_systemd" \
  M1_TEST_TRANSPORT_VARIANT=systemd M1_TEST_PID1_COMM=systemd \
  M1_TEST_PID1_EXE=/usr/lib/systemd/systemd \
  M1_TEST_PID1_CMDLINE=/usr/lib/systemd/systemd
validate_attempt "$attempt_systemd" | grep -Fxq 'SYSTEMD_CONFIRMED=YES'

# Write/readback divergence has the dedicated §17.2 exit status.
metadata_readback_bad="$tmp_root/metadata-readback-bad.env"; metadata_for "$metadata_readback_bad" readback-bad
attempt_readback_bad="$tmp_root/20260728T001300Z-readback-bad"
capture_attempt "$metadata_readback_bad" "$attempt_readback_bad" \
  M1_TEST_DEVICE_READBACK=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
assert_status 60 'write/readback' validate_attempt "$attempt_readback_bad"

# Evidence env files are data, never shell fragments.  Reject before signing.
metadata_shell="$tmp_root/metadata-shell.env"; metadata_for "$metadata_shell" shell
sed -i 's/^UNIQUE_VARIABLE=.*/UNIQUE_VARIABLE=$(id)/' "$metadata_shell"
assert_status 10 'shell metacharacter' capture_attempt "$metadata_shell" \
  "$tmp_root/20260728T001400Z-shell"
metadata_shell_evidence="$tmp_root/metadata-shell-evidence.env"; metadata_for "$metadata_shell_evidence" shell-evidence
attempt_shell_evidence="$tmp_root/20260728T001410Z-shell-evidence"
capture_attempt "$metadata_shell_evidence" "$attempt_shell_evidence" M1_TEST_TRANSPORT_VARIANT=shell-product
assert_status 40 'shell metacharacter' validate_attempt "$attempt_shell_evidence"

# A valid signature cannot be edited in the registry, and signer-generated
# sequence state cannot be skipped when claiming two consecutive attempts.
new_trust_context signature-tamper
signed_metadata="$tmp_root/signed.env"; metadata_for "$signed_metadata" signed
signed_attempt="$tmp_root/20260728T001500Z-signed"
capture_attempt "$signed_metadata" "$signed_attempt"
signed_session="$(sed -n 's/^CAPTURE_SESSION=//p' "$signed_attempt/capture-session.env")"
chmod 600 "$registry/receipts/$signed_session.receipt"
sed -i 's/^SIGNER_SEQUENCE=.*/SIGNER_SEQUENCE=99/' "$registry/receipts/$signed_session.receipt"
assert_status 20 'receipt signature is invalid' validate_attempt "$signed_attempt"

new_trust_context skipped-chain
chain_a_meta="$tmp_root/chain-a.env"; metadata_for "$chain_a_meta" chain-a
chain_mid_meta="$tmp_root/chain-mid.env"; metadata_for "$chain_mid_meta" chain-mid
chain_c_meta="$tmp_root/chain-c.env"; metadata_for "$chain_c_meta" chain-c
chain_a="$tmp_root/20260728T001600Z-chain-a"
chain_mid="$tmp_root/20260728T001610Z-chain-mid"
chain_c="$tmp_root/20260728T001620Z-chain-c"
capture_attempt "$chain_a_meta" "$chain_a"
capture_attempt "$chain_mid_meta" "$chain_mid"
capture_attempt "$chain_c_meta" "$chain_c"
assert_status 20 'not one direct host session chain' compare_attempts "$chain_a" "$chain_c"

# Two captures of one kernel boot are not two boot attempts, even when the
# caller changes attempt IDs and directory timestamps.  The signer owns the
# seen-boot registry and refuses to issue the second receipt.
new_trust_context repeated-boot
repeat_a_meta="$tmp_root/repeat-a.env"; metadata_for "$repeat_a_meta" repeat-a
repeat_b_meta="$tmp_root/repeat-b.env"; metadata_for "$repeat_b_meta" repeat-b
repeat_a="$tmp_root/20260728T001700Z-repeat-a"
repeat_b="$tmp_root/20260728T001710Z-repeat-b"
fixed_boot_id=12345678-1234-4123-8123-123456789abc
capture_attempt "$repeat_a_meta" "$repeat_a" M1_TEST_BOOT_ID="$fixed_boot_id"
assert_status 20 'trusted capture witness failed' capture_attempt "$repeat_b_meta" "$repeat_b" \
  M1_TEST_BOOT_ID="$fixed_boot_id"

# Direct-chain pair comparisons cover all static metadata, write/readback,
# preflight, boot/cmdline, transport and every runtime evidence file.
new_trust_context metadata-pair
pair_meta_a="$tmp_root/20260728T002000Z-meta-a"
pair_meta_b="$tmp_root/20260728T002100Z-meta-b"
meta_a="$tmp_root/meta-a.env"; metadata_for "$meta_a" meta-a
meta_b="$tmp_root/meta-b.env"; metadata_for "$meta_b" meta-b \
  1111111111111111111111111111111111111111111111111111111111111111 \
  eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
capture_attempt "$meta_a" "$pair_meta_a"
capture_attempt "$meta_b" "$pair_meta_b"
assert_status 30 'metadata mismatch: SOURCE_TREE_SHA256' compare_attempts "$pair_meta_a" "$pair_meta_b"

new_trust_context readback-pair
pair_read_a="$tmp_root/20260728T002200Z-read-a"
pair_read_b="$tmp_root/20260728T002300Z-read-b"
read_a="$tmp_root/read-a.env"; metadata_for "$read_a" read-a
read_b="$tmp_root/read-b.env"; metadata_for "$read_b" read-b \
  2222222222222222222222222222222222222222222222222222222222222222
capture_attempt "$read_a" "$pair_read_a"
capture_attempt "$read_b" "$pair_read_b" \
  M1_TEST_PREDECESSOR=2222222222222222222222222222222222222222222222222222222222222222
assert_status 60 'write-readback evidence mismatch' compare_attempts "$pair_read_a" "$pair_read_b"

new_trust_context runtime-pair
pair_runtime_a="$tmp_root/20260728T002400Z-runtime-a"
pair_runtime_b="$tmp_root/20260728T002500Z-runtime-b"
runtime_a="$tmp_root/runtime-a.env"; metadata_for "$runtime_a" runtime-a
runtime_b="$tmp_root/runtime-b.env"; metadata_for "$runtime_b" runtime-b
capture_attempt "$runtime_a" "$pair_runtime_a"
capture_attempt "$runtime_b" "$pair_runtime_b" M1_TEST_RUNTIME_JOURNAL='different journal evidence'
assert_status 20 'runtime evidence mismatch: runtime/journal.txt' compare_attempts "$pair_runtime_a" "$pair_runtime_b"

new_trust_context preflight-pair
pair_preflight_a="$tmp_root/20260728T002600Z-preflight-a"
pair_preflight_b="$tmp_root/20260728T002700Z-preflight-b"
preflight_a="$tmp_root/preflight-a.env"; metadata_for "$preflight_a" preflight-a
preflight_b="$tmp_root/preflight-b.env"; metadata_for "$preflight_b" preflight-b
capture_attempt "$preflight_a" "$pair_preflight_a"
capture_attempt "$preflight_b" "$pair_preflight_b" M1_TEST_PREFLIGHT_VARIANT=battery-90
assert_status 50 'preflight evidence mismatch' compare_attempts "$pair_preflight_a" "$pair_preflight_b"

echo 'M1 attempt evidence pure-logic adversarial tests passed (production fixed-root preflight tested separately)'
