#!/usr/bin/python3
"""Race-resistant regular-file snapshot, verification, and publication."""

import hashlib
import os
import secrets
import stat
import sys


CHUNK_SIZE = 1024 * 1024
NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
CLOEXEC = getattr(os, "O_CLOEXEC", 0)


def fail(message: str) -> "None":
    raise SystemExit(f"error: {message}")


def parse_size(value: str):
    if value == "-":
        return None
    try:
        parsed = int(value)
    except ValueError:
        fail("invalid expected file size")
    if parsed < 0:
        fail("invalid expected file size")
    return parsed


def parse_digest(value: str):
    if value == "-":
        return None
    if len(value) != 64 or any(c not in "0123456789abcdef" for c in value):
        fail("invalid expected SHA-256")
    return value


def open_source(path: str):
    try:
        before = os.lstat(path)
    except OSError as exc:
        fail(f"cannot lstat source: {exc}")
    if not stat.S_ISREG(before.st_mode):
        fail("source must be a non-symlink regular file")
    try:
        fd = os.open(path, os.O_RDONLY | NOFOLLOW | CLOEXEC)
    except OSError as exc:
        fail(f"cannot open source without following symlinks: {exc}")
    opened = os.fstat(fd)
    if not stat.S_ISREG(opened.st_mode):
        os.close(fd)
        fail("opened source is not a regular file")
    if (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino):
        os.close(fd)
        fail("source identity changed while opening")
    return fd, opened


def check_open_source(path: str, fd: int, opened, digest: str, expected_size, expected_digest):
    after = os.fstat(fd)
    try:
        named = os.lstat(path)
    except OSError as exc:
        fail(f"source path disappeared after read: {exc}")
    identity = (opened.st_dev, opened.st_ino)
    if identity != (after.st_dev, after.st_ino) or identity != (named.st_dev, named.st_ino):
        fail("source path identity changed after snapshot")
    if opened.st_size != after.st_size or opened.st_size != named.st_size:
        fail("source size changed after snapshot")
    if expected_size is not None and after.st_size != expected_size:
        fail("source size does not match expected value")
    if expected_digest is not None and digest != expected_digest:
        fail("source SHA-256 does not match expected value")


def open_destination_exclusive(path: str):
    parent = os.path.dirname(path) or "."
    name = os.path.basename(path)
    if name in ("", ".", "..") or "/" in name:
        fail("invalid destination basename")
    try:
        parent_fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW | CLOEXEC)
    except OSError as exc:
        fail(f"cannot open destination parent safely: {exc}")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW | CLOEXEC
    try:
        fd = os.open(name, flags, 0o600, dir_fd=parent_fd)
    except OSError as exc:
        os.close(parent_fd)
        fail(f"cannot create destination exclusively: {exc}")
    created = os.fstat(fd)
    return parent_fd, name, fd, created


def safe_unlink(parent_fd: int, name: str, created) -> None:
    try:
        current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except OSError:
        return
    if (current.st_dev, current.st_ino) == (created.st_dev, created.st_ino):
        try:
            os.unlink(name, dir_fd=parent_fd)
        except OSError:
            pass


def copy_open_file(source_fd: int, destination_fd: int):
    digest = hashlib.sha256()
    size = 0
    while True:
        chunk = os.read(source_fd, CHUNK_SIZE)
        if not chunk:
            break
        digest.update(chunk)
        view = memoryview(chunk)
        while view:
            written = os.write(destination_fd, view)
            if written <= 0:
                fail("short destination write")
            view = view[written:]
        size += len(chunk)
    return size, digest.hexdigest()


def snapshot(source: str, destination: str, expected_size, expected_digest):
    source_fd, opened = open_source(source)
    parent_fd = name = destination_fd = created = None
    try:
        parent_fd, name, destination_fd, created = open_destination_exclusive(destination)
        size, digest = copy_open_file(source_fd, destination_fd)
        os.fsync(destination_fd)
        copied = os.fstat(destination_fd)
        if copied.st_size != size:
            fail("snapshot destination size mismatch")
        check_open_source(source, source_fd, opened, digest, expected_size, expected_digest)
        os.fchmod(destination_fd, 0o600)
        return digest
    except BaseException:
        if parent_fd is not None and created is not None:
            safe_unlink(parent_fd, name, created)
        raise
    finally:
        os.close(source_fd)
        if destination_fd is not None:
            os.close(destination_fd)
        if parent_fd is not None:
            os.close(parent_fd)


def verify(path: str, expected_size, expected_digest):
    fd, opened = open_source(path)
    try:
        digest = hashlib.sha256()
        size = 0
        while True:
            chunk = os.read(fd, CHUNK_SIZE)
            if not chunk:
                break
            digest.update(chunk)
            size += len(chunk)
        value = digest.hexdigest()
        if size != opened.st_size:
            fail("verified byte count does not match opened size")
        check_open_source(path, fd, opened, value, expected_size, expected_digest)
        return value
    finally:
        os.close(fd)


def publish(source: str, destination: str, expected_size, expected_digest):
    # Copy from an opened source descriptor into a random same-directory
    # staging inode, verify it, and only then atomically hard-link it to the
    # final name.  link(2) is the no-overwrite publication primitive here.
    source_fd, opened = open_source(source)
    parent = os.path.dirname(destination) or "."
    name = os.path.basename(destination)
    if name in ("", ".", "..") or "/" in name:
        os.close(source_fd)
        fail("invalid destination basename")
    parent_fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW | CLOEXEC)
    stage_name = destination_fd = created = None
    try:
        for _ in range(16):
            candidate = f".m1-publish-{os.getpid()}-{secrets.token_hex(16)}"
            try:
                destination_fd = os.open(
                    candidate,
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW | CLOEXEC,
                    0o600,
                    dir_fd=parent_fd,
                )
                stage_name = candidate
                created = os.fstat(destination_fd)
                break
            except FileExistsError:
                continue
        if destination_fd is None:
            fail("cannot allocate private publication staging file")
        size, digest = copy_open_file(source_fd, destination_fd)
        os.fsync(destination_fd)
        check_open_source(source, source_fd, opened, digest, expected_size, expected_digest)
        copied = os.fstat(destination_fd)
        if copied.st_size != size or (expected_size is not None and copied.st_size != expected_size):
            fail("published destination size mismatch")
        os.fchmod(destination_fd, 0o400)
        os.fsync(destination_fd)
        os.close(destination_fd)
        destination_fd = None
        stage = os.stat(stage_name, dir_fd=parent_fd, follow_symlinks=False)
        if (stage.st_dev, stage.st_ino) != (created.st_dev, created.st_ino):
            fail("publication staging identity changed")
        try:
            os.link(
                stage_name,
                name,
                src_dir_fd=parent_fd,
                dst_dir_fd=parent_fd,
                follow_symlinks=False,
            )
        except OSError as exc:
            fail(f"cannot publish destination without overwrite: {exc}")
        os.fsync(parent_fd)
        verify_fd = os.open(name, os.O_RDONLY | NOFOLLOW | CLOEXEC, dir_fd=parent_fd)
        try:
            named = os.fstat(verify_fd)
            if (named.st_dev, named.st_ino) != (created.st_dev, created.st_ino):
                fail("published destination identity changed")
        finally:
            os.close(verify_fd)
        if verify(destination, expected_size, expected_digest) != digest:
            fail("published destination digest changed")
        safe_unlink(parent_fd, stage_name, created)
        stage_name = None
        os.fsync(parent_fd)
        return digest
    except BaseException:
        if stage_name is not None and created is not None:
            safe_unlink(parent_fd, stage_name, created)
        raise
    finally:
        os.close(source_fd)
        if destination_fd is not None:
            os.close(destination_fd)
        os.close(parent_fd)


def main():
    if len(sys.argv) < 2:
        fail("missing command")
    command = sys.argv[1]
    if command == "snapshot" and len(sys.argv) == 6:
        result = snapshot(sys.argv[2], sys.argv[3], parse_size(sys.argv[4]), parse_digest(sys.argv[5]))
    elif command == "verify" and len(sys.argv) == 5:
        result = verify(sys.argv[2], parse_size(sys.argv[3]), parse_digest(sys.argv[4]))
    elif command == "publish" and len(sys.argv) == 6:
        result = publish(sys.argv[2], sys.argv[3], parse_size(sys.argv[4]), parse_digest(sys.argv[5]))
    else:
        fail("invalid command or argument count")
    print(result)


if __name__ == "__main__":
    main()
