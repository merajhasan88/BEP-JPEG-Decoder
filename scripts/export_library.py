#!/usr/bin/env python3
"""Export the BEP-JPEG library (the `main` branch) from this development tree.

BEP-JPEG is a subset of the development branch: the decoder, its tests, the board examples and the
benchmarks, without the development history (FAST_STATUS.md), the gate-level flows, the
experimental Quartus projects and the owner's photos other than test_images/adapter.jpg.  Only
files tracked by git here are exported, filtered by INCLUDE / EXCLUDE below; files in the target
that git tracks in the target but are no longer exported are removed (untracked build outputs and
its .git are left alone).

usage: export_library.py <target folder>      (e.g. ../BEBCL-JPEG, a worktree of the main branch)
       export_library.py --list               (print what would be exported)"""
import os, sys, shutil, fnmatch, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.abspath(os.path.join(HERE, ".."))

INCLUDE = [
    "README.md", "LICENSE", "NOTICE.md", "BENCHMARKS.md", ".gitignore", "decode.sh",
    "rtl/*", "model/*",
    "scripts/decode.py", "scripts/make_corpus.py", "scripts/compare_refs.py", "scripts/jpeg_to_hex.py",
    "scripts/pnm_checksum.py",
    "tb/Makefile", "tb/*.cpp", "tb/run_tests.py", "tb/run_stream_tests.py", "tb/run_malformed_tests.py",
    "tb/make_malformed.py", "tb/corpus/*", "tb/malformed/*", "tb/golden/*",
    "tb/tb_jpeg.sv", "tb/sim.sh", "tb/run_tests.sh", "tb/expected.txt", "tb/stream_scenarios.txt",
    "tb/export_expectations.py", "tb/trail/*",
    "tb/jpeg_checker.sv", "tb/jpeg_checker_bind.sv", "tb/run_checker_tests.py", "tb/run_trunc_tests.py",
    "tb/run_arith_tests.py", "tb/make_arith.py", "tb/arith/*",
    "test_images/adapter.jpg", "test_images/README.md",
    "boards/ep2c5/README.md", "boards/ep2c5/rtl/*", "boards/ep2c5/scripts/*", "boards/ep2c5/sim/*",
    "boards/ep2c5/compile_all.sh", "boards/ep2c5/sta_paths.tcl", "boards/ep2c5/sta_detail.tcl",
    "boards/ep2c5/fpga/*", "boards/ep2c5/fpga_raster/*", "boards/ep2c5/fpga_raster_box/*",
    "boards/ep2c5/fpga_raster_ycc/*", "boards/ep2c5/fpga_fast/*", "boards/ep2c5/fpga_fast_bench/*",
    "boards/ep2c5/fpga_jtag/*",
    "boards/acorn_cle215/*",
    "bench/*",
]
EXCLUDE = [
    "*/build_status.txt", "*/final_build.txt",          # notes of earlier builds (development history)
    "tb/regression_*", "tb/stream_tests*.txt", "tb/final_regression.txt", "tb/big*",   # run logs
    # research for Proposals A and B (PROPOSALS.md, development branch only) until something is built
    "model/perf/syncstats.c", "model/perf/proposals.py", "model/perf/proposals_*.json",
    "model/perf/probes/hufloop_probe3.sv", "model/perf/probes/hufloop_probe4.sv", "model/perf/probes/probe_fmax.tcl",
    # UltraScale+ timing check for Task B (AWS F2), development branch only
    "model/perf/probes/usplus_*",
]

def tracked():
    r = subprocess.run(["git", "-C", DEV, "ls-files", "-z"], capture_output=True, check=True)
    return [p for p in r.stdout.decode().split("\0") if p]

def exported():
    out = []
    for p in tracked():
        if any(fnmatch.fnmatch(p, g) for g in EXCLUDE): continue
        if any(fnmatch.fnmatch(p, g) for g in INCLUDE): out.append(p)
    return sorted(out)

def main():
    if len(sys.argv) != 2: sys.exit(__doc__)
    # only the development branch is exported: work in progress on other branches (Proposals A and B
    # on proposals-AB, in the worktree ../BEBCL-JPEG-proposals) must not reach main by accident
    branch = subprocess.run(["git", "-C", DEV, "rev-parse", "--abbrev-ref", "HEAD"],
                            capture_output=True, text=True, check=True).stdout.strip()
    if branch != "BEP-JPEG-development":
        sys.exit(f"export_library.py: this checkout is on branch {branch!r}; the library is exported from "
                 "branch BEP-JPEG-development only")
    files = exported()
    if sys.argv[1] == "--list":
        print("\n".join(files)); return
    dst = os.path.abspath(sys.argv[1])
    os.makedirs(dst, exist_ok=True)
    keep = set(files)
    if os.path.exists(os.path.join(dst, ".git")):         # a worktree: drop tracked files no longer exported
        r = subprocess.run(["git", "-C", dst, "ls-files", "-z"], capture_output=True, check=True)
        for rel in r.stdout.decode().split("\0"):
            if rel and rel not in keep and os.path.exists(os.path.join(dst, rel)):
                os.remove(os.path.join(dst, rel))
    for p in files:
        os.makedirs(os.path.dirname(os.path.join(dst, p)) or dst, exist_ok=True)
        shutil.copy2(os.path.join(DEV, p), os.path.join(dst, p))
    for dp, dns, fns in sorted(os.walk(dst), reverse=True):     # drop empty folders
        if ".git" not in dp.split(os.sep) and dp != dst and not os.listdir(dp): os.rmdir(dp)
    print(f"exported {len(files)} files to {dst}")

if __name__ == "__main__":
    main()
