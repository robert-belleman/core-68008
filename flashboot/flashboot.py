#!/usr/bin/env python3
"""Send a 256K image to FLASHBOOT and program the board's SST39SF020A.

    python3 flashboot.py /dev/cu.usbserial-XXXX ../monitor/monitor.bin

Steps: read the flash ID, chip erase + blank check, program every 256-byte
block of the image that is not all $FF, then compare the sum of every
programmed range and of the whole flash with the file. No pyserial needed.

Options:
    --no-rtscts   do not use RTS/CTS flow control on the host side
    --id          only show the flash ID
    --verify      only compare the flash with the image (no erase/program)
"""
import os
import select
import sys
import termios
import time

FLASH_SIZE = 0x40000
BLOCK = 256


def open_port(path, rtscts):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    t = termios.tcgetattr(fd)
    iflag, oflag, cflag, lflag, ispeed, ospeed, cc = t
    iflag = 0
    oflag = 0
    lflag = 0
    cflag = termios.CS8 | termios.CREAD | termios.CLOCAL
    if rtscts:
        cflag |= getattr(termios, "CRTSCTS", 0) or (
            getattr(termios, "CCTS_OFLOW", 0) | getattr(termios, "CRTS_IFLOW", 0))
    cc[termios.VMIN] = 0
    cc[termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW,
                      [iflag, oflag, cflag, lflag, termios.B38400, termios.B38400, cc])
    os.set_blocking(fd, True)
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def read_until_prompt(fd, timeout):
    """Collect output until the loader's '>' prompt; return the text before it."""
    buf = b""
    end = time.time() + timeout
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            data = os.read(fd, 4096)
            buf += data
            if buf.endswith(b">"):
                return buf[:-1].decode("latin-1").strip()
    raise TimeoutError("no '>' prompt from the board (got %r)" % buf.decode("latin-1"))


def send(fd, data):
    view = memoryview(data)
    while view:
        n = os.write(fd, view)
        view = view[n:]


def command(fd, data, timeout):
    send(fd, data)
    return read_until_prompt(fd, timeout)


def ranges_of(image):
    """Merged ranges of 256-byte blocks that are not all $FF."""
    out = []
    for off in range(0, len(image), BLOCK):
        if image[off:off + BLOCK].count(0xFF) == BLOCK:
            continue
        if out and out[-1][1] == off:
            out[-1][1] = off + BLOCK
        else:
            out.append([off, off + BLOCK])
    return [(a, b - a) for a, b in out]


def hdr(off, length):
    return off.to_bytes(3, "big") + length.to_bytes(3, "big")


def check_sums(fd, image, ranges):
    ok = True
    for off, n in ranges:
        got = command(fd, b"S" + hdr(off, n), 10)
        want = "%08X" % (sum(image[off:off + n]) & 0xFFFFFFFF)
        print("  sum $%05X+$%05X: board %s, file %s %s"
              % (off, n, got, want, "ok" if got == want else "MISMATCH"))
        ok &= got == want
    got = command(fd, b"s", 10)
    want = "%08X" % (sum(image) & 0xFFFFFFFF)
    print("  sum of all 256K: board %s, file %s %s"
          % (got, want, "ok" if got == want else "MISMATCH"))
    return ok and got == want


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    opts = {a for a in sys.argv[1:] if a.startswith("--")}
    if len(args) < 1 or (len(args) < 2 and "--id" not in opts):
        print(__doc__)
        return 2
    fd = open_port(args[0], "--no-rtscts" not in opts)

    print("Waiting for FLASHBOOT (press reset on the board if nothing happens)...")
    while True:
        try:
            command(fd, b"F", 3)    # SERTEST: start FLASHBOOT; FLASHBOOT: "?"
            break
        except TimeoutError:
            pass
    time.sleep(0.3)                     # drop a banner/prompt still in transit
    termios.tcflush(fd, termios.TCIFLUSH)
    reply = command(fd, b"I", 3)
    print("  " + reply.replace("\r\n", "\n  "))
    if "BFB6" not in reply:
        print("Flash ID is not BFB6 (SST39SF020A); stopping.")
        return 1
    if "--id" in opts:
        return 0

    image = open(args[1], "rb").read()
    if len(image) > FLASH_SIZE:
        print("Image is larger than 256K")
        return 1
    image = image + b"\xff" * (FLASH_SIZE - len(image))
    ranges = ranges_of(image)

    if "--verify" not in opts:
        print("Chip erase and blank check...")
        reply = command(fd, b"E", 15)
        print("  " + reply)
        if not reply.endswith("OK"):
            return 1
        for off, n in ranges:
            print("Programming $%05X-$%05X (%d bytes)..." % (0x80000 + off, 0x80000 + off + n - 1, n))
            send(fd, b"P" + hdr(off, n))
            t0 = time.time()
            for i in range(0, n, 1024):
                send(fd, image[off + i:off + min(i + 1024, n)])
                done = min(i + 1024, n)
                print("\r  %3d%%  %5.1f s" % (100 * done // n, time.time() - t0), end="", flush=True)
            print()
            reply = read_until_prompt(fd, 30)
            print("  " + reply)
            if not reply.endswith("OK"):
                return 1

    print("Verifying...")
    if check_sums(fd, image, ranges):
        print("Done: the flash matches %s." % args[1])
        return 0
    print("The flash does NOT match the image.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
