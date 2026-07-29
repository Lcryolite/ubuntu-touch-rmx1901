#!/usr/bin/python3
"""Fixed, read-only panic transport for RMX1901 M1 evidence.

This adapter deliberately supports only the pre-systemd panic shell.  It never
uses ADB, never configures networking, and never falls back to SSH: support
for authenticated diagnostic SSH belongs to the later M2 control plane.
"""
import os
import re
import secrets
import socket
import stat
import subprocess
import sys
from pathlib import Path

USB_ROOT = Path("/sys/bus/usb/devices")
TARGET_HOST = "192.168.2.15"
TARGET_PORT = 23
TIMEOUT = 10
MAX_REPLY = 1024 * 1024

FILES = {
    "proc-cmdline.txt": "cat /proc/cmdline",
    "handoff-events.log": "cat /run/rmx1901-handoff.events",
    "handoff-kmsg.log": "dmesg",
    "runtime/pid1-comm.txt": "cat /proc/1/comm",
    "runtime/pid1-exe.txt": "readlink /proc/1/exe",
    "runtime/pid1-cmdline.txt": "tr '\\000' ' ' </proc/1/cmdline",
    "runtime/boot-id.txt": "cat /proc/sys/kernel/random/boot_id",
    "runtime/mounts.txt": "cat /proc/mounts",
    "runtime/journal.txt": "journalctl -b --no-pager 2>&1 || printf unavailable",
    "runtime/failed-units.txt": "systemctl --failed --no-legend 2>&1 || printf unavailable",
    "runtime/configfs.txt": "find /config -maxdepth 3 -type f -print 2>&1 || printf unavailable",
    "runtime/netdev.txt": "ip -o link 2>&1",
}


def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(20)


def clean_environment():
    os.environ.clear()
    os.environ["PATH"] = "/usr/sbin:/usr/bin:/bin"
    os.umask(0o077)


def read_text(path):
    try:
        value = path.read_text(encoding="ascii")
    except OSError:
        return None
    return value.strip()


def assert_panic_usb():
    """Require the same physical USB identity as the panic classifier."""
    found = []
    try:
        products = list(USB_ROOT.glob("*/product"))
    except OSError:
        products = []
    for product_path in products:
        parent = product_path.parent
        if read_text(product_path) != "Failed to boot":
            continue
        if read_text(parent / "idVendor") == "18d1" and read_text(parent / "idProduct") == "d001":
            found.append(parent)
    if len(found) != 1:
        fail("RMX1901 panic USB identity is not unique")


def local_netdev():
    try:
        output = subprocess.run(
            ["/usr/sbin/ip", "-o", "route", "get", TARGET_HOST],
            env={"PATH": "/usr/sbin:/usr/bin:/bin"}, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, timeout=TIMEOUT, check=True, text=True,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        fail("RMX1901 panic route is unavailable")
    match = re.search(r"(?:^| )dev ([A-Za-z0-9_.-]+)(?: |$)", output)
    if not match:
        fail("RMX1901 panic route has no network device")
    return match.group(1)


def negotiate_telnet(conn):
    """Decline optional Telnet features before issuing the fixed command.

    BusyBox ash on the panic bridge emits IAC negotiation then echoes the
    command line.  The old raw-TCP implementation parsed that echo as proof.
    """
    original_timeout = conn.gettimeout()
    try:
        conn.settimeout(min(TIMEOUT, 0.25))
        opening = conn.recv(256)
    except socket.timeout:
        return
    finally:
        conn.settimeout(original_timeout)
    response = bytearray()
    index = 0
    while index + 2 < len(opening):
        if opening[index] != 255:
            index += 1; continue
        verb, option = opening[index + 1], opening[index + 2]
        if verb in (251, 252): response += bytes((255, 254, option)) # WILL/WONT -> DONT
        elif verb in (253, 254): response += bytes((255, 252, option)) # DO/DONT -> WONT
        index += 3
    if response: conn.sendall(response)


def remote(command):
    # The command vocabulary is this module's fixed map; no caller-provided
    # text reaches the remote shell.  Markers make prompt/echo noise fail
    # closed instead of becoming evidence.
    nonce = secrets.token_hex(16)
    begin, end = f"__M1_{nonce}_BEGIN__".encode("ascii"), f"__M1_{nonce}_END__".encode("ascii")
    # Split each literal marker inside a shell word. The shell joins adjacent
    # quoted/unquoted fragments, while command echo never contains either
    # complete marker, so an echoed `printf ...; dmesg; printf ...` cannot
    # terminate collection before the actual command output arrives.
    begin_request = f"__M1_{nonce}_BE''GIN__".encode("ascii")
    end_request = f"__M1_{nonce}_EN''D__".encode("ascii")
    request = b"printf " + begin_request + b"; " + command.encode("ascii") + b"; printf " + end_request + b"; exit\r\n"
    try:
        with socket.create_connection((TARGET_HOST, TARGET_PORT), timeout=TIMEOUT) as conn:
            conn.settimeout(TIMEOUT)
            negotiate_telnet(conn)
            conn.sendall(request)
            reply = bytearray()
            while end not in reply:
                chunk = conn.recv(65536)
                if not chunk:
                    break
                reply.extend(chunk)
                if len(reply) > MAX_REPLY:
                    fail("RMX1901 panic response is oversized")
    except (OSError, socket.timeout):
        fail("RMX1901 panic telnet transport failed")
    if reply.count(begin) < 1 or reply.count(end) < 1:
        fail("RMX1901 panic response framing is invalid")
    payload = bytes(reply).rsplit(begin, 1)[1].split(end, 1)[0]
    try:
        # Telnet transports BusyBox shell output as CRLF.  All downstream
        # evidence contracts use canonical LF bytes, including boot-id.txt;
        # normalise at this transport boundary rather than letting a tolerant
        # witness and a strict publisher disagree about the same payload.
        text = payload.decode("utf-8", "strict").replace("\r\n", "\n")
    except UnicodeDecodeError:
        fail("RMX1901 panic response is not UTF-8")
    if "\r" in text:
        fail("RMX1901 panic response has a non-canonical line ending")
    return text


def write_output(root, relative, data):
    target = root / relative
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if target.exists() or target.is_symlink():
        fail("RMX1901 panic output is unsafe")
    # Empty PID1 exe is valid panic evidence but every runtime evidence file
    # must still be a non-empty regular file for the witness contract.
    target.write_text(data if data else "\n", encoding="utf-8")
    target.chmod(0o400)


def capture(out):
    assert_panic_usb()
    netdev = local_netdev()
    for relative, command in FILES.items():
        data = remote(command)
        if relative in ("runtime/pid1-comm.txt", "runtime/pid1-exe.txt", "runtime/pid1-cmdline.txt"):
            data = data.strip() + "\n"
        write_output(out, relative, data)
    pid1_comm = (out / "runtime/pid1-comm.txt").read_text().strip()
    pid1_cmdline = (out / "runtime/pid1-cmdline.txt").read_text().strip()
    pid1_exe = (out / "runtime/pid1-exe.txt").read_text().strip()
    if pid1_comm != "init" or pid1_cmdline != "/bin/sh /init" or pid1_exe != "/bin/sh":
        fail("RMX1901 panic PID 1 evidence is invalid")
    write_output(out, "transport.env", "TRANSPORT=panic\nPRODUCT=Failed to boot\nTCP22=CLOSED\nTCP23=OPEN\nBANNER=NONE\nHOSTKEY=NONE\nAUTH=NONE\nPID1_COMM=init\nPID1_EXE=/bin/sh\nPID1_CMDLINE=/bin/sh /init\n")
    write_output(out, "usb-state.env", f"CLASSIFICATION=panic\nVIDPID=18d1:d001\nPRODUCT=Failed to boot\nNETDEV={netdev}\nIP={TARGET_HOST}\nTCP22=CLOSED\nTCP23=OPEN\n")
    write_output(out, "runtime/systemd-confirmed.env", "SYSTEMD_CONFIRMED=NO\n")


def main():
    clean_environment()
    if len(sys.argv) != 3 or sys.argv[1] != "capture":
        fail("usage: m1-runtime-adapter.py capture EMPTY_ABSOLUTE_DIRECTORY")
    out = Path(sys.argv[2])
    if not out.is_absolute() or not out.is_dir() or out.is_symlink() or any(out.iterdir()):
        fail("RMX1901 panic output directory is unsafe")
    capture(out)


if __name__ == "__main__":
    main()
