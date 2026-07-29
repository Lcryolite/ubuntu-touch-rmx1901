#!/usr/bin/env python3
import hashlib
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
AUDITOR = ROOT / "scripts/audit-installer-source-tree.py"
FIXTURES = ROOT / "tests/fixtures/installer-audit"

SAFE_TREE_SHA256 = "810036b246c62af05c1fe1048aa05ae8c777b8fd99dcda356ca345e01bc4e08d"


def run_audit(tree: pathlib.Path, digest: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            str(AUDITOR),
            "--tree",
            str(tree),
            "--expected-tree-sha256",
            digest,
        ],
        text=True,
        capture_output=True,
        check=False,
    )


def fixture_digest(tree: pathlib.Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(candidate for candidate in tree.rglob("*") if candidate.is_file()):
        relative = path.relative_to(tree).as_posix().encode("utf-8")
        digest.update(relative + b"\0")
        digest.update(hashlib.sha256(path.read_bytes()).hexdigest().encode("ascii") + b"\n")
    return digest.hexdigest()


python_tools = run_audit(FIXTURES / "safe", SAFE_TREE_SHA256)
assert python_tools.returncode != 0
assert "Python execution cannot be proven safe" in python_tools.stderr
assert fixture_digest(FIXTURES / "safe") == SAFE_TREE_SHA256, "auditor mutated its input tree"

with tempfile.TemporaryDirectory() as tmp:
    shell_safe_tree = pathlib.Path(tmp)
    shutil.copytree(FIXTURES / "safe", shell_safe_tree, dirs_exist_ok=True)
    for tool in ("prepare-fake-ota", "system-image-from-ota"):
        (shell_safe_tree / tool).write_text("#!/bin/sh\nset -eu\n", encoding="utf-8")
    safe = run_audit(shell_safe_tree, fixture_digest(shell_safe_tree))
    assert safe.returncode == 0, safe.stderr
    assert "static report clean" in safe.stdout
    assert "dry-run" in safe.stdout
    assert "host image creation" in safe.stdout
    assert "report_only=yes" in safe.stdout
    assert "execution_authorized=no" in safe.stdout
    assert "final device write plan" not in safe.stdout

wrong_digest = run_audit(FIXTURES / "safe", "0" * 64)
assert wrong_digest.returncode != 0
assert "tree SHA-256 mismatch" in wrong_digest.stderr

for fixture, expected in (
    ("flash-vbmeta.sh", "forbidden fastboot action"),
    ("raw-userdata.sh", "forbidden command: dd"),
    ("repair-and-resize.sh", "forbidden command: e2fsck"),
    ("network-source.sh", "network source is forbidden"),
    ("dynamic-target.sh", "dynamic write target is forbidden"),
    ("legacy-halium-install.sh", "deprecated halium-install is forbidden"),
    ("unpinned-write-source.sh", "write source is not a pinned local file"),
    ("command-substitution.sh", "dynamic shell evaluation is forbidden"),
):
    with tempfile.TemporaryDirectory() as tmp:
        tree = pathlib.Path(tmp)
        shutil.copy2(FIXTURES / "malicious" / fixture, tree / fixture)
        rejected = run_audit(tree, fixture_digest(tree))
        assert rejected.returncode != 0, fixture
        assert expected in rejected.stderr, (fixture, rejected.stderr)

with tempfile.TemporaryDirectory() as tmp:
    empty = pathlib.Path(tmp)
    rejected = run_audit(empty, fixture_digest(empty))
    assert rejected.returncode != 0
    assert "no shell installer evidence" in rejected.stderr

with tempfile.TemporaryDirectory() as tmp:
    tree = pathlib.Path(tmp)
    (tree / "install.sh").write_text("#!/bin/sh\ncp ./rootfs.img /data/rootfs.img\n", encoding="utf-8")
    (tree / "rootfs.img").write_text("fixture\n", encoding="utf-8")
    (tree / "escape.sh").symlink_to("install.sh")
    rejected = run_audit(tree, fixture_digest(tree))
    assert rejected.returncode != 0
    assert "symbolic links are forbidden" in rejected.stderr

with tempfile.TemporaryDirectory() as tmp:
    tree = pathlib.Path(tmp)
    (tree / "install.sh").write_text("#!/bin/sh\ntest -f ./rootfs.img\n", encoding="utf-8")
    os.mkfifo(tree / "runtime-input")
    rejected = run_audit(tree, fixture_digest(tree))
    assert rejected.returncode != 0
    assert "non-regular input is forbidden" in rejected.stderr

with tempfile.TemporaryDirectory() as tmp:
    tree = pathlib.Path(tmp)
    (tree / "install.sh").write_text(
        "#!/bin/sh\n./prepare-fake-ota --output ./out/fake.zip\n", encoding="utf-8"
    )
    (tree / "prepare-fake-ota").write_text(
        "#!/usr/bin/env python3\nimport os\nos.system('fastboot flash vbmeta payload')\n",
        encoding="utf-8",
    )
    rejected = run_audit(tree, fixture_digest(tree))
    assert rejected.returncode != 0
    assert "Python execution cannot be proven safe" in rejected.stderr

for command, expected in (
    ("cp ./rootfs.img /data/rootfs.img", "host write target escapes pinned tree"),
    (
        "adb shell 'cp ./rootfs.img /data/rootfs.img'",
        "adb shell writes are forbidden",
    ),
    (
        "adb shell 'printf attacker-bytes > /data/system.img'",
        "adb shell writes are forbidden",
    ),
    (
        "./prepare-fake-ota --output=/etc/passwd",
        "host write target escapes pinned tree",
    ),
    (
        "./system-image-from-ota --output-dir=/tmp/escape",
        "host write target escapes pinned tree",
    ),
    (
        "cp ./payload ./prepare-fake-ota",
        "host write target is outside dedicated output tree",
    ),
    (
        "env -S'python3 -c print(12345)'",
        "wrapper commands cannot be proven safe",
    ),
    (
        "env --split-string='python3 -c print(12345)'",
        "wrapper commands cannot be proven safe",
    ),
    (
        "adb shell 'printf x >| /data/system.img'",
        "adb shell writes are forbidden",
    ),
    (
        "./prepare-fake-ota -o/etc/passwd",
        "adaptation tool arguments cannot be proven safe",
    ),
    (
        "prepare-fake-ota --output ./out/fake.zip",
        "adaptation tool requires an explicit pinned relative path",
    ),
    (
        "/tmp/fastboot boot ./halium-boot.img",
        "fastboot executable must be exactly fastboot",
    ),
    (
        "./adb push ./rootfs.img /data/rootfs.img",
        "adb executable must be exactly adb",
    ),
    (
        "PATH=./out adb push ./rootfs.img /data/rootfs.img",
        "shell environment assignments cannot be proven safe",
    ),
    (
        "cd /tmp; adb push ./rootfs.img /data/rootfs.img",
        "unrecognized command cannot be proven read-only: cd",
    ),
    (
        "cd /tmp; fastboot boot ./halium-boot.img",
        "unrecognized command cannot be proven read-only: cd",
    ),
    (
        "./printf x > ./out/generated",
        "safe command executable is not approved",
    ),
):
    with tempfile.TemporaryDirectory() as tmp:
        tree = pathlib.Path(tmp)
        (tree / "install.sh").write_text(f"#!/bin/sh\n{command}\n", encoding="utf-8")
        (tree / "rootfs.img").write_text("fixture\n", encoding="utf-8")
        (tree / "halium-boot.img").write_text("fixture\n", encoding="utf-8")
        (tree / "payload").write_bytes(b"ELF malicious fixture\n")
        (tree / "adb").write_bytes(b"ELF opaque adb fixture\n")
        (tree / "printf").write_bytes(b"ELF opaque printf fixture\n")
        for tool in ("prepare-fake-ota", "system-image-from-ota"):
            (tree / tool).write_text("#!/bin/sh\nset -eu\n", encoding="utf-8")
        rejected = run_audit(tree, fixture_digest(tree))
        assert rejected.returncode != 0, command
        assert expected in rejected.stderr, (command, rejected.stderr)

with tempfile.TemporaryDirectory() as tmp:
    tree = pathlib.Path(tmp)
    (tree / "install.sh").write_text("#!/bin/sh\ntest -f ./rootfs.img\n", encoding="utf-8")
    (tree / "rootfs.img").write_text("fixture\n", encoding="utf-8")
    os.link(tree / "rootfs.img", tree / "rootfs-hardlink.img")
    rejected = run_audit(tree, fixture_digest(tree))
    assert rejected.returncode != 0
    assert "hard-linked input is forbidden" in rejected.stderr

for forbidden_command in (
    "flash",
    "erase",
    "format",
    "wipe",
    "mkfs.ext4",
    "fsck.ext4",
    "resize2fs",
    "dd",
    "blkdiscard",
    "sgdisk",
    "parted",
):
    with tempfile.TemporaryDirectory() as tmp:
        tree = pathlib.Path(tmp)
        (tree / "install.sh").write_text(
            f"#!/bin/sh\n{forbidden_command} payload\n", encoding="utf-8"
        )
        rejected = run_audit(tree, fixture_digest(tree))
        assert rejected.returncode != 0, forbidden_command
        assert "forbidden command:" in rejected.stderr, (forbidden_command, rejected.stderr)

for raw_partition in (
    "recovery",
    "vendor",
    "dtbo",
    "vbmeta",
    "persist",
    "modem",
    "userdata",
):
    with tempfile.TemporaryDirectory() as tmp:
        tree = pathlib.Path(tmp)
        (tree / "payload.img").write_text("pinned fixture\n", encoding="utf-8")
        (tree / "install.sh").write_text(
            f"#!/bin/sh\nadb push ./payload.img /dev/block/by-name/{raw_partition}\n",
            encoding="utf-8",
        )
        rejected = run_audit(tree, fixture_digest(tree))
        assert rejected.returncode != 0, raw_partition
        assert "raw device path is forbidden" in rejected.stderr, (
            raw_partition,
            rejected.stderr,
        )

print("rootfs installer audit tests passed")
