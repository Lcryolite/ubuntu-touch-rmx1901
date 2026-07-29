#!/usr/bin/env bash
set -euo pipefail

# Catches a regression where the release API URL matcher rejects a real,
# immutable GitHub API URL (for example through over-escaping literal dots).
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
metadata="$repo_root/safe-initrd-release.json"
checker="$repo_root/scripts/require-safe-initrd-release.py"
backup="$(mktemp "$repo_root/.safe-initrd-release-test.XXXXXX")"

cp "$metadata" "$backup"
restore_metadata() {
  cp "$backup" "$metadata"
  rm -f "$backup"
}
trap restore_metadata EXIT

assert_rejected() {
  if "$checker" >/dev/null 2>&1; then
    echo "unsafe release metadata was accepted" >&2
    exit 1
  fi
}

# The repository's checked-in release 360539684 / asset 491633704 is valid.
"$checker" >/dev/null

cp "$backup" "$metadata"
sed -i 's#https://api.github.com/#https://github.invalid/#g' "$metadata"
assert_rejected

cp "$backup" "$metadata"
sed -i 's#/releases/360539684"#/releases/0"#' "$metadata"
assert_rejected

cp "$backup" "$metadata"
sed -i 's#/assets/491633704"#/assets/0"#' "$metadata"
assert_rejected

cp "$backup" "$metadata"
sed -i 's/"production_status": "released"/"production_status": "pending-immutable-release"/' "$metadata"
assert_rejected

cp "$backup" "$metadata"
sed -i 's/3f02a6379313dd14b596d15049130f3a2ba98f3799757c4918515ece6befb5da/ac74c1124cc5cab7b9b42c9a06ca8ff5e14fc2d6e0d7237deb42da8a6788ceca/' "$metadata"
assert_rejected

echo 'safe initrd immutable-release validation tests passed'
