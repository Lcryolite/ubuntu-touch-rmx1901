#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 IMAGE_GZ EXTRACT_IKCONFIG" >&2
  exit 2
fi

image_gz=$1
extract_ikconfig=$2

"$extract_ikconfig" "$image_gz" | grep -qx 'CONFIG_DEVTMPFS=y'
"$extract_ikconfig" "$image_gz" | grep -qx 'CONFIG_SECURITY_APPARMOR=y'
