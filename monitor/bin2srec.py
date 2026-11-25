#!/usr/bin/env python3
"""Turn monitor.bin into S-records that MON68K's LO loads into RAM for FL.

    python3 bin2srec.py monitor.bin [load_address] > monitor.s28

The records start at load_address (default $10000) instead of $80000, so LO
can put the image in user RAM. Records that hold only $FF are left out, which
makes the file much shorter, so fill the RAM with $FF first:

    MF 10000 4FFFF FF
    LO                         (send monitor.s28)
    FL 10000 4FFFF 80000 !

The end record has entry address 0, so LO leaves the PC alone.
"""
import sys

def rec(t, addr, data, alen):
    body = bytes([alen + len(data) + 1]) + addr.to_bytes(alen, "big") + data
    return "S%d%s%02X" % (t, body.hex().upper(), ~sum(body) & 0xFF)

def main():
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    img = open(sys.argv[1], "rb").read()
    base = int(sys.argv[2], 16) if len(sys.argv) == 3 else 0x10000
    if base < 0x1000 or base + len(img) > 0x80000:
        sys.exit("the image must fit in user RAM $01000-$7FFFF")
    out = [rec(0, 0, b"MON68K image for FL", 2)]
    n = 0
    for off in range(0, len(img), 32):
        chunk = img[off:off + 32]
        if chunk.count(0xFF) == len(chunk):
            continue
        out.append(rec(2, base + off, chunk, 3))
        n += 1
    if n <= 0xFFFF:
        out.append(rec(5, n, b"", 2))
    out.append(rec(8, 0, b"", 3))
    sys.stdout.write("\n".join(out) + "\n")

if __name__ == "__main__":
    main()
