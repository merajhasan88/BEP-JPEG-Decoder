#!/usr/bin/env python3
"""RTL regression for jpeg_decoder: every build configuration x output format x test image,
with and without 30 % random input stalls / output back-pressure.

  mcu, rbox      golden = model --upsample box   --cc libjpeg9   (djpeg 9e -dct int -nosmooth)
  rfancy, ep2c5  golden = model --upsample fancy --cc turbo      (Pillow / OpenCV / turbo djpeg);
                 RGB output is also compared with Pillow's own decode of the file.
Raster configurations must deliver pixels in strict raster order.  Images that do not fit the
row buffer of a configuration must end with err = ERR_WIDTH and no pixels.  Files the decoder
does not support (progressive) must terminate with a non-zero err, as must the output formats the
model refuses for an image (YCbCr or Y output of an RGB-coded image).
usage: run_tests.py [--quick] [--configs=a,b] [image.jpg ...]      (default: tb/corpus/*.jpg)"""
import sys, os, re, subprocess, glob
import numpy as np
from PIL import Image
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "model"))
import jpeg_golden as G

CONFIGS = {   # name: (raster, fancy+turbo, row buffer bytes or None, has RGB converter[, FAST])
    "mcu":    (False, False, None,  True),
    "fmcu":   (False, False, None,  True,  True),
    "frbox":  (True,  False, 16384, True,  True),
    "frfancy":(True,  True,  16384, True,  True),
    "wmcu":   (False, False, None,  True,  True),     # FAST=2: 4 pixels per beat, MCU order
    "rbox":   (True,  False, 16384, True),
    "rfancy": (True,  True,  16384, True),
    "ep2c5":  (True,  True,  9216,  True),
    "noyrgb": (True,  True,  9216,  False),
}
ERR_WIDTH = 1 << 10
FMTS = ["rgb", "ycbcr", "y"]

def rowbuf_need(data, fancy, fmt):
    """Bytes of row buffer an image needs (mirrors jpeg_decoder S_GEO*)."""
    d = G.Decoder(data); p = 2
    while True:
        while data[p] == 0xFF: p += 1
        m = data[p]; p += 1; L = d.u16(p)
        if m == 0xC0: d.parse_sof(data[p+2:p+L]); break
        p += L
    f = d.frame; comps = f['comps']; W = f['W']; hm, vm = f['hmax'], f['vmax']; mcux = f['mcux']
    use = comps[:1] if (len(comps) == 1 or fmt == 'y') else comps
    planes = sum(mcux * 8 * c['h'] * 8 * c['v'] for c in use)
    defer = False
    for c in use:
        uh, uv = hm // c['h'] == 2, vm // c['v'] == 2
        cw = -(-W * c['h'] // hm)
        if fancy and uv and (not uh or cw > 2): defer = True
    return planes + (sum(mcux * 8 * c['h'] for c in use) if defer else 0)

def rowbuf_fits_fast(data, fancy, fmt, rb):
    """FAST raster build: does the MCU row fit its component RAMs (mirrors jpeg_dec_fast S_GEO*)?
    Component 0 has rb/8 32-bit words, components 1 and 2 rb/16 each; per component one plane
    (pw = mcux*2*Hc words per row, 8*Vc rows) plus two line-buffer rows when the vertical filter
    is on."""
    d = G.Decoder(data); p = 2
    while True:
        while data[p] == 0xFF: p += 1
        m = data[p]; p += 1; L = d.u16(p)
        if m == 0xC0: d.parse_sof(data[p+2:p+L]); break
        p += L
    f = d.frame; comps = f['comps']; W = f['W']; hm, vm = f['hmax'], f['vmax']; mcux = f['mcux']
    use = comps[:1] if (len(comps) == 1 or fmt == 'y') else comps
    defer = any(fancy and vm // c['v'] == 2 and (hm // c['h'] != 2 or W > 4) for c in use)
    for i, c in enumerate(use):
        pw = mcux * 2 * c['h']
        need = pw * 8 * c['v'] + (2 * pw if defer else 0)
        if need > (rb // 8 if i == 0 else rb // 16): return False
    return True

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    quick = "--quick" in sys.argv
    sel = [a.split("=", 1)[1].split(",") for a in sys.argv[1:] if a.startswith("--configs=")]
    configs = {k: v for k, v in CONFIGS.items() if not sel or k in sel[0]}
    images = args or sorted(glob.glob(os.path.join(HERE, "corpus", "*.jpg")))   # scripts/make_corpus.py
    os.makedirs(os.path.join(HERE, "golden"), exist_ok=True); os.makedirs(os.path.join(HERE, "out"), exist_ok=True)
    stalls = [0] if quick else [0, 30]
    total = fails = 0
    summary = {c: [0, 0] for c in configs}
    for img in images:
        b = os.path.basename(img)[:-4]
        data = open(img, "rb").read()
        unsupported = "UNSUPPORTED" in b
        goldens = {}
        if not unsupported:
            for prof in ("box", "fancy"):
                for fmt in FMTS:
                    g = os.path.join(HERE, "golden", f"{b}.{prof}.{fmt}.pnm")
                    try:
                        if not os.path.exists(g) or os.path.getmtime(g) < os.path.getmtime(img):
                            out = G.Decoder(data, upsample=prof, cc="turbo" if prof == "fancy" else "libjpeg9", out=fmt).run()
                            open(g, "wb").write(out)
                        goldens[(prof, fmt)] = g
                    except ValueError:        # e.g. YCbCr or Y output of an RGB image: the decoder flags it
                        goldens[(prof, fmt)] = None
        for cfg, cv in configs.items():
            raster, fancy, rb, has_rgb = cv[:4]
            fast = len(cv) > 4 and cv[4]
            binp = os.path.join(HERE, f"obj_{cfg}", "Vjpeg_decoder")
            for fmt in (["rgb"] if unsupported else FMTS):
                for st in stalls:
                    outp = os.path.join(HERE, "out", f"{b}.{cfg}.{fmt}.s{st}.pnm")
                    cmd = [binp, img, outp, "--fmt", fmt, "--stall", str(st), "--quiet"]
                    if raster: cmd.append("--raster")
                    expect = "pass"
                    if unsupported: expect = "error"
                    elif rb is not None and (not rowbuf_fits_fast(data, fancy, fmt, rb) if fast else rowbuf_need(data, fancy, fmt) > rb):
                        expect = "width"; cmd += ["--expect-err", "%x" % ERR_WIDTH]
                    elif goldens[("fancy" if fancy else "box", fmt)] is None:
                        expect = "error"                                      # an unsupported format of this image
                    else:
                        prof = "fancy" if fancy else "box"
                        rgb_img = goldens[(prof, "ycbcr")] is None            # an RGB image: rgb = its components
                        gfmt = fmt if (has_rgb or fmt != "rgb" or rgb_img) else "ycbcr"   # RGB_OUT=0: rgb -> YCbCr
                        if gfmt != fmt: cmd[cmd.index("--fmt") + 1] = fmt     # still request FMT_RGB ...
                        cmd += ["--golden", goldens[(prof, gfmt)]]
                        if gfmt != fmt: cmd += ["--as-ycbcr"]                 # ... and compare as YCbCr
                    r = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
                    log = r.stderr
                    if expect == "error":
                        m = re.search(r"err=0x([0-9a-f]+)", log)
                        ok = m is not None and int(m.group(1), 16) != 0 and "frame_done never seen" not in log
                    else:
                        ok = r.returncode == 0 and "PASS" in log
                    if ok and fancy and has_rgb and fmt == "rgb" and expect == "pass" and st == 0:
                        # independent check against Pillow's decode of the same file
                        mo = re.match(rb'(P[56])\s+(\d+)\s+(\d+)\s+255\s', open(outp, "rb").read())
                        raw = open(outp, "rb").read()[mo.end():]
                        w, h = int(mo.group(2)), int(mo.group(3))
                        arr = np.frombuffer(raw, np.uint8).reshape(h, w, 3) if mo.group(1) == b'P6' else np.repeat(np.frombuffer(raw, np.uint8).reshape(h, w, 1), 3, axis=2)
                        ok = np.array_equal(arr, np.asarray(Image.open(img).convert("RGB")))
                        if not ok: log += "\nFAIL: differs from Pillow"
                    total += 1; summary[cfg][0] += 1
                    if not ok:
                        fails += 1; summary[cfg][1] += 1
                        print(f"FAIL {cfg:6s} {fmt:5s} stall={st:2d} {b}  ({expect})")
                        print("   " + "\n   ".join(l for l in log.splitlines() if l.strip())[-900:])
        print(f"done {b}", flush=True)
    print("\n" + "  ".join(f"{c}: {n - f}/{n}" for c, (n, f) in summary.items()))
    print(f"TOTAL {total - fails}/{total} passed" + ("" if fails == 0 else f"  ({fails} FAILED)"))
    return 1 if fails else 0

if __name__ == "__main__":
    sys.exit(main())
