#!/usr/bin/env python3
"""Save the norns screen as a PNG, 4x size, read with screen.peek through the
matron REPL. Usage: tools/screenshot.py OUT.png [-H host]"""
import os, struct, subprocess, sys, zlib

out = sys.argv[1]
here = os.path.dirname(os.path.abspath(__file__))
lua = ('local p = screen.peek(0,0,128,64); local t = {}; '
       'for i = 1, #p do t[#t+1] = string.format("%x", p:byte(i)) end; '
       'print("PX" .. table.concat(t))')
res = subprocess.run([os.path.join(here, "repl.py"), "-w", "2"] + sys.argv[2:] + [lua],
                     capture_output=True, text=True).stdout
line = next(l for l in res.splitlines() if l.startswith("PX"))
lv = [int(c, 16) for c in line[2:]]
scale = 4
rows = bytearray()
for y in range(64 * scale):
    rows.append(0)
    for x in range(128 * scale):
        v = lv[(y // scale) * 128 + x // scale] * 17
        rows += bytes((v, v, v))

def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)

with open(out, "wb") as f:
    f.write(b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", 128 * scale, 64 * scale, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(rows)))
            + chunk(b"IEND", b""))
