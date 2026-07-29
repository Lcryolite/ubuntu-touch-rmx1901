#!/usr/bin/env bash
set -euo pipefail

ADAPTATION_TOOLS_URL='https://gitlab.com/ubports/porting/community-ports/halium-generic-adaptation-build-tools.git'
ADAPTATION_TOOLS_COMMIT='d5838d5c4cf90c7dbece749a451fb14271847dc9'
KERNEL_URL='https://github.com/Lcryolite/kernel_realme_sdm710_ubuntu_touch.git'
KERNEL_COMMIT='a0b817e2e6929cc7e60feeba0f271dd07e7bfa01'

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mapfile -t safe_initrd < <("$repo_root/scripts/require-safe-initrd-release.py")
test "${#safe_initrd[@]}" -eq 3 || {
  printf 'error: invalid immutable RMX1901 safe-initrd release/provenance\n' >&2
  exit 1
}
RAMDISK_URL="${safe_initrd[0]}"
RAMDISK_SHA256="${safe_initrd[1]}"
RAMDISK_SOURCE_COMMIT="${safe_initrd[2]}"
build_dir="$repo_root/workdir"
args=("$@")

for ((index = 0; index < ${#args[@]}; index++)); do
  if test "${args[index]}" = -b; then
    test $((index + 1)) -lt ${#args[@]} || {
      printf 'error: -b requires a directory\n' >&2
      exit 2
    }
    build_dir="${args[index + 1]}"
    break
  fi
done

case "$build_dir" in
  /*) ;;
  *) build_dir="$repo_root/$build_dir" ;;
esac

ensure_checkout() {
  local url="$1" commit="$2" destination="$3"
  if test ! -d "$destination/.git"; then
    test ! -e "$destination" || {
      printf 'error: non-git path blocks pinned checkout: %s\n' "$destination" >&2
      exit 1
    }
    git clone --filter=blob:none --no-checkout "$url" "$destination"
  fi
  test "$(git -C "$destination" remote get-url origin)" = "$url" || {
    printf 'error: unexpected origin for %s\n' "$destination" >&2
    exit 1
  }
  if ! git -C "$destination" cat-file -e "$commit^{commit}" 2>/dev/null; then
    git -C "$destination" fetch --depth=1 origin "$commit"
  fi
  git -C "$destination" checkout --detach "$commit"
  test "$(git -C "$destination" rev-parse HEAD)" = "$commit"
  test -z "$(git -C "$destination" status --porcelain --untracked-files=all)" || {
    printf 'error: pinned checkout is dirty: %s\n' "$destination" >&2
    exit 1
  }
}

mkdir -p "$build_dir/downloads"
ensure_checkout "$ADAPTATION_TOOLS_URL" "$ADAPTATION_TOOLS_COMMIT" "$repo_root/build"
ensure_checkout "$KERNEL_URL" "$KERNEL_COMMIT" "$build_dir/downloads/kernel_realme_sdm710_ubuntu_touch"

"$repo_root/scripts/check-kernel-root-markers.sh" \
  "$build_dir/downloads/kernel_realme_sdm710_ubuntu_touch"

ramdisk="$repo_root/halium-boot-ramdisk.img"
if test -f "$ramdisk" && ! printf '%s  %s\n' "$RAMDISK_SHA256" "$ramdisk" | sha256sum --check --status; then
  printf 'error: existing ramdisk does not match the pinned digest\n' >&2
  exit 1
fi
if test ! -f "$ramdisk"; then
  ramdisk_tmp="$repo_root/.halium-boot-ramdisk.img.download"
  trap 'test ! -f "$ramdisk_tmp" || unlink "$ramdisk_tmp"' EXIT
  curl --fail --location --retry 3 --connect-timeout 20 --output "$ramdisk_tmp" "$RAMDISK_URL"
  printf '%s  %s\n' "$RAMDISK_SHA256" "$ramdisk_tmp" | sha256sum --check --status || {
    printf 'error: downloaded ramdisk digest mismatch\n' >&2
    exit 1
  }
  mv "$ramdisk_tmp" "$ramdisk"
  trap - EXIT
fi

"$repo_root/scripts/stage-build-inputs.sh" "$ramdisk" "$RAMDISK_SHA256" "$build_dir"
# shellcheck disable=SC1091
source "$repo_root/scripts/configure-build-environment.sh" "$build_dir"
"$repo_root/scripts/verify-source-pins.sh" "$build_dir"
cd "$repo_root"
export PATH="$repo_root/scripts/build-tools:$PATH"
exec "$repo_root/build/build.sh" "$@"
