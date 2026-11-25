#!/usr/bin/env python3
"""Make flashupd.s28: FLASHUPD at $1000 plus a MON68K image at $10000.

    python3 flashupd/mkflashupd.py flashupd/flashupd.bin monitor.bin > flashupd/flashupd.s28

Stores the 32-bit sum of the image bytes in FLASHUPD (offset 4, after the
"FLASHUPD" check at offset 8), so FLASHUPD can tell whether the whole image
arrived. Image records that hold only $FF are left out, so the RAM must be
filled with $FF before LO (MF 10000 4FFFF FF). The end record's entry
address is $1000, so LO sets the PC and GO starts FLASHUPD.
"""
import sys

PROG, IMG = 0x1000, 0x10000

def rec(t, addr, data, alen):
    body = bytes([alen + len(data) + 1]) + addr.to_bytes(alen, "big") + data
    return "S%d%s%02X" % (t, body.hex().upper(), ~sum(body) & 0xFF)

def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    prog = bytearray(open(sys.argv[1], "rb").read())
    img = open(sys.argv[2], "rb").read()
    if prog[8:16] != b"FLASHUPD":
        sys.exit("flashupd.bin: no FLASHUPD marker at offset 8")
    if len(img) != 0x40000:
        sys.exit("the image must be 256K")
    if PROG + len(prog) > IMG:
        sys.exit("FLASHUPD runs into the image area at $10000")
    prog[4:8] = (sum(img) & 0xFFFFFFFF).to_bytes(4, "big")
    out = [rec(0, 0, b"FLASHUPD + MON68K image", 2)]
    n = 0
    for off in range(0, len(prog), 32):
        out.append(rec(2, PROG + off, bytes(prog[off:off + 32]), 3)); n += 1
    for off in range(0, len(img), 32):
        chunk = img[off:off + 32]
        if chunk.count(0xFF) == len(chunk):
            continue
        out.append(rec(2, IMG + off, chunk, 3)); n += 1
    if n <= 0xFFFF:
        out.append(rec(5, n, b"", 2))
    out.append(rec(8, PROG, b"", 3))
    sys.stdout.write("\n".join(out) + "\n")

if __name__ == "__main__":
    main()
