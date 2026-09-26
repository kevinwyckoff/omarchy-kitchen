#!/usr/bin/env python3
# Usage: shot.py <host:port> <out.png>  — QMP screendump (PPM) converted to PNG with stdlib only.
import json, socket, sys, zlib, struct, os, time
sock_path, out = sys.argv[1], sys.argv[2]
ppm = out + ".ppm"
h, p = sock_path.rsplit(":", 1); s = socket.create_connection((h, int(p))); f = s.makefile("rw")
f.readline()
for cmd in ({"execute": "qmp_capabilities"}, {"execute": "screendump", "arguments": {"filename": ppm}}):
    f.write(json.dumps(cmd) + "\n"); f.flush()
    while "return" not in (r := json.loads(f.readline())) and "error" not in r: pass
    if "error" in r: sys.exit(r)
time.sleep(0.2)
data = open(ppm, "rb").read()
parts = data.split(maxsplit=4); w, h = int(parts[1]), int(parts[2]); px = parts[4]
raw = b"".join(b"\x00" + px[y*w*3:(y+1)*w*3] for y in range(h))
chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
open(out, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))
os.remove(ppm); print(f"{out} {w}x{h}")
