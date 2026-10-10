#!/usr/bin/env python3
"""Generate malformed / truncated JPEG files for the decoder's validation tests (tb/malformed/).

Each case is derived from a valid corpus file (tb/corpus/, made from the owner's photos) by one
targeted edit, and has an expectation for tb_jpeg (see run_malformed_tests.py):
  err bits that must be set at frame_done, and whether pixels may appear.
Covers the review items: missing / invalid / incomplete DQT, illegal Huffman tables (over-subscribed,
all-ones code, DC symbol > 11, too short), zero width or height, bad SOF/SOS lengths, repeated
component ids, undefined tables in a scan, RSTn out of order or without DRI, and files cut short
(in_last before EOI) in the headers, in the scan and just before the EOI.  From the review of
2026-10-10: a file that ends inside a comment after its scan (no EOI), DRI lengths other than 4,
impossible segment lengths (0 and 1; SOF / SOS also 2), component ids repeated in both SOF and SOS,
AC symbols outside the baseline domain, and libjpeg 9's colour transforms (LSE marker, big-gamut
ids), which the decoder does not support.
usage: make_malformed.py  (writes tb/malformed/*.jpg and tb/malformed/cases.json)"""
import os, json, struct
HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.join(HERE, "corpus")
OUT = os.path.join(HERE, "malformed")
# error bits (rtl/jpeg_pkg.sv)
SOF_TYPE, DQT, DHT, SCAN, MARKER, SYNC, FRAME, TRUNC = 1 << 0, 1 << 2, 1 << 3, 1 << 6, 1 << 8, 1 << 9, 1 << 11, 1 << 12

def split(data):
    """-> (list of [marker, payload] before SOS, SOS payload, entropy data incl. EOI)"""
    i, segs = 2, []
    while True:
        m = data[i + 1]; L = struct.unpack(">H", data[i + 2:i + 4])[0]
        if m == 0xDA:
            return segs, data[i + 4:i + 2 + L], data[i + 2 + L:]
        segs.append([m, data[i + 4:i + 2 + L]]); i += 2 + L

def join(segs, sos, ent):
    out = bytearray(b"\xFF\xD8")
    for m, p in segs + [[0xDA, sos]]:
        out += bytes([0xFF, m]) + struct.pack(">H", len(p) + 2) + p
    return bytes(out + ent)

def seg(m, p): return bytes([0xFF, m]) + struct.pack(">H", len(p) + 2) + p

def load(name): return open(os.path.join(CORPUS, name + ".jpg"), "rb").read()

def dht(tc_th, bits, vals):
    return bytes([tc_th]) + bytes(bits + [0] * (16 - len(bits))) + bytes(vals)

cases = {}
def add(name, data, bits, pixels):
    """bits: err bits required at frame_done; pixels: False = the frame must have no pixels"""
    open(os.path.join(OUT, name + ".jpg"), "wb").write(data)
    cases[name] = {"err": bits, "pixels": pixels}

def main():
    os.makedirs(OUT, exist_ok=True)
    col = load("adp_16x16_q25_420")          # DQT x2, SOF0 (3 comps), DHT x4
    rst = load("adp_45x37_q30_420_rst2")     # with DRI and RSTn markers
    gry = load("adp_16x16_q25_gray")         # 1 component, tables 0 only
    S, sos, ent = split(col)
    def edit(fn):
        segs = [[m, bytearray(p)] for m, p in S]; s = bytearray(sos)
        r = fn(segs, s)
        return join([[m, bytes(p)] for m, p in (r or segs)], bytes(s), ent)
    sof = lambda segs: next(p for m, p in segs if m == 0xC0)

    # ---- DQT (B.2.4.1)
    add("dqt_missing", edit(lambda g, s: [x for x in g if x[0] != 0xDB]), DQT, False)
    def tq4(g, s): next(p for m, p in g if m == 0xDB)[0] = 0x04
    add("dqt_id4", edit(tq4), DQT, False)
    def short(g, s):
        for x in g:
            if x[0] == 0xDB: x[1] = x[1][:2]; break          # PqTq + one Qk
    add("dqt_incomplete", edit(short), DQT, False)
    def zero(g, s): next(p for m, p in g if m == 0xDB)[10] = 0
    add("dqt_zero_q", edit(zero), DQT, False)
    # ---- DHT (B.2.4.2, Annex C): an extra DHT after the real ones redefines DC table 0
    def extra(tbl):
        def f(g, s):
            i = max(k for k, x in enumerate(g) if x[0] == 0xC4)
            return g[:i + 1] + [[0xC4, bytearray(tbl)]] + g[i + 1:]
        return f
    add("dht_oversubscribed", edit(extra(dht(0x00, [3], [0, 1, 2]))), DHT, False)
    add("dht_all_ones", edit(extra(dht(0x00, [2], [0, 1]))), DHT, False)
    add("dht_dc_symbol12", edit(extra(dht(0x00, [1, 1], [0, 12]))), DHT, False)
    add("dht_incomplete", edit(extra(dht(0x00, [1, 1, 1], [0]))), DHT, False)      # 3 codes, 1 value
    add("dht_id2", edit(extra(dht(0x02, [1], [0]))), DHT, False)
    # ---- SOF0 (B.2.2)
    def w0(g, s): p = sof(g); p[3] = p[4] = 0
    add("sof_width0", edit(w0), FRAME, False)
    def h0(g, s): p = sof(g); p[1] = p[2] = 0
    add("sof_height0_dnl", edit(h0), FRAME, False)
    def sof_long(g, s): p = sof(g); p.append(0)
    add("sof_length", edit(sof_long), FRAME, False)
    def dup_ci(g, s): p = sof(g); p[6 + 3] = p[6]           # C2 = C1
    add("sof_dup_ci", edit(dup_ci), SCAN, False)             # caught at the SOS: a component named twice
    def tq5(g, s): p = sof(g); p[6 + 2] = 5
    add("sof_tq5", edit(tq5), FRAME, False)
    def tq3(g, s): p = sof(g); p[6 + 2] = 3                  # legal id, never defined
    add("sof_tq_undefined", edit(tq3), DQT, False)
    add("sof_missing", edit(lambda g, s: [x for x in g if x[0] != 0xC0]), FRAME, False)
    # ---- SOS (B.2.3)
    def dup_cs(g, s): s[3] = s[1]                            # Cs2 = Cs1
    add("sos_dup_cs", edit(dup_cs), SCAN, False)
    def sos_long(g, s): s.append(0)
    add("sos_length", edit(sos_long), SCAN, False)
    def reorder(g, s): s[3], s[5] = s[5], s[3]; s[4], s[6] = s[6], s[4]      # Cs2 <-> Cs3 (with their tables)
    add("sos_out_of_order", edit(reorder), SCAN, False)
    Sg, sosg, entg = split(gry)
    sg = bytearray(sosg); sg[2] = 0x10                        # Td = 1: no DC table 1 in the file
    add("sos_undefined_dht", join(Sg, bytes(sg), entg), DHT, False)
    # ---- restart markers (B.2.4.4)
    Sr, sosr, entr = split(rst)
    k = entr.index(b"\xFF\xD0")
    add("rst_out_of_order", join(Sr, sosr, entr[:k] + b"\xFF\xD5" + entr[k + 2:]), MARKER, True)
    add("rst_without_dri", join([x for x in Sr if x[0] != 0xDD], sosr, entr), MARKER, True)
    # ---- truncated files (in_last before EOI)
    add("trunc_in_headers", col[:len(col) // 3], TRUNC, False)
    add("trunc_in_scan", col[:len(col) - len(ent) // 2], TRUNC, True)
    add("trunc_before_eoi", col[:-2], TRUNC, True)
    add("trunc_in_scan_rst", rst[:len(rst) - 200], TRUNC, True)
    # ---- review 2026-10-10
    eoi_at = len(col) - 2                                   # col ends with its EOI
    com = seg(0xFE, (b"a comment after the scan, with FF D9 inside: \xFF\xD9. " * 100)[:4998])   # 5,000 bytes
    add("com_after_scan_no_eoi", col[:eoi_at] + com, TRUNC, True)
    k_sos = col.index(b"\xFF\xDA")
    for L in (0, 1, 2, 3, 5):                               # B.2.4.4: Lr = 4
        add(f"dri_len{L}", col[:k_sos] + b"\xFF\xDD" + struct.pack(">H", L) + bytes(max(L - 2, 0)) + col[k_sos:], SYNC, True)
    for m, bit, lens in ((0xDB, DQT, (0, 1)), (0xC4, DHT, (0, 1)), (0xC0, FRAME, (0, 1, 2)), (0xDA, SCAN, (0, 1, 2))):
        for L in lens:                                      # an extra segment of impossible length before the headers
            add(f"seg_{m:02x}_len{L}", col[:2] + bytes([0xFF, m]) + struct.pack(">H", L) + col[2:], bit, False)
    def dup_both(g, s): p = sof(g); p[6 + 3] = p[6]; s[3] = s[1]       # C2 = C1 and Cs2 = Cs1 (B.2.2)
    add("dup_ci_sof_and_sos", edit(dup_both), FRAME, False)
    for v in (0x10, 0x20, 0xE0, 0x0B, 0x0F):                # F.1.2.2.1: AC sizes 1..10, or 0x00 / 0xF0
        def badac(g, s, v=v):
            for m, p in g:
                if m != 0xC4: continue
                q = 0
                while q < len(p):
                    n = sum(p[q + 1:q + 17])
                    if p[q] >> 4 == 1: p[q + 16 + n] = v; return   # the AC table's last symbol
                    q += 17 + n
        add(f"ac_symbol_{v:02x}", edit(badac), DHT, False)
    lse = bytes([0xFF, 0xF8]) + struct.pack(">H", 24) + bytes([0x0D, 0x00, 0xFF, 3, 2, 1, 3, 0x80, 0, 0, 0, 0,
                                                              0, 0, 1, 0, 0, 0, 0, 1, 0, 0])   # libjpeg 9's subtract-green
    add("lse_colour_transform", col[:k_sos] + lse + col[k_sos:], SOF_TYPE, False)
    def bg_ids(g, s): p = sof(g); p[6], p[9], p[12] = 1, 0x22, 0x23; s[1], s[3], s[5] = 1, 0x22, 0x23
    add("bg_ycc_ids", edit(bg_ids), SOF_TYPE, False)
    json.dump(cases, open(os.path.join(OUT, "cases.json"), "w"), indent=1)
    print(f"{len(cases)} cases in {OUT}")

if __name__ == "__main__":
    main()
