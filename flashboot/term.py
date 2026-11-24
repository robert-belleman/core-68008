#!/usr/bin/env python3
"""Minimal serial terminal for any baud rate on macOS (also non-standard ones).

    python3 term.py /dev/cu.usbserial-A901ROZL 1050

minicom (and tio) only use the standard termios speeds on macOS; this sets
the speed with the IOSSIOSPEED ioctl, so 1050 or any other rate works.
8N1, no flow control. Keys are sent as typed (Enter sends CR).
Quit with Ctrl-].
"""
import fcntl
import os
import select
import struct
import sys
import termios
import tty

IOSSIOSPEED = 0x80085402        # _IOW('T', 2, speed_t)


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    port, baud = sys.argv[1], int(sys.argv[2])
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    t = termios.tcgetattr(fd)
    t[0] = t[1] = t[3] = 0
    t[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    t[4] = t[5] = termios.B9600
    t[6][termios.VMIN] = 0
    t[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, t)
    fcntl.ioctl(fd, IOSSIOSPEED, struct.pack("L", baud))
    termios.tcflush(fd, termios.TCIOFLUSH)

    interactive = os.isatty(0)
    saved = termios.tcgetattr(0) if interactive else None
    if interactive:
        tty.setraw(0)
    sys.stderr.write("[%s at %d baud, 8N1; Ctrl-] quits]\r\n" % (port, baud))
    sys.stderr.flush()
    try:
        inputs = [fd, 0]
        while True:
            r, _, _ = select.select(inputs, [], [])
            if fd in r:
                try:
                    data = os.read(fd, 4096)
                except BlockingIOError:
                    data = b""
                if data:
                    os.write(1, data)
            if 0 in r:
                key = os.read(0, 64)
                if not key:                 # stdin closed: keep listening
                    inputs = [fd]
                    continue
                if b"\x1d" in key:
                    break
                os.write(fd, key.replace(b"\n", b"\r") if not interactive else key)
    except KeyboardInterrupt:
        pass
    finally:
        if interactive:
            termios.tcsetattr(0, termios.TCSADRAIN, saved)
        os.close(fd)
        sys.stderr.write("\r\n[closed]\r\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
