#!/usr/bin/python3
"""Descriptor-anchored snapshots for untrusted M1 evidence trees."""

import ctypes
import errno
import os
import secrets
import shutil
import stat
import sys


NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
CLOEXEC = getattr(os, "O_CLOEXEC", 0)
RENAME_NOREPLACE = 1


def fail(message):
    raise SystemExit(f"error: {message}")


def identity(value):
    return (
        value.st_dev, value.st_ino, value.st_mode, value.st_size,
        value.st_mtime_ns, value.st_ctime_ns,
    )


def open_directory(path):
    try:
        before = os.lstat(path)
    except OSError as exc:
        fail(f"cannot lstat source tree: {exc}")
    if not stat.S_ISDIR(before.st_mode):
        fail("source tree must be a non-symlink directory")
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW | CLOEXEC)
    except OSError as exc:
        fail(f"cannot open source tree safely: {exc}")
    opened = os.fstat(descriptor)
    if (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino):
        os.close(descriptor)
        fail("source tree identity changed while opening")
    return descriptor, before


def copy_regular(source_dir_fd, destination_dir_fd, name, observed):
    flags = os.O_RDONLY | NOFOLLOW | CLOEXEC
    try:
        source_fd = os.open(name, flags, dir_fd=source_dir_fd)
    except OSError as exc:
        fail(f"cannot open regular evidence file safely: {name}: {exc}")
    destination_fd = None
    try:
        opened = os.fstat(source_fd)
        if not stat.S_ISREG(opened.st_mode) or identity(opened) != identity(observed):
            fail(f"evidence file identity changed while opening: {name}")
        destination_fd = os.open(
            name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW | CLOEXEC,
            0o600,
            dir_fd=destination_dir_fd,
        )
        copied = 0
        while True:
            chunk = os.read(source_fd, 1024 * 1024)
            if not chunk:
                break
            view = memoryview(chunk)
            while view:
                written = os.write(destination_fd, view)
                if written <= 0:
                    fail(f"short evidence snapshot write: {name}")
                view = view[written:]
            copied += len(chunk)
        os.fsync(destination_fd)
        after_fd = os.fstat(source_fd)
        after_name = os.stat(name, dir_fd=source_dir_fd, follow_symlinks=False)
        if identity(after_fd) != identity(opened) or identity(after_name) != identity(opened):
            fail(f"evidence file changed during snapshot: {name}")
        if copied != opened.st_size or os.fstat(destination_fd).st_size != opened.st_size:
            fail(f"evidence file size changed during snapshot: {name}")
        os.fchmod(destination_fd, 0o400)
    finally:
        os.close(source_fd)
        if destination_fd is not None:
            os.close(destination_fd)


def copy_directory(source_fd, destination_fd, relative=""):
    try:
        names = sorted(os.listdir(source_fd))
    except OSError as exc:
        fail(f"cannot enumerate evidence tree: {exc}")
    observed = {}
    for name in names:
        if name in ("", ".", "..") or "/" in name or "\x00" in name:
            fail("unsafe evidence entry name")
        try:
            item = os.stat(name, dir_fd=source_fd, follow_symlinks=False)
        except OSError as exc:
            fail(f"cannot inspect evidence entry: {name}: {exc}")
        observed[name] = identity(item)
        label = f"{relative}/{name}" if relative else name
        if stat.S_ISREG(item.st_mode):
            copy_regular(source_fd, destination_fd, name, item)
        elif stat.S_ISDIR(item.st_mode):
            os.mkdir(name, 0o700, dir_fd=destination_fd)
            child_source = os.open(
                name, os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW | CLOEXEC,
                dir_fd=source_fd,
            )
            child_destination = os.open(
                name, os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW | CLOEXEC,
                dir_fd=destination_fd,
            )
            try:
                opened = os.fstat(child_source)
                if identity(opened) != identity(item):
                    fail(f"evidence directory identity changed while opening: {label}")
                copy_directory(child_source, child_destination, label)
                after = os.stat(name, dir_fd=source_fd, follow_symlinks=False)
                if identity(after) != identity(opened):
                    fail(f"evidence directory changed during snapshot: {label}")
                os.fchmod(child_destination, 0o500)
            finally:
                os.close(child_source)
                os.close(child_destination)
        else:
            fail(f"evidence entry is not a regular file or directory: {label}")

    if sorted(os.listdir(source_fd)) != names:
        fail("evidence tree entries changed during snapshot")
    for name, wanted in observed.items():
        current = os.stat(name, dir_fd=source_fd, follow_symlinks=False)
        if identity(current) != wanted:
            fail(f"evidence entry changed during snapshot: {name}")


def snapshot_tree(source, destination):
    if os.path.lexists(destination):
        fail("snapshot destination already exists")
    parent = os.path.dirname(destination) or "."
    basename = os.path.basename(destination)
    if basename in ("", ".", "..") or "/" in basename:
        fail("invalid snapshot destination")
    parent_fd, _ = open_directory(parent)
    source_fd, source_before = open_directory(source)
    destination_fd = None
    created = False
    try:
        os.mkdir(basename, 0o700, dir_fd=parent_fd)
        created = True
        destination_fd = os.open(
            basename, os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW | CLOEXEC,
            dir_fd=parent_fd,
        )
        copy_directory(source_fd, destination_fd)
        source_after_fd = os.fstat(source_fd)
        source_after_name = os.lstat(source)
        if (source_before.st_dev, source_before.st_ino) != (source_after_fd.st_dev, source_after_fd.st_ino):
            fail("source tree identity changed during snapshot")
        if (source_before.st_dev, source_before.st_ino) != (source_after_name.st_dev, source_after_name.st_ino):
            fail("source tree path changed during snapshot")
        os.fchmod(destination_fd, 0o500)
        os.fsync(destination_fd)
        os.fsync(parent_fd)
    except BaseException:
        if created:
            shutil.rmtree(destination, ignore_errors=True)
        raise
    finally:
        os.close(source_fd)
        if destination_fd is not None:
            os.close(destination_fd)
        os.close(parent_fd)


def rename_noreplace(parent_fd, source_name, destination_name):
    libc = ctypes.CDLL(None, use_errno=True)
    renameat2 = getattr(libc, "renameat2", None)
    if renameat2 is None:
        fail("renameat2 is unavailable; cannot publish without overwrite")
    result = renameat2(
        ctypes.c_int(parent_fd), ctypes.c_char_p(os.fsencode(source_name)),
        ctypes.c_int(parent_fd), ctypes.c_char_p(os.fsencode(destination_name)),
        ctypes.c_uint(RENAME_NOREPLACE),
    )
    if result != 0:
        value = ctypes.get_errno()
        if value == errno.EEXIST:
            fail("publication destination already exists")
        fail(f"cannot publish evidence tree without overwrite: {os.strerror(value)}")


def publish_tree(source, destination):
    parent = os.path.dirname(destination) or "."
    basename = os.path.basename(destination)
    if basename in ("", ".", "..") or "/" in basename:
        fail("invalid publication destination")
    parent_fd, _ = open_directory(parent)
    stage_name = f".m1-publish-{os.getpid()}-{secrets.token_hex(16)}"
    stage_path = os.path.join(parent, stage_name)
    try:
        snapshot_tree(source, stage_path)
        rename_noreplace(parent_fd, stage_name, basename)
        os.fsync(parent_fd)
    except BaseException:
        shutil.rmtree(stage_path, ignore_errors=True)
        raise
    finally:
        os.close(parent_fd)


def main():
    if len(sys.argv) != 4:
        fail("usage: m1-evidence-snapshot.py snapshot-tree|publish-tree SOURCE DESTINATION")
    command, source, destination = sys.argv[1:]
    if command == "snapshot-tree":
        snapshot_tree(source, destination)
    elif command == "publish-tree":
        publish_tree(source, destination)
    else:
        fail("unknown snapshot command")


if __name__ == "__main__":
    main()
