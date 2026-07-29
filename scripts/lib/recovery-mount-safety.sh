#!/usr/bin/env bash

# Return success only for a read-only mount whose option list contains a
# standalone `ro` token and no standalone `rw` token.  Filesystem options
# such as `noatime` describe metadata-update policy, not mount writability.
is_read_only_mount_options() {
  local options="$1"
  local option
  local has_ro=0

  test -n "$options" || return 1
  [[ "$options" != *[[:space:]]* ]] || return 1
  IFS=',' read -r -a mount_options <<<"$options"
  for option in "${mount_options[@]}"; do
    test -n "$option" || return 1
    case "$option" in
      ro) has_ro=1 ;;
      rw) return 1 ;;
    esac
  done
  test "$has_ro" -eq 1
}
