#!/bin/bash
# build_on_aws.sh - builds the BEP-JPEG F2 image's design checkpoint (the tarball AWS turns into an AFI) on AWS's FPGA
# Developer AMI (Vivado 2025.2), from a source tarball of one commit (made with git archive; its top folder holds a file
# COMMIT with the commit's hash). Every step logs to $WORK/logs and the script stops at the first failure:
#   1. aws-fpga HDK v2.3.5 (git clone, then its hdk_setup.sh: the shell checkpoint and the CL IP for this Vivado)
#   2. the CL (this folder in the tarball): the commit's first 8 hex digits stamped into cl_jpeg_defines.vh (the OCL
#      register COMMIT reads them back on the F2); the HDK's three build scripts linked into build/scripts
#   3. AWS's XSIM test of the CL (verif/tests/cl_jpeg_test.sv): must end with "TEST PASSED"
#   4. the DCP build (aws_build_dcp_from_cl.py -c cl_jpeg --no-encrypt: our sources are open), then the timing check:
#      a design that fails timing (post_route.VIOLATED.dcp) is reported and not offered for AFI creation
# usage (on the build instance, in the unpacked tarball's top folder):
#   boards/aws_f2/cl_jpeg/build_on_aws.sh [--sim-only] [--skip-sim]
set -euo pipefail
SIM=1; BUILD=1
for a in "$@"; do
  case "$a" in
    --sim-only) BUILD=0 ;;
    --skip-sim) SIM=0 ;;
    *) echo "unknown option $a"; exit 2 ;;
  esac
done
SRC=$(cd "$(dirname "$0")/../../.." && pwd)              # the unpacked tarball's top folder
CL=$SRC/boards/aws_f2/cl_jpeg
WORK=${WORK:-$HOME/bepjpeg_f2}
mkdir -p "$WORK/logs"
log() { echo "$(date '+%F %T') $*" | tee -a "$WORK/logs/build_on_aws.log"; }
[ -f "$SRC/COMMIT" ] || { log "no COMMIT file in $SRC: make the tarball with the packaging steps (boards/aws_f2/README.md)"; exit 1; }
COMMIT=$(tr -d '[:space:]' < "$SRC/COMMIT")
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || { log "COMMIT is not a full commit hash: $COMMIT"; exit 1; }
log "source commit $COMMIT, CL $CL, work folder $WORK"

# ---- 1. the HDK
if [ ! -d "$WORK/aws-fpga" ]; then
  log "cloning aws-fpga (as AWS documents it), then checking out v2.3.5"
  git clone https://github.com/aws/aws-fpga.git "$WORK/aws-fpga" >> "$WORK/logs/clone.log" 2>&1
  git -C "$WORK/aws-fpga" checkout -q v2.3.5 >> "$WORK/logs/clone.log" 2>&1
fi
[ "$(git -C "$WORK/aws-fpga" rev-parse HEAD)" = "c34f88e97eaf8a9b6ea7a3516ab65ee64690ab82" ] || { log "aws-fpga is not v2.3.5"; exit 1; }
if ! command -v vivado > /dev/null; then                  # a shell that did not run the AMI's login profile
  for f in /tools/Xilinx/*/Vivado/settings64.sh /tools/Xilinx/Vivado/*/settings64.sh /opt/Xilinx/*/Vivado/settings64.sh \
           /opt/Xilinx/Vivado/*/settings64.sh; do
    if [ -f "$f" ]; then set +u; source "$f"; set -u; log "sourced $f"; break; fi
  done
fi
command -v vivado > /dev/null || { log "vivado is not on PATH and no settings64.sh was found"; exit 1; }
log "vivado: $(vivado -version | head -1)"
cd "$WORK/aws-fpga"
set +e +u                                                 # AWS's setup script is not written for errexit / nounset
set --                                                    # a sourced script sees our arguments: hdk_setup.sh rejects them
# shellcheck disable=SC1091
source hdk_setup.sh > "$WORK/logs/hdk_setup.log" 2>&1
rc=$?
set -e -u
grep -q "AWS HDK setup PASSED" "$WORK/logs/hdk_setup.log" && [ $rc -eq 0 ] || { log "hdk_setup.sh failed (rc=$rc, logs/hdk_setup.log)"; exit 1; }
log "hdk_setup.sh passed: HDK_SHELL_DIR=$HDK_SHELL_DIR VIVADO_TOOL_VERSION=$VIVADO_TOOL_VERSION"

# ---- 2. the CL
export CL_DIR=$CL
sed -i "s/^\`define JPEG_F2_COMMIT .*/\`define JPEG_F2_COMMIT 32'h${COMMIT:0:8}/" "$CL/design/cl_jpeg_defines.vh"
grep -q "JPEG_F2_COMMIT 32'h${COMMIT:0:8}" "$CL/design/cl_jpeg_defines.vh" || { log "the commit stamp was not written"; exit 1; }
for f in aws_build_dcp_from_cl.py build_all.tcl build_level_1_cl.tcl; do
  ln -sf "$HDK_SHELL_DIR/build/scripts/$f" "$CL/build/scripts/$f"
done
log "CL ready: commit stamp 32'h${COMMIT:0:8}"

# ---- 3. AWS's XSIM test
if [ $SIM = 1 ]; then
  log "XSIM test cl_jpeg_test (the first run also compiles AWS's simulation IP)"
  cd "$CL/verif/scripts"
  set +e
  timeout 14400 make TEST=cl_jpeg_test DONT_GENERATE_FILE_LIST=1 > "$WORK/logs/xsim_cl_jpeg_test.log" 2>&1
  rc=$?
  set -e
  grep -E "\*\*\* TEST (PASSED|FAILED)|ERROR|Detected" "$WORK/logs/xsim_cl_jpeg_test.log" | tail -20 | tee -a "$WORK/logs/build_on_aws.log"
  if [ $rc -ne 0 ] || ! grep -q "\*\*\* TEST PASSED \*\*\*" "$WORK/logs/xsim_cl_jpeg_test.log"; then
    log "XSIM test did not pass (rc=$rc): stopping before the build (logs/xsim_cl_jpeg_test.log)"; exit 1
  fi
  grep -q "COMMIT 0x${COMMIT:0:8}" "$WORK/logs/xsim_cl_jpeg_test.log" || \
    { log "XSIM: the COMMIT register does not read 0x${COMMIT:0:8} (the stamp did not reach the design)"; exit 1; }
  log "XSIM test passed; the COMMIT register reads 0x${COMMIT:0:8}"
fi
[ $BUILD = 1 ] || { log "--sim-only: done"; exit 0; }

# ---- 4. the DCP build and its timing
cd "$CL/build/scripts"
log "DCP build started (aws_build_dcp_from_cl.py -c cl_jpeg --no-encrypt)"
set +e
timeout 36000 ./aws_build_dcp_from_cl.py -c cl_jpeg --no-encrypt > "$WORK/logs/dcp_build.log" 2>&1
rc=$?
set -e
log "DCP build ended (rc=$rc)"
CK=$CL/build/checkpoints
TAR=$(ls -t "$CK"/*.Developer_CL.tar 2>/dev/null | head -1 || true)
RPT=$(ls -t "$CL"/build/reports/*.post_route_timing.rpt 2>/dev/null | head -1 || true)
[ -n "$RPT" ] && grep -m3 -E "^Slack|slack \(" "$RPT" | tee -a "$WORK/logs/build_on_aws.log" || true
if ls "$CK"/*.post_route.VIOLATED.dcp > /dev/null 2>&1; then
  log "TIMING FAILED: post_route.VIOLATED.dcp - do not create an AFI from this build (report: $RPT)"; exit 1
fi
[ -n "$TAR" ] || { log "no Developer_CL.tar was written (logs/dcp_build.log)"; exit 1; }
log "timing met; tarball $TAR"
log "sha256 $(sha256sum "$TAR" | cut -d' ' -f1)"
tar -tvf "$TAR" | tee -a "$WORK/logs/build_on_aws.log"
log "next: the AFI (boards/aws_f2/README.md, 'Creating the AFI'); keep logs/, the reports and the tarball"
