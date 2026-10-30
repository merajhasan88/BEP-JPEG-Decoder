#!/usr/bin/env python3
"""
Based in part on the work of the Independent JPEG Group: the integer arithmetic reproduces
libjpeg / libjpeg-turbo so that the output is bit-identical to them (see ../NOTICE.md).

Bit-exact Python reference model of a baseline JPEG decoder (ITU T.81, SOF0, 8-bit,
Huffman).  Arithmetic is a faithful port of libjpeg 9e with `-dct int -nosmooth`:
  * jidctint.c  jpeg_idct_islow     (CONST_BITS=13, PASS1_BITS=2, RANGE_BITS=2)
  * jdsample.c  h2v1/h2v2_upsample  (box replication, no "fancy" DCT scaling)
  * jdcolor.c   build_ycc_rgb_table / ycc_rgb_convert (SCALEBITS=16)
so its output must equal `djpeg -dct int -nosmooth -pnm file.jpg` byte for byte.

It is the golden reference for the RTL in ../rtl and can dump every intermediate
(quantised coefficients, dequantised blocks, IDCT samples) for debugging.

Usage:
  jpeg_golden.py in.jpg out.pnm [--profile djpeg9|pillow] [--upsample box|fancy] [--cc libjpeg9|turbo]
                 [--out rgb|ycbcr|y] [--dump blocks.txt] [--maxblocks N]
"""
import sys, struct

# T.81 Figure A.6 zig-zag sequence: ZZ[k] -> natural (row-major) index
ZIGZAG = [
     0, 1, 8,16, 9, 2, 3,10,17,24,32,25,18,11, 4, 5,
    12,19,26,33,40,48,41,34,27,20,13, 6, 7,14,21,28,
    35,42,49,56,57,50,43,36,29,22,15,23,30,37,44,51,
    58,59,52,45,38,31,39,46,53,60,61,54,47,55,62,63]

# ---------------------------------------------------------------- Huffman
class HuffTable:
    """Annex C / F.2.2.3 tables: mincode, maxcode, valptr per code length."""
    def __init__(self, bits, huffval):
        self.bits, self.huffval = bits, huffval
        self.mincode = [0]*17; self.maxcode = [-1]*17; self.valptr = [0]*17
        code = 0; k = 0
        for l in range(1, 17):
            n = bits[l-1]
            if n:
                self.valptr[l] = k; self.mincode[l] = code
                code += n; self.maxcode[l] = code - 1; k += n
            else:
                self.maxcode[l] = -1
            code <<= 1
        # also the plain (length, code)->symbol map, handy for dumps
        self.codes = {}
        code = 0; k = 0
        for l in range(1, 17):
            for _ in range(bits[l-1]):
                self.codes[(l, code)] = huffval[k]; code += 1; k += 1
            code <<= 1

class BitReader:
    """F.2.2.5 style reader with FF00 un-stuffing; stops (returns 0-bits) at a marker."""
    def __init__(self, data, pos):
        self.data, self.pos = data, pos
        self.acc, self.n = 0, 0
        self.marker = None      # marker code hit while filling (e.g. 0xD0..0xD7, 0xD9)
    def _fill(self):
        while self.n <= 24:
            if self.marker is not None:
                self.acc = (self.acc << 8); self.n += 8; continue     # pad zeros (T.81 F.2.2.5 note)
            b = self.data[self.pos]; self.pos += 1
            if b == 0xFF:
                nxt = self.data[self.pos]
                if nxt == 0x00:
                    self.pos += 1                                       # stuffed byte
                else:
                    self.marker = nxt; self.pos -= 1                    # leave marker in stream
                    continue
            self.acc = (self.acc << 8) | b; self.n += 8
    def bit(self):
        if self.n == 0: self._fill()
        self.n -= 1
        return (self.acc >> self.n) & 1
    def bits(self, s):
        v = 0
        for _ in range(s): v = (v << 1) | self.bit()
        return v
    def restart(self):
        """Consume the RSTn marker that must follow (F.2.2.5); residual prefetched bits are padding."""
        self.acc, self.n = 0, 0
        if self.marker is None:                       # marker not reached by the prefetch yet
            while not (self.data[self.pos] == 0xFF and 0xD0 <= self.data[self.pos+1] <= 0xD7):
                self.pos += 1
            self.marker = self.data[self.pos+1]
        assert 0xD0 <= self.marker <= 0xD7, "expected RSTn, got %r" % self.marker
        assert self.data[self.pos] == 0xFF and self.data[self.pos+1] == self.marker
        self.pos += 2; self.marker = None

def huff_decode(br, tbl):
    """F.2.2.3 DECODE"""
    code = 0
    for l in range(1, 17):
        code = (code << 1) | br.bit()
        if tbl.maxcode[l] >= 0 and code <= tbl.maxcode[l]:
            return tbl.huffval[tbl.valptr[l] + code - tbl.mincode[l]], l, code
    raise ValueError("bad Huffman code")

def extend(v, s):
    """F.2.2.1 EXTEND"""
    if s == 0: return 0
    return v - (1 << s) + 1 if v < (1 << (s-1)) else v

# ---------------------------------------------------------------- IDCT (jidctint.c islow)
CONST_BITS, PASS1_BITS = 13, 2
FIX_0_298631336, FIX_0_390180644, FIX_0_541196100, FIX_0_765366865 = 2446, 3196, 4433, 6270
FIX_0_899976223, FIX_1_175875602, FIX_1_501321110, FIX_1_847759065 = 7373, 9633, 12299, 15137
FIX_1_961570560, FIX_2_053119869, FIX_2_562915447, FIX_3_072711026 = 16069, 16819, 20995, 25172
RANGE_CENTER = 128 << 2          # RANGE_BITS = 2
RANGE_MASK = RANGE_CENTER*2 - 1  # 1023

# The decoder's documented 16-bit limits (rtl/jpeg_coefdec.sv, jpeg_huffdec*.sv, jpeg_idct*.sv): the
# dequantised coefficient and the IDCT's pass-1 workspace saturate to 16 bits, where libjpeg keeps an int.
# Images from 8-bit sources never reach these limits (all test images: SAT[0] stays 0), so the model is
# libjpeg 9e's arithmetic for them; for synthetic extreme files (tb/make_arith.py) it is the decoder's.
SAT = [0]                        # saturations so far (Decoder.run resets it; Decoder.saturations)
def sat16(v):
    if v > 32767: SAT[0] += 1; return 32767
    if v < -32768: SAT[0] += 1; return -32768
    return v
def wrap16(v):
    """(JCOEF) s of libjpeg's decode_mcu = the decoder's 16-bit DC predictor"""
    return ((v + 32768) & 0xFFFF) - 32768

def range_limit(v):
    """IDCT_range_limit[(v) & RANGE_MASK] of libjpeg 9 (sample_range_limit - RANGE_SUBSET)."""
    v &= RANGE_MASK
    if v < RANGE_CENTER - 128: return 0
    if v < RANGE_CENTER + 128: return v - (RANGE_CENTER - 128)
    return 255

def idct_1d_core(x0, x1, x2, x3, x4, x5, x6, x7, z2_pre, z3_pre):
    """Shared even/odd butterfly of jpeg_idct_islow. z2_pre/z3_pre are the already
    prepared (shifted / fudge-added) DC and x4 terms; x1..x7 are the raw inputs."""
    tmp0 = z2_pre + z3_pre
    tmp1 = z2_pre - z3_pre
    z2, z3 = x2, x6
    z1 = (z2 + z3) * FIX_0_541196100
    tmp2 = z1 + z2 * FIX_0_765366865
    tmp3 = z1 - z3 * FIX_1_847759065
    tmp10, tmp13 = tmp0 + tmp2, tmp0 - tmp2
    tmp11, tmp12 = tmp1 + tmp3, tmp1 - tmp3
    t0, t1, t2, t3 = x7, x5, x3, x1
    z2, z3 = t0 + t2, t1 + t3
    z1 = (z2 + z3) * FIX_1_175875602
    z2 = z2 * (-FIX_1_961570560) + z1
    z3 = z3 * (-FIX_0_390180644) + z1
    z1 = (t0 + t3) * (-FIX_0_899976223)
    t0 = t0 * FIX_0_298631336 + z1 + z2
    t3 = t3 * FIX_1_501321110 + z1 + z3
    z1 = (t1 + t2) * (-FIX_2_562915447)
    t1 = t1 * FIX_2_053119869 + z1 + z3
    t2 = t2 * FIX_3_072711026 + z1 + z2
    return (tmp10 + t3, tmp11 + t2, tmp12 + t1, tmp13 + t0,
            tmp13 - t0, tmp12 - t1, tmp11 - t2, tmp10 - t3)

def idct_islow(coef):
    """coef: 64 dequantised coefficients in natural order -> 64 samples 0..255 (row-major)."""
    ws = [0]*64
    for c in range(8):                          # pass 1: columns
        x = [coef[8*r + c] for r in range(8)]
        z2 = (x[0] << CONST_BITS) + (1 << (CONST_BITS - PASS1_BITS - 1))
        z3 = x[4] << CONST_BITS
        out = idct_1d_core(x[0], x[1], x[2], x[3], x[4], x[5], x[6], x[7], z2, z3)
        for r in range(8):
            ws[8*r + c] = sat16(out[r] >> (CONST_BITS - PASS1_BITS))   # the decoder's 16-bit workspace
    res = [0]*64
    for r in range(8):                          # pass 2: rows
        w = ws[8*r:8*r+8]
        # libjpeg: z2 = ws[0] + (RANGE_CENTER<<(PASS1_BITS+3)) + (1<<(PASS1_BITS+2)); z3 = ws[4];
        #          tmp0 = (z2+z3)<<CONST_BITS ; tmp1 = (z2-z3)<<CONST_BITS
        z2p = w[0] + (RANGE_CENTER << (PASS1_BITS+3)) + (1 << (PASS1_BITS+2))
        out = idct_1d_core(w[0], w[1], w[2], w[3], w[4], w[5], w[6], w[7],
                           z2p << CONST_BITS, w[4] << CONST_BITS)
        for c in range(8):
            res[8*r + c] = range_limit(out[c] >> (CONST_BITS + PASS1_BITS + 3))
    return res

# ---------------------------------------------------------------- colour (jdcolor.c)
# libjpeg 9 uses FIX(0.344136286) = 22553 and FIX(0.714136286) = 46802 for the G term;
# libjpeg 6b / libjpeg-turbo (what Pillow, OpenCV use) use FIX(0.34414) = 22554 and
# FIX(0.71414) = 46802.  Only the Cb->G constant differs, by one LSB.
SCALEBITS = 16; ONE_HALF = 1 << (SCALEBITS-1)
def FIXC(x): return int(x * (1 << SCALEBITS) + 0.5)
Cr_r = [ (FIXC(1.402)*(i-128) + ONE_HALF) >> SCALEBITS for i in range(256)]
Cb_b = [ (FIXC(1.772)*(i-128) + ONE_HALF) >> SCALEBITS for i in range(256)]
CB_G_CONST = {'libjpeg9': FIXC(0.344136286), 'turbo': FIXC(0.34414)}
CR_G_CONST = {'libjpeg9': FIXC(0.714136286), 'turbo': FIXC(0.71414)}
def clamp8(v): return 0 if v < 0 else 255 if v > 255 else v
def make_ycc_to_rgb(cc='libjpeg9'):
    cbg, crg = CB_G_CONST[cc], CR_G_CONST[cc]
    Cr_g = [(-crg)*(i-128) for i in range(256)]
    Cb_g = [(-cbg)*(i-128) + ONE_HALF for i in range(256)]
    def conv(y, cb, cr):
        return (clamp8(y + Cr_r[cr]),
                clamp8(y + ((Cb_g[cb] + Cr_g[cr]) >> SCALEBITS)),
                clamp8(y + Cb_b[cb]))
    return conv
ycc_to_rgb = make_ycc_to_rgb('libjpeg9')

# ---------------------------------------------------------------- upsampling
def upsample_plane(plane, pw, cw, ch, W, H, uh, uv, fancy):
    """Full-resolution W x H plane from one component plane (padded pitch pw, true size cw x ch).
    uh/uv: component is subsampled 2:1 horizontally/vertically relative to Hmax/Vmax.
    fancy=False: sample replication (libjpeg -nosmooth, h2v1/h2v2_upsample).
    fancy=True : libjpeg-turbo's triangle filter (jdsample.c h2v1/h1v2/h2v2_fancy_upsample),
                 written as one formula:  out = (3*cs[i] + cs[neighbour] + bias) >> 4  with
                 cs = 3*near_row + far_row (vertical fancy) or 4*near_row, edges replicated
                 at the true component size (jdmainct.c duplicates the last real row)."""
    hf = fancy and uh and cw > 2                   # turbo: fancy only if downsampled_width > 2
    vf = fancy and uv and (not uh or cw > 2)       # h2v2 with width <= 2 falls back to box
    out = bytearray(W * H)
    for y in range(H):
        cr = (y >> 1) if uv else y
        if vf:
            v = y & 1
            far = min(max(cr + 1 if v else cr - 1, 0), ch - 1)
            rn, rf = cr * pw, far * pw
            cs = [3 * plane[rn + i] + plane[rf + i] for i in range(cw)]
        else:
            v = 0
            rn = cr * pw
            cs = [4 * plane[rn + i] for i in range(cw)]
        o = y * W
        for x in range(W):
            if uh:
                i = x >> 1
                if hf:
                    if x & 1 == 0: nb = cs[max(i - 1, 0)];      bias = 8 if vf else 4
                    else:          nb = cs[min(i + 1, cw - 1)]; bias = 7 if vf else 8
                else:
                    nb = cs[i]; bias = 0
            else:
                i = x; nb = cs[i]
                bias = (4 if v == 0 else 8) if vf else 0
            out[o + x] = (3 * cs[i] + nb + bias) >> 4
    return out

def upsample_plane_turbo_ref(plane, pw, cw, ch, W, H, uh, uv):
    """Literal transcription of libjpeg-turbo's C loops, used only to cross-check upsample_plane."""
    def row(r): r = min(max(r, 0), ch - 1); return plane[r*pw : r*pw + cw]
    rows = []
    if uh and uv and cw > 2:                       # h2v2_fancy_upsample
        for inrow in range((H + 1) // 2):
            for v in range(2):
                in0 = row(inrow); in1 = row(inrow - 1 if v == 0 else inrow + 1)
                o = []
                this = in0[0]*3 + in1[0]; nxt = in0[1]*3 + in1[1]
                o.append((this*4 + 8) >> 4); o.append((this*3 + nxt + 7) >> 4)
                last = this; this = nxt
                for c in range(2, cw):
                    nxt = in0[c]*3 + in1[c]
                    o.append((this*3 + last + 8) >> 4); o.append((this*3 + nxt + 7) >> 4)
                    last = this; this = nxt
                o.append((this*3 + last + 8) >> 4); o.append((this*4 + 7) >> 4)
                rows.append(o)
    elif uh and not uv and cw > 2:                 # h2v1_fancy_upsample
        for r in range(H):
            inp = row(r); o = [inp[0], (inp[0]*3 + inp[1] + 2) >> 2]
            for c in range(1, cw - 1):
                t = inp[c]*3; o.append((t + inp[c-1] + 1) >> 2); o.append((t + inp[c+1] + 2) >> 2)
            o.append((inp[cw-1]*3 + inp[cw-2] + 1) >> 2); o.append(inp[cw-1])
            rows.append(o)
    elif uv and not uh:                            # h1v2_fancy_upsample
        for inrow in range((H + 1) // 2):
            for v in range(2):
                in0 = row(inrow); in1 = row(inrow - 1 if v == 0 else inrow + 1); bias = 1 if v == 0 else 2
                rows.append([(in0[c]*3 + in1[c] + bias) >> 2 for c in range(cw)])
    else:                                          # replication (incl. width <= 2 fallback) / full size
        for y in range(H):
            r = row(y >> 1 if uv else y)
            rows.append([r[x >> 1 if uh else x] for x in range(W)])
    out = bytearray(W * H)
    for y in range(H): out[y*W:(y+1)*W] = bytes(rows[y][:W])
    return out

# ---------------------------------------------------------------- decoder
class Decoder:
    def __init__(self, data, dump=None, maxblocks=None, upsample='box', cc='libjpeg9', out='rgb', crosscheck=False):
        self.data = data; self.dump = dump; self.maxblocks = maxblocks
        self.upsample, self.cc, self.out, self.crosscheck = upsample, cc, out, crosscheck
        self.qt = {}; self.dc = {}; self.ac = {}; self.ri = 0
        self.frame = None; self.nblocks_dumped = 0
        self.saw_jfif = self.saw_adobe = False; self.adobe_transform = None   # libjpeg examine_app0/app14
    def u16(self, p): return (self.data[p] << 8) | self.data[p+1]
    def run(self):
        SAT[0] = 0
        try: return self._run()
        finally: self.saturations = SAT[0]
    def _run(self):
        d = self.data; p = 0
        assert d[0] == 0xFF and d[1] == 0xD8, "no SOI"; p = 2
        while True:
            assert d[p] == 0xFF, "marker expected at %d" % p
            while d[p] == 0xFF: p += 1               # fill bytes allowed (B.1.1.2)
            m = d[p]; p += 1
            if m == 0xD9: break
            L = self.u16(p); seg = d[p+2:p+L]
            if m == 0xDB:   self.parse_dqt(seg)
            elif m == 0xC4: self.parse_dht(seg)
            elif m == 0xC0: self.parse_sof(seg)
            elif m in (0xC1,0xC2,0xC3,0xC5,0xC6,0xC7,0xC9,0xCA,0xCB,0xCD,0xCE,0xCF):
                raise ValueError("unsupported SOF type FF%02X (only baseline SOF0)" % m)
            elif m == 0xDD: self.ri = self.u16(p+2)
            elif m == 0xE0 and len(seg) >= 14 and seg[:5] == b"JFIF\0": self.saw_jfif = True
            elif m == 0xEE and len(seg) >= 12 and seg[:5] == b"Adobe":
                self.saw_adobe = True; self.adobe_transform = seg[11]
            elif m == 0xF8:
                raise ValueError("unsupported: LSE marker (libjpeg 9 colour transform)")
            elif m == 0xDA:
                p = self.decode_scan(seg, p + L); continue
            # APPn, COM, DNL, etc: skip
            p += L
        return self.output()

    def parse_dqt(self, seg):
        p = 0
        while p < len(seg):
            pq, tq = seg[p] >> 4, seg[p] & 15; p += 1
            assert pq == 0, "16-bit quant tables are not allowed in baseline"
            q = [0]*64
            for k in range(64): q[ZIGZAG[k]] = seg[p+k]          # DQT is in zig-zag order
            self.qt[tq] = q; p += 64
    def parse_dht(self, seg):
        p = 0
        while p < len(seg):
            tc, th = seg[p] >> 4, seg[p] & 15; p += 1
            bits = list(seg[p:p+16]); p += 16
            n = sum(bits); vals = list(seg[p:p+n]); p += n
            (self.ac if tc else self.dc)[th] = HuffTable(bits, vals)
    def parse_sof(self, seg):
        P, H, W, Nf = seg[0], (seg[1]<<8)|seg[2], (seg[3]<<8)|seg[4], seg[5]
        assert P == 8, "only 8-bit precision"
        comps = []
        for i in range(Nf):
            cid, hv, tq = seg[6+3*i], seg[7+3*i], seg[8+3*i]
            comps.append(dict(id=cid, h=hv>>4, v=hv&15, tq=tq))
        hmax = max(c['h'] for c in comps); vmax = max(c['v'] for c in comps)
        if Nf == 1: hmax = vmax = comps[0]['h'] = comps[0]['v'] = 1   # non-interleaved: factors irrelevant
        mcux = (W + 8*hmax - 1) // (8*hmax); mcuy = (H + 8*vmax - 1) // (8*vmax)
        for c in comps:
            c['bw'] = mcux * c['h']; c['bh'] = mcuy * c['v']           # padded plane size in blocks
            c['plane'] = bytearray(c['bw']*8 * c['bh']*8)
        self.frame = dict(W=W, H=H, comps=comps, hmax=hmax, vmax=vmax, mcux=mcux, mcuy=mcuy)

    def decode_block(self, br, comp, pred, bx, by, mcu_no, blk_no):
        """F.2.2.1/F.2.2.2: returns new DC predictor; writes samples into the component plane."""
        zz = [0]*64
        t, l, code = huff_decode(br, comp['dct'])
        diff = extend(br.bits(t), t) if t else 0
        pred = wrap16(pred + diff); zz[0] = pred
        k = 1
        while k < 64:
            rs, l, code = huff_decode(br, comp['act'])
            r, s = rs >> 4, rs & 15
            if s == 0:
                if r == 15: k += 16; continue
                break                                                    # EOB
            k += r
            if k > 63: raise ValueError("AC run past end of block")
            zz[k] = extend(br.bits(s), s); k += 1
        q = self.qt[comp['tq']]
        coef = [0]*64
        for k in range(64): coef[ZIGZAG[k]] = sat16(zz[k] * q[ZIGZAG[k]])   # dequantised, 16-bit as in the decoder
        samp = idct_islow(coef)
        if self.dump is not None and (self.maxblocks is None or self.nblocks_dumped < self.maxblocks):
            self.dump.write("BLOCK mcu=%d n=%d comp=%d bx=%d by=%d dcpred=%d\n" % (mcu_no, blk_no, comp['id'], bx, by, pred))
            self.dump.write("  ZZ   " + " ".join(str(v) for v in zz) + "\n")
            self.dump.write("  COEF " + " ".join(str(v) for v in coef) + "\n")
            self.dump.write("  SAMP " + " ".join(str(v) for v in samp) + "\n")
            self.nblocks_dumped += 1
        pw = comp['bw']*8
        for r in range(8):
            base = (by*8 + r)*pw + bx*8
            comp['plane'][base:base+8] = bytes(samp[8*r:8*r+8])
        return pred

    def decode_scan(self, seg, p):
        f = self.frame; Ns = seg[0]
        scomps = []
        for j in range(Ns):
            cs, tdta = seg[1+2*j], seg[2+2*j]
            c = next(c for c in f['comps'] if c['id'] == cs)
            c['dct'] = self.dc[tdta >> 4]; c['act'] = self.ac[tdta & 15]; scomps.append(c)
        ss, se, ahal = seg[1+2*Ns], seg[2+2*Ns], seg[3+2*Ns]
        assert (ss, se, ahal) == (0, 63, 0), "baseline scan expected"
        br = BitReader(self.data, p)
        pred = {c['id']: 0 for c in scomps}
        if Ns == 1:
            c = scomps[0]
            # T.81 A.2.2: ceil(ceil(X*Hi/Hmax)/8) blocks per line for a non-interleaved scan
            bw = (f['W']*c['h'] + 8*f['hmax'] - 1) // (8*f['hmax'])
            bh = (f['H']*c['v'] + 8*f['vmax'] - 1) // (8*f['vmax'])
            n = 0
            for by in range(bh):
                for bx in range(bw):
                    if self.ri and n and n % self.ri == 0:
                        br.restart(); pred = {k: 0 for k in pred}
                    pred[c['id']] = self.decode_block(br, c, pred[c['id']], bx, by, n, 0); n += 1
        else:
            n = 0
            for my in range(f['mcuy']):
                for mx in range(f['mcux']):
                    if self.ri and n and n % self.ri == 0:
                        br.restart(); pred = {k: 0 for k in pred}
                    b = 0
                    for c in scomps:
                        for v in range(c['v']):
                            for h in range(c['h']):
                                pred[c['id']] = self.decode_block(br, c, pred[c['id']], mx*c['h']+h, my*c['v']+v, n, b); b += 1
                    n += 1
        # skip to the marker that ends the entropy-coded segment
        p = br.pos
        while not (self.data[p] == 0xFF and self.data[p+1] != 0 and not (0xD0 <= self.data[p+1] <= 0xD7)): p += 1
        return p

    def colour_space(self):
        """libjpeg 9e jdapimin.c default_decompress_parms for 3 components: component IDs first, then the
        JFIF APP0, then the Adobe APP14 transform; 'ycc' or 'rgb' (big-gamut IDs are not supported)"""
        comps = self.frame['comps']
        if len(comps) != 3: return 'ycc'
        ids = tuple(c['id'] for c in comps)
        if ids == (1, 2, 3): return 'ycc'
        if ids in ((1, 0x22, 0x23), (0x72, 0x67, 0x62)):
            raise ValueError("unsupported: libjpeg 9 big-gamut colour space (component IDs %r)" % (ids,))
        if ids == (0x52, 0x47, 0x42): return 'rgb'
        if self.saw_jfif: return 'ycc'
        if self.saw_adobe and self.adobe_transform == 0: return 'rgb'
        return 'ycc'

    def output(self):
        """rgb  : P6 R,G,B (grey images: P5 Y, like djpeg)
           ycbcr: P6 Y,Cb,Cr after upsampling, no colour conversion (grey images: Y,128,128)
           y    : P5 luma only (component 0), chroma never needed"""
        f = self.frame; W, H = f['W'], f['H']; comps = f['comps']
        hmax, vmax = f['hmax'], f['vmax']
        rgb = self.colour_space() == 'rgb'
        if rgb and self.out != 'rgb':
            raise ValueError("unsupported: %s output of an RGB image (the decoder gives RGB only)" % self.out)
        use = comps[:1] if (self.out == 'y' or len(comps) == 1) else comps
        assert len(comps) in (1, 3), "only 1- or 3-component images"
        planes = []
        for c in use:
            pw = c['bw'] * 8
            uh, uv = hmax // c['h'] == 2, vmax // c['v'] == 2
            cw = -(-W * c['h'] // hmax); ch = -(-H * c['v'] // vmax)
            p = upsample_plane(c['plane'], pw, cw, ch, W, H, uh, uv, self.upsample == 'fancy')
            if self.crosscheck and self.upsample == 'fancy':
                ref = upsample_plane_turbo_ref(c['plane'], pw, cw, ch, W, H, uh, uv)
                assert p == ref, "unified fancy formula disagrees with the turbo transcription"
            planes.append(p)
        if self.out == 'y' or (len(comps) == 1 and self.out == 'rgb'):
            return b"P5\n%d %d\n255\n" % (W, H) + bytes(planes[0])
        n = W * H; out = bytearray(3 * n)
        if len(planes) == 1:                                     # grey image, ycbcr output
            out[0::3] = planes[0]; out[1::3] = bytes([128]) * n; out[2::3] = bytes([128]) * n
        elif self.out == 'ycbcr' or rgb:                         # an RGB image: its components as they are
            out[0::3], out[1::3], out[2::3] = planes[0], planes[1], planes[2]
        else:
            conv = make_ycc_to_rgb(self.cc)
            for k in range(n):
                out[3*k], out[3*k+1], out[3*k+2] = conv(planes[0][k], planes[1][k], planes[2][k])
        return b"P6\n%d %d\n255\n" % (W, H) + bytes(out)

if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description="bit-exact reference JPEG decoder (baseline)")
    ap.add_argument("jpg"); ap.add_argument("out_pnm")
    ap.add_argument("--upsample", choices=["box", "fancy"], default="box",
                    help="box = libjpeg -nosmooth (default); fancy = libjpeg-turbo triangle filter")
    ap.add_argument("--cc", choices=["libjpeg9", "turbo"], default="libjpeg9",
                    help="YCbCr->RGB constants of libjpeg 9 (default) or libjpeg-turbo")
    ap.add_argument("--out", choices=["rgb", "ycbcr", "y"], default="rgb")
    ap.add_argument("--profile", choices=["djpeg9", "pillow"],
                    help="djpeg9 = box+libjpeg9 (djpeg 9e -dct int -nosmooth); pillow = fancy+turbo")
    ap.add_argument("--crosscheck", action="store_true", help="also run the literal turbo transcription")
    ap.add_argument("--dump"); ap.add_argument("--maxblocks", type=int)
    a = ap.parse_args()
    if a.profile == "djpeg9": a.upsample, a.cc = "box", "libjpeg9"
    if a.profile == "pillow": a.upsample, a.cc = "fancy", "turbo"
    dump = open(a.dump, "w") if a.dump else None
    data = open(a.jpg, "rb").read()
    out = Decoder(data, dump, a.maxblocks, a.upsample, a.cc, a.out, a.crosscheck).run()
    open(a.out_pnm, "wb").write(out)
    if dump: dump.close()
