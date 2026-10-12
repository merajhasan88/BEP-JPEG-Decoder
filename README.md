# BEBCL-JPEG Decoder

**B**it-**E**xact, **B**ackwards-**C**ompatible, **L**east clocks-per-pixel **JPEG** decoder: a streaming
baseline JPEG decoder for FPGAs, in SystemVerilog. JPEG bytes in, pixels out, with no processor and
no frame buffer. It decodes baseline JPEG (ITU-T T.81 sequential DCT, Huffman coding, 8-bit
samples), which is what cameras, phones and almost all software write.

- **Bit-exact**: its pixels are identical to libjpeg 9e, or (one build option) to Pillow, OpenCV
  and libjpeg-turbo, on every test file and photo - for the supported formats (baseline 8-bit, grey /
  YCbCr / RGB, the libjpeg islow IDCT; see below); anything else is flagged in `err`.
- **Backwards-compatible**: plain SystemVerilog in the subset that Quartus II 13.0sp1 accepts, with
  no vendor primitives (RAMs and multipliers are inferred). The same RTL runs on a 2004 Intel/Altera
  Cyclone II (EP2C5, 4,608 logic elements) and a current Xilinx Artix-7, and builds with Quartus,
  Vivado and Yosys (Lattice ECP5).
- **Least clocks per pixel** among the open-source FPGA JPEG decoders measured (below): 1.0-2.4
  clocks per pixel for the fast core, 0.25-0.56 on phone photos for the wide core (`FAST=2`, up to four
  pixels per output beat; how many per clock it reaches depends on the image, see "Performance by image"
  in BENCHMARKS.md), which on an Artix-7 at 150 MHz decodes a 12-megapixel photo faster than any CPU
  decoder on one laptop core.

Every build option is verified **bit for bit** against a reference decoder:

| profile (build options) | pixels identical to |
|---|---|
| default | libjpeg 9e `djpeg -dct int -nosmooth` |
| `RASTER_OUT=1 FANCY_UPSAMPLE=1 CC_TURBO=1` | **Pillow, OpenCV** and libjpeg-turbo `djpeg -dct int` (libjpeg-turbo 2.1 defaults) |

Three cores share one interface: a compact core (`FAST=0`, option `--core small`, ~13.6 clocks per
pixel, the smallest), a pipelined core that outputs one pixel per clock (`FAST=1`, `--core single`;
called the fast core in this README, **1.0-2.4 clocks per pixel**) and, for larger FPGAs, a wide core
(`FAST=2`, `--core wide`, **0.25-0.56 clocks per pixel** on phone photos, four pixels per output beat,
MCU order).

| measured on a board | core | clock | resources | 12-megapixel photo |
|---|---|---:|---|---:|
| Intel/Altera Cyclone II EP2C5T144C8 (2004, 4,608 LEs) | `FAST=1` | 95 MHz | 4,481 LEs (97 %), 26/26 multipliers | 202-284 ms |
| Xilinx Artix-7 XC7A200T (Acorn CLE-215+, remote board at fpgas.online) | `FAST=1` | 150 MHz | 2,488 LUTs, 17 DSP48E1, 7.5 BRAM | 87-154 ms |
| the same Artix-7 board | `FAST=2` | 150 MHz | 6,211 LUTs, 33 DSP48E1, 9 BRAM | **22-49 ms** |
| the same board, 15 decoders at once | 15 x `FAST=2` | 150 MHz (-3 grade) | 91,949 LUTs, 495 DSP48E1, 135 BRAM | **15 photos in 40 ms** (adapter.jpg) |

How it compares with the two other open-source FPGA JPEG decoders and with CPU decoders: below and
in **[BENCHMARKS.md](BENCHMARKS.md)** (Artix-7 details: `boards/acorn_cle215/README.md`).

## What sets it apart

Compared with the two other open-source FPGA JPEG decoders that could be measured, ultraembedded
core_jpeg and H. Ishihara's aq_djpeg (same harness, same board, same files):

- **Bit-exact.** BEBCL-JPEG's pixels are identical to libjpeg 9e, or with `RASTER_OUT=1
  FANCY_UPSAMPLE=1 CC_TURBO=1` to Pillow, OpenCV and libjpeg-turbo. Those of core_jpeg and
  aq_djpeg differ from libjpeg's by up to 4-14 levels on the photos (PSNR 41.6-46.8 dB) and by up
  to 32 on one small test file.
- **Fewest clocks per pixel.** 0.25-0.56 for the wide core on the photos and 1.0-2.4 for the fast
  core, against 1.4-5.0 (aq_djpeg) and 2.1-3.3
  (core_jpeg, on the files it can decode). On the same Artix-7 board the others needed 1.4-2.1x
  more clocks per photo, and BEBCL-JPEG has the highest Fmax of the three (160 MHz against 153
  and 95-104 MHz), so it decoded every photo fastest: 87-154 ms at 150 MHz, against 119-295 ms
  (aq_djpeg, 150 MHz) and about 301 ms (core_jpeg, 92.3 MHz, 4:2:0 copies only).
- **Small enough for a 2004 FPGA.** The fast decoder fits the 4,608-LE Cyclone II EP2C5 with its 26
  multipliers and runs at 95 MHz; on the larger EP2C35 the others need 7.8k-9.5k LEs and 34-64
  multiplier elements. On the Artix-7 it is 2,204 LUTs alone and 2,488 with the measurement
  harness, against 4,919 (aq_djpeg) and 6,681 (core_jpeg) with the same harness.
- **Handles real camera files.** Every baseline chroma layout (4:4:4, 4:2:2, 4:2:0, 4:4:0, mixed),
  restart markers, EXIF thumbnails skipped correctly. core_jpeg supports neither 4:2:2 nor restart
  markers, and on phone photos with an EXIF thumbnail it read the thumbnail instead of the photo.
- **Defined behaviour on bad input.** Headers and tables are validated; every image ends with
  exactly one "frame done" and an error code, also when the file is truncated or corrupt (26
  malformed files, tested in simulation and on the board).
- **Output for real pipelines.** MCU order, or strict raster order with start-of-frame /
  end-of-line flags for an AXI4-Stream video path; RGB, YCbCr or luma-only output (luma-only skips
  the chroma blocks and is ~30 % faster); the colour converter can be removed.
- **Three cores, one interface.** A compact core (3.4k LEs, ~13.6 clocks/pixel), a fast core
  (~1-2.4 clocks/pixel, fits the EP2C5) and a wide core (~6k LUTs, 0.25-0.56 clocks/pixel), chosen
  with one parameter.
- **Verified in depth.** Two independent testbenches (C++ and SystemVerilog) run the same 3,060
  checks (bit-exact pixels, files back to back, malformed files); gate-level simulation of the
  placed design; Verilator and Vivado's simulator; hardware from two vendors.

Where the others are ahead: aq_djpeg uses fewer block RAMs (4 against 7.5 tiles) and DSP blocks
(14 against 17), and its README says it can extract the first layer of a progressive JPEG (not
tested here), which BEBCL-JPEG rejects; core_jpeg has a smaller build with fixed Huffman tables.
"Least clocks per pixel" holds among open-source decoders: commercial cores claim more, e.g. CAST's
JPEG-DX-F decodes 2 to 32 colour samples per clock depending on its configuration, where
BEBCL-JPEG's fast core decodes 1.1-1.7 on the photos and its wide core 3.6-6.8 (a 4:2:2 pixel is 2
samples, a 4:2:0 pixel 1.5).

**Against CPU decoders** (one laptop core, CPU times rescaled to a steady 3.9 GHz, the laptop's best
case; [BENCHMARKS.md](BENCHMARKS.md)): libjpeg-turbo -nosmooth (the same pixels) decodes a single
photo 2.2-3.2x faster than the `FAST=1` core at 150 MHz, but the `FAST=2` core at 150 MHz takes
0.64-0.80x libjpeg-turbo's time and 0.64-0.88x that of the fastest CPU decoder on each photo, measured
on the board. This is single-image time on one CPU core; a multi-core CPU decoding several photos at
once still has more throughput than one decoder. Fifteen wide decoders on the same board decoded at
the same time with pixels identical to libjpeg 9e; from their clock counts (each lane's decode time
with an ideal input: the gated clocks leave out the waits for the UART; a real system must feed all
15 lanes at full speed, about 1.3 GB/s of JPEG in and 14.5 GB/s of RGB out for adapter-sized photos)
that is 372 photos/s on adapter.jpg (4.83 Gpixel/s; the 15 lanes decoded copies of one file sent
once), 20.7x one laptop core. On the 24 photo files the batch does 408 photos/s (a schedule of the
24 single-file times on 15 lanes, longest first: 371.5 in file order, 470.8 with ideal balance), against 74.5 photos/s measured on the laptop's whole CPU (i7-8550U, 4 cores / 8 threads,
libjpeg-turbo -nosmooth; it holds 2.35 GHz on all cores at its ~18 W limit): 5.5x the whole laptop
CPU, and 3.3x even if every core held 3.9 GHz. Estimate only: about half of a 16-core CPU whose
cores are each a hypothetical core 2.04x the laptop's (the libjpeg-turbo tjbench ratio of a Core Ultra 9 285K to the i7-8550U on OpenBenchmarking, 359 vs 176 Mpixel/s; not measured on these files). That build meets
150 MHz for the board's -3 speed grade; on -2, the grade of the other rows, it reaches 141.5 MHz
([boards/acorn_cle215](boards/acorn_cle215/README.md)).

## Quick start: decode your own images

Put your JPEGs in `test_images/` (`adapter.jpg` is already there) and pick one of three ways to
run the decoder. All three simulate the same RTL cycle by cycle, write the decoded images to
`out/` and print the decode time in clocks:

| way | needs | decode `test_images/` | compare with a reference decoder |
|---|---|---|---|
| **SystemVerilog testbench + shell** (`tb/tb_jpeg.sv`) | Verilator 5.002+ or Vivado's xsim (both tested); Questa and Icarus 12 untested (Icarus 11 is too old) | `./decode.sh` | `./decode.sh --profile pillow --check` (needs `djpeg`) |
| **C++ harness** (`tb/tb_jpeg.cpp`, Verilator) | Verilator 5, make, a C++ compiler | `make -C tb decode` | `tb/obj_fmcu/Vjpeg_decoder in.jpg out.ppm --golden ref.ppm` |
| **Python** (`scripts/decode.py`, drives the C++ harness) | the above + Python 3 (Pillow optional) | `python3 scripts/decode.py` | `python3 scripts/decode.py --profile pillow --check` |

```sh
git clone https://github.com/merajhasan88/BEBCL-JPEG-Decoder.git && cd BEBCL-JPEG-Decoder
cp ~/photos/*.jpg test_images/
./decode.sh                                   # or: ./decode.sh --sim xsim   (Vivado's simulator)
```
```
file                                    size     type       clocks  clk/px  ms@100MHz  result
adapter.jpg                        3120x4160    4:2:2     19234181   1.482     192.34  ok
```

Options of `decode.sh` and `decode.py`:

- `--core single|wide|small`: which core decodes. It sets the `FAST` parameter of
  `rtl/jpeg_decoder.sv`; in hardware that is a build-time choice (the cores are different circuits),
  here it picks the simulation build that runs.

  | `--core` | core | `FAST` | pixels per clock | `--profile` | size (measured builds) |
  |---|---|---|---|---|---|
  | `single` (default) | pipelined (fast) core | 1 | at most 1; 1.0-2.4 clocks per pixel | `libjpeg`, `pillow` | 4,410-4,481 LEs on the Cyclone II EP2C5 |
  | `wide` | wide core | 2 | at most 4; 0.25-0.56 clocks per pixel on phone photos | `libjpeg` (MCU order only) | ~5,800 LUTs and 33 DSPs on an Artix-7; too big for the EP2C5 |
  | `small` | compact core | 0 (the RTL default) | ~13.6 clocks per pixel | `libjpeg`, `pillow` | 3,469-4,587 LEs on the EP2C5 |

  The test scripts (`tb/run_tests.py --configs`, `tb/sim.sh -c`) name their builds after the core:
  `fmcu`, `frbox`, `frfancy` = single; `wmcu` = wide; `mcu`, `rbox`, `rfancy`, `ep2c5`, `noyrgb` = small.
- `--profile libjpeg|pillow`: which reference the pixels match: libjpeg 9e with replicated chroma,
  any image size; or Pillow / OpenCV / libjpeg-turbo with smoothed chroma, raster order.
- `--fmt rgb|ycbcr|y`, `--mhz F` (report times at your clock), `--out DIR`.

A file the decoder does not support (progressive, 12-bit, arithmetic coding ...) is reported with
its error bits.

## Using BEBCL-JPEG in your FPGA design

Add the files of `rtl/` to your project (Quartus, Vivado, Yosys, ...; `rtl/files.f` lists them in
compile order), instantiate `jpeg_decoder` and set the parameters below. `boards/` has complete examples:
`boards/ep2c5/` (Quartus II 13.0sp1, Cyclone II: ROM demo with UART output, a 95 MHz build that
streams JPEGs over the USB-Blaster) and `boards/acorn_cle215/` (Vivado, Artix-7: files over a
UART, with the decoder's clock counted on the chip).

```
bytes in ─► jpeg_parser ─► table RAMs (DQT, Huffman MAXCODE/VALPTR, HUFFVAL)
               │
               └─ un-stuffed entropy bytes + marker tokens
                        ▼
                  jpeg_bitreader ─► jpeg_coefdec ─► jpeg_blockram (64x16 coefficients)
                  (1 bit / clock)   (Huffman, RECEIVE/EXTEND,          │
                                     DC prediction, xQk, zig-zag)      ▼
                                                              jpeg_idct (libjpeg islow, bit-exact)
                                                                       │
              RASTER_OUT = 0 ──────────────────────────────────────────┼─────────────── RASTER_OUT = 1
              MCU buffer (1 KB) ◄──────────────────────────────────────┴──► MCU-row buffer (ROWBUF_BYTES)
              jpeg_pixgen: replication, YCbCr->RGB                           jpeg_raster: replication or libjpeg-turbo
              pixels in MCU order (8x8 / 16x16 tiles)                        triangle filter, YCbCr->RGB; pixels row by row
                                                                       ▼
                     pixels out: (x, y, c0, c1, c2, sof, eol) with a valid/ready handshake
```
(the compact core; the `FAST=1` core has the same structure with a 32-bit bit window, lookahead
Huffman tables, a 2-lane pipelined IDCT and 1-pixel-per-clock output stages; the `FAST=2` core
decodes one Huffman symbol per clock, transforms a block in 8 clocks with two pipelined 1-D IDCTs
and emits up to four pixels per output beat (at most one beat per clock), in MCU order.)

### Interface (`rtl/jpeg_decoder.sv`)

| port | dir | meaning |
|---|---|---|
| `clk`, `rst` | in | one clock; synchronous active-high reset |
| `in_valid`, `in_data[7:0]`, `in_ready` | in | the JPEG file, one byte per accepted clock (files may follow back to back) |
| `in_last` | in | 1 on the last byte of a file (0 if unknown): a file cut short before its EOI still ends with `frame_done` and `ERR_TRUNC` |
| `out_fmt[1:0]` | in | `FMT_RGB` (0), `FMT_YCBCR` (1), `FMT_Y` (2); sampled when a frame starts |
| `px_valid`, `px_ready` | out/in | pixel handshake (AXI4-Stream style: a beat moves when both are high) |
| `px_x`, `px_y` | out | coordinates of the beat's first pixel |
| `px_n[2:0]` | out | pixels in the beat: always 1 for `FAST=0/1`; for `FAST=2` 4, fewer only where the beat reaches the right edge of the image |
| `px_c0`, `px_c1`, `px_c2` `[8*NPIX-1:0]` | out | R,G,B / Y,Cb,Cr / Y,128,128 (grey images in RGB: Y,Y,Y); pixel i of the beat (at `px_x + i`) in bits 8i+7..8i, `NPIX` = 1 (`FAST=0/1`) or 4 (`FAST=2`) |
| `px_sof`, `px_eol` | out | the beat starts the frame (0,0) / holds the last pixel of an image row (x = W-1) |
| `img_w`, `img_h`, `frame_start`, `frame_done` | out | frame size (valid from `frame_start`), end of frame |
| `err[12:0]` | out | errors of the current image (`rtl/jpeg_pkg.sv`): unsupported frame type, invalid/missing/incomplete tables or headers, corrupt data, truncated file, row buffer too small ... |

`FMT_YCBCR` hands out the upsampled Y, Cb, Cr without colour conversion; `FMT_Y` hands out luma
only, and chroma blocks are then only entropy-decoded (to keep the bitstream in step) but never
transformed, which makes decoding ~30 % faster. With `RASTER_OUT=1` pixels arrive in strict
raster order, so `px_sof`/`px_eol` map directly onto AXI4-Stream video `tuser`/`tlast`.

**Completion contract.** Every image that reaches its scan (SOS) produces exactly one
`frame_start` and one `frame_done`, also when it is unusable. Read `err` at `frame_done`: it
holds that image's errors (it is cleared when the next image's SOI is accepted; the input is held
at that SOI until the previous frame is done). If `err` is not zero, discard the frame's pixels.
`frame_done` comes at the image's EOI: segments after the scan (a COM, for example) are consumed
first, a file that ends without its EOI (`in_last`) ends with `ERR_TRUNC`, and a second scan after a
decoded one is `ERR_SCAN` (since 2026-10-10; before, the frame could end with the last pixel, ahead
of a trailing segment, without the error of a missing EOI).
An image with a header or table error produces no pixels at all. The parser only uses a table
that was read completely and legally, and only one that the image or an earlier one defined:
DQT (Pq = 0, Tq <= 3, no zero Qk), DHT (Tc/Th <= 1, a code tree that is not over-subscribed and
has no all-ones code, DC symbols <= 11), SOF0 (length, distinct Ci, Tq <= 3, non-zero width and
height - DNL is not supported), SOS (length, the frame's components in frame order as T.81 B.2.3
requires, defined tables), and RSTn in sequence. With `in_last` on the last byte, a truncated file
raises `ERR_TRUNC` and the decoder completes the frame from zero bits - its pixels are not meant to
be used (libjpeg fills the rest of such a scan with uniform grey instead, so they differ); a file
cut inside its headers gives a frame without pixels. With `in_last` tied to 0 a truncated file
leaves the decoder waiting for more bytes: reset it to abort. A file without any scan (tables
only, or no SOI) produces no frame.

### Parameters

| parameter | default | effect |
|---|---|---|
| `FAST` | 0 | 0: compact core (~13.6 clocks/pixel, smallest). 1: pipelined core, **~1-2.4 clocks/pixel** (Huffman lookahead tables, 2-lane pipelined IDCT, 1 pixel/clock output); same pixels, same interface. 2: wide core for larger FPGAs (Artix-7 class), **0.25-0.55 clocks/pixel** on phone photos (one Huffman symbol per clock, IDCT in 8 clocks per block, 4 pixels per beat), MCU order only (`RASTER_OUT=0`), same pixels |
| `NPIX` | derived | pixels per beat, 4 for `FAST=2` and 1 otherwise; set by `FAST` (other values stop the elaboration) |
| `RASTER_OUT` | 0 | 0: pixels in MCU order, 1 KB buffer, any width. 1: raster order via an MCU-row buffer |
| `ROWBUF_BYTES` | 16384 | row-buffer size for `RASTER_OUT=1`; images whose MCU row does not fit set `err[ERR_WIDTH]` and produce no pixels (the file is still consumed) |
| `FANCY_UPSAMPLE` | 0 | libjpeg-turbo's triangle-filter chroma upsampling (Pillow/OpenCV default) instead of replication; needs `RASTER_OUT=1` |
| `CC_TURBO` | 0 | YCbCr->RGB constants of libjpeg-turbo (`FIX(0.34414)`=22554) instead of libjpeg 9 (22553); differs for 59 of 65,536 (Cb,Cr) pairs |
| `RGB_OUT` | 1 | 0 removes the colour converter (~280 LEs) for YCbCr/luma consumers; `FMT_RGB` then delivers YCbCr |
| `CHECKS` | 1 | header and table validation (above); 0 saves ~100 LEs on a device where every LE counts |
| `ROWBUF_Y_BYTES`, `ROWBUF_C_BYTES` | 0 | `FAST=1` with `RASTER_OUT=1`: separate luma / chroma row buffers (0 = derived from `ROWBUF_BYTES`) |

Row-buffer bytes needed per 16 pixels of image width (`FMT_Y` stores luma only):

| sampling | replication | with `FANCY_UPSAMPLE` | `FMT_Y` |
|---|---:|---:|---:|
| grey | 128 | 128 | 128 |
| 4:2:2 | 256 | 256 | 128 |
| 4:2:0 | 384 | 416 | 256 |
| 4:4:4 | 384 | 384 | 128 |
| 4:4:0 | 512 | 560 | 256 |

Tool notes: the RTL is the SystemVerilog-2005 subset that Quartus II 13.0sp1 accepts (the oldest
tool it targets), so newer tools take it unchanged. RAMs are written to infer block RAM
(`rtl/jpeg_sdp_ram.sv`); `(* ramstyle = "M4K" *)` and `(* multstyle = "dsp" *)` are Quartus hints
that other tools ignore.

### Resources

| device, tool | build | logic | memory | multipliers | Fmax |
|---|---|---:|---:|---:|---:|
| Cyclone II EP2C5, Quartus 13.0sp1 | compact, MCU order (`boards/ep2c5/fpga`) | 3,469 LEs | 9 M4K | 26 9-bit | 59.7 MHz |
| Cyclone II EP2C5, Quartus 13.0sp1 | compact, raster + Pillow smoothing + RGB (`fpga_raster`) | 4,587 LEs | 25 M4K | 26 9-bit | 60.5 MHz |
| Cyclone II EP2C5, Quartus 13.0sp1 | fast, MCU order (`fpga_jtag`, board harness included) | 4,481 LEs | 59,712 bits | 26 9-bit | 99.2 MHz |
| Artix-7 XC7A200T-2, Vivado 2026.1 | fast, MCU order, decoder alone (from the build below) | 2,204 LUTs, 2,124 FFs | 13 BRAM18 | 17 DSP48E1 | - |
| Artix-7 XC7A200T-2, Vivado 2026.1 | fast, MCU order (`boards/acorn_cle215`, UART harness included) | 2,488 LUTs, 2,671 FFs | 7.5 BRAM36 | 17 DSP48E1 | 157-160 MHz |

The fast raster core (`FAST=1 RASTER_OUT=1`) needs ~6,900 LEs on a Cyclone IV E (EP4CE10).
More EP2C5 builds and their timing: `boards/ep2c5/README.md`.

## What is supported

Baseline sequential DCT (SOF0), 8-bit samples, Huffman coding, 1 or 3 components, sampling
factors 1 or 2 in each direction (4:4:4, 4:2:2, 4:4:0, 4:2:0, and luma-subsampled layouts), one
interleaved scan (components in frame order, T.81 B.2.3), restart intervals (DRI/RSTn), any
number of APPn/COM segments (EXIF thumbnails are skipped correctly), several tables per DQT/DHT
segment, image sizes up to 65535x65535 (MCU order; raster order up to the row-buffer width).
Not supported, flagged in `err`, and the scan is skipped to its EOI: progressive, lossless,
arithmetic coding, 12-bit samples, 16-bit quantisation tables, non-interleaved multi-scan files,
sampling factors 3/4, 4-component (CMYK) files, libjpeg 9's big-gamut colour spaces and its LSE
colour transform (`ERR_SOF_TYPE`). RGB-coded files (libjpeg 9e's rule: component ids 'R','G','B', or
an Adobe APP14 with transform 0 and neither JFIF nor the ids 1,2,3) are passed through without colour
conversion, RGB output only (YCbCr or Y output of such a file is `ERR_SOF_TYPE`). Headers are
checked as T.81 requires (since 2026-10-10 also: segment lengths, the 4-byte DRI, distinct component
ids, the baseline AC symbol domain). Dequantised coefficients and the IDCT workspace are 16-bit (saturating); real images
from 8-bit sources stay far inside that, so all test files match exactly. The limits themselves are tested
(`tb/make_arith.py`, `tb/run_arith_tests.py`): 17 synthetic files written straight from quantised coefficients -
AC +-1023 at every zig-zag position with the largest Q that stays inside the limits (and that Q + 1), every DC
value from -1024 to 1023, a DC predictor past 16 bits, dense blocks of +-1023 with Q = 1, 8 and 255, chroma
extremes in 4:2:0. Inside the limits the decoder equals libjpeg 9e exactly; beyond them it saturates exactly as
`model/jpeg_golden.py` does, the same in all three cores (918 runs: 9 configurations x 3 formats x 2 stall
settings). Two of the files hold all 256 sign corners of both IDCT passes; every intermediate value is linear
in a pass's inputs, so no file can overflow the IDCT's datapath.

## Verification

```sh
tb/run_tests.sh                       # SystemVerilog testbench: 1,926 + 234 + 900 runs (-s xsim for Vivado's simulator)
cd tb && make && make test            # the same runs with the C++ harness, driven by Python
python3 ../scripts/compare_refs.py corpus/*.jpg   # the model against Pillow / OpenCV / libjpeg-turbo
```
Both regressions compare against the reference images in `tb/golden/` (made by the Python model,
`model/jpeg_golden.py`); `tb/run_tests.sh` takes its expectations from `tb/expected.txt`,
`tb/stream_scenarios.txt` and `tb/malformed/cases.txt` (written by `tb/export_expectations.py`).

- **Test files** (`tb/corpus/`, 37 files): generated by `scripts/make_corpus.py` from one photo,
  `test_images/adapter.jpg` (settings of every file in `tb/corpus/SOURCES.md`): every chroma
  layout, sizes from 1x1 to 1160 px wide, restart intervals, an EXIF APP1 embedding a whole JPEG,
  strips at the row-buffer limits, dense q90-q98 images with Huffman codes up to 16 bits, an
  RGB-coded file (Adobe transform 0), a 5,000-byte comment between the scan and the EOI, and two
  unsupported files.
- **Reference model** (`model/jpeg_golden.py`): a bit-exact Python decoder in both profiles; on
  every corpus file it is identical to Pillow, OpenCV and libjpeg-turbo `djpeg` (default,
  `-nosmooth`, `-grayscale`) and to Pillow's YCbCr/luma draft modes (`scripts/compare_refs.py`).
- **RTL regression** (`tb/run_tests.py`): 9 build configurations (5 compact, 3 `FAST=1`, 1 `FAST=2`)
  x 3 output formats x 35 files x {no stalls, 30 % random input stalls + output back-pressure}, plus
  the 2 unsupported files = **1,926 runs, all bit-exact, with no unexpected error bit**, with
  strict raster order and `sof`/`eol` checked and `ERR_WIDTH` raised exactly where predicted; every
  run also fails if `frame_done` comes before the image's EOI (or, without one, its last byte).
- **Images back to back without reset** (`tb/run_stream_tests.py`): 13 scenarios = 234 runs, among
  them malformed files each followed by a valid image (its own error, the next frame exact).
- **Two independent testbenches**: the C++ harness (`make test`) and the SystemVerilog testbench
  (`tb/run_tests.sh`) run the same 3,060 checks (1,926 + 234 + 900) and both pass all of them on
  Verilator (2026-10-10); on Vivado's
  xsim the SystemVerilog testbench passed a 396-run subset of the compact and fast cores (MCU and
  raster output, smoothing, malformed files) and 264 runs of the wide and fast cores (2026-10-04), and
  on the RTL with the review's fixes all 510 runs of the wide, fast and compact cores in MCU order
  without stalls (321 + 39 + 150, 2026-10-10, `tb/regression_xsim_2026-10-10.txt`). xsim's stricter
  4-state semantics found problems that Verilator, Quartus and the hardware never showed: a loop
  counter shared by several `always` blocks, a signal used in a port connection before its
  declaration, and unreset valid bits in the wide core's IDCT pipeline (all fixed); and an xsim bug
  (`tab[idx[k]]` inside a procedural loop read as `tab[k]`) that the wide core's output stage now
  avoids.
- **Malformed and truncated files** (`tb/make_malformed.py`, `tb/run_malformed_tests.py`): 50
  files, each one edit away from a corpus file (bad, missing or incomplete DQT/DHT/SOF/SOS, RSTn
  errors, files cut in the headers, in the scan, before the EOI and inside a comment after the scan,
  impossible segment lengths, DRI lengths other than 4, repeated component ids, AC symbols outside
  the baseline domain, libjpeg 9 colour transforms) x 9 configurations x 2 stall settings =
  **900 runs**: each must end with `frame_done`, the expected error bit and, for header
  errors, no pixels.
- **Systematic truncation** (`tb/run_trunc_tests.py`, 2026-10-10): three corpus files (restart
  intervals, an EXIF thumbnail, grey) cut at 230 points - every segment boundary, after each marker
  and length field, mid-payload, around the scan's restart markers, before and inside the EOI - each
  followed by a valid image in the same decoder without a reset, x 9 configurations x 2 stall settings =
  **4,140 runs**: a cut file of 3 bytes or more ends with its own frame and ERR_TRUNC, a 1-2 byte cut
  (no frame header) starts no frame, the next image is exact, nothing hangs. The same script streams
  each of the 50 malformed files followed by a valid image (**900 runs**): its own error bits, the next
  image exact.
- **Colour converter**: exhaustive over all 2^24 (Y,Cb,Cr) inputs for both constant sets.
- **On hardware**: on the EP2C5 every test photo decodes with libjpeg's checksum and exactly the
  simulated clock count (`boards/ep2c5/fpga_jtag`; re-run 2026-10-10 with the review fixes: the 12 photos
  with the same clocks and checksums as before, the new RGB, comment-tail and malformed files as
  expected, `bench/board_jtag_95mhz_2026-10-10.txt`); on the Artix-7 (fpgas.online) the owner's 12
  phone photos and 4:2:0 re-encodes of them decode identically to libjpeg 9e
  (`boards/acorn_cle215`). The boards report a clock count and a pixel checksum (a sum over the
  pixels of `{(x^y)[7:0], R, G, B}`): it binds the pixel count but not each colour to its position;
  the pixel-by-pixel evidence is the simulation of the same files, whose clock counts the boards
  reproduce exactly.
- **Portability**: `sv2v` + Yosys synthesize the compact and the fast raster + smoothing
  configurations for Xilinx 7-series and Lattice ECP5 and the fast MCU-order core for Xilinx
  7-series without errors; Verilator lint is clean with implicit-net warnings enabled.

## Repository layout

| path | what |
|------|------|
| `rtl/` | the decoder (vendor-neutral; `files.f` lists the files in compile order): `jpeg_decoder.sv` (top, selects the core), `jpeg_dec_small.sv` (compact core), `jpeg_dec_fast.sv` + `jpeg_bitwin.sv`, `jpeg_huffdec.sv`, `jpeg_idct_fast.sv`, `jpeg_mcuout.sv`, `jpeg_raster_fast.sv` (fast core), `jpeg_parser.sv` (Annex B markers, Annex C tables), `jpeg_bitreader.sv`, `jpeg_coefdec.sv` (F.2.2 decoding), `jpeg_idct.sv` (libjpeg islow), `jpeg_pixgen.sv`, `jpeg_raster.sv` (output stages), `jpeg_ycc2rgb.sv`, `jpeg_blockram.sv`, `jpeg_sdp_ram.sv`, `jpeg_pkg.sv` |
| `test_images/` | your JPEGs; `adapter.jpg` is the photo the test files are made from |
| `decode.sh` | decode your images with the SystemVerilog testbench (shell, any simulator) |
| `scripts/` | `decode.py` (decode your images, Python), `make_corpus.py`, `compare_refs.py`, `jpeg_to_hex.py`, `pnm_checksum.py` |
| `model/jpeg_golden.py` | bit-exact reference decoder: `--profile djpeg9|pillow`, `--out rgb|ycbcr|y`, block dumps |
| `tb/` | testbenches: `tb_jpeg.sv` (SystemVerilog, any simulator; `sim.sh`, `run_tests.sh`) and `tb_jpeg.cpp`, `tb_multi.cpp` (C++, Verilator; `Makefile`, Python regression scripts); test files `corpus/`, `malformed/`; reference images `golden/` |
| `boards/ep2c5/` | Intel/Altera Cyclone II EP2C5 board: tops (`rtl/`), Quartus projects, programming and host scripts, board-level simulations |
| `boards/acorn_cle215/` | Xilinx Artix-7 (Acorn CLE-215+): Vivado build, UART measurement harness, host script, results |
| `bench/` | benchmarks against CPU decoders and other FPGA decoders; results in `BENCHMARKS.md` |
| `LICENSE`, `NOTICE.md` | Apache License 2.0; copyright and the credits that travel with the code |

## History

BEBCL-JPEG grew out of Meraj Hasan's 2022 JPEG decoder in SystemVerilog, a simulation model written
from the ITU-T T.81 standard (marker parsing, quantisation and Huffman tables); those first
commits are kept in this repository's history (tag `original-2023`). The synthesizable decoder,
its tests and the board builds were developed from 2026 on; the full development history,
including the timing-closure work on the EP2C5, is on the `BEBCL-JPEG-development` branch.

## Acknowledgements

- [fpgas.online](https://fpgas.online) (Welland site) for public remote access to the SQRL Acorn
  CLE-215+ (Artix-7 XC7A200T) board on which the three decoders were compared.
- The Independent JPEG Group (libjpeg) and the libjpeg-turbo project: the decoder's IDCT, colour
  conversion and upsampling arithmetic follow their code, and their decoders are the references.
- ultraembedded (core_jpeg) and Hidemi Ishihara (aq_djpeg), whose open-source decoders made the
  comparison possible; their code is not part of BEBCL-JPEG.
- Verilator, Icarus Verilog, Yosys, sv2v and openFPGALoader, used to simulate, synthesize and load it.

## License

Copyright 2026 Meraj Hasan. Licensed under the Apache License, Version 2.0 (`LICENSE`); see
`NOTICE.md` for the credits that must travel with the code, including the Independent JPEG Group
credit for the IDCT, colour-conversion and upsampling arithmetic.
