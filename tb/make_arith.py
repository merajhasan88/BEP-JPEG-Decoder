#!/usr/bin/env python3
"""make_arith.py - synthetic baseline JPEG files at the decoder's arithmetic extremes (the review of 2026-10-10:
"extend arithmetic testing around coefficient extremes and the documented internal saturation limits").

Real encoders working from 8-bit images never come near the decoder's 16-bit limits (dequantised coefficient,
IDCT pass-1 workspace), so the corpus cannot test them. These files are written directly from quantised
coefficients by a minimal baseline encoder (T.81 F.1.2: DC differences, AC run/size symbols, ZRL, EOB; the
Huffman tables of Annex K, K.3: luminance for component 1, chrominance for 2 and 3; byte stuffing; 1-bit
padding), so any coefficient the baseline syntax allows can be placed: DC differences up to +-2047 (category
11), AC values up to +-1023 (category 10), quantisation values 1-255.

Every file is classed by the model (model/jpeg_golden.py, which carries the decoder's 16-bit limits):
  inside   no saturation anywhere: the decoder must equal libjpeg 9e exactly (checked here against djpeg 9e)
  beyond   the model saturates somewhere: the decoder's documented behaviour; libjpeg's wider arithmetic
           differs (the number of differing samples is recorded, not required)
Writes tb/arith/<name>.jpg and tb/arith/cases.json.
  make_arith.py [--check]      (--check: rebuild in memory and compare with the files on disk)"""
import json, os, random, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, ".."))
sys.path.insert(0, os.path.join(REPO, "model"))
import jpeg_golden as G
OUT = os.path.join(HERE, "arith")

# ---- Annex K, K.3 (Tables K.3-K.6): BITS (codes of lengths 1..16) and HUFFVAL, as in libjpeg's jcomapi.c
STD = {
    ("dc", 0): ([0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0], list(range(12))),
    ("dc", 1): ([0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0], list(range(12))),
    ("ac", 0): ([0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d], [
        0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
        0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
        0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
        0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
        0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
        0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
        0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
        0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
        0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
        0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
        0xf9, 0xfa]),
    ("ac", 1): ([0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77], [
        0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
        0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0,
        0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
        0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
        0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
        0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
        0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5,
        0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3,
        0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
        0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
        0xf9, 0xfa]),
}

def codes(bits, vals):
    """Annex C: the code of each symbol (Figures C.1-C.3)"""
    out, code, k = {}, 0, 0
    for l in range(1, 17):
        for _ in range(bits[l - 1]):
            out[vals[k]] = (code, l); code += 1; k += 1
        code <<= 1
    return out

class Bits:
    def __init__(self): self.out = bytearray(); self.acc = 0; self.n = 0
    def put(self, v, n):
        for i in range(n - 1, -1, -1):
            self.acc = (self.acc << 1) | ((v >> i) & 1); self.n += 1
            if self.n == 8:
                self.out.append(self.acc)
                if self.acc == 0xFF: self.out.append(0x00)           # byte stuffing (F.1.2.3)
                self.acc = 0; self.n = 0
    def flush(self):
        while self.n: self.put(1, 1)                                 # pad with 1-bits
        return bytes(self.out)

def size(v): return abs(v).bit_length()                              # SSSS (F.1.2.1.1)
def amp(v, s): return v if v >= 0 else v + (1 << s) - 1              # the low s bits of v - 1 for v < 0

def encode_block(bw, zz, diff, dc, ac):
    """diff: the DC difference (F.1.2.1); zz[1..63]: the AC coefficients in zig-zag order (F.1.2.2)"""
    s = size(diff); assert s <= 11, diff
    c, l = dc[s]; bw.put(c, l)
    if s: bw.put(amp(diff, s), s)
    last = max([k for k in range(1, 64) if zz[k]], default=0)
    run = 0
    for k in range(1, last + 1):
        if zz[k] == 0: run += 1; continue
        while run > 15: c, l = ac[0xF0]; bw.put(c, l); run -= 16     # ZRL
        s = size(zz[k]); assert 1 <= s <= 10, zz[k]
        c, l = ac[(run << 4) | s]; bw.put(c, l); bw.put(amp(zz[k], s), s); run = 0
    if last < 63: c, l = ac[0x00]; bw.put(c, l)                       # EOB

def jpeg(W, H, comps, qt, blocks):
    """comps: [(id, h, v, tq)]; qt: {tq: 64 values in zig-zag order}; blocks: one list per component of zz
    arrays in the component's raster order of blocks (padded to whole MCUs); zz[0] is the block's DC value
    (any integer: the differences are formed here in scan order, as an encoder does, and must fit category 11)"""
    b = bytearray(b"\xFF\xD8")
    for tq, q in sorted(qt.items()):
        assert len(q) == 64 and all(1 <= v <= 255 for v in q)
        b += bytes([0xFF, 0xDB, 0, 67, tq]) + bytes(q)
    b += bytes([0xFF, 0xC0, 0, 8 + 3 * len(comps), 8, H >> 8, H & 255, W >> 8, W & 255, len(comps)])
    for cid, h, v, tq in comps: b += bytes([cid, (h << 4) | v, tq])
    tabs = [("dc", 0), ("ac", 0)] + ([("dc", 1), ("ac", 1)] if len(comps) > 1 else [])
    for kind, th in tabs:
        bits, vals = STD[(kind, th)]
        seg = bytes([(0 if kind == "dc" else 1) << 4 | th]) + bytes(bits) + bytes(vals)
        b += bytes([0xFF, 0xC4, (len(seg) + 2) >> 8, (len(seg) + 2) & 255]) + seg
    b += bytes([0xFF, 0xDA, 0, 6 + 2 * len(comps), len(comps)])
    for i, (cid, h, v, tq) in enumerate(comps): b += bytes([cid, 0x00 if i == 0 else 0x11])
    b += bytes([0, 63, 0])
    hmax, vmax = max(c[1] for c in comps), max(c[2] for c in comps)
    mcux, mcuy = -(-W // (8 * hmax)), -(-H // (8 * vmax))
    cod = {k: codes(*v) for k, v in STD.items()}
    bw = Bits()
    pred = [0] * len(comps)                                           # F.1.2.1: one DC predictor per component
    for my in range(mcuy):
        for mx in range(mcux):
            for i, (cid, h, v, tq) in enumerate(comps):
                bpr = mcux * h                                        # blocks per row of this component
                for by in range(v):
                    for bx in range(h):
                        n = (my * v + by) * bpr + mx * h + bx
                        th = 0 if i == 0 else 1
                        z = blocks[i][n]
                        encode_block(bw, z, z[0] - pred[i], cod[("dc", th)], cod[("ac", th)]); pred[i] = z[0]
    b += bw.flush() + b"\xFF\xD9"
    return bytes(b)

def zz_block(dc=0, ac=None):
    z = [0] * 64; z[0] = dc
    for k, v in (ac or {}).items(): z[k] = v
    return z

def grey(W, H, q, zzs):
    n = (W // 8) * (H // 8)
    zzs = zzs + [zz_block() for _ in range(n - len(zzs))]
    assert len(zzs) == n
    return jpeg(W, H, [(1, 1, 1, 0)], {0: q}, [zzs])

def flat(v): return [v] * 64

def cases():
    rnd = random.Random(20261012)
    c = {}
    # single AC coefficients of the largest magnitude at every zig-zag position, both signs
    one = [zz_block(0, {k: 1023}) for k in range(1, 64)] + [zz_block(0, {k: -1023}) for k in range(1, 64)]
    c["ari_ac1023_q1_grey"] = grey(64, 128, flat(1), one)
    c["ari_ac1023_q32_grey"] = grey(64, 128, flat(32), one)          # dequantised 32,736: below the 16-bit limit
    c["ari_ac1023_q255_grey"] = grey(64, 128, flat(255), one)        # 260,865: far beyond it
    # at the limit: per zig-zag position the largest Q for which a single +-1023 saturates nothing (inside),
    # and that Q + 1 (beyond)
    def inside(k, q):
        coef = [0] * 64; coef[G.ZIGZAG[k]] = G.sat16(1023 * q); n0 = G.SAT[0]
        G.idct_islow(coef); G.idct_islow([-v for v in coef])
        return G.SAT[0] == n0 and 1023 * q <= 32767
    qlim = [1] * 64
    for k in range(64):
        lo = 1
        while lo < 255 and inside(k, lo + 1): lo += 1
        qlim[k] = lo
    c["ari_ac1023_qlimit_grey"] = grey(64, 128, qlim, one)
    c["ari_ac1023_qlimit1_grey"] = grey(64, 128, [min(255, q + 1) for q in qlim], one)
    # every DC value from -1024 to 1023 (differences of 1 after the first): the output range limit's wrap
    sweep = [zz_block(d) for d in range(-1024, 1024)]
    c["ari_dc_sweep_q8_grey"] = grey(256, 512, flat(8), sweep)       # workspace up to exactly -32,768
    c["ari_dc_sweep_q9_grey"] = grey(256, 512, flat(9), sweep)       # beyond at both ends
    # DC predictor beyond 16 bits: libjpeg stores (JCOEF) s, the decoder a 16-bit predictor
    steps = [2047] * 20 + [-2047] * 40 + [2047] * 20 + [5] * 48       # DC values 2,047 ... 40,940 ... -40,940 ...
    wrap = [zz_block(sum(steps[:i + 1])) for i in range(len(steps))]
    c["ari_dc_wrap_grey"] = grey(64, 128, flat(1), wrap)
    # the largest quantisation value with small coefficients (inside), and dense random blocks kept inside
    small = [zz_block(rnd.randint(-4, 4), {k: rnd.randint(-4, 4) for k in rnd.sample(range(1, 64), 6)}) for _ in range(128)]
    c["ari_q255_small_grey"] = grey(64, 128, flat(255), small)
    q_rand = [rnd.randint(1, 255) for _ in range(64)]
    dense, n = [], 0
    while len(dense) < 256:
        r = rnd.choice([2, 4, 8, 16, 32, 64, 128])
        z = [rnd.randint(-r, r) for _ in range(64)]
        coef = [0] * 64
        for k in range(64): coef[G.ZIGZAG[k]] = G.sat16(z[k] * q_rand[k])
        G.SAT[0] = 0; G.idct_islow([G.sat16(v) for v in coef])
        if G.SAT[0] == 0 and all(abs(z[k] * q_rand[k]) <= 32767 for k in range(64)): dense.append(z); n += 1
    c["ari_dense_inside_grey"] = grey(128, 128, q_rand, dense)
    ext = [zz_block(rnd.choice([-1023, 1023]), {k: rnd.choice([-1023, 1023]) for k in range(1, 64)}) for _ in range(64)]
    c["ari_dense_extreme_q1_grey"] = grey(64, 64, flat(1), ext)
    c["ari_dense_extreme_q8_grey"] = grey(64, 64, flat(8), ext)       # dequantised +-8,184: the workspace saturates
    c["ari_dense_extreme_q255_grey"] = grey(64, 64, flat(255), ext)   # every value saturated to +-32,767 first
    # every corner of the IDCT's input box (each input +32,767 or -32,768: +-1023 x 255 saturated). Each
    # intermediate value is linear in the 8 inputs of a 1-D pass, so its largest magnitude is at a corner: if
    # the decoder matches the model at all 256 corners of both passes, no file can overflow its datapath.
    zz_of = {G.ZIGZAG[k]: k for k in range(64)}                     # natural index -> zig-zag position
    def block(nat):                                                  # nat: {natural index: +-1023}
        z = [0] * 64
        for i, v in nat.items(): z[zz_of[i]] = v
        return z
    pats = list(range(256))
    p1 = []                                                          # pass 1 (columns): pattern per column
    for b in range(32):
        nat = {}
        for col in range(8):
            pat = pats[8 * b + col]
            for row in range(8): nat[8 * row + col] = 1023 if (pat >> row) & 1 else -1023
        p1.append(block(nat))
    c["ari_corners_pass1_q255_grey"] = grey(64, 32, flat(255), p1)
    # pass 2 (rows): only the first row of coefficients, so every workspace row is the saturated
    # 4 x coefficient of its column: the row pattern of the block
    p2 = [block({col: (1023 if (pat >> col) & 1 else -1023) for col in range(8)}) for pat in pats]
    c["ari_corners_pass2_q255_grey"] = grey(128, 128, flat(255), p2)
    # colour: 4:2:0 with the chroma DC at its extremes (colour conversion clamps), and 4:4:4 with AC extremes
    W, H = 64, 64
    ny, nc = (W // 8) * (H // 8), (W // 16) * (H // 16)
    ydc = [rnd.randint(-1024, 1023) for _ in range(ny)]
    cbdc = [(-1024 if i % 2 else 1023) for i in range(nc)]
    crdc = [(1023 if i % 3 else -1024) for i in range(nc)]
    blocks = [[zz_block(d) for d in ydc], [zz_block(d) for d in cbdc], [zz_block(d) for d in crdc]]
    c["ari_chroma_dc_q8_420"] = jpeg(W, H, [(1, 2, 2, 0), (2, 1, 1, 1), (3, 1, 1, 1)], {0: flat(8), 1: flat(8)}, blocks)
    n3 = (W // 8) * (H // 8)
    acs = [[zz_block(0, {rnd.randint(1, 63): rnd.choice([-1023, 1023])}) for _ in range(n3)] for _ in range(3)]
    c["ari_ac1023_q1_444"] = jpeg(W, H, [(1, 1, 1, 0), (2, 1, 1, 1), (3, 1, 1, 1)], {0: flat(1), 1: flat(1)}, acs)
    return c

def classify(name, data, djpeg):
    d = G.Decoder(data); out = d.run()
    rec = dict(saturations=d.saturations, cls="inside" if d.saturations == 0 else "beyond", bytes=len(data))
    with tempfile.TemporaryDirectory() as t:
        f = os.path.join(t, name + ".jpg"); open(f, "wb").write(data)
        r = subprocess.run([djpeg, "-dct", "int", "-nosmooth", "-pnm", f], capture_output=True)
        if r.returncode != 0: rec["libjpeg"] = "error: " + r.stderr.decode(errors="replace").strip()[:200]; return rec
        ref = r.stdout
    hdr = lambda b: b.split(b"\n", 3)                                 # P5/P6, size, 255, data (no comments here)
    a, b = hdr(out), hdr(ref)
    if a[:3] != b[:3]: rec["libjpeg"] = "header differs"; return rec
    rec["libjpeg_diff_bytes"] = sum(x != y for x, y in zip(a[3], b[3]))
    return rec

def main():
    sys.path.insert(0, os.path.join(REPO, "bench")); import tools
    djpeg = os.environ.get("LIBJPEG9_DJPEG") or tools.djpeg9()
    cs = cases()
    if "--check" in sys.argv:
        bad = [n for n, d in cs.items() if open(os.path.join(OUT, n + ".jpg"), "rb").read() != d]
        print("identical" if not bad else "differ: " + ", ".join(bad)); return 1 if bad else 0
    os.makedirs(OUT, exist_ok=True)
    meta = {}
    for n, d in cs.items():
        open(os.path.join(OUT, n + ".jpg"), "wb").write(d)
        meta[n] = classify(n, d, djpeg)
        m = meta[n]
        print(f"{n:28s} {m['bytes']:7d} bytes  {m['cls']:6s} saturations {m['saturations']:6d}  "
              f"vs libjpeg 9e: {m.get('libjpeg', str(m.get('libjpeg_diff_bytes')) + ' bytes differ')}")
    json.dump(meta, open(os.path.join(OUT, "cases.json"), "w"), indent=1, sort_keys=True)
    bad = [n for n, m in meta.items() if m["cls"] == "inside" and m.get("libjpeg_diff_bytes") != 0]
    if bad: print("INSIDE BUT DIFFERENT FROM LIBJPEG 9e:", ", ".join(bad)); return 1
    return 0

if __name__ == "__main__":
    sys.exit(main())
