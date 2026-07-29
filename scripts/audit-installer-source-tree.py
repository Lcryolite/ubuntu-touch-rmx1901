#!/usr/bin/env python3
"""Fail-closed static audit for a user-pinned rootfs/adaptation source tree."""

from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import re
import shlex
import sys
from dataclasses import dataclass


ALLOWED_DEVICE_WRITES = frozenset({"/data/rootfs.img", "/data/system.img"})
HOST_OUTPUT_DIRECTORY = "out"
NETWORK_COMMANDS = frozenset(
    {"aria2c", "curl", "ftp", "git", "nc", "ncat", "netcat", "repo", "scp", "sftp", "ssh", "wget"}
)
FORBIDDEN_EXACT = frozenset(
    {
        "blkdiscard",
        "dd",
        "erase",
        "flash",
        "format",
        "halium-install",
        "parted",
        "sgdisk",
        "wipe",
        "wipefs",
    }
)
SAFE_COMMANDS = frozenset(
    {
        ":",
        "[",
        "basename",
        "dirname",
        "echo",
        "exit",
        "false",
        "printf",
        "pwd",
        "readlink",
        "return",
        "set",
        "sha256sum",
        "shift",
        "stat",
        "test",
        "true",
    }
)
SHELL_SUFFIXES = frozenset({".sh", ".bash", ".dash", ".ash", ".ksh", ".zsh"})
ADAPTATION_TOOLS = frozenset(
    {
        "prepare-fake-ota",
        "prepare-fake-ota.py",
        "prepare-fake-ota.sh",
        "system-image-from-ota",
        "system-image-from-ota.py",
        "system-image-from-ota.sh",
    }
)
SHELL_SHEBANG = re.compile(rb"^#![^\n]*(?:^|[/ ])(?:ba|da|a|k|z)?sh(?:\s|$)")
URL = re.compile(r"(?:https?|ftp)://|git(?:\+ssh)?://", re.IGNORECASE)
VARIABLE = re.compile(r"\$|`|\$\(")
CONTROL = frozenset({";", "&&", "||", "|", "&"})


@dataclass(frozen=True)
class Finding:
    path: pathlib.Path
    line: int
    message: str

    def render(self, root: pathlib.Path) -> str:
        return f"{self.path.relative_to(root)}:{self.line}: {self.message}"


def tree_files(root: pathlib.Path) -> tuple[list[pathlib.Path], list[Finding]]:
    files: list[pathlib.Path] = []
    findings: list[Finding] = []
    for directory, names, filenames in os.walk(root, followlinks=False):
        base = pathlib.Path(directory)
        for name in sorted(names + filenames):
            candidate = base / name
            if candidate.is_symlink():
                findings.append(Finding(candidate, 0, "symbolic links are forbidden in pinned input trees"))
            elif candidate.is_file():
                if candidate.stat(follow_symlinks=False).st_nlink != 1:
                    findings.append(Finding(candidate, 0, "hard-linked input is forbidden in pinned input trees"))
                else:
                    files.append(candidate)
            elif not candidate.is_dir():
                findings.append(Finding(candidate, 0, "non-regular input is forbidden in pinned input trees"))
    return sorted(files), findings


def tree_sha256(root: pathlib.Path, files: list[pathlib.Path]) -> str:
    digest = hashlib.sha256()
    for path in files:
        relative = path.relative_to(root).as_posix().encode("utf-8")
        digest.update(relative + b"\0")
        digest.update(hashlib.sha256(path.read_bytes()).hexdigest().encode("ascii") + b"\n")
    return digest.hexdigest()


def is_shell_script(path: pathlib.Path) -> bool:
    if path.suffix.lower() in SHELL_SUFFIXES:
        return True
    with path.open("rb") as stream:
        return bool(SHELL_SHEBANG.match(stream.readline(512)))


def is_python_script(path: pathlib.Path) -> bool:
    if path.suffix.lower() == ".py":
        return True
    with path.open("rb") as stream:
        return b"python" in stream.readline(512).lower()


def command_segments(line: str) -> list[list[str]]:
    lexer = shlex.shlex(line, posix=True, punctuation_chars=";&|<>")
    lexer.whitespace_split = True
    lexer.commenters = "#"
    segments: list[list[str]] = [[]]
    for token in lexer:
        if token in CONTROL:
            if segments[-1]:
                segments.append([])
        else:
            segments[-1].append(token)
    return [segment for segment in segments if segment]


def command_name(tokens: list[str]) -> tuple[str, list[str]]:
    remaining = list(tokens)
    while remaining and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", remaining[0]):
        remaining.pop(0)
    if not remaining:
        return "", []
    return pathlib.PurePosixPath(remaining[0]).name, remaining


def is_output_redirection(token: str) -> bool:
    return ">" in token and re.fullmatch(r"[<>&|]+", token) is not None


def dangerous_name(name: str) -> bool:
    return (
        name in FORBIDDEN_EXACT
        or name.startswith("mkfs")
        or name.startswith("fsck")
        or name.endswith("fsck")
        or name.startswith("resize")
    )


def local_path_is_pinned(root: pathlib.Path, raw: str, *, must_exist: bool) -> bool:
    if VARIABLE.search(raw) or URL.search(raw):
        return False
    candidate = pathlib.Path(raw)
    if candidate.is_absolute():
        return False
    resolved = (root / candidate).resolve(strict=False)
    try:
        resolved.relative_to(root)
    except ValueError:
        return False
    return not must_exist or resolved.is_file()


def validate_write_target(root: pathlib.Path, raw: str, *, context: str) -> str | None:
    if VARIABLE.search(raw):
        return "dynamic write target is forbidden"
    if context == "device":
        return f"adb shell writes are forbidden: {raw}"
    if pathlib.Path(raw).is_absolute() or not local_path_is_pinned(root, raw, must_exist=False):
        return f"host write target escapes pinned tree: {raw}"
    resolved = (root / raw).resolve(strict=False)
    relative = resolved.relative_to(root)
    if not relative.parts or relative.parts[0] != HOST_OUTPUT_DIRECTORY:
        return f"host write target is outside dedicated output tree: {raw}"
    return None


def audit_segment(
    root: pathlib.Path,
    path: pathlib.Path,
    line_number: int,
    tokens: list[str],
    *,
    context: str = "host",
) -> list[Finding]:
    findings: list[Finding] = []
    if any("$(" in token or "`" in token for token in tokens):
        return [Finding(path, line_number, "dynamic shell evaluation is forbidden")]
    if tokens and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", tokens[0]):
        return [Finding(path, line_number, "shell environment assignments cannot be proven safe")]
    name, command = command_name(tokens)
    if not name:
        return findings
    if name in {"command", "env", "sudo"}:
        return [Finding(path, line_number, "wrapper commands cannot be proven safe")]
    if name in NETWORK_COMMANDS or any(URL.search(token) for token in command):
        return [Finding(path, line_number, "network source is forbidden")]
    if name == "halium-install":
        return [Finding(path, line_number, "deprecated halium-install is forbidden")]
    if dangerous_name(name):
        return [Finding(path, line_number, f"forbidden command: {name}")]
    if any(token.startswith("/dev/") for token in command[1:]):
        return [Finding(path, line_number, "raw device path is forbidden")]

    for index, token in enumerate(command):
        if is_output_redirection(token):
            if index + 1 >= len(command):
                findings.append(Finding(path, line_number, "write redirection has no target"))
                continue
            message = validate_write_target(root, command[index + 1], context=context)
            if message:
                findings.append(Finding(path, line_number, message))

    if name == "fastboot":
        if command[0] != "fastboot":
            findings.append(Finding(path, line_number, "fastboot executable must be exactly fastboot"))
        elif context != "host":
            findings.append(Finding(path, line_number, "fastboot is forbidden inside adb shell"))
        elif len(command) != 3 or command[1] != "boot":
            findings.append(Finding(path, line_number, "forbidden fastboot action; only transient fastboot boot is allowed"))
        elif not local_path_is_pinned(root, command[2], must_exist=True):
            findings.append(Finding(path, line_number, "fastboot boot image is not a pinned local file"))
        return findings

    if name == "adb":
        if command[0] != "adb":
            findings.append(Finding(path, line_number, "adb executable must be exactly adb"))
        elif len(command) == 4 and command[1] == "push":
            if not local_path_is_pinned(root, command[2], must_exist=True):
                findings.append(Finding(path, line_number, "adb push source is not a pinned local file"))
            target = command[3]
            if target not in ALLOWED_DEVICE_WRITES:
                message = (
                    "raw device path is forbidden"
                    if target.startswith("/dev/")
                    else f"device write target is not allowlisted: {target}"
                )
                findings.append(Finding(path, line_number, message))
        elif len(command) >= 3 and command[1] == "shell":
            nested = " ".join(command[2:])
            try:
                for segment in command_segments(nested):
                    findings.extend(
                        audit_segment(root, path, line_number, segment, context="device")
                    )
            except ValueError as error:
                findings.append(Finding(path, line_number, f"unparseable adb shell command: {error}"))
        else:
            findings.append(Finding(path, line_number, "adb action cannot be proven safe"))
        return findings

    if name in {"cp", "install", "mv"}:
        operands: list[str] = []
        arguments = iter(command[1:])
        for token in arguments:
            if token == "--":
                operands.extend(arguments)
                break
            if name == "install" and token in {"-g", "-m", "-o", "-t"}:
                next(arguments, None)
            elif not token.startswith("-"):
                operands.append(token)
        if len(operands) < 2:
            findings.append(Finding(path, line_number, f"{name} write target cannot be determined"))
        else:
            for source in operands[:-1]:
                if not local_path_is_pinned(root, source, must_exist=True):
                    findings.append(Finding(path, line_number, "write source is not a pinned local file"))
            message = validate_write_target(root, operands[-1], context=context)
            if message:
                findings.append(Finding(path, line_number, message))
        return findings

    if name == "mkdir":
        operands = [token for token in command[1:] if not token.startswith("-")]
        for target in operands:
            message = validate_write_target(root, target, context=context)
            if message:
                findings.append(Finding(path, line_number, message))
        return findings

    if name in {"python", "python3"}:
        findings.append(Finding(path, line_number, "Python execution cannot be proven safe"))
        return findings

    if name in ADAPTATION_TOOLS:
        if context != "host":
            findings.append(Finding(path, line_number, "adaptation tools are forbidden inside adb shell"))
            return findings
        tool = command[0]
        if tool != f"./{name}":
            findings.append(
                Finding(path, line_number, "adaptation tool requires an explicit pinned relative path")
            )
        elif not local_path_is_pinned(root, tool, must_exist=True):
            findings.append(Finding(path, line_number, "adaptation tool is not a pinned local file"))
        else:
            resolved_tool = (root / tool).resolve(strict=True)
            if resolved_tool.parent != root:
                findings.append(Finding(path, line_number, "adaptation tool must be at pinned tree root"))
            elif not is_shell_script(resolved_tool) or is_python_script(resolved_tool):
                findings.append(Finding(path, line_number, "Python execution cannot be proven safe"))
        output_target: str | None = None
        if len(command) == 3 and command[1] in {"-o", "--output", "--output-dir"}:
            output_target = command[2]
        elif len(command) == 2 and any(
            command[1].startswith(prefix) for prefix in ("--output=", "--output-dir=")
        ):
            output_target = command[1].split("=", 1)[1]
        else:
            findings.append(
                Finding(path, line_number, "adaptation tool arguments cannot be proven safe")
            )
        if output_target is not None:
            message = validate_write_target(root, output_target, context="host")
            if message:
                findings.append(Finding(path, line_number, message))
        return findings

    if name in SAFE_COMMANDS and command[0] != name:
        findings.append(Finding(path, line_number, "safe command executable is not approved"))
    elif name not in SAFE_COMMANDS:
        findings.append(Finding(path, line_number, f"unrecognized command cannot be proven read-only: {name}"))
    return findings


def audit_script(root: pathlib.Path, path: pathlib.Path) -> list[Finding]:
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return [Finding(path, 0, "shell evidence is not valid UTF-8")]
    findings: list[Finding] = []
    logical = text.replace("\\\n", " ")
    for line_number, line in enumerate(logical.splitlines(), start=1):
        if line_number == 1 and line.startswith("#!"):
            continue
        try:
            for segment in command_segments(line):
                findings.extend(audit_segment(root, path, line_number, segment))
        except ValueError as error:
            findings.append(Finding(path, line_number, f"unparseable shell syntax: {error}"))
    return findings


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tree", required=True, type=pathlib.Path)
    parser.add_argument("--expected-tree-sha256", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = args.tree.resolve(strict=False)
    if not root.is_dir():
        print("input tree is missing", file=sys.stderr)
        return 1
    if not re.fullmatch(r"[0-9a-f]{64}", args.expected_tree_sha256):
        print("expected tree SHA-256 must be 64 lowercase hexadecimal characters", file=sys.stderr)
        return 1

    files, findings = tree_files(root)
    if findings:
        for finding in findings:
            print(finding.render(root), file=sys.stderr)
        return 1
    actual = tree_sha256(root, files)
    if actual != args.expected_tree_sha256:
        print(f"tree SHA-256 mismatch: expected {args.expected_tree_sha256}, got {actual}", file=sys.stderr)
        return 1

    scripts = [path for path in files if is_shell_script(path)]
    if not scripts:
        print("no shell installer evidence found; refusing incomplete audit", file=sys.stderr)
        return 1
    for script in scripts:
        findings.extend(audit_script(root, script))
    for python_path in (path for path in files if is_python_script(path)):
        findings.append(Finding(python_path, 1, "Python execution cannot be proven safe"))
    final_files, final_tree_findings = tree_files(root)
    findings.extend(final_tree_findings)
    if final_files != files or tree_sha256(root, final_files) != actual:
        findings.append(Finding(root, 0, "input tree changed during audit"))
    if findings:
        for finding in findings:
            print(finding.render(root), file=sys.stderr)
        return 1

    print(f"static report clean (dry-run): {len(files)} pinned files, {len(scripts)} shell scripts")
    print("host image creation: pinned prepare-fake-ota/system-image-from-ota calls only")
    print("report_only=yes")
    print("execution_authorized=no")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
