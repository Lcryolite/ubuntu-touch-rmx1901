#!/usr/bin/env python3
"""Verify that the official Halium patch series is complete and ordered."""

from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path


PORT_ROOT = Path(__file__).resolve().parents[1]
HALIUM_ROOT = Path(os.environ.get("HALIUM_ROOT", "/home/lknife/android/rmx1901-halium11"))
LOCK = PORT_ROOT / "artifacts/product-audit/halium-patchset.lock.tsv"
PATCHSET_REVISION = "0b07bd1d2f0a8468b2b101bddfc9c4cba14edde0"


def git(repo: Path, *args: str, input_bytes: bytes | None = None) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        input=input_bytes,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode:
        detail = result.stderr.decode().strip()
        raise SystemExit(f"git {' '.join(args)} failed in {repo}: {detail}")
    return result.stdout.decode().strip()


def patch_id(data: bytes) -> str:
    result = subprocess.run(
        ["git", "patch-id", "--stable"],
        input=data,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    )
    output = result.stdout.decode().strip()
    if not output:
        raise SystemExit("git patch-id produced no output")
    return output.split()[0]


def records() -> list[tuple[str, str, str, int]]:
    rows = []
    for raw in LOCK.read_text(encoding="utf-8").splitlines():
        if not raw or raw.startswith("#"):
            continue
        path, base, head, count = raw.split("\t")
        rows.append((path, base, head, int(count)))
    return rows


patch_root = HALIUM_ROOT / "hybris-patches"
if git(patch_root, "rev-parse", "HEAD") != PATCHSET_REVISION:
    raise SystemExit("hybris-patches checkout differs from the audited revision")
if git(patch_root, "status", "--porcelain"):
    raise SystemExit("hybris-patches worktree is not clean")

tree_paths = git(
    patch_root, "ls-tree", "-r", "--name-only", PATCHSET_REVISION
).splitlines()
official_paths = sorted(path for path in tree_paths if path.endswith(".patch"))
official_repositories = {str(Path(path).parent) for path in official_paths}

rows = records()
if len(rows) != 14:
    raise SystemExit(f"expected 14 patched repositories, found {len(rows)}")
locked_repositories = [row[0] for row in rows]
if len(set(locked_repositories)) != len(locked_repositories):
    raise SystemExit("patchset lock contains duplicate repository paths")
if set(locked_repositories) != official_repositories:
    raise SystemExit(
        "patchset lock repository set differs from the official revision: "
        f"lock={sorted(locked_repositories)}, official={sorted(official_repositories)}"
    )

total = 0
for relative, base, expected_head, expected_count in rows:
    repo = HALIUM_ROOT / relative
    actual_head = git(repo, "rev-parse", "HEAD")
    if actual_head != expected_head:
        raise SystemExit(f"{relative}: HEAD {actual_head} != lock {expected_head}")
    if git(repo, "status", "--porcelain"):
        raise SystemExit(f"{relative}: worktree is not clean")

    patches = [
        path for path in official_paths if str(Path(path).parent) == relative
    ]
    commits = git(repo, "rev-list", "--reverse", f"{base}..{expected_head}").splitlines()
    if len(patches) != expected_count or len(commits) != expected_count:
        raise SystemExit(
            f"{relative}: expected {expected_count}, found {len(patches)} patches "
            f"and {len(commits)} commits"
        )

    direct_base = git(repo, "rev-parse", f"{expected_head}~{expected_count}")
    if direct_base != base:
        raise SystemExit(f"{relative}: patch commits are not directly based on {base}")
    ancestry = git(repo, "rev-list", "--parents", f"{base}..{expected_head}").splitlines()
    if any(len(line.split()) != 2 for line in ancestry):
        raise SystemExit(f"{relative}: patch segment contains a merge commit")

    if relative == "frameworks/av":
        prefixes = [Path(path).name[:4] for path in patches]
        expected_prefixes = [f"{number:04d}" for number in range(1, 12)]
        if prefixes != expected_prefixes:
            raise SystemExit("frameworks/av patch sequence is not exactly 0001 through 0011")

    for patch, commit in zip(patches, commits, strict=True):
        official_patch = subprocess.check_output(
            ["git", "-C", str(patch_root), "show", f"{PATCHSET_REVISION}:{patch}"]
        )
        expected_id = patch_id(official_patch)
        commit_diff = subprocess.check_output(
            ["git", "-C", str(repo), "show", "--pretty=format:", commit]
        )
        actual_id = patch_id(commit_diff)
        if actual_id != expected_id:
            raise SystemExit(
                f"{relative}: {Path(patch).name} does not match ordered commit {commit}"
            )
    total += expected_count

if total != 61:
    raise SystemExit(f"expected 61 official patches, found {total}")

print("Halium patchset contract tests passed: 61 patches across 14 repositories")
