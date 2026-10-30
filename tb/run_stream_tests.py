#!/usr/bin/env python3
"""Multi-image regression: several files streamed back to back through one decoder without a
reset, for every build configuration, with and without 30 % random stalls.  Every supported
frame must match its golden with err = 0; an unsupported file must end with a non-zero err and
no pixels, and must not affect the image after it.
usage: run_stream_tests.py [--configs=a,b]      (needs obj_<cfg>/Vmulti: `make multi`)"""
import sys, os, re, subprocess
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "model"))
import jpeg_golden as G
from run_tests import CONFIGS

CORPUS = os.path.join(HERE, "corpus")
SCENARIOS = [
    ("restart interval does not leak into the next image", ["adp_45x37_q30_420_rst2", "adp_32x32_q25_420"]),
    ("an unsupported SOF1 file does not block the next image", ["adp_40x40_q20_sof1_UNSUPPORTED", "adp_32x32_q25_420"]),
    ("an unsupported progressive file does not block the next image", ["adp_45x37_q30_progressive_UNSUPPORTED", "adp_17x33_q40_420"]),
    ("grey, 4:4:4, 4:2:0 with restarts, 4:2:2 with EXIF, back to back",
     ["adp_13x11_q40_gray", "adp_32x32_q25_444", "adp_40x50_q30_420_rst3", "adp_45x37_q30_422_exifthumb"]),
    ("the same image twice", ["adp_64x64_q25_420", "adp_64x64_q25_420"]),
    # review 2026-10-10: each frame ends at its own EOI with its own error; the next image is unaffected
    ("a comment after the scan: the frame ends at its EOI", ["adp_16x16_q25_420_comtail", "adp_32x32_q25_420"]),
    ("a file ending inside a comment after its scan (no EOI), then a valid image", ["malformed/com_after_scan_no_eoi", "adp_32x32_q25_420"]),
    ("a DRI of length 0, then a valid image", ["malformed/dri_len0", "adp_17x33_q40_420"]),
    ("an SOF of length 1, then a valid image", ["malformed/seg_c0_len1", "adp_32x32_q25_420"]),
    ("component ids repeated in SOF and SOS, then a valid image", ["malformed/dup_ci_sof_and_sos", "adp_32x32_q25_420"]),
    ("an illegal AC symbol, then a valid image", ["malformed/ac_symbol_10", "adp_32x32_q25_420"]),
    ("a libjpeg 9 colour transform (LSE), then a valid image", ["malformed/lse_colour_transform", "adp_32x32_q25_420"]),
    ("an RGB-coded image between two YCbCr images", ["adp_32x32_q25_420", "adp_32x24_q50_rgb", "adp_17x33_q40_420"]),
    # 2026-10-12 (found by tb/jpeg_checker.sv): bytes after an EOI belong to no image - they once set ERR_SYNC on
    # the finished frame
    ("bytes after the EOI (a camera's trailer: zeros, FF fill, a stray FF D9, text) leave the frame's err alone",
     ["trail_adp_32x32_q25_420", "adp_17x33_q40_420"]),
]
# what trail_<image> appends to the corpus image: no SOI in it, and it ends with a lone FF (the next file's FF D8
# follows it)
TRAILER = (bytes(64) + b"\xFF\x00\xFF\xFF\xFF\xD9" + b"SEFH\x00\x00\x00\x01 trailer written after the EOI "
           + bytes(range(1, 255, 3)) + b"\xFF")

def path_of(name):
    """the file of a scenario entry: tb/corpus/<name>.jpg; tb/malformed/<name>.jpg for malformed/<name>;
    tb/trail/<name>.jpg for trail_<image>: the corpus image followed by TRAILER (written here when it differs)"""
    if name.startswith("malformed/"): return os.path.join(HERE, name + ".jpg")
    if name.startswith("trail_"):
        p = os.path.join(HERE, "trail", name + ".jpg")
        data = open(os.path.join(CORPUS, name[len("trail_"):] + ".jpg"), "rb").read() + TRAILER
        if not os.path.exists(p) or open(p, "rb").read() != data:
            os.makedirs(os.path.dirname(p), exist_ok=True); open(p, "wb").write(data)
        return p
    return os.path.join(CORPUS, name + ".jpg")

def golden(name, prof, fmt):
    """the model's output, or None: an unsupported or malformed file, or a format the model refuses for it
    (YCbCr / Y output of an RGB image) - the decoder must then end the frame with an error"""
    if "UNSUPPORTED" in name or name.startswith("malformed/"): return None
    g = os.path.join(HERE, "golden", f"{name}.{prof}.{fmt}.pnm")
    src = path_of(name)
    if not os.path.exists(g) or os.path.getmtime(g) < os.path.getmtime(src):
        os.makedirs(os.path.dirname(g), exist_ok=True)
        data = open(src, "rb").read()
        try: out = G.Decoder(data, upsample=prof, cc="turbo" if prof == "fancy" else "libjpeg9", out=fmt).run()
        except ValueError: return None
        open(g, "wb").write(out)
    return g

def main():
    sel = [a.split("=", 1)[1].split(",") for a in sys.argv[1:] if a.startswith("--configs=")]
    configs = {k: v for k, v in CONFIGS.items() if not sel or k in sel[0]}
    total = fails = 0
    for cfg, cv in configs.items():
        raster, fancy, rb, has_rgb = cv[:4]
        fmt = "rgb" if has_rgb else "ycbcr"          # RGB_OUT=0 builds deliver YCbCr
        prof = "fancy" if fancy else "box"
        binp = os.path.join(HERE, f"obj_{cfg}", "Vmulti")
        for title, names in SCENARIOS:
            for stall in (0, 30):
                args = [binp, "--fmt", fmt, "--stall", str(stall)]
                golds = [golden(n, prof, fmt) for n in names]
                for n, g in zip(names, golds):
                    args += [path_of(n), g or "-"]
                r = subprocess.run(args, capture_output=True, text=True, timeout=600)
                frames = re.findall(r"frame (\d+): (\d+)x(\d+), (\d+) pixels, err=0x([0-9a-f]+), (.*)", r.stdout)
                ok = len(frames) == len(names)
                for (k, w, h, npx, err, verdict), n, g in zip(frames, names, golds):
                    if n.startswith("malformed/"): ok &= int(err, 16) != 0          # its own error; pixels allowed
                    elif g is None: ok &= int(err, 16) != 0 and int(npx) == 0      # unsupported: no pixels
                    else: ok &= int(err, 16) == 0 and verdict.strip() == "MATCH"
                total += 1
                if not ok:
                    fails += 1
                    print(f"FAIL {cfg:7s} stall={stall:2d} {title}\n   " + r.stdout.strip().replace("\n", "\n   "))
        print(f"done {cfg}", flush=True)
    print(f"STREAM TESTS {total - fails}/{total} passed" + ("" if not fails else f"  ({fails} FAILED)"))
    return 1 if fails else 0

if __name__ == "__main__":
    sys.exit(main())
