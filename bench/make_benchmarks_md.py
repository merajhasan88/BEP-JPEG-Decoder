#!/usr/bin/env python3
"""Assemble ../BENCHMARKS.md from doc/head.md, the per-image tables (bench_report.py bench.json
[bench_powersaver.json]),
doc/middle.md, the FPGA-decoder comparison (others/report.py), the Artix-7 board run
(doc/artix7.md + boards/acorn_cle215/report.py), the photos (doc/photos.md + photos_report.py on bench_photos_2026-10-12.json), the
clocks by image (doc/perf.md + perf_by_image.py report perf_by_image_2026-10-10.json) and doc/tail.md.
usage: make_benchmarks_md.py [bench.json]"""
import os, sys, subprocess
HERE = os.path.dirname(os.path.abspath(__file__))
bj = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "bench.json")
ps = os.path.join(HERE, "bench_powersaver.json")     # the CPU runs of 2026-09-30 in the laptop's power-saver profile
tables = subprocess.run(["python3", os.path.join(HERE, "bench_report.py"), bj], capture_output=True, text=True, check=True).stdout
# ... compared with the same images in the performance profile on the same day (bench_2026-09-30.json; the images
# of the CPU runs changed to test_images/ on 2026-10-12)
if os.path.exists(ps):
    tables += subprocess.run(["python3", os.path.join(HERE, "bench_report.py"), os.path.join(HERE, "bench_2026-09-30.json"), ps,
                              "--compare-only"], capture_output=True, text=True, check=True).stdout
others = subprocess.run(["python3", os.path.join(HERE, "others", "report.py")], capture_output=True, text=True, check=True).stdout
# the same decoders on a remote Artix-7 board (boards/acorn_cle215, results file of the run)
acorn = os.path.join(HERE, "..", "boards", "acorn_cle215")
artix = subprocess.run(["python3", os.path.join(acorn, "report.py"), os.path.join(acorn, "results_2026-10-04.json")],
                       capture_output=True, text=True, check=True).stdout
# the CPU decoders on the same photos (bench_photos_2026-10-12.json) against the FPGA decoders
photos = subprocess.run(["python3", os.path.join(HERE, "photos_report.py"), os.path.join(HERE, "bench_photos_2026-10-12.json"),
                         os.path.join(acorn, "results_2026-10-04.json")], capture_output=True, text=True, check=True).stdout
# the fast and wide cores' clocks against size, subsampling, quality and compressed bits per pixel
perf = subprocess.run(["python3", os.path.join(HERE, "perf_by_image.py"), "report", os.path.join(HERE, "perf_by_image_2026-10-10.json")],
                      capture_output=True, text=True, check=True).stdout
parts = [open(os.path.join(HERE, "doc", "head.md")).read(), tables, open(os.path.join(HERE, "doc", "middle.md")).read(),
         others, open(os.path.join(HERE, "doc", "artix7.md")).read() + "\n" + artix,
         open(os.path.join(HERE, "doc", "photos.md")).read() + "\n" + photos,
         open(os.path.join(HERE, "doc", "perf.md")).read() + "\n" + perf, open(os.path.join(HERE, "doc", "tail.md")).read()]
open(os.path.join(HERE, "..", "BENCHMARKS.md"), "w").write("\n".join(p.rstrip("\n") + "\n" for p in parts))
print("wrote BENCHMARKS.md")
