#!/usr/bin/env python3
"""The memory lane (../mem_lane.sv) on the test corpus: every supported tb/corpus file, with and without
30 % random gaps on every AXI channel, against the regression's golden images (libjpeg 9e profile,
tb/golden/<name>.box.rgb.pnm); optionally photos (golden from libjpeg 9e's djpeg).
  run_lane_tests.py [--photos file.jpg ...]      (needs obj_lane/Vmem_lane: make)"""
import os, sys, glob, subprocess
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
EXE = os.path.join(HERE, "obj_lane", "Vmem_lane")

def run(jpg, golden, stall, seed=1):
    r = subprocess.run([EXE, jpg, "--golden", golden, "--stall", str(stall), "--seed", str(seed)],
                       capture_output=True, text=True, timeout=7200)
    line = (r.stdout.strip().splitlines() or [""])[-1]
    return r.returncode == 0 and line.endswith("PASS"), line + ("" if r.returncode == 0 else " | " + r.stderr.strip()[-300:])

def main():
    args = sys.argv[1:]
    photos = args[args.index("--photos") + 1:] if "--photos" in args else []
    n = fails = 0
    for jpg in sorted(glob.glob(os.path.join(REPO, "tb", "corpus", "*.jpg"))):
        b = os.path.basename(jpg)[:-4]
        g = os.path.join(REPO, "tb", "golden", f"{b}.box.rgb.pnm")
        if "UNSUPPORTED" in b or not os.path.exists(g): continue
        for stall in (0, 30):
            ok, line = run(jpg, g, stall); n += 1
            if not ok: fails += 1; print("FAIL", line)
    if photos:
        sys.path.insert(0, os.path.join(REPO, "bench")); import tools
        djpeg = tools.djpeg9(); tmp = os.path.join(HERE, "out"); os.makedirs(tmp, exist_ok=True)
        for jpg in photos:
            g = os.path.join(tmp, os.path.basename(jpg) + ".ppm")
            subprocess.run([djpeg, "-dct", "int", "-nosmooth", "-pnm", "-outfile", g, jpg], check=True)
            ok, line = run(jpg, g, 30); n += 1
            print(("PASS " if ok else "FAIL ") + line, flush=True)
            if not ok: fails += 1
    print(f"LANE TESTS {n - fails}/{n} passed")
    return 1 if fails else 0

if __name__ == "__main__":
    sys.exit(main())
