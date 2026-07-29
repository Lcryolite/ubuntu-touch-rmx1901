#!/usr/bin/env bash
set -euo pipefail

kernel_tree="${1:?usage: check-kernel-root-markers.sh KERNEL_TREE}"

if git -C "$kernel_tree" grep -niE 'resukisu|sukisu' -- . \
  ':(exclude)tests/test-ubuntu-touch-defconfig.sh'; then
  printf 'error: forbidden root framework marker in pinned kernel\n' >&2
  exit 1
fi
