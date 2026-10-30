#!/usr/bin/env python3
"""Arithmetic edge cases (tb/make_arith.py, tb/arith/*.jpg) through every build configuration, every output
format, with and without 30 % random stalls (the Verilator harnesses tb/obj_<cfg>/Vjpeg_decoder).
  inside files   (no 16-bit saturation; make_arith.py checked the model = libjpeg 9e on them): the decoder must
                 equal the model exactly, i.e. libjpeg 9e (box profile) or the Pillow profile (fancy)
  beyond files   (the decoder's documented 16-bit saturation): compared with the model, which carries the same
                 limits; and the configurations with the same profile and format must agree with each other
Goldens go to tb/out/arith_golden (generated from the model).
usage: run_arith_tests.py [--quick] [--configs=a,b]      (needs obj_<cfg>/Vjpeg_decoder: make)"""
import glob, hashlib, json, os, re, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "model"))
import jpeg_golden as G
from run_tests import CONFIGS, FMTS, ERR_WIDTH, rowbuf_need, rowbuf_fits_fast

def pixels(path):
    b = open(path, "rb").read()
    m = re.match(rb"(P[56])\s+(\d+)\s+(\d+)\s+255\s", b)
    return b[m.end():] if m else None

def main():
    quick = "--quick" in sys.argv
    sel = [a.split("=", 1)[1].split(",") for a in sys.argv[1:] if a.startswith("--configs=")]
    configs = {k: v for k, v in CONFIGS.items() if not sel or k in sel[0]}
    meta = json.load(open(os.path.join(HERE, "arith", "cases.json")))
    gdir = os.path.join(HERE, "out", "arith_golden"); odir = os.path.join(HERE, "out", "arith")
    os.makedirs(gdir, exist_ok=True); os.makedirs(odir, exist_ok=True)
    stalls = [0] if quick else [0, 30]
    total = fails = 0
    outputs = {}                                     # (image, profile, format) -> {config: output digest}
    for img in sorted(glob.glob(os.path.join(HERE, "arith", "*.jpg"))):
        b = os.path.basename(img)[:-4]
        data = open(img, "rb").read()
        cls = meta[b]["cls"]
        goldens = {}
        for prof in ("box", "fancy"):
            for fmt in FMTS:
                g = os.path.join(gdir, f"{b}.{prof}.{fmt}.pnm")
                if not os.path.exists(g) or os.path.getmtime(g) < os.path.getmtime(img):
                    open(g, "wb").write(G.Decoder(data, upsample=prof, cc="turbo" if prof == "fancy" else "libjpeg9", out=fmt).run())
                goldens[(prof, fmt)] = g
        for cfg, cv in configs.items():
            raster, fancy, rb, has_rgb = cv[:4]
            fast = len(cv) > 4 and cv[4]
            prof = "fancy" if fancy else "box"
            binp = os.path.join(HERE, f"obj_{cfg}", "Vjpeg_decoder")
            for fmt in FMTS:
                for st in stalls:
                    outp = os.path.join(odir, f"{b}.{cfg}.{fmt}.s{st}.pnm")
                    cmd = [binp, img, outp, "--fmt", fmt, "--stall", str(st), "--quiet"]
                    if raster: cmd.append("--raster")
                    if rb is not None and (not rowbuf_fits_fast(data, fancy, fmt, rb) if fast else rowbuf_need(data, fancy, fmt) > rb):
                        raise SystemExit(f"{b} does not fit the row buffer of {cfg}: make the image narrower")
                    gfmt = fmt if (has_rgb or fmt != "rgb") else "ycbcr"            # RGB_OUT=0: rgb -> YCbCr
                    cmd += ["--golden", goldens[(prof, gfmt)]] + (["--as-ycbcr"] if gfmt != fmt else [])
                    r = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
                    ok = r.returncode == 0 and "PASS" in r.stderr
                    total += 1
                    px = pixels(outp) if os.path.exists(outp) else None
                    if px is not None and st == 0:
                        outputs.setdefault((b, prof, gfmt), {})[cfg] = hashlib.sha256(px).hexdigest()[:16]
                    if not ok:
                        fails += 1
                        print(f"FAIL {cfg:7s} {fmt:5s} stall={st:2d} {b} ({cls})")
                        print("   " + "\n   ".join(l for l in r.stderr.splitlines() if "FAIL" in l or "cycles=" in l or "DIFF" in l)[-600:])
        print(f"done {b} ({cls}, {meta[b]['saturations']} saturations)", flush=True)
    # the configurations of one profile and format must give the same image
    disagree = [(k, v) for k, v in outputs.items() if len(set(v.values())) > 1]
    for (b, prof, fmt), v in disagree:
        print(f"DISAGREE {b} {prof} {fmt}: " + ", ".join(f"{c}={h}" for c, h in sorted(v.items())))
    n_in = sum(1 for m in meta.values() if m["cls"] == "inside")
    print(f"files: {len(meta)} ({n_in} inside the 16-bit limits, {len(meta) - n_in} beyond)")
    print(f"ARITH TESTS {total - fails}/{total} passed" + ("" if not fails else f"  ({fails} FAILED)")
          + ("" if not disagree else f"; {len(disagree)} image/format groups where configurations disagree"))
    return 1 if fails or disagree else 0

if __name__ == "__main__":
    sys.exit(main())
