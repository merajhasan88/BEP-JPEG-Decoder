#!/bin/sh
# tb/sim.sh - build (once) and run the SystemVerilog testbench tb/tb_jpeg.sv with a simulator.
# No Python and no C++ needed.
#   tb/sim.sh [-s SIM] [-c CONFIG] [--build] [+PLUSARG ...]
#     SIM     verilator (default; 5.002 or later: --binary --timing) or xsim (Vivado: xvlog/xelab/xsim
#             on PATH) - both tested; icarus (Icarus Verilog 12 or later; 11 cannot compile the fast
#             raster core and mis-simulates the compact core) and questa (vlog/vsim) are untested
#     CONFIG  the decoder's build options (default fmcu):
#               mcu      FAST=0, MCU order, replication              = libjpeg 9e `djpeg -dct int -nosmooth`
#               fmcu     FAST=1, MCU order                           (same pixels, ~10x fewer clocks)
#               rbox     FAST=0 RASTER_OUT=1      frbox  FAST=1 RASTER_OUT=1
#               rfancy   FAST=0 raster + FANCY_UPSAMPLE + CC_TURBO   = Pillow / OpenCV / libjpeg-turbo
#               frfancy  FAST=1 raster + FANCY_UPSAMPLE + CC_TURBO
#               wmcu     FAST=2, MCU order, 4 pixels per beat       (the wide core, Artix-7-class FPGAs)
#               ep2c5    rfancy with a 9,216-byte row buffer          noyrgb  ep2c5 with RGB_OUT=0
#               <raster config>_rbN   with ROWBUF_BYTES=N (e.g. frfancy_rb262144 for wide photos)
#     +PLUSARGS for tb_jpeg.sv: +JPEG=in.jpg +OUT=out.ppm +GOLDEN=ref.ppm +FMT=rgb|ycbcr|y +STALL=N ...
#     --build   only build
# Builds are kept in tb/build/<sim>_<config>/ and rebuilt when rtl/ or tb_jpeg.sv change.
set -e
HERE=$(cd "$(dirname "$0")" && pwd); RTLDIR=$HERE/../rtl
SIM=verilator; CFG=fmcu; BUILD_ONLY=0
while [ $# -gt 0 ]; do
  case $1 in
    -s) SIM=$2; shift 2;;
    -c) CFG=$2; shift 2;;
    --build) BUILD_ONLY=1; shift;;
    *) break;;
  esac
done
base=${CFG%%_rb*}; rb=16384
case $CFG in *_rb*) rb=${CFG##*_rb};; esac
case $base in
  mcu)     P="FAST=0";;
  fmcu)    P="FAST=1";;
  wmcu)    P="FAST=2";;
  rbox)    P="FAST=0 RASTER_OUT=1 ROWBUF_BYTES=$rb";;
  frbox)   P="FAST=1 RASTER_OUT=1 ROWBUF_BYTES=$rb";;
  rfancy)  P="FAST=0 RASTER_OUT=1 FANCY_UPSAMPLE=1 CC_TURBO=1 ROWBUF_BYTES=$rb";;
  frfancy) P="FAST=1 RASTER_OUT=1 FANCY_UPSAMPLE=1 CC_TURBO=1 ROWBUF_BYTES=$rb";;
  ep2c5)   P="FAST=0 RASTER_OUT=1 FANCY_UPSAMPLE=1 CC_TURBO=1 ROWBUF_BYTES=9216";;
  noyrgb)  P="FAST=0 RASTER_OUT=1 FANCY_UPSAMPLE=1 CC_TURBO=1 ROWBUF_BYTES=9216 RGB_OUT=0";;
  *) echo "unknown configuration $CFG" >&2; exit 2;;
esac
RTL=$(grep -v '^//' "$RTLDIR/files.f" | sed "s|^|$RTLDIR/|")
TB="$HERE/jpeg_checker.sv $HERE/tb_jpeg.sv"     # the testbench and its interface assertions
B=$HERE/build/${SIM}_$CFG
stale() {   # rebuild when a source is newer than the last build
  [ ! -f "$B/stamp" ] && return 0
  for f in $RTL $TB; do [ "$f" -nt "$B/stamp" ] && return 0; done
  return 1
}
if stale; then
  rm -rf "$B"; mkdir -p "$B"
  case $SIM in
    verilator)
      G=""; for p in $P; do G="$G -G$p"; done
      verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -O2 --x-assign fast --x-initial fast \
        --top-module tb_jpeg $G -Mdir "$B" $RTL $TB -o Vtb > "$B/build.log" 2>&1 \
        || { tail -30 "$B/build.log"; exit 1; };;
    xsim)
      G=""; for p in $P; do G="$G -generic_top $p"; done
      ( cd "$B" && xvlog -sv $RTL $TB > build.log 2>&1 && \
        xelab tb_jpeg $G -timescale 1ns/1ps -s tb_snap >> build.log 2>&1 ) || { tail -30 "$B/build.log"; exit 1; };;
    icarus)
      G=""; for p in $P; do G="$G -Ptb_jpeg.$p"; done
      iverilog -g2012 -s tb_jpeg $G -o "$B/tb.vvp" $RTL $TB > "$B/build.log" 2>&1 \
        || { tail -30 "$B/build.log"; exit 1; };;
    questa)
      G=""; for p in $P; do G="$G -g$p"; done
      ( cd "$B" && vlib work > build.log 2>&1 && vlog -sv $RTL $TB >> build.log 2>&1 ) \
        || { tail -30 "$B/build.log"; exit 1; }
      echo "$G" > "$B/generics";;
    *) echo "unknown simulator $SIM" >&2; exit 2;;
  esac
  touch "$B/stamp"
fi
[ $BUILD_ONLY = 1 ] && exit 0
if [ "$SIM" = xsim ] || [ "$SIM" = questa ]; then     # they run inside the build folder: absolute paths
  n=$#
  for a in "$@"; do
    case $a in
      +JPEG=*|+OUT=*|+GOLDEN=*) a="${a%%=*}=$(realpath -m "${a#*=}")";;
      +FILES=*|+GOLDENS=*)
        k=${a%%=*}; rest=${a#*=}; v=""
        while [ -n "$rest" ]; do
          p=${rest%%,*}; [ "$p" = "$rest" ] && rest="" || rest=${rest#*,}
          [ "$p" = - ] && v="$v,-" || v="$v,$(realpath -m "$p")"
        done
        a="$k=${v#,}";;
    esac
    set -- "$@" "$a"
  done
  shift $n
fi
case $SIM in
  verilator) exec "$B/Vtb" "$@";;
  xsim)      A=""; for a in "$@"; do A="$A -testplusarg ${a#+}"; done
             cd "$B" && exec xsim tb_snap -R $A;;
  icarus)    exec vvp -n "$B/tb.vvp" "$@";;
  questa)    cd "$B" && exec vsim -c $(cat generics) tb_jpeg -do "run -all; quit -f" "$@";;
esac
