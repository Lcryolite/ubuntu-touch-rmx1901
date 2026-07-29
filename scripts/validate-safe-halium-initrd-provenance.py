#!/usr/bin/env python3
import json
import pathlib
import re
import sys


REPOSITORY = "Lcryolite/initramfs-tools-halium-rmx1901"
LEGACY_SHA256 = {
    "ac74c1124cc5cab7b9b42c9a06ca8ff5e14fc2d6e0d7237deb42da8a6788ceca",
    "b3582e99c21eab2dd2912fc2e1c8c128d9c03fab7147452569d0b2da6bf44e6a",
}


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: validate-safe-halium-initrd-provenance.py METADATA.json")
    path = pathlib.Path(sys.argv[1])
    data = json.loads(path.read_text(encoding="utf-8"))
    required = (
        "repository", "source_branch", "source_commit", "production_status",
        "release_id", "release_tag", "release_target_commitish", "release_api_url",
        "release_immutable", "asset_id", "asset_name", "asset_api_url",
        "asset_size", "asset_digest", "sha256",
    )
    missing = [key for key in required if key not in data]
    if missing:
        raise SystemExit("missing safe initrd provenance fields: " + ", ".join(missing))
    if data["production_status"] != "released" or data["release_immutable"] is not True:
        raise SystemExit("RMX1901 safe initrd requires an immutable published release")
    if data["repository"] != REPOSITORY or data["source_branch"] != "main":
        raise SystemExit("safe initrd provenance has an unexpected source repository")
    if not re.fullmatch(r"[0-9a-f]{40}", data["source_commit"]):
        raise SystemExit("safe initrd provenance has an invalid source commit")
    if data["release_target_commitish"] != data["source_commit"]:
        raise SystemExit("safe initrd release target does not match the source commit")
    if not isinstance(data["release_id"], int) or data["release_id"] <= 0:
        raise SystemExit("safe initrd provenance has an invalid release ID")
    if not isinstance(data["asset_id"], int) or data["asset_id"] <= 0:
        raise SystemExit("safe initrd provenance has an invalid asset ID")
    if not isinstance(data["asset_size"], int) or data["asset_size"] <= 0:
        raise SystemExit("safe initrd provenance has an invalid asset size")
    if data["release_api_url"] != f"https://api.github.com/repos/{REPOSITORY}/releases/{data['release_id']}":
        raise SystemExit("safe initrd provenance has an invalid release API URL")
    if data["asset_api_url"] != f"https://api.github.com/repos/{REPOSITORY}/releases/assets/{data['asset_id']}":
        raise SystemExit("safe initrd provenance has an invalid asset API URL")
    if not re.fullmatch(r"[0-9a-f]{64}", data["sha256"]):
        raise SystemExit("safe initrd provenance has an invalid SHA-256")
    if data["sha256"] in LEGACY_SHA256:
        raise SystemExit("legacy RMX1901 safe initrd input is forbidden")
    if data["asset_digest"] != "sha256:" + data["sha256"]:
        raise SystemExit("safe initrd asset digest does not match SHA-256")
    for value in (
        data["asset_api_url"],
        str(data["asset_id"]),
        str(data["asset_size"]),
        data["sha256"],
        data["asset_name"],
        data["source_commit"],
    ):
        print(value)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
