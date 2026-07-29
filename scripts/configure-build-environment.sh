#!/usr/bin/env bash

build_dir="${1:?usage: source configure-build-environment.sh BUILD_DIR}"
export TMPDIR="$build_dir/compiler-tmp"
mkdir -p "$TMPDIR"
