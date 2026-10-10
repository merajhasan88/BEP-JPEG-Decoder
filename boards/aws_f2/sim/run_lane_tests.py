#!/usr/bin/env python3
"""The memory lane (../mem_lane.sv): job lists run back to back on one lane (no reset between jobs), with
256- and 512-bit data, with and without 30 % random gaps on every AXI channel.
  corpus     every tb/corpus file: supported ones identical to the regression's golden images (libjpeg 9e
             profile, tb/golden/<name>.box.rgb.pnm), the UNSUPPORTED ones with ERR_SOF_TYPE and no pixels
  special    each followed by a clean corpus file (a job's leftovers would show up in the next one):
             the 50 tb/malformed cases (expected bits and pixels from cases.json); the 230 cut files of
             tb/run_trunc_tests.py (ERR_TRUNC; a 1-2 byte cut never starts a frame: aborted); files with zeros after
             their EOI (the lane stops reading at the frame's end); a file without an SOI (never ends a
             frame: aborted); a large file aborted in mid-frame at three points; a file with too little
             room for its records (res_ovf)
  runs       512- and 256-bit data, each with no gaps, 30 % gaps (two seeds) and 60 % gaps
  photos     optional (--photos file.jpg ...): golden from libjpeg 9e's djpeg -dct int -nosmooth
  run_lane_tests.py [--quick] [--photos file.jpg ...]      (needs obj_lane*/Vmem_lane: make)"""
import os, sys, glob, json, subprocess
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
EXES = {512: os.path.join(HERE, "obj_lane", "Vmem_lane"), 256: os.path.join(HERE, "obj_lane256", "Vmem_lane")}
OUT = os.path.join(HERE, "out")
ERR_SOF_TYPE = 0x0001

def corpus_jobs():
    ok, unsup = [], []
    for jpg in sorted(glob.glob(os.path.join(REPO, "tb", "corpus", "*.jpg"))):
        b = os.path.basename(jpg)[:-4]
        g = os.path.join(REPO, "tb", "golden", f"{b}.box.rgb.pnm")
        if "UNSUPPORTED" in b: unsup.append(f"{jpg} - errnp:{ERR_SOF_TYPE:x} 0")
        elif os.path.exists(g): ok.append(f"{jpg} {g} ok 0")
        else: raise SystemExit(f"no golden for {jpg}")
    return ok, unsup

def special_jobs():
    cases = json.load(open(os.path.join(REPO, "tb", "malformed", "cases.json")))
    jobs = []
    for name, c in sorted(cases.items()):
        jobs.append(f"{os.path.join(REPO, 'tb', 'malformed', name + '.jpg')} - {'err' if c['pixels'] else 'errnp'}:{c['err']:x} 0")
    corpus = lambda b: os.path.join(REPO, "tb", "corpus", b + ".jpg")
    gold = lambda b: os.path.join(REPO, "tb", "golden", b + ".box.rgb.pnm")
    sys.path.insert(0, os.path.join(REPO, "tb"))     # the cut files of tb/run_trunc_tests.py: ERR_TRUNC, or
    import run_trunc_tests as RT                        # no frame at all for a 1-2 byte cut (aborted)
    for b in RT.BASES:
        d = open(os.path.join(REPO, "tb", "corpus", b + ".jpg"), "rb").read()
        for p in RT.cuts(d):
            f = os.path.join(RT.OUT, f"{b}_{p}.jpg")
            if not os.path.exists(f):
                os.makedirs(RT.OUT, exist_ok=True)
                with open(f, "wb") as fh: fh.write(d[:p])
            jobs.append(f"{f} - {'abort:20000' if p <= 2 else 'err:%x' % RT.ERR_TRUNC} 0")
    for b, pad in (("adp_16x16_q25_420", 5000), ("adp_45x37_q30_420_rst2", 1), ("adp_320x240_q90_420", 70000)):
        jobs.append(f"{corpus(b)} {gold(b)} ok {pad}")         # zeros after the EOI: not read, no effect
    os.makedirs(OUT, exist_ok=True)
    nosoi = os.path.join(OUT, "no_soi.bin")                   # bytes without any FF D8: no frame at all
    with open(nosoi, "wb") as f: f.write(bytes((i * 37 + 11) % 255 for i in range(3000)))
    jobs.append(f"{nosoi} - abort:20000 0")
    for t in (30000, 20011, 9001):                                         # aborted in mid-frame
        jobs.append(f"{corpus('adp_240x320_q95_422_rst4')} - abort:{t} 0")
    jobs.append(f"{corpus('adp_64x64_q25_420')} - ok 0 1024")               # room for 64 of its records
    return jobs

def run(dw, jobs, stall, seed, tag):
    os.makedirs(OUT, exist_ok=True)
    jf = os.path.join(OUT, f"jobs_{tag}_{dw}_{stall}_{seed}.txt")
    with open(jf, "w") as f: f.write("\n".join(jobs) + "\n")
    r = subprocess.run([EXES[dw], "--stall", str(stall), "--seed", str(seed), jf], capture_output=True, text=True, timeout=14400)
    lines = r.stdout.strip().splitlines()
    res = [l for l in lines if l.endswith(" PASS") or l.endswith(" FAIL")]
    fails = [l for l in res if l.endswith(" FAIL")]
    summary = next((l for l in lines if l.startswith("LANE JOBS")), "no summary")
    if r.returncode != 0 and not fails: fails = [f"exit {r.returncode}: " + r.stderr.strip()[-400:]]
    return len(jobs), len(jobs) - len(fails) if len(res) == len(jobs) else len(res) - len(fails), fails, summary, res, r.stderr

def main():
    args = sys.argv[1:]
    photos = args[args.index("--photos") + 1:] if "--photos" in args else []
    quick = "--quick" in args
    ok_jobs, unsup = corpus_jobs()
    special = special_jobs()
    # every special job followed by a clean file; then the whole corpus
    mixed = []
    for i, s in enumerate(special + unsup):
        mixed += [s, ok_jobs[i % len(ok_jobs)]]
    mixed += ok_jobs
    total = passed = 0
    for dw in (512, 256):
        for stall, seed in ((0, 1), (30, 2), (30, 5), (60, 7)) if not quick else ((30, 2),):
            n, p, fails, summary, res, err = run(dw, mixed, stall, seed, "mixed")
            total += n; passed += p
            print(f"DW={dw} stall {stall}%: {summary}", flush=True)
            for l in fails[:10]: print("  FAIL", l)
            if fails and err.strip(): print("  stderr:", err.strip()[-400:])
    if photos:
        sys.path.insert(0, os.path.join(REPO, "bench")); import tools
        djpeg = tools.djpeg9()
        jobs = []
        for jpg in photos:
            g = os.path.join(OUT, os.path.basename(jpg) + ".ppm")
            subprocess.run([djpeg, "-dct", "int", "-nosmooth", "-pnm", "-outfile", g, jpg], check=True)
            jobs.append(f"{jpg} {g} ok 0")
        for dw in (512, 256):
            n, p, fails, summary, res, err = run(dw, jobs, 30, 3, "photos")
            total += n; passed += p
            print(f"photos DW={dw} stall 30%: {summary}", flush=True)
            for l in res: print("  " + l)
    print(f"LANE TESTS {passed}/{total} passed")
    return 0 if passed == total else 1

if __name__ == "__main__":
    sys.exit(main())
