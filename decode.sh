#!/bin/sh
# decode.sh - decode JPEG files with BEP-JPEG's RTL in simulation (the SystemVerilog testbench
# tb/tb_jpeg.sv, run by tb/sim.sh) and report the decode time in clocks.  Needs a simulator
# (Verilator 5.002 or later by default); no Python.
#
#   ./decode.sh [options] [file.jpg ...]           (default: every .jpg/.jpeg in test_images/)
#     --profile libjpeg   pixels identical to libjpeg 9e `djpeg -dct int -nosmooth` (default; MCU-order
#                         output, any image size)
#     --profile pillow    pixels identical to Pillow / OpenCV / libjpeg-turbo (raster output with fancy
#                         upsampling; the row buffer is sized for the widest image)
#     --core single|wide|small  the decoder core (the FAST parameter; in hardware a build-time choice):
#                         single  FAST=1, one pixel per clock, ~1-2.4 clocks/pixel (default)
#                         wide    FAST=2, four pixels per clock, ~0.25-0.56 clocks/pixel on photos
#                                 (MCU order, so --profile libjpeg only)
#                         small   FAST=0, the compact core, ~13.6 clocks/pixel
#     --fmt rgb|ycbcr|y   output format (default rgb)
#     --sim SIM           verilator (default) or xsim (Vivado); icarus 12+ / questa untested
#     --out DIR           output folder (default out/): <name>.ppm (.pgm for y); <name>.png too when
#                         ImageMagick's `convert` is installed
#     --mhz F             also report the decode time at this clock (default 100)
#     --check             compare with djpeg: libjpeg-turbo's (the usual system djpeg) for
#                         --profile pillow; libjpeg 9e's for --profile libjpeg (--djpeg PATH)
#     --djpeg PATH        the djpeg to compare with
# Other ways to run the decoder: scripts/decode.py (Python), tb/Makefile (C++ Verilator harness).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
PROFILE=libjpeg; CORE=single; FMT=rgb; SIM=verilator; OUT=$HERE/out; MHZ=100; CHECK=0; DJPEG=djpeg
while [ $# -gt 0 ]; do
  case $1 in
    --profile) PROFILE=$2; shift 2;;
    --core) CORE=$2; shift 2;;
    --fmt) FMT=$2; shift 2;;
    --sim) SIM=$2; shift 2;;
    --out) OUT=$2; shift 2;;
    --mhz) MHZ=$2; shift 2;;
    --check) CHECK=1; shift;;
    --djpeg) DJPEG=$2; shift 2;;
    -h|--help) sed -n '2,21p' "$0"; exit 0;;
    -*) echo "unknown option $1 (see --help)" >&2; exit 2;;
    *) break;;
  esac
done
if [ $# -eq 0 ]; then
  set -- $(ls "$HERE"/test_images/*.jpg "$HERE"/test_images/*.jpeg "$HERE"/test_images/*.JPG 2>/dev/null)
  [ $# -eq 0 ] && { echo "no JPEG files given and none in test_images/" >&2; exit 2; }
fi
mkdir -p "$OUT"
if [ $CHECK = 1 ] && [ "$PROFILE" = libjpeg ] && $DJPEG -version 2>&1 | grep -qi turbo; then
  echo "note: $DJPEG is libjpeg-turbo, whose -nosmooth colour conversion differs slightly from libjpeg 9e;"
  echo "      the libjpeg profile is checked against libjpeg 9e only (--djpeg PATH), or use --profile pillow"
  CHECK=0
fi

# width, height and sampling of a JPEG (first SOFn; APPn segments such as EXIF are skipped by length)
sof_info() {
  od -An -v -tu1 -w1 -N 1048576 "$1" | awk '
    { b[n++] = $1 }
    END {
      i = 2
      while (i + 3 < n && b[i] == 255) {
        m = b[i+1]
        if (m == 216 || m == 1 || (m >= 208 && m <= 215)) { i += 2; continue }
        L = b[i+2] * 256 + b[i+3]
        if (m >= 192 && m <= 207 && m != 196 && m != 200 && m != 204) {
          h = b[i+5] * 256 + b[i+6]; w = b[i+7] * 256 + b[i+8]; nf = b[i+9]
          hs = int(b[i+11] / 16); vs = b[i+11] % 16
          if (nf == 1) t = "grey"; else if (hs == 1 && vs == 1) t = "4:4:4"; else if (hs == 2 && vs == 1) t = "4:2:2"
          else if (hs == 2 && vs == 2) t = "4:2:0"; else if (hs == 1 && vs == 2) t = "4:4:0"; else t = hs "x" vs
          if (m != 192) t = "SOF" (m - 192) "," t
          print w, h, t; exit
        }
        if (m == 218) break
        i += 2 + L
      }
      print 0, 0, "?"
    }'
}

# build configuration
case $CORE in
  single|wide|small) ;;
  fast) echo "--core fast is now called --core single" >&2; exit 2;;
  *) echo "--core single, wide or small" >&2; exit 2;;
esac
F=""; [ "$CORE" = single ] && F=f
case $PROFILE in
  libjpeg) CFG=${F}mcu; [ "$CORE" = wide ] && CFG=wmcu;;
  pillow)
    [ "$CORE" = wide ] && { echo "the wide core (FAST=2) has MCU-order output only: use --profile libjpeg" >&2; exit 2; }
    maxw=0
    for f in "$@"; do w=$(sof_info "$f" | cut -d' ' -f1); [ "$w" -gt "$maxw" ] && maxw=$w; done
    need=$(( (maxw + 15) / 16 * 560 )); rb=16384                  # 560 bytes per 16 px: the worst case
    while [ $rb -lt $need ]; do rb=$((rb * 2)); done
    CFG=${F}rfancy_rb$rb;;
  *) echo "--profile libjpeg or pillow" >&2; exit 2;;
esac
echo "building the $CFG simulation with $SIM (first use only) ..."
"$HERE/tb/sim.sh" -s "$SIM" -c "$CFG" --build

ERRS="SOF_TYPE PRECISION DQT DHT NCOMP SAMPLING SCAN HUFF MARKER SYNC WIDTH FRAME TRUNC"
printf "%-32s %11s %8s %12s %7s %10s  %s\n" file size type clocks clk/px "ms@${MHZ}MHz" result
bad=0
for f in "$@"; do
  name=$(basename "$f"); base=${name%.*}
  set -- $(sof_info "$f"); w=$1; h=$2; kind=$3
  ext=ppm; [ "$FMT" = y ] && ext=pgm
  outp="$OUT/$base.$ext"; gold=""; note=""
  if [ $CHECK = 1 ]; then
    gold="$OUT/$base.ref.$ext"
    if [ "$FMT" = ycbcr ]; then note="; no check (djpeg has no YCbCr output)"; gold=""
    elif [ "$PROFILE" = pillow ]; then
      $DJPEG -dct int $( [ "$FMT" = y ] && echo -grayscale ) -pnm -outfile "$gold" "$f" 2>/dev/null || gold=""
    else
      $DJPEG -dct int -nosmooth $( [ "$FMT" = y ] && echo -grayscale ) -pnm -outfile "$gold" "$f" 2>/dev/null || gold=""
    fi
    [ -n "$gold" ] && [ ! -s "$gold" ] && gold=""
  fi
  log=$("$HERE/tb/sim.sh" -s "$SIM" -c "$CFG" +JPEG="$f" +OUT="$outp" +FMT="$FMT" +QUIET ${gold:+"+GOLDEN=$gold"} 2>&1 || true)
  line=$(echo "$log" | grep "cycles=" | head -1)
  cyc=$(echo "$line" | sed -n 's/.*cycles=\([0-9]*\).*/\1/p'); err=$(echo "$line" | sed -n 's/.*err=0x\([0-9a-f]*\).*/\1/p')
  [ -z "$cyc" ] && { echo "$name: simulation failed"; echo "$log" | tail -5; bad=1; continue; }
  if [ "$err" = 0000 ]; then res=ok
  else
    res="err"; e=$((0x$err)); k=0
    for n in $ERRS; do [ $(( (e >> k) & 1 )) = 1 ] && res="$res $n"; k=$((k + 1)); done
    bad=1
  fi
  if [ -n "$gold" ]; then
    if echo "$log" | grep -q "PASS: output matches"; then
      [ "$PROFILE" = pillow ] && res="$res; identical to libjpeg-turbo/Pillow" || res="$res; identical to libjpeg 9e"
    else res="$res; DIFFERS from $DJPEG"; bad=1; fi
    rm -f "$gold"
  elif [ $CHECK = 1 ] && [ -z "$note" ]; then note="; no check (djpeg failed)"; fi
  if [ "$err" = 0000 ] && command -v convert >/dev/null 2>&1; then convert "$outp" "$OUT/$base.png" 2>/dev/null || true; fi
  px=$((w * h)); [ $px -eq 0 ] && px=1
  printf "%-32s %11s %8s %12s %7s %10s  %s\n" "$name" "${w}x$h" "$kind" "$cyc" \
    "$(awk -v c="$cyc" -v p="$px" 'BEGIN{printf "%.3f", c/p}')" \
    "$(awk -v c="$cyc" -v m="$MHZ" 'BEGIN{printf "%.2f", c/(m*1000)}')" "$res$note"
done
echo "outputs in $OUT"
exit $bad
