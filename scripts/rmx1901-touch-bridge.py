#!/usr/bin/python3
"""Normalize the RMX1901 touchpanel into a single-touch uinput device."""

import fcntl
import os
import socket
import stat
import select
import signal
import struct
import sys
import time

EV_SYN = 0
EV_KEY = 1
EV_ABS = 3
SYN_REPORT = 0
SYN_DROPPED = 3
BTN_TOOL_FINGER = 325
BTN_TOUCH = 330
ABS_MT_SLOT = 47
ABS_MT_TOUCH_MAJOR = 48
ABS_MT_WIDTH_MAJOR = 50
ABS_MT_POSITION_X = 53
ABS_MT_POSITION_Y = 54
ABS_MT_TRACKING_ID = 57
ABS_MT_PRESSURE = 58
INPUT_PROP_DIRECT = 1
SOURCE = "/dev/input/event1"
UINPUT = "/dev/uinput"
EVENT_SIZE = struct.calcsize("llHHi")
ABSINFO_SIZE = struct.calcsize("iiiiii")


def _iow(type_char: str, number: int, size: int = 4) -> int:
    return (1 << 30) | (size << 16) | (ord(type_char) << 8) | number


def _ior(type_char: str, number: int, size: int) -> int:
    return (2 << 30) | (size << 16) | (ord(type_char) << 8) | number


UI_SET_EVBIT = _iow("U", 100)
UI_SET_KEYBIT = _iow("U", 101)
UI_SET_ABSBIT = _iow("U", 103)
UI_SET_PROPBIT = _iow("U", 110)
UI_DEV_CREATE = (ord("U") << 8) | 1
UI_DEV_DESTROY = (ord("U") << 8) | 2
EVIOCGRAB = _iow("E", 0x90)


def abs_get_request(axis: int) -> int:
    return _ior("E", 0x40 + axis, ABSINFO_SIZE)


def abs_set_request(axis: int) -> int:
    return _iow("E", 0xC0 + axis, ABSINFO_SIZE)


def read_abs(source_fd: int, axis: int) -> tuple[int, int, int, int, int, int]:
    buffer = bytearray(ABSINFO_SIZE)
    fcntl.ioctl(source_fd, abs_get_request(axis), buffer, True)
    return struct.unpack("iiiiii", buffer)


def repair_abs_range(source_fd: int, axis: int) -> None:
    value, minimum, maximum, fuzz, flat, resolution = read_abs(source_fd, axis)
    if minimum >= maximum:
        fcntl.ioctl(
            source_fd,
            abs_set_request(axis),
            struct.pack("iiiiii", value, 0, 255, fuzz, flat, resolution),
        )
    _, minimum, maximum, _, _, _ = read_abs(source_fd, axis)
    if minimum >= maximum:
        raise RuntimeError(f"axis {axis} still has invalid range {minimum}..{maximum}")


def verify_source(source_fd: int) -> None:
    name_buffer = bytearray(256)
    fcntl.ioctl(source_fd, _ior("E", 0x06, len(name_buffer)), name_buffer, True)
    name = bytes(name_buffer).split(b"\0", 1)[0].decode(errors="replace")
    if name != "touchpanel":
        raise RuntimeError(f"{SOURCE} is {name!r}, not 'touchpanel'")
    x_info = read_abs(source_fd, ABS_MT_POSITION_X)
    y_info = read_abs(source_fd, ABS_MT_POSITION_Y)
    if x_info[1:3] != (0, 1079) or y_info[1:3] != (0, 2339):
        raise RuntimeError(f"unexpected touch geometry: x={x_info[1:3]} y={y_info[1:3]}")
    repair_abs_range(source_fd, ABS_MT_WIDTH_MAJOR)
    repair_abs_range(source_fd, ABS_MT_PRESSURE)


def create_uinput() -> int:
    target_fd = os.open(UINPUT, os.O_WRONLY | os.O_NONBLOCK)
    for event_type in (EV_SYN, EV_KEY, EV_ABS):
        fcntl.ioctl(target_fd, UI_SET_EVBIT, event_type)
    for key in (BTN_TOOL_FINGER, BTN_TOUCH):
        fcntl.ioctl(target_fd, UI_SET_KEYBIT, key)
    for axis in (
        ABS_MT_SLOT,
        ABS_MT_TOUCH_MAJOR,
        ABS_MT_WIDTH_MAJOR,
        ABS_MT_POSITION_X,
        ABS_MT_POSITION_Y,
        ABS_MT_TRACKING_ID,
        ABS_MT_PRESSURE,
    ):
        fcntl.ioctl(target_fd, UI_SET_ABSBIT, axis)
    fcntl.ioctl(target_fd, UI_SET_PROPBIT, INPUT_PROP_DIRECT)

    descriptor = bytearray(1116)
    struct.pack_into(
        "80sHHHHI",
        descriptor,
        0,
        b"rmx1901-touch-bridge",
        3,
        0x1209,
        0x1901,
        1,
        0,
    )
    abs_maximum_offset = 92
    for axis, maximum in (
        (ABS_MT_SLOT, 0),
        (ABS_MT_TOUCH_MAJOR, 255),
        (ABS_MT_WIDTH_MAJOR, 255),
        (ABS_MT_POSITION_X, 1079),
        (ABS_MT_POSITION_Y, 2339),
        (ABS_MT_TRACKING_ID, 65535),
        (ABS_MT_PRESSURE, 255),
    ):
        struct.pack_into("i", descriptor, abs_maximum_offset + axis * 4, maximum)
    if os.write(target_fd, descriptor) != len(descriptor):
        raise RuntimeError("short uinput descriptor write")
    fcntl.ioctl(target_fd, UI_DEV_CREATE)
    return target_fd


def emit(target_fd: int, event: tuple[int, int, int, int, int]) -> None:
    if os.write(target_fd, struct.pack("llHHi", *event)) != EVENT_SIZE:
        raise RuntimeError("short uinput event write")


def wait_for_character_device(path: str, timeout: float = 20.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if stat.S_ISCHR(os.stat(path).st_mode):
                return
        except FileNotFoundError:
            pass
        time.sleep(0.1)
    raise RuntimeError(f"character device did not appear: {path}")


def sd_notify(message: str) -> None:
    address = os.environ.get("NOTIFY_SOCKET")
    if not address:
        return
    if address.startswith("@"):
        address = "\0" + address[1:]
    notifier = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    try:
        notifier.sendto(message.encode(), address)
    finally:
        notifier.close()


def run() -> int:
    wait_for_character_device(SOURCE)
    wait_for_character_device(UINPUT)
    source_fd = os.open(SOURCE, os.O_RDWR | os.O_NONBLOCK)
    target_fd = -1
    grabbed = False
    running = True
    raw_events = 0
    replay_frames = 0

    def stop(_signum: int, _frame: object) -> None:
        nonlocal running
        running = False

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)

    try:
        verify_source(source_fd)
        fcntl.ioctl(source_fd, EVIOCGRAB, 1)
        grabbed = True
        target_fd = create_uinput()
        print(
            "rmx1901_touch_bridge=ready source=event1 geometry=1080x2340 mode=slot0",
            flush=True,
        )
        sd_notify("READY=1\nSTATUS=RMX1901 touch bridge ready")

        current_slot = 0
        active = False
        pending_frame = False
        while running:
            ready, _, _ = select.select([source_fd], [], [], 0.5)
            if not ready:
                continue
            data = os.read(source_fd, EVENT_SIZE * 128)
            if not data:
                raise RuntimeError("touch source returned EOF")
            if len(data) % EVENT_SIZE:
                raise RuntimeError(f"partial input event buffer: {len(data)} bytes")

            for offset in range(0, len(data), EVENT_SIZE):
                event = struct.unpack("llHHi", data[offset : offset + EVENT_SIZE])
                seconds, microseconds, event_type, code, value = event
                raw_events += 1

                if event_type == EV_SYN and code == SYN_DROPPED:
                    raise RuntimeError("touch source reported SYN_DROPPED")
                if event_type == EV_ABS and code == ABS_MT_SLOT:
                    current_slot = value
                elif event_type == EV_ABS and current_slot == 0 and code == ABS_MT_TRACKING_ID:
                    emit(target_fd, (seconds, microseconds, EV_ABS, ABS_MT_SLOT, 0))
                    emit(target_fd, event)
                    if value >= 0:
                        active = True
                    else:
                        emit(target_fd, (seconds, microseconds, EV_KEY, BTN_TOUCH, 0))
                        emit(target_fd, (seconds, microseconds, EV_KEY, BTN_TOOL_FINGER, 0))
                        active = False
                    pending_frame = True
                elif event_type == EV_ABS and current_slot == 0 and code in (
                    ABS_MT_TOUCH_MAJOR,
                    ABS_MT_WIDTH_MAJOR,
                    ABS_MT_POSITION_X,
                    ABS_MT_POSITION_Y,
                    ABS_MT_PRESSURE,
                ):
                    emit(target_fd, event)
                    pending_frame = True
                elif event_type == EV_SYN and code == SYN_REPORT and pending_frame:
                    if active:
                        emit(target_fd, (seconds, microseconds, EV_KEY, BTN_TOOL_FINGER, 1))
                        emit(target_fd, (seconds, microseconds, EV_KEY, BTN_TOUCH, 1))
                    emit(target_fd, event)
                    replay_frames += 1
                    pending_frame = False
    finally:
        if grabbed:
            try:
                fcntl.ioctl(source_fd, EVIOCGRAB, 0)
            except OSError:
                pass
        if target_fd >= 0:
            try:
                fcntl.ioctl(target_fd, UI_DEV_DESTROY)
            except OSError:
                pass
            os.close(target_fd)
        os.close(source_fd)
        print(
            f"rmx1901_touch_bridge=stopped raw_events={raw_events} replay_frames={replay_frames}",
            flush=True,
        )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(run())
    except Exception as error:
        print(f"rmx1901_touch_bridge=failed error={error}", file=sys.stderr, flush=True)
        raise
