#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$repo_root/scripts/prepare-unprivileged-system-image-script.sh"
wrapper="$repo_root/scripts/system-image-from-ota-unprivileged.sh"
runner="$repo_root/scripts/run-unprivileged-system-image-script.sh"
mkdir -p "$repo_root/workdir"
test_root="$(mktemp -d -p "$repo_root/workdir" unprivileged-system-image-test.XXXXXXXXXX)"
cleanup() {
    local status=$?
    trap - EXIT
    if test -d "$test_root"; then
        if test -x "$runner"; then
            "$runner" /usr/bin/rm -rf -- "$test_root" || status=1
        else
            rm -rf -- "$test_root" || status=1
        fi
    fi
    exit "$status"
}
trap cleanup EXIT

test -x "$helper" || {
    echo 'missing unprivileged transformation helper' >&2
    exit 1
}
test -x "$wrapper" || {
    echo 'missing unprivileged system-image wrapper' >&2
    exit 1
}

upstream="$test_root/system-image-from-ota.sh"
cat > "$upstream" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ARCHIVE="$1"
OUT="$2"
SYSTEM_MOUNTPOINT="$3"
deviceinfo_system_partition_size=16384
mkdir -p "$OUT"
mkdir -p "$SYSTEM_MOUNTPOINT"
xzcat "$ARCHIVE" | tar --numeric-owner -xf - -C "$SYSTEM_MOUNTPOINT"
if test "${FAIL_AFTER_EXTRACT:-false}" = true; then
    exit 23
fi
truncate -s 8M "$OUT/rootfs.img"
printf '%s\n' '/tmp/system-image' > "$RESULT_FILE"
: /tmp/system-image
: /tmp/system-image
: /tmp/system-image
: /tmp/system-image
: /tmp/system-image
: /tmp/system-image
: /tmp/system-image
: /tmp/system-image
: /tmp/system-image
: /tmp/system-image
: /tmp/system-image
: /tmp/system-image
                    LOOPDEV=$(sudo losetup -f) || true
if false; then
    sudo true
    sudo true
    sudo true
    sudo true
    sudo true
    sudo true
    sudo true
    sudo true
    sudo true
fi
test -z "$LOOPDEV"
                        mke2fs -t ext4 -O \^metadata_csum "$OUT/rootfs.img" ${deviceinfo_system_partition_size:-3584M} -d "$SYSTEM_MOUNTPOINT"
EOF
chmod +x "$upstream"

malformed="$test_root/malformed-system-image-from-ota.sh"
sed '0,/: \/tmp\/system-image/d' "$upstream" > "$malformed"
mkdir "$test_root/rejected-scratch"
if "$helper" "$malformed" "$test_root/rejected-scratch/rejected.sh" \
    "$test_root/rejected-scratch" \
    >"$test_root/rejected.stdout" 2>"$test_root/rejected.stderr"; then
    echo 'expected an altered upstream shape to be rejected' >&2
    exit 1
fi
test ! -e "$test_root/rejected-scratch/rejected.sh"
grep -Fq 'unexpected /tmp/system-image shape' "$test_root/rejected.stderr"

missing_mke2fs="$test_root/missing-mke2fs-system-image-from-ota.sh"
grep -Fv 'mke2fs -t ext4 -O \^metadata_csum' "$upstream" > "$missing_mke2fs"
mkdir "$test_root/rejected-mke2fs-scratch"
if "$helper" "$missing_mke2fs" \
    "$test_root/rejected-mke2fs-scratch/rejected-mke2fs.sh" \
    "$test_root/rejected-mke2fs-scratch" \
    >"$test_root/rejected-mke2fs.stdout" 2>"$test_root/rejected-mke2fs.stderr"; then
    echo 'expected a changed mke2fs upstream shape to be rejected' >&2
    exit 1
fi
test ! -e "$test_root/rejected-mke2fs-scratch/rejected-mke2fs.sh"
grep -Fq 'expected exactly one pinned mke2fs fallback, found 0' \
    "$test_root/rejected-mke2fs.stderr"

scratch="$test_root/runtime-scratch"
mkdir "$scratch"
transformed="$scratch/system-image-from-ota.sh"
"$helper" "$upstream" "$transformed" "$scratch"
test -x "$transformed"
if grep -Fq '/tmp/system-image' "$transformed"; then
    echo 'transformed script retained /tmp/system-image' >&2
    exit 1
fi
if grep -Eq '(^|[^[:alnum:]_])sudo([^[:alnum:]_]|$)' "$transformed"; then
    echo 'transformed script retained sudo' >&2
    exit 1
fi
unsafe_mke2fs='                        mke2fs -t ext4 -O \^metadata_csum "$OUT/rootfs.img" ${deviceinfo_system_partition_size:-3584M} -d "$SYSTEM_MOUNTPOINT"'
safe_mke2fs='                        mke2fs -F -t ext4 -O \^metadata_csum,\^orphan_file -d "$SYSTEM_MOUNTPOINT" "$OUT/rootfs.img"'
if test "$(grep -Fxc "$unsafe_mke2fs" "$transformed" || true)" -ne 0; then
    echo 'transformed script retained byte-count-as-block-count mke2fs fallback' >&2
    exit 1
fi
if test "$(grep -Fxc "$safe_mke2fs" "$transformed" || true)" -ne 1; then
    echo 'transformed script is missing the bounded mke2fs fallback' >&2
    exit 1
fi

fake_bin="$test_root/bin"
mkdir "$fake_bin"
cat > "$fake_bin/sudo" <<'EOF'
#!/usr/bin/env bash
touch "$SUDO_CALLED"
exit 99
EOF
chmod +x "$fake_bin/sudo"

result_file="$test_root/result"
sudo_called="$test_root/sudo-called"
test -x "$runner" || {
    echo 'missing user-namespace system-image runner' >&2
    exit 1
}
archive_root="$test_root/archive-root"
fixture_tar="$test_root/fixture.tar"
fixture_archive="$fixture_tar.xz"
fixture_out="$test_root/fixture-out"
mkdir -p "$archive_root/system/locked"
printf 'namespace-readable\n' > "$archive_root/system/locked/payload"
tar --numeric-owner --owner=103 --group=107 --no-recursion \
    -cf "$fixture_tar" -C "$archive_root" system
tar --numeric-owner --owner=32011 --group=32011 --mode=0111 --no-recursion \
    -rf "$fixture_tar" -C "$archive_root" system/locked
tar --numeric-owner --owner=103 --group=107 \
    -rf "$fixture_tar" -C "$archive_root" system/locked/payload
xz "$fixture_tar"
failure_out="$test_root/failure-out"
set +e
RESULT_FILE="$result_file" SUDO_CALLED="$sudo_called" PATH="$fake_bin:$PATH" \
    FAIL_AFTER_EXTRACT=true \
    "$runner" "$transformed" "$fixture_archive" "$failure_out" "$failure_out/tree"
failure_status=$?
set -e
test "$failure_status" -eq 23
test "$(stat -c %u "$failure_out/tree/system")" -ne "$(id -u)"
"$runner" /usr/bin/rm -rf -- "$failure_out/tree"
test ! -e "$failure_out/tree"

RESULT_FILE="$result_file" SUDO_CALLED="$sudo_called" PATH="$fake_bin:$PATH" \
    "$runner" "$transformed" "$fixture_archive" "$fixture_out" "$fixture_out/tree"
test ! -e "$sudo_called"
test "$(cat "$result_file")" = "$scratch"
test "$(stat -c %s "$fixture_out/rootfs.img")" -eq 8388608
if dumpe2fs -h "$fixture_out/rootfs.img" 2>/dev/null |
    grep -Eq '^Filesystem features:.*(^|[[:space:]])orphan_file([[:space:]]|$)'; then
    echo 'rootless fallback re-enabled orphan_file' >&2
    exit 1
fi
if dumpe2fs -h "$fixture_out/rootfs.img" 2>/dev/null |
    grep -Eq '^Filesystem features:.*(^|[[:space:]])metadata_csum([[:space:]]|$)'; then
    echo 'rootless fallback re-enabled metadata_csum' >&2
    exit 1
fi
debugfs -R 'stat /system/locked' "$fixture_out/rootfs.img" 2>/dev/null |
    grep -Eq 'Mode:[[:space:]]+0111'
debugfs -R 'stat /system' "$fixture_out/rootfs.img" 2>/dev/null |
    grep -Eq 'User:[[:space:]]+103[[:space:]]+Group:[[:space:]]+107'
debugfs -R 'stat /system/locked' "$fixture_out/rootfs.img" 2>/dev/null |
    grep -Eq 'User:[[:space:]]+32011[[:space:]]+Group:[[:space:]]+32011'
test "$(debugfs -R 'cat /system/locked/payload' "$fixture_out/rootfs.img" 2>/dev/null)" = \
    'namespace-readable'
"$runner" /usr/bin/rm -rf -- "$fixture_out/tree"
test ! -e "$fixture_out/tree"

tools_dir="$repo_root/build"
expected_tools_commit='d5838d5c4cf90c7dbece749a451fb14271847dc9'
test "$(git -C "$tools_dir" rev-parse HEAD)" = "$expected_tools_commit"
test -z "$(git -C "$tools_dir" status --porcelain --untracked-files=all)"
real_scratch="$test_root/real-upstream-scratch"
mkdir "$real_scratch"
real_transformed="$real_scratch/system-image-from-ota.sh"
"$helper" "$tools_dir/system-image-from-ota.sh" "$real_transformed" "$real_scratch"
test -x "$real_transformed"
! grep -Fq '/tmp/system-image' "$real_transformed"
! grep -Eq '(^|[^[:alnum:]_])sudo([^[:alnum:]_]|$)' "$real_transformed"
test "$(grep -Fxc '                    LOOPDEV=' "$real_transformed")" -eq 1

echo 'unprivileged system-image transformation tests passed'
