#!/bin/bash -p
# Install the fixed-root M1 witness control plane.  This command is never run
# by tests; --stage is a non-installing packaging inspection mode.
set -euo pipefail
PATH=/usr/bin:/bin
export PATH
umask 077

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
witness_source="$repo_root/scripts/m1-root-control-witness.py"
adapter_source="$repo_root/scripts/m1-runtime-adapter.py"
profile_generator_source="$repo_root/scripts/m1-preboot-profile-generator.py"
candidate_stager_source="$repo_root/scripts/stage-m1-candidate.py"
predecessor_stager_source="$repo_root/scripts/stage-m1-predecessor.py"
boot_controller_source="$repo_root/scripts/m1-boot-controller.py"
deployment_lock_source="$repo_root/config/m1-deployment-v1.json"
trust_source="$repo_root/scripts/m1-fixed-trust.py"
unit_source="$repo_root/systemd/rmx1901-m1-control.service"

# These digests are release inputs, not caller options.  Update them only as a
# reviewed source change together with the package test.
witness_source_sha=97b5d64791ec193d84ef1297a7ce976b270061c3b716ad3bbf2a58889d9f154d
adapter_source_sha=1dac88b5c77bcc3cfef00ef73fb8f320ba4ec5f44fe40ce89cde9f40764213f2
profile_generator_source_sha=bd5449efbaa9a0bc10a245f0e8d029e204832d1325062b6a0b98eba1c721e4b6
candidate_stager_source_sha=c4cf5c628dc58936ef59d3d3f9f51bf436ce38a569b2dccb5397071db2fd828c
predecessor_stager_source_sha=2fb0979dff731c27225f2af2d3c90b09d3e9d003ecafb91e6505392bcf2bf1b9
boot_controller_source_sha=a917c7648f2b031013933afd140e84e8eb42846cff8568ce8ee0298dd5032d7e
deployment_lock_source_sha=1878845f075f45990f841b1ae84a753227737de3204b36b01b442d1bf01e6a07
trust_source_sha=06afdc6351bce46af13311ef9b1229753297cfc5fe65cff3f64c8a9e8aae3a25
unit_source_sha=ae6f3827b943323770ccbacaab28a41e4bd224cb0e581c97f0dc6bba854e8700

die() { printf '%s\n' "$1" >&2; exit 1; }
usage() { die 'usage: install-m1-root-control-plane.sh --stage ABSOLUTE_DIRECTORY | --install | --upgrade-writer | --upgrade-panic-adapter | --upgrade-witness'; }

test -x "$witness_source" || die 'M1 witness source is missing or not executable'
test -x "$adapter_source" || die 'M1 runtime adapter source is missing or not executable'
test -x "$profile_generator_source" || die 'M1 preboot profile generator source is missing or not executable'
test -x "$candidate_stager_source" || die 'M1 candidate stager source is missing or not executable'
test -x "$predecessor_stager_source" || die 'M1 predecessor stager source is missing or not executable'
test -x "$boot_controller_source" || die 'M1 boot controller source is missing or not executable'
test -f "$deployment_lock_source" || die 'M1 deployment lock source is missing'
test -x "$trust_source" || die 'M1 fixed trust source is missing or not executable'
test -f "$unit_source" || die 'M1 systemd unit source is missing'

safe_stage_parent() {
  /usr/bin/python3 - "$1" <<'PY'
import os, stat, sys
path = os.path.abspath(sys.argv[1])
if path != os.path.normpath(path):
    raise SystemExit("stage parent is not normalized")
fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
try:
    for part in path.split("/")[1:]:
        current = os.stat(part, dir_fd=fd, follow_symlinks=False)
        if stat.S_ISLNK(current.st_mode):
            raise SystemExit("stage parent contains a symlink")
        if not stat.S_ISDIR(current.st_mode):
            raise SystemExit("stage parent is not a directory")
        child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
        os.close(fd)
        fd = child
finally:
    os.close(fd)
PY
}

snapshot_source() {
  local source="$1" destination="$2" wanted="$3"
  /usr/bin/python3 - "$source" "$destination" "$wanted" <<'PY'
import hashlib, os, stat, sys
source, destination, wanted = sys.argv[1:]
before = os.lstat(source)
if not stat.S_ISREG(before.st_mode): raise SystemExit("installer source is not a regular file")
src = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
try:
    opened = os.fstat(src)
    if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns): raise SystemExit("installer source changed while opening")
    dst = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o500)
    try:
        digest = hashlib.sha256()
        while True:
            chunk = os.read(src, 1024 * 1024)
            if not chunk: break
            digest.update(chunk)
            os.write(dst, chunk)
        os.fsync(dst)
    finally: os.close(dst)
    after = os.lstat(source)
    if (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns): raise SystemExit("installer source changed while copying")
    if digest.hexdigest() != wanted: raise SystemExit("installer source fingerprint mismatch")
finally: os.close(src)
PY
}

stage() {
  local destination="$1"
  [[ "$destination" = /* ]] || die 'stage destination must be absolute'
  test ! -e "$destination" && test ! -L "$destination" || die 'stage destination already exists'
  /usr/bin/python3 - "$(dirname "$destination")" "$(basename "$destination")" "$witness_source" "$adapter_source" "$profile_generator_source" "$candidate_stager_source" "$predecessor_stager_source" "$boot_controller_source" "$deployment_lock_source" "$trust_source" "$unit_source" <<'PY' || die 'stage parent contains a symlink, changed during creation, or is unsafe'
import os, stat, sys
parent, base, witness, adapter, generator, stager, predecessor_stager, controller, deployment_lock, trust, unit = sys.argv[1:]
if base in ('', '.', '..') or '/' in base: raise SystemExit(1)
fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
try:
    for part in parent.split('/')[1:]:
        entry = os.stat(part, dir_fd=fd, follow_symlinks=False)
        if not stat.S_ISDIR(entry.st_mode) or stat.S_ISLNK(entry.st_mode): raise SystemExit(1)
        child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
        os.close(fd); fd = child
    os.mkdir(base, 0o700, dir_fd=fd)
    root = os.open(base, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
    try:
        def dirs(rootfd, names, mode):
            current = rootfd
            for name in names:
                os.mkdir(name, mode, dir_fd=current)
                child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=current)
                if current != rootfd: os.close(current)
                current = child
            return current
        lib = dirs(root, ['usr','local','libexec','rmx1901-m1-control'], 0o700)
        etc = dirs(root, ['etc','systemd','system'], 0o755)
        var = dirs(root, ['var','lib','rmx1901-m1-control'], 0o700)
        def copy(src, directory, name, mode):
            source = os.open(src, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
            target = os.open(name, os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW|os.O_CLOEXEC, mode, dir_fd=directory)
            try:
                while True:
                    block = os.read(source, 1048576)
                    if not block: break
                    os.write(target, block)
                os.fsync(target)
            finally: os.close(source); os.close(target)
        copy(witness, lib, 'capture-witness', 0o500)
        copy(adapter, lib, 'runtime-adapter', 0o500)
        copy(generator, lib, 'seal-preboot-profile', 0o500)
        copy(stager, lib, 'stage-m1-candidate', 0o500)
        copy(predecessor_stager, lib, 'stage-m1-predecessor', 0o500)
        copy(controller, lib, 'boot-controller', 0o500)
        copy(deployment_lock, var, 'm1-deployment-v1.json', 0o400)
        copy(trust, lib, 'fixed-trust', 0o500)
        copy(unit, etc, 'rmx1901-m1-control.service', 0o644)
        readme = b'This is a staging-only package inspection tree.  It does not install keys, state, registry, or a witness into the staged persistent trust root, and it cannot be used as an M1 trust root.  Only a reviewed clean root systemd installation service may install this control plane.\n'
        target = os.open('README', os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW|os.O_CLOEXEC, 0o400, dir_fd=var)
        os.write(target, readme); os.fsync(target); os.close(target)
        for item in (lib,etc,var): os.close(item)
    finally: os.close(root)
finally: os.close(fd)
PY
}

install_control_plane() {
  test "$(id -u)" = 0 || die '--install requires host root'
  test "${M1_CONTROL_PLANE_CLEAN_INSTALL:-}" = 1 || die '--install requires the reviewed env -i root launcher'
  test "${PATH:-}" = /usr/bin:/bin || die '--install requires the reviewed fixed PATH'
  for unsafe_var in BASH_ENV ENV LD_PRELOAD LD_LIBRARY_PATH PYTHONHOME PYTHONPATH; do
    test -z "${!unsafe_var:-}" || die '--install rejects dynamic-loader or interpreter environment input'
  done
  test ! -e /var/lib/rmx1901-m1-control || die 'refusing to overwrite an existing M1 control plane'
  test ! -e /usr/local/libexec/rmx1901-m1-control || die 'refusing to overwrite existing M1 control-plane executables'
  test ! -e /etc/systemd/system/rmx1901-m1-control.service || die 'refusing to overwrite existing M1 control-plane unit'

  scratch="$(/usr/bin/mktemp -d /var/tmp/rmx1901-m1-control-source.XXXXXX)"
  trap 'chmod -R u+w "$scratch" 2>/dev/null || true; rm -rf -- "$scratch"' EXIT
  snapshot_source "$witness_source" "$scratch/capture-witness" "$witness_source_sha" || die 'trusted witness source snapshot failed'
  snapshot_source "$adapter_source" "$scratch/runtime-adapter" "$adapter_source_sha" || die 'trusted runtime adapter source snapshot failed'
  snapshot_source "$profile_generator_source" "$scratch/seal-preboot-profile" "$profile_generator_source_sha" || die 'trusted preboot profile generator source snapshot failed'
  snapshot_source "$candidate_stager_source" "$scratch/stage-m1-candidate" "$candidate_stager_source_sha" || die 'trusted candidate stager source snapshot failed'
  snapshot_source "$predecessor_stager_source" "$scratch/stage-m1-predecessor" "$predecessor_stager_source_sha" || die 'trusted predecessor stager source snapshot failed'
  snapshot_source "$boot_controller_source" "$scratch/boot-controller" "$boot_controller_source_sha" || die 'trusted boot controller source snapshot failed'
  snapshot_source "$deployment_lock_source" "$scratch/m1-deployment-v1.json" "$deployment_lock_source_sha" || die 'trusted deployment lock source snapshot failed'
  snapshot_source "$trust_source" "$scratch/fixed-trust" "$trust_source_sha" || die 'trusted fixed-trust source snapshot failed'
  snapshot_source "$unit_source" "$scratch/rmx1901-m1-control.service" "$unit_source_sha" || die 'trusted unit source snapshot failed'

  /usr/bin/install -d -o 0 -g 0 -m 0700 /var/lib/rmx1901-m1-control
  /usr/bin/install -d -o 0 -g 0 -m 0700 /var/lib/rmx1901-m1-control/state /var/lib/rmx1901-m1-control/registry /var/lib/rmx1901-m1-control/registry/receipts
  /usr/bin/install -d -o 0 -g 0 -m 0755 /usr/local/libexec/rmx1901-m1-control
  /usr/bin/install -o 0 -g 0 -m 0500 "$scratch/capture-witness" /usr/local/libexec/rmx1901-m1-control/capture-witness
  /usr/bin/install -o 0 -g 0 -m 0500 "$scratch/runtime-adapter" /usr/local/libexec/rmx1901-m1-control/runtime-adapter
  /usr/bin/install -o 0 -g 0 -m 0500 "$scratch/seal-preboot-profile" /usr/local/libexec/rmx1901-m1-control/seal-preboot-profile
  /usr/bin/install -o 0 -g 0 -m 0500 "$scratch/stage-m1-candidate" /usr/local/libexec/rmx1901-m1-control/stage-m1-candidate
  /usr/bin/install -o 0 -g 0 -m 0500 "$scratch/stage-m1-predecessor" /usr/local/libexec/rmx1901-m1-control/stage-m1-predecessor
  /usr/bin/install -o 0 -g 0 -m 0500 "$scratch/boot-controller" /usr/local/libexec/rmx1901-m1-control/boot-controller
  /usr/bin/install -o 0 -g 0 -m 0400 "$scratch/m1-deployment-v1.json" /var/lib/rmx1901-m1-control/m1-deployment-v1.json
  /usr/bin/install -o 0 -g 0 -m 0500 "$scratch/fixed-trust" /usr/local/libexec/rmx1901-m1-control/fixed-trust
  /usr/bin/sha256sum /usr/local/libexec/rmx1901-m1-control/capture-witness | /usr/bin/awk '{print $1}' > /var/lib/rmx1901-m1-control/capture-witness.sha256
  /usr/bin/sha256sum /usr/local/libexec/rmx1901-m1-control/runtime-adapter | /usr/bin/awk '{print $1}' > /var/lib/rmx1901-m1-control/runtime-adapter.sha256
  /usr/bin/openssl genpkey -algorithm ED25519 -out /var/lib/rmx1901-m1-control/witness-ed25519.pem
  /usr/bin/openssl pkey -in /var/lib/rmx1901-m1-control/witness-ed25519.pem -pubout -out /var/lib/rmx1901-m1-control/witness-ed25519.pub
  chmod 0400 /var/lib/rmx1901-m1-control/witness-ed25519.pem /var/lib/rmx1901-m1-control/capture-witness.sha256 /var/lib/rmx1901-m1-control/runtime-adapter.sha256 /var/lib/rmx1901-m1-control/witness-ed25519.pub
  /usr/bin/sha256sum /var/lib/rmx1901-m1-control/witness-ed25519.pub | /usr/bin/awk '{print $1}' > /var/lib/rmx1901-m1-control/witness-ed25519.sha256
  chmod 0400 /var/lib/rmx1901-m1-control/witness-ed25519.sha256
  /usr/bin/install -o 0 -g 0 -m 0644 "$scratch/rmx1901-m1-control.service" /etc/systemd/system/rmx1901-m1-control.service
  /usr/bin/systemctl daemon-reload
  printf '%s\n' 'installed a fail-closed M1 control plane; no selector is available for capture'
}

upgrade_writer() {
  test "$(id -u)" = 0 || die '--upgrade-writer requires host root'
  test "${M1_CONTROL_PLANE_CLEAN_INSTALL:-}" = 1 || die '--upgrade-writer requires the reviewed env -i root launcher'
  test "${PATH:-}" = /usr/bin:/bin || die '--upgrade-writer requires the reviewed fixed PATH'
  for unsafe_var in BASH_ENV ENV LD_PRELOAD LD_LIBRARY_PATH PYTHONHOME PYTHONPATH; do
    test -z "${!unsafe_var:-}" || die '--upgrade-writer rejects dynamic-loader or interpreter environment input'
  done
  test -x /usr/local/libexec/rmx1901-m1-control/fixed-trust || die 'existing M1 fixed trust is unavailable'
  /usr/local/libexec/rmx1901-m1-control/fixed-trust check || die 'existing M1 fixed trust validation failed'
  scratch="$(/usr/bin/mktemp -d /var/tmp/rmx1901-m1-writer-upgrade.XXXXXX)"
  trap 'chmod -R u+w "$scratch" 2>/dev/null || true; rm -rf -- "$scratch"' EXIT
  snapshot_source "$candidate_stager_source" "$scratch/stage-m1-candidate" "$candidate_stager_source_sha" || die 'trusted candidate stager source snapshot failed'
  snapshot_source "$predecessor_stager_source" "$scratch/stage-m1-predecessor" "$predecessor_stager_source_sha" || die 'trusted predecessor stager source snapshot failed'
  snapshot_source "$boot_controller_source" "$scratch/boot-controller" "$boot_controller_source_sha" || die 'trusted boot controller source snapshot failed'
  snapshot_source "$deployment_lock_source" "$scratch/m1-deployment-v1.json" "$deployment_lock_source_sha" || die 'trusted deployment lock source snapshot failed'
  /usr/bin/install -o 0 -g 0 -m 0500 "$scratch/stage-m1-candidate" /usr/local/libexec/rmx1901-m1-control/stage-m1-candidate
  /usr/bin/install -o 0 -g 0 -m 0500 "$scratch/stage-m1-predecessor" /usr/local/libexec/rmx1901-m1-control/stage-m1-predecessor
  /usr/bin/install -o 0 -g 0 -m 0500 "$scratch/boot-controller" /usr/local/libexec/rmx1901-m1-control/boot-controller
  /usr/bin/install -o 0 -g 0 -m 0400 "$scratch/m1-deployment-v1.json" /var/lib/rmx1901-m1-control/m1-deployment-v1.json
  printf '%s\n' 'upgraded the fixed M1 writer only; no device operation was performed'
}

upgrade_panic_adapter() {
  test "$(id -u)" = 0 || die '--upgrade-panic-adapter requires host root'
  test "${M1_CONTROL_PLANE_CLEAN_INSTALL:-}" = 1 || die '--upgrade-panic-adapter requires the reviewed env -i root launcher'
  test "${PATH:-}" = /usr/bin:/bin || die '--upgrade-panic-adapter requires the reviewed fixed PATH'
  for unsafe_var in BASH_ENV ENV LD_PRELOAD LD_LIBRARY_PATH PYTHONHOME PYTHONPATH; do test -z "${!unsafe_var:-}" || die '--upgrade-panic-adapter rejects dynamic-loader or interpreter environment input'; done
  test -x /usr/local/libexec/rmx1901-m1-control/fixed-trust || die 'existing M1 fixed trust is unavailable'
  /usr/local/libexec/rmx1901-m1-control/fixed-trust check || die 'existing M1 fixed trust validation failed'
  scratch="$(/usr/bin/mktemp -d /var/tmp/rmx1901-m1-adapter-upgrade.XXXXXX)"
  trap 'chmod -R u+w "$scratch" 2>/dev/null || true; rm -rf -- "$scratch"' EXIT
  snapshot_source "$adapter_source" "$scratch/runtime-adapter" "$adapter_source_sha" || die 'trusted runtime adapter source snapshot failed'
  /usr/bin/install -o 0 -g 0 -m 0500 "$scratch/runtime-adapter" /usr/local/libexec/rmx1901-m1-control/runtime-adapter
  /usr/bin/sha256sum /usr/local/libexec/rmx1901-m1-control/runtime-adapter | /usr/bin/awk '{print $1}' > /var/lib/rmx1901-m1-control/runtime-adapter.sha256
  chmod 0400 /var/lib/rmx1901-m1-control/runtime-adapter.sha256
  /usr/local/libexec/rmx1901-m1-control/fixed-trust check || die 'updated M1 fixed trust validation failed'
  printf '%s\n' 'upgraded the fixed M1 panic adapter only; no device operation was performed'
}

upgrade_witness() {
  test "$(id -u)" = 0 || die '--upgrade-witness requires host root'
  test "${M1_CONTROL_PLANE_CLEAN_INSTALL:-}" = 1 || die '--upgrade-witness requires the reviewed env -i root launcher'
  test "${PATH:-}" = /usr/bin:/bin || die '--upgrade-witness requires the reviewed fixed PATH'
  for unsafe_var in BASH_ENV ENV LD_PRELOAD LD_LIBRARY_PATH PYTHONHOME PYTHONPATH; do test -z "${!unsafe_var:-}" || die '--upgrade-witness rejects dynamic-loader or interpreter environment input'; done
  /usr/local/libexec/rmx1901-m1-control/fixed-trust check || die 'existing M1 fixed trust validation failed'
  scratch="$(/usr/bin/mktemp -d /var/tmp/rmx1901-m1-witness-upgrade.XXXXXX)"
  trap 'chmod -R u+w "$scratch" 2>/dev/null || true; rm -rf -- "$scratch"' EXIT
  snapshot_source "$witness_source" "$scratch/capture-witness" "$witness_source_sha" || die 'trusted witness source snapshot failed'
  /usr/bin/install -o 0 -g 0 -m 0500 "$scratch/capture-witness" /usr/local/libexec/rmx1901-m1-control/capture-witness
  /usr/bin/sha256sum /usr/local/libexec/rmx1901-m1-control/capture-witness | /usr/bin/awk '{print $1}' > /var/lib/rmx1901-m1-control/capture-witness.sha256
  chmod 0400 /var/lib/rmx1901-m1-control/capture-witness.sha256
  /usr/local/libexec/rmx1901-m1-control/fixed-trust check || die 'updated M1 fixed trust validation failed'
  printf '%s\n' 'upgraded the fixed M1 witness only; no device operation was performed'
}

if test "$#" -eq 0; then usage; fi
case "$#:$1" in
  2:--stage) stage "$2" ;;
  1:--install) install_control_plane ;;
  1:--upgrade-writer) upgrade_writer ;;
  1:--upgrade-panic-adapter) upgrade_panic_adapter ;;
  1:--upgrade-witness) upgrade_witness ;;
  *) usage ;;
esac
