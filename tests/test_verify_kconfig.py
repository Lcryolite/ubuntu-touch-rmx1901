#!/usr/bin/env python3
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
VERIFIER = ROOT / "scripts" / "verify-kconfig.py"
FIXTURE = ROOT / "tests" / "fixtures" / "minimal.config"


class VerifyKconfigTest(unittest.TestCase):
    def test_reports_sorted_missing_required_symbols(self):
        result = subprocess.run(
            [sys.executable, str(VERIFIER), str(FIXTURE)],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )

        self.assertEqual(1, result.returncode)
        self.assertEqual(
            "\n".join(
                [
                    "CONFIG_BLK_DEV_LOOP=y",
                    "CONFIG_CC_STACKPROTECTOR_STRONG=y",
                    "CONFIG_CGROUPS=y",
                    "CONFIG_DEVTMPFS=y",
                    "CONFIG_EXT4_FS=y",
                    "CONFIG_FUSE_FS=y",
                    "CONFIG_SECURITY_APPARMOR=y",
                    "CONFIG_TMPFS=y",
                ]
            )
            + "\n",
            result.stdout,
        )

    def test_rejects_enabled_resukisu_config(self):
        config = "\n".join(
            [
                "CONFIG_ANDROID_BINDER_IPC=y",
                "CONFIG_SECURITY_APPARMOR=y",
                "CONFIG_CGROUPS=y",
                "CONFIG_BLK_DEV_LOOP=y",
                "CONFIG_FUSE_FS=y",
                "CONFIG_DEVTMPFS=y",
                "CONFIG_TMPFS=y",
                "CONFIG_EXT4_FS=y",
                "CONFIG_CC_STACKPROTECTOR_STRONG=y",
                "CONFIG_RESUKISU=y",
            ]
        )
        with tempfile.NamedTemporaryFile(mode="w", suffix=".config") as fixture:
            fixture.write(config + "\n")
            fixture.flush()
            result = subprocess.run(
                [sys.executable, str(VERIFIER), fixture.name],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )

        self.assertEqual(1, result.returncode)
        self.assertEqual("forbidden kernel config: CONFIG_RESUKISU=y\n", result.stdout)


if __name__ == "__main__":
    unittest.main()
