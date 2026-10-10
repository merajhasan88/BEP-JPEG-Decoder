#!/usr/bin/env python3
"""Decode-speed benchmark: CPU decoders on this machine vs the RTL decoder's cycle counts.

CPU side (single thread, pinned to one core, JPEG already in memory, median of ~0.1 s batches):
  libjpeg-turbo 2.1.2 (C API)   default = ISLOW + fancy upsampling (what Pillow/OpenCV use); also -nosmooth
  libjpeg 9e (C API)            built by tools.py (downloaded from ijg.org); default and -nosmooth
  stb_image                     stb_image.h, downloaded by tools.py
  Pillow 9.0.1                  Image.open(BytesIO).load()           (libjpeg-turbo underneath)
  OpenCV 4.7                    cv2.imdecode, cv2.setNumThreads(1)   (libjpeg-turbo underneath)
  FFmpeg                        its own mjpeg decoder, -threads 1, many loops of one image
  zune-jpeg 0.4                 Rust, its own decoder with run-time SIMD (bench_zune/), RGB output
  Go image/jpeg                 Go's standard library (bench_go/), YCbCr converted to RGBA with image/draw
  model/jpeg_golden.py          pure-Python reference (small images only, for scale)
Each CPU run is wrapped in `perf stat` (when available) to record the average CPU clock during the
run, so the results can also be given in CPU clocks per pixel.
RTL side (bench_fpga.py): exact clock counts from Verilator simulation of the decoder.

CPU clock: a laptop's power profile changes the results several-fold (this one in "power-saver"
runs at ~0.8-0.9 GHz instead of up to 4 GHz).  With BENCH_POWER_PROFILE=performance the script sets
that power profile (powerprofilesctl) for the run and restores the previous one at the end; the
profile in effect and the measured clock are stored in the results.
usage: [BENCH_POWER_PROFILE=performance] run_bench.py out.json [image.jpg ...]   (tables: bench_report.py out.json)"""
import os, sys, re, json, subprocess, shutil, time
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import tools
SCR = tools.SCR
CORE = os.environ.get("BENCH_CORE", "3")
# images: run_bench.py out.json [image.jpg ...]; default: three small corpus files and every JPEG in
# test_images/ (the published BENCHMARKS.md was measured on the owner's photos listed there)
IMAGES = [(os.path.splitext(os.path.basename(p))[0], p) for p in sys.argv[2:]
          if p.lower().endswith((".jpg", ".jpeg"))] or tools.default_images()   # (bench_fpga.py imports it)

def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)

def parse(out):
    m = re.search(r"(\d+)x(\d+) ms=([\d.]+) mpx_s=([\d.]+) decodes=(\d+) elapsed=([\d.]+) uJ_per_decode=([-\d.]+)", out)
    if not m: return None
    return dict(w=int(m[1]), h=int(m[2]), ms=float(m[3]), mpx_s=float(m[4]), n=int(m[5]), uj=float(m[7]))

PERF_OUT = f"{SCR}/perf_stat.txt"
def pinned(cmd):
    """run on one core; with perf available, count CPU cycles and task time as well"""
    base = ["taskset", "-c", CORE] + cmd
    if not shutil.which("perf"): return base
    return ["perf", "stat", "-x,", "-e", "cycles,task-clock", "-o", PERF_OUT, "--"] + base

def ghz():
    """average CPU clock of the last pinned() run (cycles / task time), None if unknown"""
    try:
        s = open(PERF_OUT).read(); os.remove(PERF_OUT)
        cyc = float(re.search(r"^([\d.]+),[^,]*,cycles", s, re.M)[1])
        ms = float(re.search(r"^([\d.]+),msec,task-clock", s, re.M)[1])
        return round(cyc / (ms * 1e6), 3)
    except Exception:
        return None

def timed(cmd):
    """parse() of a pinned run, with its average CPU clock"""
    v = parse(run(pinned(cmd)).stdout)
    if v: v["ghz"] = ghz()
    return v

def power_profile(set_to=None):
    if not shutil.which("powerprofilesctl"): return None
    if set_to: run(["powerprofilesctl", "set", set_to])
    return run(["powerprofilesctl", "get"]).stdout.strip() or None

def build():
    os.makedirs(SCR, exist_ok=True)
    cc = ["gcc", "-O2", "-march=native", "-o"]
    r = run(cc + [f"{SCR}/bench_turbo", f"{HERE}/bench_c.c", "-DBACKEND_LIBJPEG", "-ljpeg"]); assert r.returncode == 0, r.stderr
    r = run(cc + [f"{SCR}/bench_stb", f"{HERE}/bench_c.c", "-DBACKEND_STB", f"-I{tools.stb_image_dir()}", "-lm"]); assert r.returncode == 0, r.stderr
    j9 = tools.libjpeg9()
    r = run(cc + [f"{SCR}/bench_jpeg9", f"{HERE}/bench_c.c", "-DBACKEND_LIBJPEG", f"-I{j9}/include", f"{j9}/lib/libjpeg.a"]); assert r.returncode == 0, r.stderr
    # Go's image/jpeg and zune-jpeg (Rust): skipped when the toolchain is missing
    env = dict(os.environ, GOCACHE=f"{SCR}/gocache", GOPATH=f"{SCR}/gopath", GOFLAGS="-mod=mod")
    r = subprocess.run([tools.go_bin(), "build", "-o", f"{SCR}/bench_go", "."], cwd=f"{HERE}/bench_go", env=env,
                       capture_output=True, text=True)
    if r.returncode: print("note: Go benchmark not built:", r.stderr[-300:])
    if shutil.which("cargo"):
        env = dict(os.environ, CARGO_TARGET_DIR=f"{SCR}/zune_target", RUSTFLAGS="-C target-cpu=native")
        r = subprocess.run(["cargo", "build", "--release", "--manifest-path", f"{HERE}/bench_zune/Cargo.toml"], env=env,
                           capture_output=True, text=True)
        if r.returncode: print("note: zune-jpeg benchmark not built (Rust 1.74+ needed):", r.stderr[-300:])
        else: shutil.copy(f"{SCR}/zune_target/release/bench_zune", f"{SCR}/bench_zune")

def ffmpeg_bench(path, w, h):
    """FFmpeg's own mjpeg decoder: decode an MJPEG stream of N copies of the image (one process),
    converted to RGB24 like the other decoders' output, subtract a run with N/4 copies to cancel
    process start-up, single thread."""
    data = open(path, "rb").read()
    n_big = max(20, min(400, int(3e8 // (w * h))))     # ~0.3 Gpixel of work
    n_small = n_big // 4
    times, clks = {}, {}
    for n in (n_small, n_big):
        fn = f"{SCR}/ffmpeg_{n}.mjpg"
        with open(fn, "wb") as f:
            for _ in range(n): f.write(data)
        best, best_clk = 1e9, None
        for _ in range(3):
            t0 = time.perf_counter()
            r = run(pinned(["ffmpeg", "-hide_banner", "-loglevel", "error", "-threads", "1", "-f", "mjpeg",
                            "-i", fn, "-pix_fmt", "rgb24", "-f", "null", "-"]))   # RGB out, like the others
            dt = time.perf_counter() - t0
            clk = ghz()                                  # sampled right after this trial
            if r.returncode: return None
            if dt < best: best, best_clk = dt, clk       # the clock goes with the trial that is kept
        times[n], clks[n] = best, best_clk
        os.remove(fn)
    per = (times[n_big] - times[n_small]) / (n_big - n_small)
    # (before 2026-10-10 the clock of the last trial was returned, whichever trial was fastest)
    return dict(w=w, h=h, ms=per * 1e3, mpx_s=w * h / per / 1e6, n=n_big, uj=-1, ghz=clks[n_big])

def main():
    want = os.environ.get("BENCH_POWER_PROFILE")
    before = power_profile()
    try:
        prof = power_profile(want) if want else before
        if prof != "performance":
            print(f"note: power profile is {prof!r}; CPU results depend on it (BENCH_POWER_PROFILE=performance)", flush=True)
        bench(prof)
    finally:
        if want and before and before != want: power_profile(before)

DECODERS = {   # name -> run(path, w, h); the names are the keys in the results
    "libjpeg-turbo (fancy)":    lambda p, w, h: timed([f"{SCR}/bench_turbo", p, "fancy", "1.5"]),
    "libjpeg-turbo (nosmooth)": lambda p, w, h: timed([f"{SCR}/bench_turbo", p, "nosmooth", "1.5"]),
    "libjpeg 9e (fancy)":       lambda p, w, h: timed([f"{SCR}/bench_jpeg9", p, "fancy", "1.5"]),
    "libjpeg 9e (nosmooth)":    lambda p, w, h: timed([f"{SCR}/bench_jpeg9", p, "nosmooth", "1.5"]),
    "stb_image":                lambda p, w, h: timed([f"{SCR}/bench_stb", p, "x", "1.5"]),
    "Pillow":                   lambda p, w, h: timed(["python3", f"{HERE}/bench_py.py", "pillow", p, "1.5"]),
    "OpenCV":                   lambda p, w, h: timed(["python3", f"{HERE}/bench_py.py", "opencv", p, "1.5"]),
    "FFmpeg mjpeg":             lambda p, w, h: ffmpeg_bench(p, w, h),
    "zune-jpeg":                lambda p, w, h: timed([f"{SCR}/bench_zune", p, "x", "1.5"]) if os.path.exists(f"{SCR}/bench_zune") else None,
    "Go image/jpeg":            lambda p, w, h: timed([f"{SCR}/bench_go", p, "x", "1.5"]) if os.path.exists(f"{SCR}/bench_go") else None,
    "Python reference model":   lambda p, w, h: timed(["python3", f"{HERE}/bench_py.py", "model", p, "1.0"]) if w * h <= 64 * 64 * 4 else None,
}

def bench(prof):
    """all decoders on all images; BENCH_ONLY=name,name re-runs only those and updates `out`"""
    from PIL import Image
    out = sys.argv[1] if len(sys.argv) > 1 else "bench.json"
    only = [x for x in os.environ.get("BENCH_ONLY", "").split(",") if x]
    build()
    old = json.load(open(out)) if os.path.exists(out) else {}
    res = old if (only and old) else {"cpu": run(["lscpu"]).stdout, "core": CORE, "results": {}}
    if "rtl" in old: res["rtl"] = old["rtl"]      # keep bench_fpga.py's clock counts
    res["power_profile"] = prof
    res["date"] = time.strftime("%Y-%m-%d")
    for name, path in IMAGES:
        w, h = Image.open(path).size
        r = res["results"].get(name, {}) if only else {}
        for k, f in DECODERS.items():
            if not only or k in only: r[k] = f(path, w, h)
        res["results"][name] = r
        print(name, {k: (v["ms"], v.get("ghz")) for k, v in r.items() if v and (not only or k in only)}, flush=True)
    json.dump(res, open(out, "w"), indent=1)

if __name__ == "__main__":
    main()
