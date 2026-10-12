"""Reference tools for the benchmarks and checks, built on demand inside the repository (or in
$BENCH_SCRATCH): libjpeg 9e (the IJG reference; this decoder's default profile matches its
`djpeg -dct int -nosmooth` bit for bit) and stb_image.h.
  libjpeg 9e source: $LIBJPEG9_SRC (an unpacked jpeg-9e folder) or downloaded from ijg.org
  stb_image.h:       $STB_IMAGE_H or downloaded from github.com/nothings/stb
  Go (bench_go):     go on PATH or the official release downloaded from go.dev
  zune-jpeg (Rust):  needs cargo (rustup; zune-jpeg 0.4.21 needs Rust 1.74 or later)
  python3 bench/tools.py      -> builds libjpeg 9e and prints the path of its djpeg"""
import os, shutil, subprocess, tarfile, time, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, ".."))
SCR = os.environ.get("BENCH_SCRATCH", os.path.join(HERE, "build"))
LIBJPEG9_URL = "https://www.ijg.org/files/jpegsrc.v9e.tar.gz"
STB_URL = "https://raw.githubusercontent.com/nothings/stb/master/stb_image.h"
GO_URL = "https://go.dev/dl/go1.27.1.linux-amd64.tar.gz"

def default_images():
    """the benchmark's images: three small corpus files and every JPEG in test_images/"""
    corpus = [os.path.join(REPO, "tb", "corpus", n + ".jpg")
              for n in ("adp_64x64_q25_420", "board_352x32_q6_420", "adp_320x240_q90_420")]
    ti = os.path.join(REPO, "test_images")
    photos = sorted(os.path.join(ti, f) for f in os.listdir(ti) if f.lower().endswith((".jpg", ".jpeg"))) if os.path.isdir(ti) else []
    return [(os.path.splitext(os.path.basename(p))[0], p) for p in corpus + photos if os.path.exists(p)]

def libjpeg9(prefix_only=False):
    """install prefix of libjpeg 9e (bin/djpeg, lib/libjpeg.a, include/), built once"""
    j9 = os.path.join(SCR, "jpeg9e")
    if os.path.exists(os.path.join(j9, "inst", "lib", "libjpeg.a")): return os.path.join(j9, "inst")
    os.makedirs(j9, exist_ok=True)
    src = os.environ.get("LIBJPEG9_SRC")
    if src:
        shutil.rmtree(os.path.join(j9, "src"), ignore_errors=True); shutil.copytree(src, os.path.join(j9, "src"))
    else:
        tgz = os.path.join(j9, "jpegsrc.v9e.tar.gz")
        if not os.path.exists(tgz): urllib.request.urlretrieve(LIBJPEG9_URL, tgz)
        with tarfile.open(tgz) as t: t.extractall(j9)
        shutil.rmtree(os.path.join(j9, "src"), ignore_errors=True); os.rename(os.path.join(j9, "jpeg-9e"), os.path.join(j9, "src"))
    for dp, _, fs in os.walk(os.path.join(j9, "src")):     # some copies carry CRLF line endings
        for fn in fs:
            p = os.path.join(dp, fn)
            if fn in ("configure", "config.sub", "config.guess", "install-sh", "depcomp", "compile", "missing",
                      "ltmain.sh", "ar-lib") or fn.endswith((".in", ".am")):
                s = open(p, "rb").read(); open(p, "wb").write(s.replace(b"\r\n", b"\n")); os.chmod(p, 0o755)
    b = os.path.join(j9, "build"); os.makedirs(b, exist_ok=True)
    for cmd in ([os.path.join(j9, "src", "configure"), f"--prefix={j9}/inst", "--disable-shared", "CFLAGS=-O2"],
                ["make", "-j2"], ["make", "install"]):
        r = subprocess.run(["nice", "-n", "10"] + cmd, cwd=b, capture_output=True, text=True)
        if r.returncode: raise SystemExit(f"libjpeg 9e build failed: {' '.join(cmd)}\n{r.stdout[-500:]}{r.stderr[-500:]}")
    return os.path.join(j9, "inst")

def djpeg9():
    return os.environ.get("LIBJPEG9_DJPEG") or os.path.join(libjpeg9(), "bin", "djpeg")

def ref_checksum(jpg, djpeg=None):
    """The boards' pixel checksum of libjpeg 9e's decode (`djpeg -dct int -nosmooth`, which this
    decoder's MCU-order output reproduces): sum of {(x ^ y)[7:0], R, G, B} over all pixels, mod 2^32.
    Returns (checksum, width, height); (None, 0, 0) when libjpeg rejects the file (a file with only
    warnings, such as a truncated one, still counts)."""
    import tempfile
    import numpy as np
    from PIL import Image
    with tempfile.TemporaryDirectory() as t:
        out = os.path.join(t, "ref.pnm")
        subprocess.run([djpeg or djpeg9(), "-dct", "int", "-nosmooth", "-pnm", "-outfile", out, jpg], capture_output=True)
        try:
            a = np.asarray(Image.open(out).convert("RGB")).astype(np.uint64)
        except Exception:
            return None, 0, 0
    h, w, _ = a.shape
    y, x = np.mgrid[0:h, 0:w]
    xy = ((x ^ y) & 0xFF).astype(np.uint64)
    words = (xy << 24) | (a[:, :, 0] << 16) | (a[:, :, 1] << 8) | a[:, :, 2]
    return int(words.sum()) & 0xFFFFFFFF, w, h

def go_bin():
    """the go command: on PATH, else the official release unpacked into SCR"""
    if shutil.which("go"): return "go"
    g = os.path.join(SCR, "go", "bin", "go")
    if not os.path.exists(g):
        os.makedirs(SCR, exist_ok=True)
        tgz = os.path.join(SCR, "go.tgz"); urllib.request.urlretrieve(GO_URL, tgz)
        with tarfile.open(tgz) as t: t.extractall(SCR)
        os.remove(tgz)
    return g

def stb_image_dir():
    """folder holding stb_image.h"""
    p = os.environ.get("STB_IMAGE_H")
    if p: return os.path.dirname(os.path.abspath(p))
    os.makedirs(SCR, exist_ok=True)
    h = os.path.join(SCR, "stb_image.h")
    if not os.path.exists(h): urllib.request.urlretrieve(STB_URL, h)
    return SCR

def meta(images, core, prof, method=None):
    """what a benchmark run was made with (the review of 2026-10-10: CPU model, affinity, compiler and library
    revisions, power settings, warm-up, distributions, exact input hashes)"""
    import platform, hashlib
    def first(cmd):
        try: t = subprocess.run(cmd, capture_output=True, text=True); t = (t.stdout or t.stderr).strip()
        except OSError: return None
        return t.splitlines()[0] if t else None
    def sysfs(f):
        try: return open(f).read().strip()
        except OSError: return None
    vers = {"kernel": platform.release(), "python": platform.python_version(), "gcc": first(["gcc", "--version"]),
            "libjpeg-turbo": first(["djpeg", "-version"]), "libjpeg 9e": "9e (bench/tools.py, built from ijg.org's jpegsrc.v9e)",
            "ffmpeg": first(["ffmpeg", "-version"]), "go": first([go_bin(), "version"]), "rustc": first(["rustc", "--version"])}
    try:
        stb = open(os.path.join(stb_image_dir(), "stb_image.h")).readline().strip()
        vers["stb_image"] = stb[:80]
    except OSError: pass
    try:
        import PIL, cv2, numpy
        vers.update(Pillow=PIL.__version__, OpenCV=cv2.__version__, numpy=numpy.__version__)
    except ImportError: pass
    cpu = f"/sys/devices/system/cpu/cpu{str(core).split(',')[0].split('-')[0]}/cpufreq"
    sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
    return dict(date=time.strftime("%Y-%m-%d %H:%M:%S"), versions=vers, core=core, affinity=f"taskset -c {core}",
                power_profile=prof, governor=sysfs(f"{cpu}/scaling_governor"),
                energy_performance_preference=sysfs(f"{cpu}/energy_performance_preference"),
                method=method or "one warm-up decode, a 0.05 s calibration, then batches of ~0.1 s for at least the given time "
                       "(1.5 s; at least 5, at most 64 batches); ms = the median batch's ms per decode, batches_ms = "
                       "every batch in the order measured; ghz = the run's average clock by perf stat (cycles / task time)",
                inputs={n: sha(p) for n, p in images})

if __name__ == "__main__":
    print(djpeg9())
