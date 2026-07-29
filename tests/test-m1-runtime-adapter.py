#!/usr/bin/env python3
"""Black-box contract for the fixed panic-only M1 runtime adapter."""
import os
import shutil
import socket
import subprocess
import tempfile
import threading
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SOURCE = REPO / "scripts/m1-runtime-adapter.py"
TMP = Path(tempfile.mkdtemp(prefix="m1-runtime-adapter.", dir=os.environ.get("TMPDIR", "/tmp")))


def serve(listener):
    while True:
        conn, _ = listener.accept()
        with conn:
            request = b""
            while b"_BE''GIN__" not in request:
                request += conn.recv(8192)
            request = request.decode("ascii", "ignore")
            if "_BE''GIN__" not in request:
                continue
            values = {
                "/proc/cmdline": "console=tty0 systempart=/dev/disk/by-partlabel/system systemd.unified_cgroup_hierarchy=0 rmx1901.debug_rndis=1\n",
                "/run/rmx1901-handoff.events": "RMX1901_HANDOFF sequence=1 stage=CMDLINE_PARSED systempart=valid cgroup=valid console=valid diagnostic_rndis=valid\n",
                "/proc/1/comm": "init\n",
                "/proc/1/exe": "/bin/sh\n",
                "/proc/1/cmdline": "/bin/sh /init\n",
                "/proc/sys/kernel/random/boot_id": "12345678-1234-4123-8123-123456789abc\n",
            }
            data = next((value for token, value in values.items() if token in request), "unavailable\n")
            if "dmesg" in request:
                data = ("<6>initrd: padding\n" * 128) + "<6>initrd: RMX1901_HANDOFF sequence=1 stage=CMDLINE_PARSED systempart=valid cgroup=valid console=valid diagnostic_rndis=valid\n"
            nonce = __import__('re').search(r"__M1_([0-9a-f]{32})_BE''GIN__", request)
            assert nonce
            begin = f"__M1_{nonce.group(1)}_BEGIN__"
            end = f"__M1_{nonce.group(1)}_END__"
            # BusyBox telnet returns CRLF.  The adapter must canonicalise this
            # before evidence reaches the stricter signed-bundle validator.
            data = data.replace("\n", "\r\n")
            if "dmesg" in request:
                # The command itself is echoed before its delayed, large
                # output. A complete marker in this echo must not finish
                # collection before the real marker-delimited payload.
                conn.sendall((request + "\r\n").encode("ascii"))
                time.sleep(0.1)
            conn.sendall((begin + data + end).encode("ascii"))


try:
    assert SOURCE.exists(), "production panic adapter is missing"
    usb = TMP / "usb/1-1"; usb.mkdir(parents=True)
    (usb / "product").write_text("Failed to boot\n")
    (usb / "idVendor").write_text("18d1\n")
    (usb / "idProduct").write_text("d001\n")
    listener = socket.socket(); listener.bind(("127.0.0.1", 0)); listener.listen()
    threading.Thread(target=serve, args=(listener,), daemon=True).start()
    adapter = TMP / "adapter.py"
    raw = SOURCE.read_text()
    raw = raw.replace('USB_ROOT = Path("/sys/bus/usb/devices")', f'USB_ROOT = Path("{TMP / "usb"}")')
    raw = raw.replace('TARGET_HOST = "192.168.2.15"', 'TARGET_HOST = "127.0.0.1"')
    raw = raw.replace('TARGET_PORT = 23', f'TARGET_PORT = {listener.getsockname()[1]}')
    adapter.write_text(raw); adapter.chmod(0o500)
    out = TMP / "out"; out.mkdir()
    subprocess.run([str(adapter), "capture", str(out)], check=True)
    assert (out / "transport.env").read_text().startswith("TRANSPORT=panic\n")
    assert "PRODUCT=Failed to boot\n" in (out / "usb-state.env").read_text()
    assert (out / "runtime/pid1-comm.txt").read_text() == "init\n"
    assert (out / "runtime/boot-id.txt").read_bytes() == b"12345678-1234-4123-8123-123456789abc\n"
    assert "RMX1901_HANDOFF" in (out / "handoff-kmsg.log").read_text()
    print("ok - fixed USB panic transport yields only a complete read-only panic bundle")
finally:
    shutil.rmtree(TMP, ignore_errors=True)
