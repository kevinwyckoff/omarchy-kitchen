#!/usr/bin/env python3
"""evwatch.py: is anyone touching the keyboard, mouse or a touch device?

Part of kitchen-update (S2, the activity check). Runs as root and watches every
/dev/input/event* node for SECONDS. It opens each node read-only and never
grabs it (no EVIOCGRAB), so Hyprland still receives every event: this only
looks over its shoulder.

Why evdev and not logind or the compositor: with Omarchy's Stay Awake on there
is no idle signal anywhere (logind's IdleHint is never set and the shell's idle
monitor is switched off), and device nodes carry no useful atime. Reading the
event stream is the one signal that works.

Only EV_KEY, EV_REL and EV_ABS count as a person. EV_SW (the HDA jack
switches), EV_MSC and EV_SYN noise is ignored. Nodes that appear during the
window (a Bluetooth keyboard connecting) are picked up on the next rescan.

usage: evwatch.py SECONDS [--glob PATTERN] [--rescan SECS]

exit 0: no input for the whole window
exit 1: input seen (one line says where and when)
exit 2: could not watch anything (no readable device): the caller treats
        this as busy, because silence it cannot hear is not silence
"""

import argparse
import errno
import glob
import os
import select
import struct
import sys
import time

# struct input_event on 64-bit Linux: struct timeval (two longs), __u16 type,
# __u16 code, __s32 value. calcsize keeps this right on any word size.
EVENT = struct.Struct("llHHi")
EV_KEY, EV_REL, EV_ABS = 0x01, 0x02, 0x03
PERSON = {EV_KEY: "key", EV_REL: "pointer", EV_ABS: "touch/absolute"}


def device_name(path):
    """The kernel's name for an event node, for the log line."""
    node = os.path.basename(path)
    try:
        with open(f"/sys/class/input/{node}/device/name") as f:
            return f.read().strip()
    except OSError:
        return "unknown device"


def open_new(pattern, fds):
    """Open every node matching pattern that is not open yet."""
    open_paths = set(fds.values())
    for path in sorted(glob.glob(pattern)):
        if path in open_paths:
            continue
        try:
            fds[os.open(path, os.O_RDONLY | os.O_NONBLOCK)] = path
        except OSError:
            # A node we may not read, or one that vanished: skip it. If no
            # node at all can be opened, main() reports a watch error.
            pass


def main():
    parser = argparse.ArgumentParser(description="Watch evdev input for a quiet window.")
    parser.add_argument("seconds", type=float)
    parser.add_argument("--glob", default="/dev/input/event*", help="nodes to watch (tests use a FIFO)")
    parser.add_argument("--rescan", type=float, default=10.0, help="look for new nodes this often")
    args = parser.parse_args()

    fds = {}
    open_new(args.glob, fds)
    if not fds:
        print(f"watch error: no readable input device matches {args.glob}")
        return 2

    start = time.monotonic()
    end = start + args.seconds
    next_rescan = start + args.rescan
    buffered = {}  # partial events split across reads (only ever seen on FIFOs)

    while True:
        now = time.monotonic()
        left = end - now
        if left <= 0:
            break
        if now >= next_rescan:
            open_new(args.glob, fds)
            next_rescan = now + args.rescan
        if not fds:
            print("watch error: every input device went away during the window")
            return 2
        timeout = min(left, max(0.0, next_rescan - now))
        try:
            ready, _, _ = select.select(list(fds), [], [], timeout)
        except InterruptedError:
            continue
        for fd in ready:
            try:
                data = os.read(fd, EVENT.size * 64)
            except OSError as e:
                if e.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                    continue
                # ENODEV: unplugged. Drop it; the rescan re-adds it if it returns.
                os.close(fd)
                del fds[fd]
                continue
            if not data:
                # EOF only happens on a FIFO whose writer closed; stop polling it.
                os.close(fd)
                del fds[fd]
                continue
            data = buffered.pop(fd, b"") + data
            whole = len(data) - len(data) % EVENT.size
            if whole < len(data):
                buffered[fd] = data[whole:]
            for offset in range(0, whole, EVENT.size):
                _, _, etype, _, _ = EVENT.unpack_from(data, offset)
                if etype in PERSON:
                    path = fds.get(fd, "?")
                    after = time.monotonic() - start
                    print(f"{PERSON[etype]} input on {path} ({device_name(path)}) after {after:.0f}s")
                    return 1

    watched = ", ".join(f"{p} ({device_name(p)})" for p in sorted(fds.values()))
    print(f"no key, pointer or touch input for {args.seconds:.0f}s on: {watched}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
