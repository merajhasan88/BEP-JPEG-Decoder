#!/usr/bin/env python3
"""Systematic truncation (review of 2026-10-10, priority 1): base files cut at every segment boundary, at
points inside every segment (after the marker, after the length, mid-payload, before the last byte), at
points in the entropy-coded data and around its restart markers, and just before / inside the EOI. Each cut
file is followed by a valid image and both are streamed through one decoder without a reset (Vmulti, with
in_last on each file's last byte), in every build configuration, with and without 30 % random stalls.
Required: nothing hangs; a cut file of 3 bytes or more ends with its own frame and ERR_TRUNC (bit 12);
a cut file of 1 or 2 bytes (its SOI incomplete, or only the SOI: no frame header yet) produces no frame
(in_last at or before the SOI has no effect, jpeg_parser.sv); the valid image after it matches its golden
with err = 0. (Vmulti waits for one frame per file: for the 1-2 byte cuts the valid image's golden is given
first and the run ends by Vmulti's no-progress limit after that one frame: "frames: 1" is the pass.)
Second part: each of the 50 tb/malformed files followed by the same valid image: the malformed file's frame
must carry the bits of cases.json (and no pixels where it says so), the valid image after it must be exact.
usage: run_trunc_tests.py [--configs=a,b] [--quick]      (needs obj_<cfg>/Vmulti: make multi)"""
import json, os, re, sys, subprocess
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from run_tests import CONFIGS
from run_stream_tests import golden

BASES = ["adp_45x37_q30_420_rst2", "adp_45x37_q30_422_exifthumb", "adp_13x11_q40_gray"]
NEXT = "adp_32x32_q25_420"
ERR_TRUNC = 0x1000
OUT = os.path.join(HERE, "out", "trunc")

def segments(d):
    """(offset, marker, bytes) of SOI, every marker segment, the entropy-coded data (marker None) and EOI"""
    segs, i = [(0, 0xD8, 2)], 2
    while i + 3 < len(d) and d[i] == 0xFF:
        m = d[i + 1]
        n = (d[i + 2] << 8) | d[i + 3]
        segs.append((i, m, 2 + n)); i += 2 + n
        if m == 0xDA:
            segs.append((i, None, len(d) - 2 - i)); segs.append((len(d) - 2, 0xD9, 2)); break
    return segs

def cuts(d):
    pts = set()
    for off, m, n in segments(d):
        if m is None:
            for f in (1, 2, n // 4, n // 2, 3 * n // 4, n - 2, n - 1): pts.add(off + f)
            for k in range(off, off + n - 1):          # restart markers inside the scan (B.2.4.4 / F.1.2.3)
                if d[k] == 0xFF and d[k + 1] not in (0x00, 0xFF): pts.update({k, k + 1, k + 2})
        else:
            for f in (0, 1, 2, 3, 4, n // 2, n - 1):
                if f < n: pts.add(off + f)
    pts.add(len(d) - 1)                                # the file ends with the EOI's FF
    return sorted(p for p in pts if 1 <= p < len(d))

def main():
    sel = [a.split("=", 1)[1].split(",") for a in sys.argv[1:] if a.startswith("--configs=")]
    configs = {k: v for k, v in CONFIGS.items() if not sel or k in sel[0]}
    quick = "--quick" in sys.argv
    os.makedirs(OUT, exist_ok=True)
    files = []                                         # (base, cut, path)
    for b in BASES:
        d = open(os.path.join(HERE, "corpus", b + ".jpg"), "rb").read()
        for p in cuts(d):
            f = os.path.join(OUT, f"{b}_{p}.jpg")
            if not os.path.exists(f):
                with open(f, "wb") as fh: fh.write(d[:p])
            files.append((b, p, f))
    nxt = os.path.join(HERE, "corpus", NEXT + ".jpg")
    total = fails = 0; no_frame = 0; mtotal = mfails = 0
    cases = json.load(open(os.path.join(HERE, "malformed", "cases.json")))
    for cfg, cv in configs.items():
        raster, fancy, rb, has_rgb = cv[:4]
        fmt = "rgb" if has_rgb else "ycbcr"
        prof = "fancy" if fancy else "box"
        g = golden(NEXT, prof, fmt)
        binp = os.path.join(HERE, f"obj_{cfg}", "Vmulti")
        for b, p, f in files:
            for stall in ((30,) if quick else (0, 30)):
                gl = [f, g, nxt, "-"] if p <= 2 else [f, "-", nxt, g]
                r = subprocess.run([binp, "--fmt", fmt, "--stall", str(stall)] + gl, capture_output=True, text=True, timeout=600)
                fr = re.findall(r"frame (\d+): (\d+)x(\d+), (\d+) pixels, err=0x([0-9a-f]+), (.*)", r.stdout)
                stalled = "stalled" in r.stdout
                if p <= 2:                              # SOI not complete (p = 1) or only the SOI (p = 2): no frame
                    ok = len(fr) == 1 and int(fr[0][4], 16) == 0 and fr[0][5].strip() == "MATCH" and "frames: 1" in r.stdout
                    if ok: no_frame += 1
                else:
                    ok = not stalled and len(fr) == 2 and bool(int(fr[0][4], 16) & ERR_TRUNC) \
                         and int(fr[1][4], 16) == 0 and fr[1][5].strip() == "MATCH"
                total += 1
                if not ok:
                    fails += 1
                    if fails <= 40:
                        print(f"FAIL {cfg:7s} stall={stall:2d} {b} cut at {p}:\n   " + r.stdout.strip().replace("\n", "\n   "))
        # the malformed files, each followed by the valid image
        for name, c in sorted(cases.items()):
            f = os.path.join(HERE, "malformed", name + ".jpg")
            for stall in ((30,) if quick else (0, 30)):
                r = subprocess.run([binp, "--fmt", fmt, "--stall", str(stall), f, "-", nxt, g], capture_output=True, text=True, timeout=600)
                fr = re.findall(r"frame (\d+): (\d+)x(\d+), (\d+) pixels, err=0x([0-9a-f]+), (.*)", r.stdout)
                ok = len(fr) == 2 and (int(fr[0][4], 16) & c["err"]) == c["err"] and (c["pixels"] or int(fr[0][3]) == 0) \
                     and int(fr[1][4], 16) == 0 and fr[1][5].strip() == "MATCH"
                mtotal += 1
                if not ok:
                    mfails += 1
                    if mfails <= 20:
                        print(f"FAIL {cfg:7s} stall={stall:2d} malformed {name} then {NEXT}:\n   " + r.stdout.strip().replace("\n", "\n   "))
        print(f"done {cfg}", flush=True)
    print(f"cut files: {len(files)} ({', '.join(f'{b}: {sum(1 for x in files if x[0] == b)}' for b in BASES)}); "
          f"runs of 1-2 byte cuts (no frame, the next image exact): {no_frame}")
    print(f"TRUNCATION TESTS {total - fails}/{total} passed" + ("" if not fails else f"  ({fails} FAILED)"))
    print(f"MALFORMED THEN VALID {mtotal - mfails}/{mtotal} passed" + ("" if not mfails else f"  ({mfails} FAILED)"))
    return 1 if fails or mfails else 0

if __name__ == "__main__":
    sys.exit(main())
