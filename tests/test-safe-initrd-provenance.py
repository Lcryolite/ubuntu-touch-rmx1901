#!/usr/bin/env python3
import copy
import json
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
METADATA = ROOT / "artifacts/supply-chain/rmx1901-safe-initrd-arm64.provenance.json"
VALIDATOR = ROOT / "scripts/validate-safe-halium-initrd-provenance.py"


def validate(data: dict) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory() as tmp:
        path = pathlib.Path(tmp) / "provenance.json"
        path.write_text(json.dumps(data), encoding="utf-8")
        return subprocess.run(
            [sys.executable, str(VALIDATOR), str(path)],
            text=True,
            capture_output=True,
            check=False,
        )


released = json.loads(METADATA.read_text(encoding="utf-8"))
result = validate(released)
assert result.returncode == 0, result.stderr

# The tracked metadata is the immutable release input.  A staged or otherwise
# non-production status must still be rejected even when the rest of its
# release data is unchanged.
pending = copy.deepcopy(released)
pending["production_status"] = "pending-immutable-release"
result = validate(pending)
assert result.returncode != 0
assert "immutable published release" in result.stderr

# Immutability is a separate release property and must not be inferred from a
# production-looking status alone.
nonimmutable = copy.deepcopy(released)
nonimmutable["release_immutable"] = False
result = validate(nonimmutable)
assert result.returncode != 0
assert "immutable published release" in result.stderr

# A formerly accepted legacy digest must remain rejected even if all release
# fields are made to look production-like.
legacy = copy.deepcopy(released)
legacy.update(
    sha256="ac74c1124cc5cab7b9b42c9a06ca8ff5e14fc2d6e0d7237deb42da8a6788ceca",
    asset_digest="sha256:ac74c1124cc5cab7b9b42c9a06ca8ff5e14fc2d6e0d7237deb42da8a6788ceca",
)
result = validate(legacy)
assert result.returncode != 0
assert "legacy RMX1901 safe initrd input is forbidden" in result.stderr

print("safe initrd fail-closed provenance tests passed")
