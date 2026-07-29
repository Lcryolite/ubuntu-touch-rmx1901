#!/usr/bin/env bash
set -euo pipefail

test "$#" -ge 1 || {
    echo 'usage: run-unprivileged-system-image-script.sh SCRIPT [ARGUMENT ...]' >&2
    exit 2
}
test -x "$1" || {
    echo 'error: transformed system-image script is not executable' >&2
    exit 1
}
command -v unshare >/dev/null || {
    echo 'error: unshare is required for rootless system-image creation' >&2
    exit 1
}
command -v newuidmap >/dev/null || {
    echo 'error: newuidmap is required for subordinate-ID mapping' >&2
    exit 1
}
command -v newgidmap >/dev/null || {
    echo 'error: newgidmap is required for subordinate-ID mapping' >&2
    exit 1
}

user_name="$(id -un)"
subuid_start="$(awk -F: -v user="$user_name" \
    '$1 == user && $3 >= 65535 { print $2; exit }' /etc/subuid)"
subgid_start="$(awk -F: -v user="$user_name" \
    '$1 == user && $3 >= 65535 { print $2; exit }' /etc/subgid)"
case "$subuid_start:$subgid_start" in
    *[!0-9:]*|:|*:)
        echo 'error: a subordinate uid/gid range of at least 65535 is required' >&2
        exit 1
        ;;
esac

exec unshare --map-root-user \
    --map-users "1:$subuid_start:65535" \
    --map-groups "1:$subgid_start:65535" \
    -- "$@"
