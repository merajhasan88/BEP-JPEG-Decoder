#!/usr/bin/env python3
"""manifest.py - what a set of results was made from (the review of 2026-10-10, priority 2: source and
input hashes, complete fit and timing reports). Writes one JSON file with:
  git      the commit and branch, and the files that differ from the commit (results made with them are
           not reproducible from the commit alone)
  tools    the versions of Verilator, Quartus, libjpeg 9e's and libjpeg-turbo's djpeg, Python
  sources  sha256 of the design, the model and the testbenches (rtl/, boards/*/[rtl/]*.sv, model/jpeg_golden.py,
           tb/ and boards/*/sim/ sources)
  inputs   sha256 of every test input (tb/corpus, tb/malformed, test_images) and one digest of tb/golden
  ep2c5    per Quartus project in boards/ep2c5: device, top, parameters, the files its .qsf names (sha256),
           the fit and timing summaries (full text), the bitstream's sha256 and time, and "stale": named
           files modified after the bitstream (by file time, so meaningful in the working tree only)
  python3 scripts/manifest.py [--out FILE]        (without --out: printed)"""
import glob, hashlib, json, os, re, subprocess, sys, time
REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
QUARTUS = "/root/altera/13.0sp1/quartus/bin"

def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""): h.update(b)
    return h.hexdigest()

def rel(p): return os.path.relpath(p, REPO)

def cmd(args, timeout=60):
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=timeout, cwd=REPO, stdin=subprocess.DEVNULL)
        return (r.stdout + r.stderr).rstrip()
    except (OSError, subprocess.TimeoutExpired) as e:
        return f"unavailable ({type(e).__name__})"

def first_line(s, pat=None):
    for l in s.splitlines():
        if not pat or re.search(pat, l): return l.strip()
    return s.strip()[:120]

def files(patterns):
    out = []
    for p in patterns: out += glob.glob(os.path.join(REPO, p))
    return sorted(set(f for f in out if os.path.isfile(f)))

def ep2c5():
    res = {}
    for qsf in sorted(glob.glob(os.path.join(REPO, "boards", "ep2c5", "*", "*.qsf"))):
        d = os.path.dirname(qsf); rev = os.path.basename(qsf)[:-4]
        proj = dict(revision=rev, files={}, parameters={})
        for line in open(qsf, errors="replace"):
            m = re.match(r"\s*set_global_assignment\s+-name\s+(\S+)\s+(.+?)\s*$", line)
            if m:
                k, v = m.group(1), m.group(2).strip('"')
                if k in ("DEVICE", "TOP_LEVEL_ENTITY"): proj[k.lower()] = v
                elif k.endswith("_FILE"):
                    p = os.path.normpath(os.path.join(d, v))
                    proj["files"][rel(p)] = sha(p) if os.path.isfile(p) else "missing"
            m = re.match(r"\s*set_parameter\s+-name\s+(\S+)\s+(\S+)", line)
            if m: proj["parameters"][m.group(1)] = m.group(2).strip('"')
        sof = os.path.join(d, "output_files", rev + ".sof")
        if os.path.isfile(sof):
            t = os.path.getmtime(sof)
            proj["sof"] = dict(sha256=sha(sof), time=time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(t)))
            proj["stale"] = sorted(f for f in proj["files"]
                                   if os.path.isfile(os.path.join(REPO, f)) and os.path.getmtime(os.path.join(REPO, f)) > t)
        for kind in ("fit", "sta"):
            s = os.path.join(d, "output_files", f"{rev}.{kind}.summary")
            if os.path.isfile(s): proj[f"{kind}_summary"] = open(s, errors="replace").read().strip().splitlines()
        res[rel(d)] = proj
    return res

def main():
    out = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv else None
    git = dict(commit=cmd(["git", "rev-parse", "HEAD"]), branch=cmd(["git", "rev-parse", "--abbrev-ref", "HEAD"]),
               modified=[l[3:] for l in cmd(["git", "status", "--porcelain", "--untracked-files=no"]).splitlines() if l.strip()])
    djpeg9 = os.path.join(REPO, "bench", "build", "jpeg9e", "inst", "bin", "djpeg")
    tools = dict(verilator=first_line(cmd(["verilator", "--version"])),
                 quartus=first_line(cmd([os.path.join(QUARTUS, "quartus_sh"), "--version"]), r"Version"),
                 libjpeg9e_djpeg=first_line(cmd([djpeg9, "-verbose"]), r"version") if os.path.exists(djpeg9) else "not built",
                 libjpeg_turbo_djpeg=first_line(cmd(["djpeg", "-version"])),
                 python=sys.version.split()[0])
    src = files(["rtl/*.sv", "boards/*/*.sv", "boards/*/rtl/*.sv", "model/jpeg_golden.py", "tb/*.cpp", "tb/*.sv",
                 "tb/*.py", "boards/*/sim/*.cpp", "boards/*/sim/*.py", "boards/*/sim/Makefile", "tb/Makefile"])
    inp = files(["tb/corpus/*.jpg", "tb/malformed/*.jpg", "test_images/*.jpg"])
    gold = files(["tb/golden/*"])
    gd = hashlib.sha256("".join(f"{rel(f)} {sha(f)}\n" for f in gold).encode()).hexdigest()
    m = dict(date=time.strftime("%Y-%m-%d %H:%M:%S"), git=git, tools=tools,
             sources={rel(f): sha(f) for f in src}, inputs={rel(f): sha(f) for f in inp},
             golden=dict(files=len(gold), digest_of_names_and_sha256=gd), ep2c5=ep2c5())
    s = json.dumps(m, indent=1)
    if out:
        with open(out, "w") as f: f.write(s + "\n")
        st = sum(len(p.get("stale", [])) for p in m["ep2c5"].values())
        print(f"{out}: commit {git['commit'][:7]} ({len(git['modified'])} modified files), {len(src)} sources, "
              f"{len(inp)} inputs, {len(m['ep2c5'])} EP2C5 projects ({st} stale files)")
    else: print(s)

if __name__ == "__main__":
    sys.exit(main())
