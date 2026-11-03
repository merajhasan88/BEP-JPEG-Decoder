#!/usr/bin/env python3
"""The whole F2 custom logic (../cl_jpeg/design/cl_jpeg.sv, the real top level with the HDK's cl_ports.vh) driven as
the F2 host and shell would (tb_cl.cpp): run_engine_tests.py's job list (every corpus file, the 50 malformed cases,
the 230 truncations, zeros after the EOI, a file without an SOI, mid-frame aborts, a too-small output area; a clean
file after each special one) as one batch on the 15-lane build, in four settings:
  file order, no gaps | largest first, 30 % gaps on every host and DDR4 channel | file order, the next job written
  ahead (--preload), 30 % gaps, 80-clock DDR4 latency | largest first, 10 % gaps, DDR4 answers in order
and once on the 2-lane build with a commit stamp (the COMMIT register). Every run also checks the memory before it
is ready, BAR4 at any alignment, the files' arrival, the BAR4 readback of records, the 8 us PCIS limit, the FLR
answer and the DDR4 statistics bus. --photos: the 24 photo files (test_images/ and model/perf/build/p420/, golden:
libjpeg 9e's djpeg -dct int -nosmooth) as one batch on 15 lanes: hash only in file order and largest first (the
throughput mode, no records), then with every record written and checked.
  run_cl_tests.py [--quick] [--photos] [--host-lat N]          (needs obj_cl/Vcl and obj_cl2/Vcl: make cl HDK=...)"""
import os, sys, glob, subprocess
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, HERE)
import run_lane_tests as LT
EXES = {15: os.path.join(HERE, "obj_cl", "Vcl"), 2: os.path.join(HERE, "obj_cl2", "Vcl")}

def run(nl, jobs, tag, args, host_lat):
    os.makedirs(LT.OUT, exist_ok=True)
    jf = os.path.join(LT.OUT, f"cl_{tag}.txt")
    with open(jf, "w") as f: f.write("\n".join(jobs) + "\n")
    r = subprocess.run([EXES[nl], "--host-lat", str(host_lat)] + args + [jf], capture_output=True, text=True, timeout=36000)
    lines = r.stdout.strip().splitlines()
    res = [l for l in lines if l.endswith(" PASS") or l.endswith(" FAIL")]
    fails = [l for l in res if l.endswith(" FAIL")]
    keep = [l for l in lines if l.startswith(("before the DDR4", "BAR4 at", "files into", "batch:", "checks:", "CL JOBS"))]
    with open(os.path.join(LT.OUT, f"cl_{tag}.log"), "w") as f: f.write(r.stdout + "\n--- stderr\n" + r.stderr)
    return r.returncode == 0, len(res) - len(fails), len(jobs), fails, keep, res, r.stderr

def main():
    a = sys.argv[1:]
    quick = "--quick" in a
    host_lat = int(a[a.index("--host-lat") + 1]) if "--host-lat" in a else 100
    ok_jobs, unsup = LT.corpus_jobs()
    special = LT.special_jobs()
    mixed = []
    for i, s in enumerate(special + unsup):
        mixed += [s, ok_jobs[i % len(ok_jobs)]]
    mixed += ok_jobs
    runs = [(15, "order0", ["--policy", "order", "--seed", "1"]),
            (15, "size30", ["--policy", "size", "--stall", "30", "--ddr-stall", "30", "--seed", "2"]),
            (15, "preload30", ["--policy", "order", "--preload", "--stall", "30", "--ddr-stall", "30", "--ddr-lat", "80", "--seed", "3"]),
            (15, "inorder10", ["--policy", "size", "--stall", "10", "--ddr-stall", "10", "--no-reorder", "--no-interleave", "--seed", "4"]),
            (2, "nl2_commit", ["--policy", "order", "--stall", "20", "--ddr-stall", "20", "--seed", "5"])]
    if quick: runs = runs[1:2]
    total = passed = 0; all_ok = True
    for nl, tag, args in runs:
        ok, p, n, fails, keep, res, err = run(nl, mixed, tag, args, host_lat)
        total += n; passed += p; all_ok = all_ok and ok
        print(f"{nl} lanes {tag}:", flush=True)
        for k in keep: print("  " + k)
        for l in fails[:10]: print("  FAIL", l)
        if not ok and err.strip(): print("  stderr:", err.strip()[-800:])
    if "--photos" in a:
        sys.path.insert(0, os.path.join(REPO, "bench")); import tools
        djpeg = tools.djpeg9()
        photos = sorted(glob.glob(os.path.join(REPO, "test_images", "*.jpg"))) + sorted(glob.glob(os.path.join(REPO, "model", "perf", "build", "p420", "*.jpg")))
        jobs = []
        for jpg in photos:
            g = os.path.join(LT.OUT, os.path.basename(jpg) + ".ppm")
            if not os.path.exists(g): subprocess.run([djpeg, "-dct", "int", "-nosmooth", "-pnm", "-outfile", g, jpg], check=True)
            jobs.append(f"{jpg} {g} ok 0")
        for tag, args in (("photos_hash_order", ["--hash-only", "--policy", "order"]),
                          ("photos_hash_size", ["--hash-only", "--policy", "size"]),
                          ("photos_records_order", ["--policy", "order", "--ddr-stall", "10", "--seed", "9"])):
            ok, p, n, fails, keep, res, err = run(15, jobs, tag, args, host_lat)
            total += n; passed += p; all_ok = all_ok and ok
            print(f"15 lanes {tag} ({len(jobs)} photo files):", flush=True)
            for k in keep: print("  " + k)
            for l in res: print("  " + l)
            if not ok and err.strip(): print("  stderr:", err.strip()[-800:])
    print(f"CL TESTS {passed}/{total} jobs passed, all checks {'passed' if all_ok else 'FAILED'}")
    return 0 if all_ok and passed == total else 1

if __name__ == "__main__":
    sys.exit(main())
