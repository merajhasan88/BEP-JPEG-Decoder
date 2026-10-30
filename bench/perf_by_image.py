#!/usr/bin/env python3
"""perf_by_image.py - the fast (FAST=1) and wide (FAST=2) cores' clocks against the image: size,
subsampling, quality and compressed bits per pixel, with the fixed cost of the headers (small-image
latency) apart from the scan's rate (large-image throughput). The review of 2026-10-10 asked for this:
four pixels per output beat is the wide core's peak, not its rate.
  measure  the supported tb/corpus files through the Verilator harnesses tb/obj_fmcu and tb/obj_wmcu
           (frame_start = the headers parsed and the Huffman lookahead tables built; frame_done = the
           image's EOI), and the 24 photo files from model/perf/wide_photos_sim_2026-10-04.json (the wide
           core's clocks reproduced on 2026-10-10; FAST=1 clocks of the same run); the header fields from
           the files; the quality as ImageMagick's estimate (identify %Q)
  report   markdown tables
  perf_by_image.py measure OUT.json | report IN.json"""
import glob, json, os, re, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, ".."))
sys.path.insert(0, os.path.join(REPO, "model", "perf"))

def header(path):
    """W, H, sampling label, restart interval, bytes of entropy-coded data (B.2.2-B.2.4)"""
    d = open(path, "rb").read()
    i, w = 2, dict(dri=0)
    while i + 3 < len(d) and d[i] == 0xFF:
        m, n = d[i + 1], (d[i + 2] << 8) | d[i + 3]
        if m == 0xC0:
            w["h"], w["w"], nf = (d[i + 5] << 8) | d[i + 6], (d[i + 7] << 8) | d[i + 8], d[i + 9]
            hv = [(d[i + 11 + 3 * k] >> 4, d[i + 11 + 3 * k] & 15) for k in range(nf)]
            if nf == 1: w["sub"] = "grey"
            else:
                h0, v0 = hv[0]
                w["sub"] = {(1, 1): "4:4:4", (2, 1): "4:2:2", (1, 2): "4:4:0", (2, 2): "4:2:0"}.get((h0, v0), f"{h0}x{v0}") \
                    if all(x == (1, 1) for x in hv[1:]) else "mixed"
        if m == 0xDD: w["dri"] = (d[i + 4] << 8) | d[i + 5]
        if m == 0xDA:                                # the entropy-coded data ends at the first marker other than RSTn
            k = i + 2 + n
            while k + 1 < len(d) and not (d[k] == 0xFF and d[k + 1] != 0x00 and not 0xD0 <= d[k + 1] <= 0xD7): k += 1
            w["scan_bytes"] = k - (i + 2 + n); break
        i += 2 + n
    w["bytes"] = len(d)
    return w

def quality(path):
    try: return int(subprocess.run(["identify", "-format", "%Q", path], capture_output=True, text=True, timeout=60).stdout.strip() or 0)
    except (OSError, ValueError, subprocess.TimeoutExpired): return 0

def run(core, path):
    exe = os.path.join(REPO, "tb", f"obj_{core}", "Vjpeg_decoder")
    out = os.path.join(REPO, "tb", "out", "perf_by_image.pnm")
    r = subprocess.run([exe, path, out, "--fmt", "rgb"], capture_output=True, text=True, timeout=600)
    t = r.stdout + r.stderr
    fs = re.search(r"frame_start: \d+x\d+ at cycle (\d+)", t); cy = re.search(r"cycles=(\d+) .*err=0x0000", t)
    if not (fs and cy): raise SystemExit(f"{core} {path}: no result\n{t[-500:]}")
    return int(fs.group(1)), int(cy.group(1))

def measure(out):
    os.makedirs(os.path.join(REPO, "tb", "out"), exist_ok=True)
    rows = []
    for f in sorted(glob.glob(os.path.join(REPO, "tb", "corpus", "*.jpg"))):
        b = os.path.basename(f)[:-4]
        if "UNSUPPORTED" in b or "_rgb" in b or "comtail" in b: continue   # RGB-coded (no colour conversion) and the
                                                                            # 4,900-byte trailing comment: not comparable
        h = header(f); h.update(file=b, kind="corpus", q=quality(f))
        for core, k in (("fmcu", "fast"), ("wmcu", "wide")):
            fs, cy = run(core, f); h[k] = dict(setup=fs, total=cy)
        rows.append(h)
    import perf_model as PM
    wide = json.load(open(os.path.join(REPO, "model", "perf", "wide_photos_sim_2026-10-04.json")))
    for f in PM.photos():
        b = os.path.basename(f)
        h = header(f); h.update(file=b, kind="photo", q=quality(f))
        h["fast"] = dict(total=wide[b]["fast"]); h["wide"] = dict(total=wide[b]["clocks"])
        rows.append(h)
    json.dump(dict(date="2026-10-10", what="clocks of FAST=1 (tb/obj_fmcu) and FAST=2 (tb/obj_wmcu), Verilator, "
                   "RGB, MCU order; corpus measured by perf_by_image.py at the commit in bench/manifest_2026-10-10.json "
                   "(RTL unchanged since); photos from model/perf/wide_photos_sim_2026-10-04.json (wide clocks "
                   "reproduced 2026-10-10)", rows=rows), open(out, "w"), indent=1)
    print(f"{out}: {len(rows)} files")

def report(inp):
    rows = json.load(open(inp))["rows"]
    def bpp(r): return 8.0 * r["scan_bytes"] / (r["w"] * r["h"])
    print("Small files (the corpus): the clocks until the frame starts are the headers - read at a byte per clock -")
    print("and the Huffman lookahead tables built from them; the scan's clocks per pixel are the rate.\n")
    print("| file | size | subsampling | quality | bits/pixel | setup clocks | scan clk/px fast / wide | total clocks fast / wide | wide total clk/px |")
    print("|---|---|---|---:|---:|---:|---|---|---:|")
    cs = sorted((r for r in rows if r["kind"] == "corpus"), key=lambda r: r["w"] * r["h"])
    for r in cs:
        px = r["w"] * r["h"]
        assert r["fast"]["setup"] == r["wide"]["setup"], r["file"]          # the parser is shared
        s, tf, tw = r["wide"]["setup"], r["fast"]["total"], r["wide"]["total"]
        print(f"| {r['file']} | {r['w']}x{r['h']} | {r['sub']}{' rst' if r['dri'] else ''} | {r['q']} | {bpp(r):.2f} | {s:,} | "
              f"{(tf - s) / px:.2f} / {(tw - s) / px:.2f} | {tf:,} / {tw:,} | {tw / px:.2f} |")
    ph = sorted((r for r in rows if r["kind"] == "photo"), key=lambda r: bpp(r))
    print("\nPhotos (12 MP; the header setup is under 0.1 % of their clocks): clocks per pixel against the")
    print("compressed bits per pixel, by subsampling.\n")
    print("| file | subsampling | quality | MB | bits/pixel | fast clk/px | wide clk/px | wide pixels per clock |")
    print("|---|---|---:|---:|---:|---:|---:|---:|")
    for r in ph:
        px = r["w"] * r["h"]
        print(f"| {r['file']} | {r['sub']} | {r['q']} | {r['bytes'] / 1e6:.2f} | {bpp(r):.2f} | {r['fast']['total'] / px:.3f} | {r['wide']['total'] / px:.3f} | {px / r['wide']['total']:.2f} |")
    cw = [(r["wide"]["setup"], (r["wide"]["total"] - r["wide"]["setup"]) / (r["w"] * r["h"])) for r in cs]
    cf = [(r["fast"]["setup"], (r["fast"]["total"] - r["fast"]["setup"]) / (r["w"] * r["h"])) for r in cs]
    print(f"\nSetup on the corpus: {min(x for x, _ in cw):,}-{max(x for x, _ in cw):,} clocks (both cores). "
          f"Photos: wide {min(px_r(r) for r in ph):.3f}-"
          f"{max(px_r(r) for r in ph):.3f} clocks per pixel, i.e. {1 / max(px_r(r) for r in ph):.2f}-"
          f"{1 / min(px_r(r) for r in ph):.2f} pixels per clock against the output's peak of 4.")

def px_r(r): return r["wide"]["total"] / (r["w"] * r["h"])

if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("measure", "report"): print(__doc__); sys.exit(2)
    (measure if sys.argv[1] == "measure" else report)(sys.argv[2])
