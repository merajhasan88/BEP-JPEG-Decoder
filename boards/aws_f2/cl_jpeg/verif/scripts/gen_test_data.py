#!/usr/bin/env python3
"""Writes ../tests/cl_jpeg_test_data.svh for AWS's XSIM test of the CL (cl_jpeg_test.sv): two corpus files (bytes, padded
with zeros to whole 64-byte beats, as the F2 host writes them) and
their golden images' position-binding hash (mem_lane.sv's mix, summed over every pixel), width, height and pixels.
  gen_test_data.py            (golden: tb/golden/<name>.box.rgb.pnm, the libjpeg 9e profile)"""
import os
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", "..", "..", ".."))
FILES = ["adp_16x16_q25_420", "adp_45x37_q30_420_rst2"]
M = (1 << 64) - 1
def mix(v):
    z = (v + 0x9E3779B97F4A7C15) & M
    z = ((z ^ (z >> 30)) + (z << 7)) & M
    z = ((z ^ (z >> 27)) + (z << 13)) & M
    return z ^ (z >> 31)
def ppm(p):
    d = open(p, "rb").read(); parts = []; i = 2
    while len(parts) < 3:
        while d[i:i+1].isspace(): i += 1
        if d[i:i+1] == b"#":
            while d[i:i+1] != b"\n": i += 1
            continue
        j = i
        while d[j:j+1].isdigit(): j += 1
        parts.append(int(d[i:j])); i = j
    w, h = parts[0], parts[1]; px = d[i+1:]
    if d[1:2] == b"5": px = bytes(b for v in px[:w*h] for b in (v, v, v))
    return w, h, px[:3*w*h]
out = ["// cl_jpeg_test_data.svh - written by ../scripts/gen_test_data.py: the test files and their golden images' hashes",
       f"localparam int NFILES = {len(FILES)};"]
lens = []
for k, b in enumerate(FILES):
    data = open(os.path.join(REPO, "tb", "corpus", b + ".jpg"), "rb").read()
    w, h, px = ppm(os.path.join(REPO, "tb", "golden", b + ".box.rgb.pnm"))
    hs = 0
    for y in range(h):
        for x in range(w):
            p = 3 * (y * w + x)
            hs = (hs + mix((y << 48) | (x << 32) | (px[p] << 16) | (px[p+1] << 8) | px[p+2])) & M
    lens.append(len(data))
    out.append(f"// {b}.jpg: {len(data)} bytes, {w}x{h}")
    out.append(f"localparam int LEN{k} = {len(data)}; localparam int W{k} = {w}; localparam int H{k} = {h};")
    out.append(f"localparam logic [63:0] HASH{k} = 64'h{hs:016X};")
    padded = data + bytes((-len(data)) % 64)              # whole 64-byte beats: no partial DDR4 write (ECC, X in models)
    words = [int.from_bytes(padded[i:i+4], "little") for i in range(0, len(padded), 4)]
    out.append(f"localparam int NW{k} = {len(words)};   // words written: the file padded with zeros to whole 64-byte beats")
    out.append(f"logic [31:0] JPG{k} [0:{len(words)-1}] = '{{")
    for i in range(0, len(words), 8):
        out.append("  " + ", ".join(f"32'h{v:08X}" for v in words[i:i+8]) + ("," if i + 8 < len(words) else ""))
    out.append("};")
open(os.path.join(HERE, "..", "tests", "cl_jpeg_test_data.svh"), "w").write("\n".join(out) + "\n")
print("written:", ", ".join(f"{b} ({n} bytes)" for b, n in zip(FILES, lens)))
