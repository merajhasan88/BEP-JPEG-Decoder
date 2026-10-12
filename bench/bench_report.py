#!/usr/bin/env python3
"""Per-image Markdown tables from bench.json (run_bench.py: CPU decoders; bench_fpga.py: this
project's clock counts).  Board-measured clock counts (board_jtag_95mhz.txt, from
boards/ep2c5/scripts/jtag_decode.py on the EP2C5) are marked where they exist.  With a second results file
from the laptop in another power profile (bench_powersaver.json), a table compares the two.
usage: bench_report.py bench.json [bench_powersaver.json] > tables.md"""
import os, re, sys, json
HERE = os.path.dirname(os.path.abspath(__file__))
res = json.load(open(sys.argv[1]))
# this project's EP2C5 builds: (where, clock MHz, PowerPlay estimate in mW - vectorless, low confidence)
FPGA = {
    "MCU order, replication, RGB":       ("EP2C5, compact core (`boards/ep2c5/fpga`)", 50.0, 70.4),
    "FAST, MCU order, replication, RGB": ("EP2C5, fast core (`boards/ep2c5/fpga_jtag`)", 95.0, 146.8),
}
board = {}
bf = os.path.join(HERE, "board_jtag_95mhz.txt")
if os.path.exists(bf):
    for line in open(bf):
        m = re.match(r"(\S+)\.jpg: \d+x\d+, \d+ bytes \| decoder (\d+) clocks.*-> PASS", line)
        if m: board[m[1]] = int(m[2])
BOARD_NAME = {"adp_64x64_q25_420": "adp_64x64_q25_420", "scr_320x240_q90_420": "scr_320x240_q90_420",
              "donald_2048x1365": "donald", "portrait_1944x2592_444": "unnamed", "adapter_3120x4160_422": "adapter",
              "phone_4000x3000_light": "IMG_20260912_012049", "phone_4000x3000_dense": "IMG_20260912_005827"}
cpu_order = ["libjpeg-turbo (fancy)", "libjpeg-turbo (nosmooth)", "FFmpeg mjpeg", "Pillow", "OpenCV", "stb_image",
             "libjpeg 9e (nosmooth)", "libjpeg 9e (fancy)", "Python reference model"]
names = {"libjpeg-turbo (fancy)": "libjpeg-turbo 2.1.2, default (smoothing)", "libjpeg-turbo (nosmooth)": "libjpeg-turbo 2.1.2, -nosmooth",
         "FFmpeg mjpeg": "FFmpeg 4.4.2 mjpeg decoder, RGB24 out", "Pillow": "Pillow 9.0.1 (libjpeg-turbo)", "OpenCV": "OpenCV 4.7 imdecode (libjpeg-turbo)",
         "stb_image": "stb_image v2.27", "libjpeg 9e (nosmooth)": "libjpeg 9e, -nosmooth", "libjpeg 9e (fancy)": "libjpeg 9e, default",
         "Python reference model": "model/jpeg_golden.py (pure Python)"}

def fpga_rows(name, w, h):
    """(label, where, MHz, mW, cycles, board-measured?) for this project's builds on this image"""
    for label, d in res.get("rtl", {}).get(name, {}).items():
        if label in FPGA and d["pixels"] == w * h:
            where, mhz, mw = FPGA[label]
            yield label, where, mhz, mw, d["cycles"], "FAST" in label and board.get(BOARD_NAME.get(name, "")) == d["cycles"]

prof = res.get("power_profile") or "unknown"
for name, r in res["results"].items():
    any_r = next(v for v in r.values() if v)
    w, h = any_r["w"], any_r["h"]
    print(f"\n#### {name.replace('_', ' ')}: {w}x{h} ({w*h/1e6:.2f} Mpixel)\n")
    spread = any(v and "p10_ms" in v for v in r.values())          # runs since 2026-10-12 keep every batch
    print("| decoder | where | clock | ms / image" + (" (median; p10-p90)" if spread else "")
          + " | ms at 3.9 GHz | Mpixel/s | clocks / pixel | energy / image |")
    print("|---|---|---:|---:|---:|---:|---:|---:|")
    for k in cpu_order:
        v = r.get(k)
        if not v: continue
        e = f"{v['uj']/1e3:.1f} mJ" if v.get("uj", -1) > 0 else "-"
        g = v.get("ghz")
        clk, cpp = (f"{g:.2f} GHz", f"{v['ms'] * g * 1e6 / (w * h):.1f}") if g else ("-", "-")
        at39 = f"{v['ms'] * g / 3.9:.3f}" if g else "-"
        ms = f"{v['ms']:.3f}" + (f" ({v['p10_ms']:.3f}-{v['p90_ms']:.3f})" if "p10_ms" in v else "")
        print(f"| {names[k]} | i7-8550U, 1 thread | {clk} | {ms} | {at39} | {v['mpx_s']:.1f} | {cpp} | {e} |")
    for label, where, mhz, mw, cyc, measured in fpga_rows(name, w, h):
        t = cyc / (mhz * 1e6)
        mark = " \\*" if measured else ""
        print(f"| **this decoder**: {label}{mark} | {where} | {mhz:.0f} MHz | {t*1e3:.3f} | - | {w*h/t/1e6:.2f} | "
              f"{cyc/(w*h):.2f} | {mw*t:.1f} mJ (est.) |")
print(f"\nCPU: power profile `{prof}`, clock = average measured by `perf stat` during each run (cycles / task time); "
      "ms at 3.9 GHz = the run's cycles at a steady 3.9 GHz (the laptop's highest measured clock: the CPU's best case, "
      "used in all comparisons with the FPGA); CPU clocks per pixel = time x that clock / pixels.  \\* this clock count was also measured on the EP2C5 board "
      "(identical to the simulation), see `bench/board_jtag_95mhz.txt`.  FPGA energy: PowerPlay vectorless estimate x "
      "decode time (low confidence).")

if len(sys.argv) > 2 and os.path.exists(sys.argv[2]):
    ps = json.load(open(sys.argv[2]))
    k = "libjpeg-turbo (nosmooth)"
    print(f"\n#### The same laptop in its `{ps.get('power_profile', '?')}` power profile\n")
    print(f"| image | libjpeg-turbo -nosmooth, `{ps.get('power_profile', '?')}` | libjpeg-turbo -nosmooth, `{prof}` | "
          "this decoder, EP2C5 fast core @ 95 MHz |")
    print("|---|---:|---:|---:|")
    for name, r in res["results"].items():
        a, b = ps["results"].get(name, {}).get(k), r.get(k)
        if not a or not b: continue
        w, h = b["w"], b["h"]
        ours = [cyc / 95e3 for label, _, _, _, cyc, _ in fpga_rows(name, w, h) if "FAST" in label]
        ga = f" ({a['ghz']:.2f} GHz)" if a.get("ghz") else ""
        gb = f" ({b['ghz']:.2f} GHz)" if b.get("ghz") else ""
        f = lambda ms: f"{ms:.3f}" if ms < 1 else f"{ms:.2f}"
        o = f"{f(ours[0])} ms" if ours else "-"
        print(f"| {name.replace('_', ' ')} | {f(a['ms'])} ms{ga} | {f(b['ms'])} ms{gb} | {o} |")
