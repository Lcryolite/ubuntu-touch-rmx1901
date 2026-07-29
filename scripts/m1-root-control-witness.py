#!/usr/bin/python3
"""Root-owned, fail-closed M1 evidence witness.

The recovery/boot-partition proof is intentionally *not* collected during a
post-boot capture.  A separately audited root preflight freezes it in PROFILE
before boot.  This program subsequently accepts one complete capture from the
fixed runtime adapter; it never starts ADB or talks to Recovery at runtime.
"""
import fcntl
import hashlib
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import secrets
from pathlib import Path

OPENSSL = "/usr/bin/openssl"
TRUST = "/usr/local/libexec/rmx1901-m1-control/fixed-trust"
ADAPTER = "/usr/local/libexec/rmx1901-m1-control/runtime-adapter"
ROOT = Path("/var/lib/rmx1901-m1-control")
PROFILE = ROOT / "preboot-profile"
STATE = ROOT / "state"
REGISTRY = ROOT / "registry" / "receipts"
PRIVATE_KEY = ROOT / "witness-ed25519.pem"
TIMEOUT = 30

PROFILE_FILES = ("profile.env", "preflight.env", "boot-unpack.txt", "write-readback.env")
RUNTIME_FILES = (
    "proc-cmdline.txt", "handoff-events.log", "handoff-kmsg.log",
    "transport.env", "usb-state.env", "runtime/pid1-comm.txt",
    "runtime/pid1-exe.txt", "runtime/pid1-cmdline.txt", "runtime/boot-id.txt",
    "runtime/mounts.txt", "runtime/journal.txt", "runtime/failed-units.txt",
    "runtime/configfs.txt", "runtime/netdev.txt", "runtime/systemd-confirmed.env",
)
RAW = ("attempt.env", "capture-session.env", "boot-unpack.txt") + RUNTIME_FILES + ("preflight.env", "write-readback.env", "result.env")


def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(20)


def clean():
    os.environ.clear()
    os.environ["PATH"] = "/usr/bin:/bin"
    os.umask(0o077)


def regular(path, mode=None):
    try:
        value = path.lstat()
    except OSError:
        return False
    return stat.S_ISREG(value.st_mode) and not stat.S_ISLNK(value.st_mode) and (mode is None or stat.S_IMODE(value.st_mode) == mode)


def write(path, data, mode=0o400):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with path.open("xb") as stream:
        stream.write(data if isinstance(data, bytes) else data.encode("ascii"))
        stream.flush(); os.fsync(stream.fileno())
    os.chmod(path, mode)


def fsync_directory(path):
    """Persist a rename/create boundary before treating it as a receipt fact."""
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def manifest(directory, name, files):
    write(directory / name, "".join(f"{digest(directory / item)}  {item}\n" for item in sorted(files)))


def parse_env(path, keys, label):
    if not regular(path):
        fail(f"{label} is missing or unsafe")
    try:
        lines = path.read_text(encoding="ascii").splitlines()
    except (OSError, UnicodeError):
        fail(f"{label} is invalid")
    parsed = {}
    for line in lines:
        if "=" not in line:
            fail(f"{label} is invalid")
        key, value = line.split("=", 1)
        if key not in keys or key in parsed or not re.fullmatch(r"[-A-Za-z0-9 ._/:=+,]*", value):
            fail(f"{label} is invalid")
        parsed[key] = value
    if list(parsed) != list(keys):
        fail(f"{label} is invalid")
    return parsed


def metadata_digests(metadata):
    """Extract only the immutable image-chain bindings from inert metadata."""
    try:
        values = dict(line.split("=", 1) for line in metadata.read_text(encoding="ascii").splitlines())
    except (OSError, UnicodeError, ValueError):
        fail("M1 metadata is invalid")
    wanted = ("INPUT_SHA256", "PREDECESSOR_SHA256", "BOOT_SHA256", "OUTPUT_SHA256")
    if any(not re.fullmatch(r"[0-9a-f]{64}", values.get(key, "")) for key in wanted):
        fail("M1 metadata image-chain binding is invalid")
    if values["INPUT_SHA256"] != values["PREDECESSOR_SHA256"] or values["BOOT_SHA256"] != values["OUTPUT_SHA256"]:
        fail("M1 metadata image-chain binding is invalid")
    return values


def check_profile(metadata=None):
    """Verify the fixed immutable recovery proof before accepting runtime data."""
    try:
        profile_stat = PROFILE.lstat()
    except OSError:
        fail("preboot profile is missing or unsafe")
    if not stat.S_ISDIR(profile_stat.st_mode) or stat.S_ISLNK(profile_stat.st_mode) or stat.S_IMODE(profile_stat.st_mode) != 0o700:
        fail("preboot profile is missing or unsafe")
    entries = {p.name for p in PROFILE.iterdir()}
    if entries != set(PROFILE_FILES) | {"profile-SHA256SUMS"}:
        fail("preboot profile has unexpected entries")
    if not all(regular(PROFILE / name, 0o400) for name in (*PROFILE_FILES, "profile-SHA256SUMS")):
        fail("preboot profile is missing or unsafe")
    expected = "".join(f"{digest(PROFILE / name)}  {name}\n" for name in sorted(PROFILE_FILES))
    if (PROFILE / "profile-SHA256SUMS").read_text(encoding="ascii") != expected:
        fail("preboot profile checksum is invalid")
    profile = parse_env(PROFILE / "profile.env", ("PROFILE_SCHEMA", "INPUT_SHA256", "PREDECESSOR_SHA256", "BOOT_SHA256", "OUTPUT_SHA256"), "preboot profile binding")
    if profile["PROFILE_SCHEMA"] != "RMX1901-M1-PREBOOT-V1" or any(not re.fullmatch(r"[0-9a-f]{64}", profile[key]) for key in tuple(profile)[1:]):
        fail("preboot profile binding is invalid")
    preflight = parse_env(PROFILE / "preflight.env", (
        "ADB_STATE", "ADB_SERIAL", "ADB_PRODUCT", "ADB_MODEL", "ADB_DEVICE", "UNLOCKED",
        "BOOT_PATH", "BOOT_SIZE", "BOOT_MAJOR_MINOR", "BATTERY_PERCENT", "SAFETY_GATE",
    ), "preboot recovery profile")
    expected_preflight = {
        "ADB_STATE": "recovery", "ADB_SERIAL": "7b0c1c49", "ADB_PRODUCT": "fox_RMX1901",
        "ADB_MODEL": "RMX1901", "ADB_DEVICE": "RMX1901", "UNLOCKED": "YES",
        "BOOT_PATH": "/dev/block/sde10", "BOOT_SIZE": "67108864", "BOOT_MAJOR_MINOR": "8:4a",
        "SAFETY_GATE": "PASS",
    }
    if any(preflight[k] != v for k, v in expected_preflight.items()) or not preflight["BATTERY_PERCENT"].isdigit() or not 50 <= int(preflight["BATTERY_PERCENT"]) <= 100:
        fail("preboot recovery profile does not prove RMX1901 safety")
    readback = parse_env(PROFILE / "write-readback.env", ("PREDECESSOR_SHA256", "DEVICE_READBACK_SHA256", "HOST_READBACK_SHA256"), "preboot readback")
    if any(not re.fullmatch(r"[0-9a-f]{64}", v) for v in readback.values()) or readback["DEVICE_READBACK_SHA256"] != readback["HOST_READBACK_SHA256"]:
        fail("preboot profile does not prove dual boot readback")
    if (profile["INPUT_SHA256"] != profile["PREDECESSOR_SHA256"] or profile["BOOT_SHA256"] != profile["OUTPUT_SHA256"] or
            readback["PREDECESSOR_SHA256"] != profile["PREDECESSOR_SHA256"] or readback["DEVICE_READBACK_SHA256"] != profile["BOOT_SHA256"]):
        fail("preboot profile image-chain binding is invalid")
    if metadata is not None and any(metadata_digests(metadata)[key] != profile[key] for key in ("INPUT_SHA256", "PREDECESSOR_SHA256", "BOOT_SHA256", "OUTPUT_SHA256")):
        fail("preboot profile does not bind capture metadata")
    unpack = (PROFILE / "boot-unpack.txt").read_text(encoding="utf-8", errors="strict")
    if not unpack.endswith("\n") or "additional command line args: \n" not in unpack or not re.search(r"^command line args: .+", unpack, re.M):
        fail("preboot profile does not prove exact boot unpack")


def check(metadata=None):
    try:
        result = subprocess.run([TRUST, "check"], env={"PATH": "/usr/bin:/bin"}, timeout=TIMEOUT)
    except (OSError, subprocess.TimeoutExpired):
        fail("fixed M1 control plane is unavailable")
    if result.returncode:
        fail("fixed M1 control plane is unavailable")
    check_profile(metadata)
    if not os.path.isfile(ADAPTER) or os.path.islink(ADAPTER) or not os.access(ADAPTER, os.X_OK):
        fail("fixed postboot runtime adapter is unavailable")


def validate_runtime(directory):
    entries = {str(p.relative_to(directory)) for p in directory.rglob("*")}
    if entries != set(RUNTIME_FILES) | {"runtime"}:
        fail("runtime adapter did not produce exactly one classified state")
    if not all(regular(directory / name) and (directory / name).stat().st_size for name in RUNTIME_FILES):
        fail("runtime adapter produced missing runtime evidence")
    transport = parse_env(directory / "transport.env", (
        "TRANSPORT", "PRODUCT", "TCP22", "TCP23", "BANNER", "HOSTKEY", "AUTH", "PID1_COMM", "PID1_EXE", "PID1_CMDLINE",
    ), "runtime transport")
    usb = parse_env(directory / "usb-state.env", ("CLASSIFICATION", "VIDPID", "PRODUCT", "NETDEV", "IP", "TCP22", "TCP23"), "runtime USB state")
    if transport["TRANSPORT"] not in ("panic", "diagnostic-ssh", "systemd-ssh") or transport["TRANSPORT"] != usb["CLASSIFICATION"]:
        fail("runtime adapter did not produce exactly one classified state")
    if usb["VIDPID"] != "18d1:d001" or any(transport[k] != usb[k] for k in ("PRODUCT", "TCP22", "TCP23")):
        fail("runtime adapter produced an inconsistent USB state")
    if transport["TRANSPORT"] == "panic":
        expected = {"PRODUCT":"Failed to boot", "TCP22":"CLOSED", "TCP23":"OPEN", "BANNER":"NONE", "HOSTKEY":"NONE", "AUTH":"NONE", "PID1_COMM":"init", "PID1_EXE":"/bin/sh", "PID1_CMDLINE":"/bin/sh /init"}
    else:
        expected = {"PRODUCT":"RMX1901 diagnostic bridge", "TCP22":"OPEN", "TCP23":"CLOSED", "AUTH":"PUBLICKEY_OK"}
        if not re.fullmatch(r"SSH-[^ ]+", transport["BANNER"]) or not re.fullmatch(r"SHA256:[A-Za-z0-9+/=]+", transport["HOSTKEY"]):
            fail("runtime authenticated SSH evidence is invalid")
        if transport["TRANSPORT"] == "diagnostic-ssh":
            expected.update({"PID1_COMM":"sh", "PID1_CMDLINE":"/bin/sh /init"})
        else:
            expected.update({"PID1_COMM":"systemd", "PID1_EXE":"/usr/lib/systemd/systemd", "PID1_CMDLINE":"/usr/lib/systemd/systemd"})
    if any(transport[k] != v for k, v in expected.items()):
        fail("runtime adapter did not prove its classified state")
    for key, filename in (("PID1_COMM", "runtime/pid1-comm.txt"), ("PID1_EXE", "runtime/pid1-exe.txt"), ("PID1_CMDLINE", "runtime/pid1-cmdline.txt")):
        if (directory / filename).read_text(encoding="utf-8").rstrip("\n") != transport[key]:
            fail("runtime transport does not bind PID 1 evidence")


def atomic_state(path, data):
    tmp = path.with_name(path.name + ".new")
    if tmp.exists(): fail("witness state transaction is incomplete")
    write(tmp, data)
    os.replace(tmp, path)
    fsync_directory(path.parent)


def publish_exclusive(source, target):
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o400)
    try:
        with source.open("rb") as stream:
            while block := stream.read(1024 * 1024): os.write(fd, block)
        os.fsync(fd)
    finally:
        os.close(fd)


def transaction_path():
    return STATE / "receipt-transaction.env"


def transaction_record(**values):
    keys = (
        "TRANSACTION_SCHEMA", "SESSION", "RECEIPT_SHA256", "BOOT_ID",
        "OLD_SEQUENCE", "OLD_HEAD", "OLD_SEEN_SHA256", "NEW_SEQUENCE",
        "NEW_HEAD", "NEW_SEEN_SHA256", "PHASE",
    )
    if tuple(values) != keys:
        fail("M1 receipt transaction is invalid")
    return "".join(f"{key}={values[key]}\n" for key in keys)


def read_transaction():
    path = transaction_path()
    if not path.exists():
        return None
    values = parse_env(path, (
        "TRANSACTION_SCHEMA", "SESSION", "RECEIPT_SHA256", "BOOT_ID",
        "OLD_SEQUENCE", "OLD_HEAD", "OLD_SEEN_SHA256", "NEW_SEQUENCE",
        "NEW_HEAD", "NEW_SEEN_SHA256", "PHASE",
    ), "M1 receipt transaction")
    if values["TRANSACTION_SCHEMA"] != "RMX1901-M1-RECEIPT-TRANSACTION-V1" or values["PHASE"] not in ("PREPARED", "PUBLISHED"):
        fail("M1 receipt transaction is invalid")
    if not re.fullmatch(r"m1-[0-9a-f]{32}", values["SESSION"]) or not re.fullmatch(r"[0-9a-f]{64}", values["RECEIPT_SHA256"]):
        fail("M1 receipt transaction is invalid")
    if not re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}", values["BOOT_ID"]):
        fail("M1 receipt transaction is invalid")
    for key in ("OLD_HEAD", "OLD_SEEN_SHA256", "NEW_HEAD", "NEW_SEEN_SHA256"):
        if values[key] != "GENESIS" and not re.fullmatch(r"[0-9a-f]{64}", values[key]):
            fail("M1 receipt transaction is invalid")
    if not values["OLD_SEQUENCE"].isdigit() or not values["NEW_SEQUENCE"].isdigit():
        fail("M1 receipt transaction is invalid")
    return values


def state_values():
    seen = STATE / "boot-ids"
    return {
        "sequence": (STATE / "sequence").read_text().strip() if (STATE / "sequence").exists() else "0",
        "head": (STATE / "head").read_text().strip() if (STATE / "head").exists() else "GENESIS",
        "seen": seen.read_text() if seen.exists() else "",
    }


def discard_transaction():
    transaction_path().unlink()
    fsync_directory(STATE)


def recover_transaction():
    """Finish a published receipt or reject an ambiguous half-publication.

    The journal is written and synced before either receipt file is visible.
    Thus a restart can distinguish no publication, a fully published pair, and
    the unsafe one-file case.  The latter is deliberately operator-visible;
    it is never overwritten or silently re-signed.
    """
    tx = read_transaction()
    if tx is None:
        return
    receipt = REGISTRY / f"{tx['SESSION']}.receipt"
    signature = REGISTRY / f"{tx['SESSION']}.sig"
    receipt_exists, signature_exists = receipt.exists(), signature.exists()
    if receipt_exists != signature_exists:
        fail("M1 receipt transaction has an ambiguous partial publication")
    current = state_values()
    old_match = current["sequence"] == tx["OLD_SEQUENCE"] and current["head"] == tx["OLD_HEAD"] and hashlib.sha256(current["seen"].encode()).hexdigest() == tx["OLD_SEEN_SHA256"]
    new_match = current["sequence"] == tx["NEW_SEQUENCE"] and current["head"] == tx["NEW_HEAD"] and hashlib.sha256(current["seen"].encode()).hexdigest() == tx["NEW_SEEN_SHA256"]
    if not receipt_exists:
        if not old_match:
            fail("M1 receipt transaction state is inconsistent")
        discard_transaction()
        return
    if not regular(receipt, 0o400) or not regular(signature, 0o400) or digest(receipt) != tx["RECEIPT_SHA256"]:
        fail("M1 receipt transaction publication is invalid")
    if old_match:
        atomic_state(STATE / "sequence", tx["NEW_SEQUENCE"] + "\n")
        atomic_state(STATE / "head", tx["NEW_HEAD"] + "\n")
        # The journal carries only its digest; preserve the boot-id log by
        # appending exactly the journal-bound identity once.
        atomic_state(STATE / "boot-ids", current["seen"] + tx["BOOT_ID"] + "\n")
    elif not new_match:
        fail("M1 receipt transaction state is inconsistent")
    discard_transaction()


def capture(metadata, basename, bundle):
    stage = Path(tempfile.mkdtemp(prefix=".m1-witness-", dir=bundle))
    attempt = stage / "attempt"; attempt.mkdir(mode=0o700); (attempt / "runtime").mkdir(mode=0o700)
    runtime = stage / "runtime-capture"; runtime.mkdir(mode=0o700)
    try:
        # The adapter is given one fixed verb and a private empty directory.
        # It must choose either panic telnet or authenticated SSH internally;
        # runtime adapter must not use recovery ADB: there is no Recovery ADB
        # input or fallback path in this process.
        result = subprocess.run([ADAPTER, "capture", str(runtime)], env={"PATH": "/usr/bin:/bin"}, timeout=TIMEOUT)
        if result.returncode:
            fail("fixed postboot runtime adapter failed")
        validate_runtime(runtime)
        nonce = secrets.token_hex(16)
        stamp = time.strftime("%Y%m%dT%H%M%S", time.gmtime()) + f".{time.time_ns() % 1_000_000_000:09d}Z"
        write(attempt / "attempt.env", metadata.read_bytes() + f"CAPTURE_NONCE={nonce}\nCAPTURE_TIMESTAMP={stamp}\n".encode())
        session = "m1-" + secrets.token_hex(16)
        write(attempt / "capture-session.env", f"CAPTURE_DIRECTORY={basename}\nCAPTURE_SESSION={session}\n")
        for name in ("preflight.env", "boot-unpack.txt", "write-readback.env"):
            write(attempt / name, (PROFILE / name).read_bytes())
        for name in RUNTIME_FILES:
            write(attempt / name, (runtime / name).read_bytes())
        write(attempt / "result.env", "RESULT=PASS\nFAILURE_PHASE=NONE\nREASON=SIGNED_RAW_CAPTURE_COMPLETED\n")
        manifest(attempt, "capture-SHA256SUMS", RAW)
        manifest(attempt, "SHA256SUMS", RAW + ("capture-SHA256SUMS",))
        bootid = (attempt / "runtime/boot-id.txt").read_text(encoding="ascii").strip()
        if not re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}", bootid): fail("RMX1901 boot id is invalid")
        with open(STATE / "lock", "a+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            recover_transaction()
            seen = STATE / "boot-ids"
            old_seen = seen.read_text() if seen.exists() else ""
            if bootid in old_seen.splitlines(): fail("RMX1901 boot id was already captured")
            sequence = int((STATE / "sequence").read_text() or "0") + 1 if (STATE / "sequence").exists() else 1
            previous = (STATE / "head").read_text().strip() if (STATE / "head").exists() else "GENESIS"
            receipt = (f"RECEIPT_SCHEMA=RMX1901-M1-SIGNED-RECEIPT-V1\nSIGNER_SEQUENCE={sequence}\nSIGNER_PREVIOUS_SHA256={previous}\nATTEMPT_ID={basename.split('-',1)[1]}\nCAPTURE_DIRECTORY={basename}\nCAPTURE_SESSION={session}\nCAPTURE_NONCE={nonce}\nCAPTURE_TIMESTAMP={stamp}\nBOOT_ID={bootid}\nCAPTURE_MANIFEST_SHA256={digest(attempt / 'capture-SHA256SUMS')}\n")
            write(stage / "receipt.env", receipt)
            signature = stage / "receipt.sig"
            signed = subprocess.run([OPENSSL, "pkeyutl", "-sign", "-rawin", "-inkey", str(PRIVATE_KEY), "-in", str(stage / "receipt.env"), "-out", str(signature)], env={"PATH":"/usr/bin:/bin"}, timeout=TIMEOUT)
            if signed.returncode: fail("RMX1901 receipt signature failed")
            os.chmod(signature, 0o400)
            receipt_target, sig_target = REGISTRY / f"{session}.receipt", REGISTRY / f"{session}.sig"
            # This is the durable intent record.  It is synced before either
            # externally visible receipt file, so restart recovery is exact.
            old_seen_sha = hashlib.sha256(old_seen.encode()).hexdigest()
            new_seen = old_seen + bootid + "\n"
            new_head = digest(stage / "receipt.env")
            write(transaction_path(), transaction_record(
                TRANSACTION_SCHEMA="RMX1901-M1-RECEIPT-TRANSACTION-V1",
                SESSION=session, RECEIPT_SHA256=new_head, BOOT_ID=bootid,
                OLD_SEQUENCE=str(sequence - 1), OLD_HEAD=previous,
                OLD_SEEN_SHA256=old_seen_sha, NEW_SEQUENCE=str(sequence),
                NEW_HEAD=new_head,
                NEW_SEEN_SHA256=hashlib.sha256(new_seen.encode()).hexdigest(),
                PHASE="PREPARED",
            ))
            fsync_directory(STATE)
            try:
                publish_exclusive(stage / "receipt.env", receipt_target)
                publish_exclusive(signature, sig_target)
            except OSError:
                fail("RMX1901 receipt publication collision or failure")
            fsync_directory(REGISTRY)
            # Mark publication before mutating state.  Either phase can be
            # completed deterministically by recover_transaction on restart.
            transaction_path().unlink()
            write(transaction_path(), transaction_record(
                TRANSACTION_SCHEMA="RMX1901-M1-RECEIPT-TRANSACTION-V1",
                SESSION=session, RECEIPT_SHA256=new_head, BOOT_ID=bootid,
                OLD_SEQUENCE=str(sequence - 1), OLD_HEAD=previous,
                OLD_SEEN_SHA256=old_seen_sha, NEW_SEQUENCE=str(sequence),
                NEW_HEAD=new_head,
                NEW_SEEN_SHA256=hashlib.sha256(new_seen.encode()).hexdigest(),
                PHASE="PUBLISHED",
            ))
            fsync_directory(STATE)
            atomic_state(STATE / "sequence", f"{sequence}\n")
            atomic_state(STATE / "head", new_head + "\n")
            atomic_state(seen, new_seen)
            discard_transaction()
        for item in ("attempt", "receipt.env", "receipt.sig"):
            os.replace(stage / item, bundle / item)
        # The bundle is an externally validated three-entry object.  The
        # private staging directory is empty after publication and must not
        # remain as a fourth top-level entry.
        shutil.rmtree(runtime)
        stage.rmdir()
    except BaseException:
        shutil.rmtree(stage, ignore_errors=True)
        raise


def main():
    clean()
    if sys.argv[1:] == ["--self-check"]:
        check(); return
    if sys.argv[1:] == ["--health"]:
        check(); return
    if len(sys.argv) != 4:
        fail("M1 witness requires exactly metadata, attempt basename and private output arguments")
    metadata, basename, bundle = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
    if not regular(metadata) or not re.fullmatch(r"[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9][A-Za-z0-9._-]*", basename) or not bundle.is_dir() or any(bundle.iterdir()):
        fail("unsafe M1 witness input")
    check(metadata)
    capture(metadata, basename, bundle)


if __name__ == "__main__":
    main()
