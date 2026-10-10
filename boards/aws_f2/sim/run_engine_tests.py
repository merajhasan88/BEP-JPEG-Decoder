#!/usr/bin/env python3
"""The F2 job engine (../jpeg_f2_engine.sv) as the host would drive it (tb_engine.cpp): the job list of
run_lane_tests.py (every corpus file, the 50 malformed cases, zeros after the EOI, a file without an SOI
and a mid-frame abort, a too-small output area; a clean file after each special one) as one batch, on 4
lanes of 512 bits and 3 lanes of 256 bits, jobs in file order and largest first, with and without 30 %
random gaps on every memory channel. --photos: a batch of photos (golden: libjpeg 9e's djpeg -dct int
-nosmooth) with both policies; the batch lines give the engine's wall clocks against the lower bound.
  run_engine_tests.py [--quick] [--host-lat N] [--photos file.jpg ...]      (needs obj_eng*/Vengine: make)"""
import os, sys, subprocess
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, HERE)
import run_lane_tests as LT
EXES = {"4x512": os.path.join(HERE, "obj_eng", "Vengine"), "3x256": os.path.join(HERE, "obj_eng3", "Vengine")}

def run(cfg, jobs, policy, stall, seed, host_lat, tag):
    os.makedirs(LT.OUT, exist_ok=True)
    jf = os.path.join(LT.OUT, f"engine_{tag}_{cfg}_{policy}_{stall}.txt")
    with open(jf, "w") as f: f.write("\n".join(jobs) + "\n")
    r = subprocess.run([EXES[cfg], "--policy", policy, "--stall", str(stall), "--seed", str(seed), "--host-lat", str(host_lat), jf],
                       capture_output=True, text=True, timeout=14400)
    lines = r.stdout.strip().splitlines()
    res = [l for l in lines if l.endswith(" PASS") or l.endswith(" FAIL")]
    fails = [l for l in res if l.endswith(" FAIL")]
    keep = [l for l in lines if l.startswith(("batch:", "checks:", "ENGINE JOBS"))]
    ok = r.returncode == 0
    passed = len(res) - len(fails) if ok or res else 0
    return ok, passed, len(jobs), fails, keep, res, r.stderr

def main():
    args = sys.argv[1:]
    quick = "--quick" in args
    host_lat = int(args[args.index("--host-lat") + 1]) if "--host-lat" in args else 100
    photos = args[args.index("--photos") + 1:] if "--photos" in args else []
    ok_jobs, unsup = LT.corpus_jobs()
    special = LT.special_jobs()
    mixed = []
    for i, s in enumerate(special + unsup):
        mixed += [s, ok_jobs[i % len(ok_jobs)]]
    mixed += ok_jobs
    runs = [("4x512", "order", 0, 1), ("4x512", "size", 30, 2), ("3x256", "size", 0, 3), ("3x256", "order", 30, 4)]
    if quick: runs = runs[1:2]
    total = passed = 0; all_ok = True
    for cfg, policy, stall, seed in runs:
        ok, p, n, fails, keep, res, err = run(cfg, mixed, policy, stall, seed, host_lat, "mixed")
        total += n; passed += p; all_ok = all_ok and ok
        print(f"{cfg} {policy} stall {stall}%: " + " | ".join(keep), flush=True)
        for l in fails[:10]: print("  FAIL", l)
        if not ok and err.strip(): print("  stderr:", err.strip()[-600:])
    if photos:
        sys.path.insert(0, os.path.join(REPO, "bench")); import tools
        djpeg = tools.djpeg9(); jobs = []
        for jpg in photos:
            g = os.path.join(LT.OUT, os.path.basename(jpg) + ".ppm")
            if not os.path.exists(g): subprocess.run([djpeg, "-dct", "int", "-nosmooth", "-pnm", "-outfile", g, jpg], check=True)
            jobs.append(f"{jpg} {g} ok 0")
        for policy in ("order", "size"):
            ok, p, n, fails, keep, res, err = run("4x512", jobs, policy, 0, 5, host_lat, "photos")
            total += n; passed += p; all_ok = all_ok and ok
            print(f"photos 4x512 {policy} stall 0%: " + " | ".join(keep), flush=True)
            for l in res: print("  " + l)
            if not ok and err.strip(): print("  stderr:", err.strip()[-600:])
    print(f"ENGINE TESTS {passed}/{total} jobs passed, all checks {'passed' if all_ok else 'FAILED'}")
    return 0 if all_ok and passed == total else 1

if __name__ == "__main__":
    sys.exit(main())
