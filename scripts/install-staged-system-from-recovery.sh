#!/usr/bin/env bash
set -euo pipefail

# This former M0--M3 installer is intentionally retired.  It previously
# streamed an image to the system partition from Recovery; that operation is
# not authorised until a versioned, independently reviewed flashing design is
# introduced.  Refuse before resolving ADB or inspecting any device state.
printf 'mode=retired-no-system-writer\n' >&2
printf 'result=refused\n' >&2
printf 'error=staged system partition writes are permanently disabled\n' >&2
exit 1
