#!/bin/bash
# Recompile the EP2C5 board projects one after another, niced, and summarise fit and timing in
# compile_all.log.  Gate-level twins (gls*, development branch only) also get their .vo netlist.
# Needs Quartus II 13.0sp1 (the last version with Cyclone II support) on PATH.
#   ./compile_all.sh [project ...]      (default: all, tightest builds first)
# Every project compiles the commit checked out: the checkout must have no modified tracked file and every file a
# .qsf names must be in the commit, before the compile and still after it (Quartus reads the sources during its
# analysis); <project>/output_files/provenance.txt records the commit and the sha256 of the files the .qsf names and
# of the bitstream. Otherwise the project is not compiled (BUILD_UNCOMMITTED=1: compiled anyway, recorded as
# UNCOMMITTED). Compile from a clean checkout of one commit (git worktree add --detach <dir> <commit>), not from a
# working tree that is being edited.
command -v quartus_sh >/dev/null || { echo "put the bin directory of Quartus II 13.0sp1 on PATH"; exit 1; }
cd "$(dirname "$0")"
TOP=$(git rev-parse --show-toplevel 2>/dev/null)
# the commit checked out and its modified tracked files ("-" outside a git checkout)
state() { [ -n "$TOP" ] && echo "$(git -C "$TOP" rev-parse HEAD) $(git -C "$TOP" status --porcelain --untracked-files=no | tr '\n' ' ')" || echo "-"; }
# the files a project's .qsf names, as paths from the project
named() { sed -nE 's/^[[:space:]]*set_global_assignment[[:space:]]+-name[[:space:]]+[A-Z_]*_FILE[[:space:]]+"?([^"]+)"?[[:space:]]*$/\1/p' "$1"; }
PROJ=${*:-"fpga_raster fpga_jtag fpga_fast_bench fpga_fast gls_fast gls_raster fpga_raster_ycc fpga_raster_box fpga gls"}
LOG=$PWD/compile_all.log
echo "== $(date '+%F %T') $PROJ" >> "$LOG"
for p in $PROJ; do
  [ -d "$p" ] || continue
  rev=$(basename "$(ls "$p"/*.qpf | head -1)" .qpf)
  before=$(state); bad=""
  [ "$before" = "-" ] && bad="not a git checkout"
  [ -n "$bad" ] || [ "${before#* }" = "" ] || bad="modified: ${before#* }"
  [ -n "$bad" ] || bad=$(cd "$p" && named "$rev.qsf" | while read -r f; do
                           git ls-files --error-unmatch -- "$f" > /dev/null 2>&1 || echo -n "not in the commit: $f "; done)
  if [ -n "$bad" ] && [ "$BUILD_UNCOMMITTED" != 1 ]; then
    echo "$p NOT COMPILED: the checkout is not one commit ($bad); see the top of compile_all.sh" | tee -a "$LOG"; continue
  fi
  t0=$(date +%s)
  ( cd "$p" && ulimit -v 6000000 && nice -n 10 timeout 3600 quartus_sh --flow compile "$rev" > compile.log 2>&1 )
  rc=$?
  # what was compiled: the commit, unless the checkout changed while Quartus read it
  after=$(state)
  if [ -z "$bad" ] && [ "$after" != "$before" ]; then bad="the checkout changed during the compile: $after"; rc=1; fi
  mkdir -p "$p/output_files"
  { echo "commit     ${before%% *}"
    if [ -z "$bad" ]; then echo "state      committed (no modified tracked file before or after the compile)"
    else echo "state      UNCOMMITTED ($bad)"; fi
    echo "compiled   $(date '+%F %T %z'), $(quartus_sh --version 2>/dev/null | grep -m1 -o 'Version.*')"
    echo "files the .qsf names (sha256, path):"
    (cd "$p" && named "$rev.qsf" | while read -r f; do echo "  $(sha256sum "$f" | cut -d' ' -f1) $f"; done)
    [ -f "$p/output_files/$rev.sof" ] && echo "bitstream  $rev.sof sha256 $(sha256sum "$p/output_files/$rev.sof" | cut -d' ' -f1)"
  } > "$p/output_files/provenance.txt"
  if [ $rc -eq 0 ] && grep -q "EDA_SIMULATION_TOOL" "$p/$rev.qsf"; then
    ( cd "$p" && nice -n 10 timeout 1200 quartus_eda "$rev" --simulation --tool=modelsim --format=verilog > eda.log 2>&1 )
  fi
  le=$(grep -h "Total logic elements" "$p"/output_files/"$rev".fit.summary 2>/dev/null)
  sum="$p/output_files/$rev.sta.summary"
  setup=$(awk '/^Type/{t=$0} /^Slack/{if (t ~ /Slow Model Setup/ && s == "") s=$3} END{print s}' "$sum" 2>/dev/null)
  hold=$(awk '/^Type/{t=$0} /^Slack/{if (t ~ /Slow Model Hold/ && h == "") h=$3} END{print h}' "$sum" 2>/dev/null)
  fmax=$(grep -A4 "^; Slow Model Fmax Summary" "$p"/output_files/"$rev".sta.rpt 2>/dev/null | grep -oE "[0-9.]+ MHz" | head -1)
  echo "$p rc=$rc $(( $(date +%s) - t0 ))s | $le | setup slack $setup ns, hold slack $hold ns | Fmax $fmax | commit ${before:0:8}${bad:+ UNCOMMITTED}" >> "$LOG"
done
echo "== done $(date '+%F %T')" >> "$LOG"
