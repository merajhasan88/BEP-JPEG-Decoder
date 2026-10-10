#!/bin/sh
# tb/run_tests.sh - the regression with the SystemVerilog testbench (tb_jpeg.sv): no Python, no
# C++.  The same runs as `make test` (the C++ harness driven by Python):
#   1. every test file x 8 build configurations x 3 output formats x {no stalls, 30 % random input
#      stalls + output back-pressure} against the golden images (tb/expected.txt): 1,616 runs;
#      too-wide images must end with ERR_WIDTH and no pixels, unsupported files with an error;
#   2. images back to back without a reset (tb/stream_scenarios.txt): 80 runs;
#   3. malformed and truncated files (tb/malformed/cases.txt): 416 runs.
#   tb/run_tests.sh [-s verilator|xsim|icarus|questa] [--quick] [--configs a,b,...]
# --quick: no stall runs.  Data files are written by export_expectations.py in the development tree.
HERE=$(cd "$(dirname "$0")" && pwd)
SIM=verilator; STALLS="0 30"; CONFIGS="mcu rbox rfancy ep2c5 noyrgb fmcu frbox frfancy wmcu"
while [ $# -gt 0 ]; do
  case $1 in
    -s) SIM=$2; shift 2;;
    --quick) STALLS=0; shift;;
    --configs) CONFIGS=$(echo "$2" | tr ',' ' '); shift 2;;
    --configs=*) CONFIGS=$(echo "${1#--configs=}" | tr ',' ' '); shift;;
    *) echo "unknown option $1" >&2; exit 2;;
  esac
done
for f in expected.txt stream_scenarios.txt malformed/cases.txt; do
  [ -f "$HERE/$f" ] || { echo "missing tb/$f (written by tb/export_expectations.py)" >&2; exit 2; }
done
for c in $CONFIGS; do
  echo "building $c ($SIM) ..."
  "$HERE/sim.sh" -s "$SIM" -c "$c" --build || exit 1
done
run() { "$HERE/sim.sh" -s "$SIM" -c "$@" 2>&1; }
has() { case " $CONFIGS " in *" $1 "*) return 0;; esac; return 1; }

# ---------------------------------------------------------------- 1. test files
total=0; fails=0
while read -r img cfg fmt expect golden; do
  case $img in ""|\#*) continue;; esac
  has "$cfg" || continue
  for st in $STALLS; do
    case $expect in
      pass)  log=$(run "$cfg" +JPEG="$HERE/corpus/$img.jpg" +FMT="$fmt" +STALL="$st" +QUIET +GOLDEN="$HERE/$golden")
             echo "$log" | grep -q "PASS: output matches" && ! echo "$log" | grep -q "FAIL" && ok=1 || ok=0;;
      width) log=$(run "$cfg" +JPEG="$HERE/corpus/$img.jpg" +FMT="$fmt" +STALL="$st" +QUIET +EXPECT_ERR=400)
             echo "$log" | grep -q "PASS: expected err" && ok=1 || ok=0;;
      error) log=$(run "$cfg" +JPEG="$HERE/corpus/$img.jpg" +FMT="$fmt" +STALL="$st" +QUIET)
             e=$(echo "$log" | sed -n 's/.*err=0x\([0-9a-f]*\).*/\1/p' | head -1)
             [ -n "$e" ] && [ "$e" != 0000 ] && ! echo "$log" | grep -q "frame_done never seen" && ok=1 || ok=0;;
    esac
    total=$((total + 1))
    if [ $ok = 0 ]; then
      fails=$((fails + 1)); echo "FAIL $cfg $fmt stall=$st $img ($expect)"; echo "$log" | grep -E "FAIL|cycles=" | head -3 | sed 's/^/   /'
    fi
  done
done < "$HERE/expected.txt"
echo "TEST FILES $((total - fails))/$total passed"
t1=$total; f1=$fails

# ---------------------------------------------------------------- 2. back to back
total=0; fails=0
for cfg in $CONFIGS; do
  fmt=rgb; prof=box
  case $cfg in noyrgb) fmt=ycbcr;; esac
  case $cfg in rfancy*|frfancy*|ep2c5|noyrgb) prof=fancy;; esac
  while IFS='|' read -r names title; do
    case $names in ""|\#*) continue;; esac
    files=""; golds=""; n=0
    for nm in $names; do
      n=$((n + 1))
      case $nm in malformed/*) files="$files,$HERE/$nm.jpg";; *) files="$files,$HERE/corpus/$nm.jpg";; esac
      g="$HERE/golden/$nm.$prof.$fmt.pnm"
      case $nm in *UNSUPPORTED*|malformed/*) golds="$golds,-";; *) [ -f "$g" ] && golds="$golds,$g" || golds="$golds,-";; esac
    done
    for st in $STALLS; do
      log=$(run "$cfg" +FILES="${files#,}" +GOLDENS="${golds#,}" +FMT="$fmt" +STALL="$st")
      ok=1; k=0
      for nm in $names; do
        k=$((k + 1)); fl=$(echo "$log" | grep "^frame $k:")
        case $nm in
          malformed/*) echo "$fl" | grep -q "err=0x0000" && ok=0; [ -n "$fl" ] || ok=0;;   # its own error, pixels allowed
          *UNSUPPORTED*) echo "$fl" | grep -q " 0 pixels, err=0x0000" && ok=0; echo "$fl" | grep -q " 0 pixels" || ok=0;;
          *) if [ -f "$HERE/golden/$nm.$prof.$fmt.pnm" ]; then echo "$fl" | grep -q "err=0x0000, MATCH" || ok=0
             else echo "$fl" | grep -q " 0 pixels, err=0x0000" && ok=0; echo "$fl" | grep -q " 0 pixels" || ok=0; fi;;   # a refused format
        esac
      done
      echo "$log" | grep -q "^frames: $n$" || ok=0
      total=$((total + 1))
      if [ $ok = 0 ]; then fails=$((fails + 1)); echo "FAIL $cfg stall=$st $title"; echo "$log" | sed 's/^/   /' | head -8; fi
    done
  done < "$HERE/stream_scenarios.txt"
done
echo "STREAM TESTS $((total - fails))/$total passed"
t2=$total; f2=$fails

# ---------------------------------------------------------------- 3. malformed and truncated files
total=0; fails=0
for cfg in $CONFIGS; do
  while read -r name bits pixels; do
    case $name in ""|\#*) continue;; esac
    np=""; [ "$pixels" = 0 ] && np=+NO_PIXELS
    for st in $STALLS; do
      log=$(run "$cfg" +JPEG="$HERE/malformed/$name.jpg" +QUIET +EXPECT_ERR_MASK="$bits" +STALL="$st" +MAX_CYCLES=2000000 $np)
      total=$((total + 1))
      if ! echo "$log" | grep -q "^PASS"; then
        fails=$((fails + 1)); echo "FAIL $cfg stall=$st $name"; echo "$log" | grep -E "FAIL|cycles=" | head -2 | sed 's/^/   /'
      fi
    done
  done < "$HERE/malformed/cases.txt"
done
echo "MALFORMED $((total - fails))/$total passed"
[ $((t1 + t2 + total)) = 0 ] && { echo "no runs (check --configs)" >&2; exit 1; }
[ $((f1 + f2 + fails)) = 0 ] && { echo "ALL PASSED"; exit 0; }
exit 1
