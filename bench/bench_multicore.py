#!/usr/bin/env python3
"""bench_multicore.py - multi-core decode throughput of libjpeg-turbo -nosmooth on this computer.

N workers (bench_throughput.c), each pinned to one logical CPU, decode the whole photo set round-robin
at the same time for a fixed time (whole passes only). Reported per run: photos/s and Mpixel/s (the
sum of the workers' rates), each worker's average clock (perf stat: cycles / task time), the package
energy (RAPL) per photo when readable, and the rate rescaled to a steady 3.9 GHz (the CPU's best case,
as in the single-core comparisons). The FPGA batch is compared on the same photo set.
  [BENCH_POWER_PROFILE=performance] bench_multicore.py out.json [--seconds 60] [--runs 1:0,4:0-3,8:0-7] [--repeat 3] [files]
--repeat: each run that many times (15 s cool-down before each), for the spread; "summary" gives the
lowest, median and highest photos/s per run. "meta": versions, power settings and input hashes.
--runs: workers:cpu-list per run (on this i7-8550U, CPUs 0-3 are the four cores, 4-7 their second
hyper-threads). With BENCH_POWER_PROFILE the script sets that power profile for the runs and restores
the previous one at the end (powerprofilesctl)."""
import json, os, re, shutil, subprocess, sys, tempfile, time
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "model", "perf"))
REF_GHZ = 3.9


def cpus(spec):
    out = []
    for part in spec.split(","):
        a, _, b = part.partition("-")
        out += list(range(int(a), int(b or a) + 1))
    return out


def rapl():
    try: return int(open("/sys/class/powercap/intel-rapl:0/energy_uj").read())
    except OSError: return None


def profile(set_to=None):
    if not shutil.which("powerprofilesctl"): return None
    if set_to: subprocess.run(["powerprofilesctl", "set", set_to], check=True)
    return subprocess.run(["powerprofilesctl", "get"], capture_output=True, text=True).stdout.strip() or None


def one_run(exe, files, n, cpu_list, secs, tmp):
    procs = []
    e0, t0 = rapl(), time.time()
    for w in range(n):
        po = os.path.join(tmp, f"perf{w}.txt")
        cmd = ["perf", "stat", "-x,", "-e", "cycles,task-clock", "-o", po, "--",
               "taskset", "-c", str(cpu_list[w]), exe, str(secs), str(w * len(files) // n)] + files
        procs.append((subprocess.Popen(cmd, stdout=subprocess.PIPE, text=True), po))
    res = []
    for p, po in procs:
        out = p.communicate()[0]
        kv = dict(re.findall(r"(\w+)=([\d.]+)", out))
        s = open(po).read()
        cyc = float(re.search(r"^([\d.]+),[^,]*,cycles", s, re.M)[1])
        tsk = float(re.search(r"^([\d.]+),[^,]*,task-clock", s, re.M)[1])          # milliseconds
        res.append(dict(decodes=int(kv["decodes"]), mpix=float(kv["mpix"]), seconds=float(kv["seconds"]),
                        ghz=cyc / (tsk * 1e6)))
    wall, e1 = time.time() - t0, rapl()
    photos = sum(r["decodes"] / r["seconds"] for r in res)
    ghz = sum(r["ghz"] for r in res) / n
    out = dict(workers=n, cpus=cpu_list[:n], seconds=secs, photos_per_s=photos,
               mpix_per_s=sum(r["mpix"] / r["seconds"] for r in res), mean_ghz=ghz,
               photos_per_s_at_3p9ghz=photos * REF_GHZ / ghz, per_worker=res)
    if e0 is not None and e1 is not None and e1 > e0:
        out["package_joules_per_photo"] = (e1 - e0) / 1e6 / sum(r["decodes"] for r in res)
        out["package_watts"] = (e1 - e0) / 1e6 / wall
    return out


def main():
    args = sys.argv[1:]
    def opt(name, default):
        if name in args:
            i = args.index(name); v = args[i + 1]; del args[i:i + 2]; return v
        return default
    secs = float(opt("--seconds", "60")); runs = opt("--runs", "1:0,4:0-3,8:0-7"); repeat = int(opt("--repeat", "1"))
    out_json = args[0]; files = args[1:]
    if not files:
        import perf_model
        files = perf_model.photos()
    exe = os.path.join(HERE, "build", "bench_tp")
    os.makedirs(os.path.dirname(exe), exist_ok=True)
    subprocess.run(["cc", "-O2", "-o", exe, os.path.join(HERE, "bench_throughput.c"), "-ljpeg"], check=True)
    want = os.environ.get("BENCH_POWER_PROFILE"); before = profile()
    result = dict(date=time.strftime("%Y-%m-%d %H:%M"), cpu=open("/proc/cpuinfo").read().split("model name")[1].split(":")[1].split("\n")[0].strip(),
                  decoder="libjpeg-turbo (system library) -nosmooth: ISLOW, no fancy upsampling, RGB",
                  files=[os.path.basename(f) for f in files], runs=[])
    try:
        if want: profile(want)
        result["power_profile"] = profile()
        sys.path.insert(0, HERE); import tools
        result["meta"] = tools.meta([(os.path.basename(f), f) for f in files], runs, result["power_profile"],
                                    method=f"N workers (bench_throughput.c, libjpeg-turbo -nosmooth), each pinned to one logical "
                                           f"CPU, decode the photo set round-robin for {secs:g} s (whole passes); each run "
                                           f"{repeat} time(s) after a 15 s cool-down; clocks by perf stat per worker")
        with tempfile.TemporaryDirectory() as tmp:
            k = 0
            for spec in runs.split(","):
                n, cl = spec.split(":")
                for rep in range(repeat):
                    if k: time.sleep(15)                              # a short cool-down between runs
                    k += 1
                    r = one_run(exe, files, int(n), cpus(cl), secs, tmp)
                    r["spec"] = spec; r["repeat"] = rep
                    result["runs"].append(r)
                print(f"{r['workers']} workers on CPUs {cl}: {r['photos_per_s']:.1f} photos/s, {r['mpix_per_s']:.0f} Mpixel/s, "
                      f"mean clock {r['mean_ghz']:.2f} GHz ({r['photos_per_s_at_3p9ghz']:.1f} photos/s at a steady 3.9 GHz)"
                      + (f", {r['package_watts']:.1f} W, {r['package_joules_per_photo']:.2f} J/photo" if "package_watts" in r else ""), flush=True)
    finally:
        if want and before: profile(before)
        result["power_profile_after"] = profile()
        summ = {}
        for r in result["runs"]: summ.setdefault(r["spec"], []).append(r["photos_per_s"])
        result["summary"] = {s: dict(runs=len(v), photos_per_s_min=min(v), photos_per_s_median=sorted(v)[len(v) // 2],
                                     photos_per_s_max=max(v)) for s, v in summ.items()}
        json.dump(result, open(out_json, "w"), indent=1)


if __name__ == "__main__":
    main()
