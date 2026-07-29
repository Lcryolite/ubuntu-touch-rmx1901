#!/usr/bin/env bash
set -euo pipefail

if test "$#" -ne 3; then
    echo 'usage: prepare-unprivileged-system-image-script.sh SOURCE OUTPUT SCRATCH' >&2
    exit 2
fi

source_script="$1"
output_script="$2"
scratch="$3"
expected_tmp_literals=13
expected_sudo_words=10
expected_loop_line='                    LOOPDEV=$(sudo losetup -f) || true'
expected_mke2fs_line='                        mke2fs -t ext4 -O \^metadata_csum "$OUT/rootfs.img" ${deviceinfo_system_partition_size:-3584M} -d "$SYSTEM_MOUNTPOINT"'
safe_mke2fs_line='                        mke2fs -F -t ext4 -O \^metadata_csum,\^orphan_file -d "$SYSTEM_MOUNTPOINT" "$OUT/rootfs.img"'

test -f "$source_script" && test -r "$source_script" || {
    echo 'error: upstream system-image script is not a readable file' >&2
    exit 1
}
case "$scratch" in
    /*) ;;
    *)
        echo 'error: scratch directory must be an absolute path' >&2
        exit 1
        ;;
esac
case "$scratch" in
    *[!A-Za-z0-9_./-]*)
        echo 'error: scratch directory contains unsupported characters' >&2
        exit 1
        ;;
esac
test -d "$scratch" || {
    echo 'error: scratch directory does not exist' >&2
    exit 1
}
test "$(realpath "$(dirname "$output_script")")" = "$(realpath "$scratch")" || {
    echo 'error: transformed script must be created directly in scratch' >&2
    exit 1
}
test ! -e "$output_script" || {
    echo 'error: refusing to overwrite transformed script' >&2
    exit 1
}

tmp_literal_count="$(awk '{ count += gsub(/\/tmp\/system-image/, "") } END { print count + 0 }' "$source_script")"
test "$tmp_literal_count" -eq "$expected_tmp_literals" || {
    printf 'error: unexpected /tmp/system-image shape: expected %s, found %s\n' \
        "$expected_tmp_literals" "$tmp_literal_count" >&2
    exit 1
}

sudo_word_count="$(grep -Eo '(^|[^[:alnum:]_])sudo([^[:alnum:]_]|$)' "$source_script" | wc -l)"
test "$sudo_word_count" -eq "$expected_sudo_words" || {
    printf 'error: unexpected sudo shape: expected %s, found %s\n' \
        "$expected_sudo_words" "$sudo_word_count" >&2
    exit 1
}

loop_line_count="$(grep -Fxc "$expected_loop_line" "$source_script" || true)"
test "$loop_line_count" -eq 1 || {
    printf 'error: expected exactly one pinned LOOPDEV probe, found %s\n' \
        "$loop_line_count" >&2
    exit 1
}

mke2fs_line_count="$(grep -Fxc "$expected_mke2fs_line" "$source_script" || true)"
test "$mke2fs_line_count" -eq 1 || {
    printf 'error: expected exactly one pinned mke2fs fallback, found %s\n' \
        "$mke2fs_line_count" >&2
    exit 1
}

partial="$scratch/.system-image-from-ota.sh.partial"
trap 'test ! -e "$partial" || rm -f -- "$partial"' EXIT
sed \
    -e "s|/tmp/system-image|$scratch|g" \
    -e 's#^                    LOOPDEV=$(sudo losetup -f) || true$#                    LOOPDEV=#' \
    -e 's|sudo ||g' \
    "$source_script" |
    EXPECTED_MKE2FS_LINE="$expected_mke2fs_line" SAFE_MKE2FS_LINE="$safe_mke2fs_line" \
        awk '$0 == ENVIRON["EXPECTED_MKE2FS_LINE"] { $0 = ENVIRON["SAFE_MKE2FS_LINE"] } { print }' \
        > "$partial"

if grep -Fq '/tmp/system-image' "$partial"; then
    echo 'error: transformed script retained /tmp/system-image' >&2
    exit 1
fi
if grep -Eq '(^|[^[:alnum:]_])sudo([^[:alnum:]_]|$)' "$partial"; then
    echo 'error: transformed script retained sudo' >&2
    exit 1
fi
test "$(grep -Fxc '                    LOOPDEV=' "$partial" || true)" -eq 1 || {
    echo 'error: transformed script does not contain the inert LOOPDEV assignment' >&2
    exit 1
}
test "$(grep -Fxc "$expected_mke2fs_line" "$partial" || true)" -eq 0 || {
    echo 'error: transformed script retained the unsafe mke2fs fallback' >&2
    exit 1
}
test "$(grep -Fxc "$safe_mke2fs_line" "$partial" || true)" -eq 1 || {
    echo 'error: transformed script does not contain the bounded mke2fs fallback' >&2
    exit 1
}

chmod 0755 "$partial"
mv -- "$partial" "$output_script"
trap - EXIT
