#!/usr/bin/env python3
"""The interface assertions (jpeg_checker.sv) must fire: every scenario of test_checker.cpp breaks one rule and
must end with that rule's $fatal; "clean" breaks none and must run to its end. Without this, a checker that
never fires would pass every regression.
usage: run_checker_tests.py      (needs obj_chk/Vchk: make obj_chk/Vchk)"""
import os, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
EXE = os.path.join(HERE, "obj_chk", "Vchk")
SCEN = {"clean": None, "a1_drop": "A1", "a1_change": "A1", "a2_start_twice": "A2", "a2_done_alone": "A2",
        "a3_outside": "A3", "a3_beyond": "A3", "a3_eol": "A3", "a4_soi_open": "A4", "a4_err_changes": "A4",
        "a4_err_kept": "A4", "a5_no_done": "A5"}
fails = 0
for s, rule in SCEN.items():
    r = subprocess.run([EXE, s], capture_output=True, text=True, timeout=600, cwd=HERE)
    out = r.stdout + r.stderr
    ok = (r.returncode == 0 and "CLEAN END" in out) if rule is None else \
         (r.returncode != 0 and f"jpeg_checker {rule}" in out and "NO ASSERTION FIRED" not in out)
    msg = next((l.strip() for l in out.splitlines() if "jpeg_checker" in l), out.strip()[-120:])
    print(f"{'ok  ' if ok else 'FAIL'} {s:16s} expect {rule or 'no assertion':12s} {msg[:110]}")
    fails += not ok
print(f"CHECKER TESTS {len(SCEN) - fails}/{len(SCEN)} passed")
sys.exit(1 if fails else 0)
