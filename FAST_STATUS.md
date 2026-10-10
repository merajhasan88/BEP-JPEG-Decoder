# FAST decoder: work log and resume notes

Owner's requests (2026-09-24): "Make the decoder faster", then "But it must fit inside EP2C5 and
also be fast as compared to other decoders", then "You can pause at 8 AM. When you do, save your
state thoroughly and record all important milestones to resume later without problem".

This file is the hand-over note: what was built, what is verified, what is in flight, and the
exact commands to continue.  (Scratch builds live in the session scratchpad; everything that
matters is in this repository.)

## 1. What exists now

A second decoder core, selected with `jpeg_decoder #(.FAST(1))`; the original compact core is
untouched (renamed `jpeg_dec_small`, `FAST = 0`, still the default and still bit-identical).

| file | role |
|---|---|
| `rtl/jpeg_decoder.sv` | thin wrapper, parameter `FAST` selects `jpeg_dec_small` / `jpeg_dec_fast`; also `ROWBUF_Y_BYTES`, `ROWBUF_C_BYTES` |
| `rtl/jpeg_dec_small.sv` | the previous `jpeg_decoder` (compact core), unchanged apart from the module name and unused LUT ports |
| `rtl/jpeg_dec_fast.sv` | fast core top: sequencing (entropy side), output side for MCU order (`g_mcu`) and raster order (`g_raster`), raster row-buffer geometry |
| `rtl/jpeg_parser.sv` | new parameter `LUT_EN`: builds 256-entry Huffman lookahead tables (4 tables, 1024 x 12) while DHT is parsed |
| `rtl/jpeg_bitwin.sv` | bit accumulator (libjpeg style: bytes enter at the bottom, next bit = acc[wcnt-1]), 48-bit storage, >= 33 valid bits, zero fill after the end of data |
| `rtl/jpeg_huffdec.sv` | table-driven Huffman/coefficient decoder: 3 clocks per coefficient (LOOK, LW, SYM), slow path for codes > 8 bits, pipeline E1 (magnitude) E2 (EXTEND) E3 (DC prediction) M (x Qk) S (saturate) |
| `rtl/jpeg_idct_fast.sv` | 2-lane pipelined IDCT, 32 clocks per block; 4 coefficient slots with background zeroing; 2 workspace slots; stages P, M, A1, A2, B on a 4-clock period; optional line-buffer copy of row 7 |
| `rtl/jpeg_mcuout.sv` | MCU-order output at 1 pixel/clock from 3 component RAMs (32-bit words), colour conversion in 3 registered stages |
| `rtl/jpeg_raster_fast.sv` | raster-order output at 1 pixel/clock: per-component fetchers + 3-entry column-sum FIFOs, libjpeg-turbo fancy upsampling, CMD_LINES / CMD_DEFER |
| `rtl/jpeg_sdp_ram.sv` | new parameter `OUT_REG` (block-RAM output register, 2-clock read) |
| `rtl/fpga_top.sv` | new parameters `FAST`, `BENCH` (full-speed decode + clock-count report over UART), `PLL_MUL`/`PLL_DIV` (altpll core clock); ROM -> 2-entry skid buffer -> decoder |
| `scripts/uart_bench.py` | PC side of `BENCH=1`: prints clocks, time, Mpixel/s, checks the checksum |
| `tb/tb_jpeg.cpp` | new option `--max-cycles N` |
| `tb/tb_fpga.cpp` | understands the `BENCH` report (checks its checksum against the golden PNM) |
| `tb/Makefile`, `tb/run_tests.py` | configurations `fmcu` (FAST MCU order), `frbox` (FAST raster), `frfancy` (FAST raster + Pillow-exact smoothing); `--configs=a,b` option; fit rule `rowbuf_fits_fast` |
| `bench/bench_fpga.py` | FAST configurations added (`--only FAST` to run just those) |
| `quartus/fpga_fast/` | EP2C5 project: fast core, MCU order, RGB, 64x64 ROM image (same as `quartus/fpga`), `CYCLONEII_OPTIMIZATION_TECHNIQUE AREA` |
| `quartus/fpga_fast_raster/` | Cyclone IV E EP4CE10E22C8 project: fast core, raster + smoothing, 32 KB row buffer (resource/Fmax data point only) |
| `quartus/gls_fast/` | gate-level twin of `fpga_fast` (BAUD 12.5 M, short restart delay) - not compiled yet |
| `quartus/fpga_fast_bench/` | **the speed build**: EP2C5, fast core, `BENCH=1`, PLL 95 MHz, physical synthesis; timing met |
| `quartus/sta_paths.tcl`, `quartus/sta_detail.tcl` | TimeQuest scripts: worst path per register pair / full-path reports |
| `tb/run_board_sim.sh` | board-level simulation of `fpga_top` (Verilator build + run), `FAST` and `BENCH` as arguments |
| `bench/bench_report.py` | per-build device, clock and power (fast EP2C5 build `quartus/fpga_jtag`: 95 MHz, PowerPlay 146.8 mW) |

## 2. Milestones (verified)

1. **Architecture chosen by measurement** (cycle model driven by per-block Huffman statistics of the
   benchmark photos, scratchpad `fast/cyclemodel.py`, since lost; its successor is `model/perf/`): the model reproduced the old design's
   measured 13.5 clocks/pixel within 1 %, predicted ~1.0-1.1 for the new pipeline; measured
   afterwards: 1.01-1.11.
2. **Fast core bit-exact**: full regression, 8 configurations (5 compact + 3 fast) x 3 output
   formats x 29 images x {no stalls, 30 % random stalls}: **1424/1424 with the final RTL**
   (section 5); along the way 1068/1068 (compact + fmcu) and 534/534 (fmcu + frbox + frfancy)
   after every change.  Large photos: donald.jpg,
   the 1084x1024 grey photo and the 700x400 q94 photo decode bit-identically to libjpeg 9e
   `djpeg -dct int -nosmooth` (MCU order) and to Pillow (raster + smoothing).
3. **Speed (clocks per pixel, cycle-exact Verilator)**, before -> after:

   | image | compact core | FAST MCU order | FAST raster + smoothing (double-buffered) |
   |---|---|---|---|
   | donald 2048x1365 4:2:0 | 13.46 | 1.013 | 1.013 |
   | grey 1084x1024 | 9.23 | 1.017 | 1.009 |
   | q94 700x400 | 14.84 | 1.115 | 1.076 |
   | dog 64x64 (incl. header parsing) | 13.7 | 1.40 | 1.67 |

   (Numbers from before the 100 MHz pipelining.  Final RTL, FAST MCU order: donald 1.019, grey
   1.019, q94 1.346, dog 64x64 1.412 - see section 3.)
4. **EP2C5 fit**: fast MCU-order build = 4,492 / 4,608 LEs (97 %), Fmax 55.45 MHz before the
   pipelining work; **final: 4,457 LEs, timing met at 95 MHz** (section 3).  Needed: the
   right-aligned bit accumulator (saved ~250 LEs), pass-1 saturation at the write port, AREA
   optimisation, DSP registers loaded every clock.
5. **Board-level simulation** (ROM -> decoder -> UART -> testbench): fast core passes in pixel
   mode and in BENCH mode (64x64: 5,784 clocks, checksum 0xD49C70EF = golden, LED on).
6. **Fast raster build does not fit the EP2C5**: 6,851 LEs on Cyclone IV (EP4CE10, 61.7 MHz).
   On the EP2C5 the fast core is MCU order; the compact raster builds stay the EP2C5 raster option.

## 3. Timing closure on the EP2C5: done, 95 MHz from the PLL

Owner: "it must fit inside EP2C5 and also be fast as compared to other decoders".  At 50 MHz the
fast core would decode donald.jpg in ~57 ms (simulated clock count) (faster than OpenCV, stb_image, libjpeg 9e; slower than
libjpeg-turbo 35.8, Pillow 42.6, FFmpeg 32.8 ms), so the core runs from the EP2C5's PLL.
(Those CPU figures were measured in the laptop's power-saver profile - see section 7.)

**Result** - project `quartus/fpga_fast_bench` (fast core, MCU order, RGB, `BENCH=1`,
`PLL_MUL=19`, `PLL_DIV=10` -> 95 MHz core clock, `CLK_HZ=95000000`):

| | |
|---|---|
| logic elements | **4,457 / 4,608 (97 %)** |
| memory | 63,808 / 119,808 bits |
| 9-bit multipliers | 26 / 26 (all 13 18x18 blocks) |
| timing (slow model, 85 C) | **met at 95 MHz**: setup slack +0.568 ns, hold +0.499 ns; this placement's Fmax 100.42 MHz |
| PowerPlay (vectorless, low confidence) | 151.4 mW total (118.9 core dynamic, 18.3 static, 14.1 I/O) |
| donald.jpg 2048x1365 | 2,847,577 clocks in cycle-exact simulation = **29.97 ms** at 95 MHz (93 Mpixel/s), bit-identical to libjpeg 9e. Not run on the board: the board builds hold only a 719-byte JPEG in on-chip ROM |

Settings that matter (all in `quartus/fpga_fast_bench/jpeg_fpga.qsf`):
`CYCLONEII_OPTIMIZATION_TECHNIQUE AREA`, `AUTO_PACKED_REGISTERS_STRATIXII "MINIMIZE AREA WITH CHAINS"`,
`PHYSICAL_SYNTHESIS_COMBO_LOGIC ON`, `PHYSICAL_SYNTHESIS_REGISTER_DUPLICATION ON`,
`ROUTER_TIMING_OPTIMIZATION_LEVEL MAXIMUM`; SDC: 50 MHz input + `derive_pll_clocks`.
The .sof is `quartus/fpga_fast_bench/output_files/jpeg_fpga.sof` (not yet run on the board).

How the fit and Fmax evolved (compiles constrained at 100 MHz unless noted):

| step | LEs | Fmax |
|---|---|---|
| fast core as first fitted (50 MHz SDC) | 4,492 | 55.45 MHz |
| + deep pipelining (IDCT stages P/M/A1/A2/B, huffdec 3-clock symbol + E1..S, colour 3 stages, ROM skid buffer) | 4,753-4,859 (did not fit) | - |
| + colour conversion from block-RAM tables (libjpeg's Cr_r/Cr_g/Cb_b/Cb_g) | 4,741 (no) | - |
| + BENCH report without a copy register, tables read in the V stage, 4-bit IDCT tag | 4,674 (no) | - |
| + multiplier operands/products loaded every clock (DSP input AND output registers absorbed; they share one clock enable) | **4,413 (fits)** | 75.95 MHz |
| + long-code search pipelined (hc/hv RAMs with output registers), IDCT gather-time sums, UART byte register | 4,472 | 88.5 MHz |
| + real-bits tracking in bitwin, predictor/EXTEND restructured, y1 without shift mux, parser fill limit register | 4,423 | 88.68 MHz |
| + EXTEND raw/mask split, 2-entry token buffer between parser and bitwin | 4,471 | 94.3 MHz |
| + `(* maxfan = 16 *)` on bitwin's `wcnt` (Quartus duplicates it), IDCT W1 write port registered, `x2s13` summed from registers | 4,439 | 99.24 MHz |
| + registered power-on reset in fpga_top, parser `fl_last` register | 4,437 | 92.89 MHz (placement) |
| + fitter physical synthesis, router timing effort maximum (QSF only) | 4,444 | 96.02 MHz |
| **same RTL and settings, PLL 19/10 = 95 MHz constraint (final)** | **4,457** | **met, +0.568 ns (Fmax 100.42)** |

Why not 100 MHz: one path decides Fmax, `wcnt` -> 6-level bit selector -> M4K address register of
the Huffman lookahead table (`u_lut`).  ~70 % of it is routing, so it moves by +-0.5 ns between
compiles of near-identical RTL (94.3 / 99.2 / 92.9 / 96.0 / 100.4 MHz).  Its partner in the 3-clock
symbol loop (`u_lut` data -> code length -> `wcnt`) has ~0 slack at 100 MHz too, so moving logic
from one side to the other does not help; a structurally shorter loop needs an MSB-aligned bit
buffer (~250 more LEs than the 151 left).  Options if 100 MHz is wanted later: set
`PLL_MUL 2 / PLL_DIV 1 / CLK_HZ 100000000` and try fitter seeds (`set_global_assignment -name SEED n`);
or back-annotate this 95 MHz placement (Fmax 100.42) and recompile with the PLL at 100 MHz.

(An attempt with a registered "room" flag at wcnt <= 24 deadlocked - the window stalled at 25-32
bits while the decoder waits for >= 31; replaced by the token buffer.)

Cycle cost of the pipelining: donald 1.013 -> 1.019 clocks/pixel, grey 1.017 -> 1.019, q94 photo
1.115 -> 1.346 (entropy-bound: 17 % of its codes are > 8 bits and the slow path got 3 clocks
longer), 64x64 dog 1.40 -> 1.41.

## 4. Speed against the other decoders (single image, i7-8550U single thread, see BENCHMARKS.md)

**Superseded (2026-09-30).** The CPU columns below were measured with the laptop in its power-saver
profile (~0.8-1 GHz, not noticed at the time), and FFmpeg without RGB conversion.  At full clock
(performance profile, ~3.9 GHz) libjpeg-turbo decodes donald.jpg in 6.9 ms and every CPU decoder
beats the EP2C5; the conclusion below ("the fastest of all") is withdrawn.  Current numbers:
section 7 and BENCHMARKS.md.

FPGA columns = clock counts from cycle-exact simulation x 95 MHz (projection; the board has run
only the 64x64 image, where it matched the simulated count within one clock).

| image | FAST core, EP2C5 @ 95 MHz | libjpeg-turbo | FFmpeg | Pillow | stb_image | libjpeg 9e |
|---|---|---|---|---|---|---|
| donald 2048x1365 4:2:0 | **29.97 ms** | 35.80 (33.93 nosmooth) | 32.79 | 42.57 | 72.92 | 72.14-108.26 |
| photo 700x400 q94 | **3.97 ms** | 5.18 (5.03) | 5.37 | 5.91 | 10.13 | 9.86-12.98 |
| grey 1084x1024 | 11.90 ms | 11.02 (10.57) | 11.96 | 11.48 | 18.10 | 20.27-20.63 |
| dog 64x64 | **0.061 ms** | 0.077 (0.082) | 0.143 | 0.415 | 0.126 | 0.110-0.172 |

(Withdrawn, see the note above.) The EP2C5 at 95 MHz is the fastest of all on the colour photos and on small images.  On the grey
photo it is level with FFmpeg (11.96) and Pillow (11.48) and 8 % behind libjpeg-turbo (11.02):
1 pixel per clock is the output limit, and a grey pixel is less work for a CPU.

## 5. Verification of the final RTL (2026-09-24, 05:00-07:30)

- Fast configurations after every change: `run_tests.py --configs=fmcu` 178/178 (last run with the
  final RTL), earlier 534/534 for fmcu+frbox+frfancy.
- **Full regression, all 8 configurations with the final RTL: 1424/1424 passed**
  (`tb/regression_final.txt`: mcu, rbox, rfancy, ep2c5, noyrgb, fmcu, frbox, frfancy, 178 runs
  each = 29 images x 3 output formats x {no stalls, 30 % random stalls} + unsupported files).
- Board-level simulation with the final RTL (`tb/run_board_sim.sh`): BENCH mode 64x64 = 5,784
  clocks, checksum 0xD49C70EF = golden, LED on; pixel mode: UART frame = golden, LED on.
- Large photos with the final RTL (obj_fmcu vs libjpeg 9e `djpeg -dct int -nosmooth`):
  donald.jpg, the 700x400 q94 photo and the 1084x1024 grey photo all bit-identical.
- Timing: TimeQuest slow model, 95 MHz, all paths met (setup +0.568 ns, hold +0.499 ns).

Benchmark data with the final RTL (`bench/bench.json`, tables in BENCHMARKS.md, regenerated
2026-09-24 07:33): FAST MCU order (obj_fmcu) and FAST raster + smoothing with the 72 KB + 2 x 20 KB
row buffer (obj_frfancy_pp: donald 1.014, grey 1.009, q94 1.313 clocks/pixel).  The 36 KB + 2 x 10 KB
variant (obj_frfancy_sb, rebuilt 07:39) matches it except where a row no longer double-buffers:
donald 5,275,205 clocks = 1.89 clocks/pixel.  README.md, BENCHMARKS.md and the project CLAUDE.md
describe the fast core.

## 6. On the physical board (2026-09-28)

`quartus/fpga_fast_bench/output_files/jpeg_fpga.sof` loaded over JTAG (USB-Blaster, EP2C5 IDCODE
0x020B10DD) runs at 95 MHz: checksum LED on, heartbeat blinking, and the UART report read with
`python3 scripts/uart_bench.py /dev/ttyUSB0 95 tb/golden/dog_64x64_q25_420.box.rgb.pnm`:
**5,785 clocks = 60.9 us for the 64x64 image, checksum 0xD49C70EF = golden, err 0x000**, repeated
every ~1.5 s (board-level simulation: 5,784).  Serial hookup: FT232R adapter, board pin 41 ->
adapter RX, GND -> GND, 115200 baud.  Lessons: the USB-Blaster fails to enumerate (`error -71`)
behind a USB hub and when plugged in before the board is powered; `brltty` steals CH340 adapters on
Ubuntu (masked on this laptop); one broken Dupont wire cost most of the debugging - check an
adapter with a TX->RX loopback first.

Pixel check (same day): `quartus/fpga_fast/output_files/jpeg_fpga.sof` (50 MHz, streams every
pixel over UART), frame captured with `scripts/uart_capture.py /dev/ttyUSB0 out.ppm`: **4,096 of
4,096 pixels received, all 12,288 values identical to tb/golden/dog_64x64_q25_420.box.rgb.pnm**.
(The Blaster's original USB cable was faulty; the adapter's cable fixed enumeration.)

## 7. 2026-09-30: publishable library, reuse fixes, decode timing over JTAG, other decoders

Triggered by an external review (`../Reviews/jpeg-decoder-review-2026-09-26.md`) and the owner's
requests: fix the licence problem, credit libjpeg, use the owner's own photos, stream over JTAG
with decoding time separated from streaming time, compare other FPGA decoders on the EP2C5.

- **Licence clean-up.** `gls/verilator/cycloneii_atoms_verilator.v` (~97 % Altera text) is gone;
  `gls/verilator/cycloneii_cells.v` has independent models of the 8 cell types the netlists use.
  Both gate-level runs reproduce the earlier results exactly (MCU: 0xD49C70EF; raster: 0x7809898C,
  3,388,467 clocks).  `NOTICE.md` credits the IJG / libjpeg-turbo (the IDCT, colour conversion
  and upsampling arithmetic reproduce theirs; each such file says so), `.gitignore` keeps tool
  outputs out.  The project licence is still to be chosen by the owner (no `LICENSE` yet).
- **Own test corpus.** `scripts/make_corpus.py` generates `tb/corpus/` (35 files, same coverage as
  before plus dense q90-q98 images) from the owner's screen photos and adapter photo; provenance in
  `tb/corpus/SOURCES.md`.  The model matches Pillow / OpenCV / libjpeg-turbo on all of them
  (`compare_refs.py`: ALL IDENTICAL).  The old dog/donald-derived files are in
  `../test_images/legacy_dog_donald/` and `tb/golden_legacy/` (local only).  All board ROM images
  now come from the corpus: MCU builds `adp_64x64_q25_420` (761 B, checksum 269713102), raster
  builds `board_352x32_q6_420` (1,016 B; box RGB 1002394176, fancy RGB 1014663650, fancy YCbCr
  2772707330) - **those Quartus projects still have to be recompiled** (their .sof are stale).
- **Reuse fixes (review P0).** The parser pulses `soi` and clears the restart interval and the
  frame size at every SOI; both cores clear `err` at SOI (the parser is held at the next SOI
  until frame_done, so `err` describes the last frame until then); an unusable image (e.g.
  progressive: several scans) is drained scan by scan up to its EOI and ends with one frame_done.
  `tb_jpeg` now fails on any unexpected error or a missing golden file.  New stream regression:
  `tb/tb_multi.cpp` + `tb/run_stream_tests.py` (5 scenarios x 8 configurations x 2 stall settings).
  **Results: 1616/1616 (run_tests.py) and 80/80 (run_stream_tests.py).**  Still open from the
  review: header/table validation, an end-of-input/abort contract.
- **Full-size photos** (fast core, cycle-exact, bit-identical to libjpeg 9e): donald 2,847,577
  clocks (1.02/px, 30.0 ms at 95 MHz); the owner's 12 MP phone photos 19.3-26.9 M clocks
  (1.61-2.25/px, 203-284 ms: dense, entropy-bound); adapter 3120x4160 4:2:2 19.2 M (1.48/px);
  unnamed 1944x2592 4:4:4 8.39 M (1.67/px).
- **Decode time over JTAG** (`rtl/jtag_stream_core.sv` portable, `rtl/fpga_jtag_top.sv` board top
  with altpll + altclkctrl + sld_virtual_jtag, `quartus/fpga_jtag`, host `scripts/jtag_decode.py` +
  `scripts/jtag_stream.tcl`).  The decoder clock is gated by a glitch-free global clock buffer so
  that it only runs while its next input byte is waiting: the on-chip clock count then equals the
  ideal-input decode time, whatever the JTAG speed.  Simulation (`tb/tb_jtag.cpp`,
  `tb/jtag_sim_top.sv`): identical clock counts to the ideal simulation at JTAG speeds clk/3 to
  clk/20 with random gaps (64x64: 5,780 clocks in every case) and on 6 further corpus files.
  **On the board (2026-09-30, 95 MHz, `bench/board_jtag_95mhz.txt`): all 12 images pass - every
  checksum equals libjpeg 9e's decode, every decoder clock count equals the cycle-exact simulation:**
  64x64 5,780 clocks; 320x240 q90 96,450; **donald.jpg 2,847,577 = 29.97 ms**; 1944x2592 4:4:4
  8,392,001 = 88.3 ms; 3120x4160 4:2:2 19,234,181 = 202.5 ms; the 7 phone photos 4000x3000
  19.3-26.9 M = 203-284 ms.  Streaming over JTAG runs at ~35 KB/s (a 5.9 MB photo takes ~170 s).
  Two hardware lessons: (1) the virtual-JTAG hub shifts 7 header bits into the instance before
  every payload (64-bit control/status scans hide it: the extra bits fall off the end) - data scans
  now start with the sync word 0xA5C3 and `tb/tb_jtag.cpp --hub-bits` models the header;
  (2) the owner's Huawei photos carry ~5 KB after EOI, which raise ERR_SYNC after the frame - the
  harness reports `err` as it was at frame_done.  Build: 4,473 / 4,608 LEs, timing met at 95 MHz
  (+0.221 ns setup, +0.499 ns hold, Fmax 97.0 MHz).  `quartus/fpga_jtag_dbg` = the same at 50 MHz
  without physical synthesis (used for the debugging; `set_parameter DEBUG 1` puts shift/byte
  counters on instruction 2).
- **Other FPGA decoders** (`bench/others/`: fetch.sh pins the sources into `../third_party`, not
  part of this library; `tb_other.cpp` harness, `run_others.py`, Quartus projects in
  `bench/others/quartus`, `report.py`): ultraembedded core_jpeg (Apache-2.0) and H. Ishihara's
  aq_djpeg (MIT, via ultraembedded/legacy_jpeg_decoder).  Neither fits the EP2C5 (core_jpeg 12,851
  LEs, 9,039 with fixed tables; aq_djpeg 8,970); ours in the same wrapper 4,243 LEs, 104.9 MHz.
  On the EP2C35: ours 4,408 LEs / 26 multiplier elements / 103.8 MHz, core_jpeg 9,462 / 64 / 40.4,
  fixed tables 6,971 / 64 / 40.1, aq_djpeg 7,785 / 34 / 60.2.  core_jpeg decodes the EXIF thumbnail
  instead of the photo on all 7 phone photos and mis-decodes unnamed.jpg and the q6 board strip;
  aq_djpeg decodes everything, up to 32 levels from libjpeg (PSNR 42-51 dB), at 1.4-5.0
  clocks/pixel (3.0-3.3x slower than ours on the phone photos).  donald.jpg: ours 30.0 ms,
  aq_djpeg 66.4 ms, core_jpeg 148 ms.  Tables: BENCHMARKS.md (from `bench/others/report.py`).
- **CPU benchmarks corrected.** The laptop runs in the `power-saver` power profile (~0.8-1.1 GHz
  under load); every earlier CPU benchmark (2026-09-23/24 and the first run today) was measured
  like that without anyone noticing, which made the CPU decoders look ~4-5x slower.  Measured with
  the performance profile held (`BENCH_POWER_PROFILE=performance python3 bench/run_bench.py`,
  3.4-3.9 GHz recorded by `perf stat`): donald.jpg libjpeg-turbo 6.9 ms, Pillow 7.9, libjpeg 9e
  14.1 (-nosmooth), stb_image 14.3, OpenCV 16.1, FFmpeg (RGB) 20.0 ms - all faster than the EP2C5's
  30.0 ms; libjpeg-turbo is 3-6x faster than the EP2C5 on every image (phone photos 54-73 ms against
  203-284 ms).  Per clock the FPGA does ~10x more (1.0-2.25 clocks/pixel against 8-22 for
  libjpeg-turbo with AVX2); energy per image ~15-28x lower (PowerPlay estimate against RAPL).  At the
  power-saver clock (~1 GHz) libjpeg-turbo and the EP2C5 are close (CPU 3-47 % faster on 7 images,
  21 % slower on the 64x64).  `bench_powersaver.json` keeps the power-saver runs.  **The claim that
  the EP2C5 beats libjpeg-turbo is withdrawn**; on the EP2C5 this design is near its ceiling (97 % of
  the LEs, all multipliers; limits: 1 pixel/clock out, IDCT 1.5 clocks/pixel for 4:4:4, Huffman 3
  clocks per coefficient).

## 7b. 2026-10-01 00:00-01:20: review P0 validation, end-of-input contract, Yosys fix (PAUSED mid-way)

Done and verified (RTL regression green):
- **Yosys fix**: `rtl/jpeg_raster_fast.sv` byte select is now a constant-base 32-bit word + `case`;
  sv2v v0.0.13 (scratchpad) + Yosys `synth_xilinx` / `synth_ecp5` of FAST=1 RASTER_OUT=1
  FANCY_UPSAMPLE=1 CC_TURBO=1 both succeed (Xilinx ~11.3k LUTs, 4,375 FFs, 6 BRAM, no DSP48
  inferred - look at that when the Xilinx wrapper is built; ECP5 10,854 LUT4, 13 DP16KD).
- **Header/table validation** in `rtl/jpeg_parser.sv` (parameter `CHECKS`, default 1, plumbed through
  jpeg_decoder / both cores / fpga_top / jtag_stream_core / fpga_jtag_top): q_def/h_def table-defined
  flags (tables persist, redefinition invalidates until complete), DQT Tq<=3 / zero Qk / incomplete,
  DHT Tc/Th<=1 (bad id -> S_SKIP, no aliasing), code tree check = libjpeg's (Annex C code + BITS(L)
  must stay < 2^16 at every L - equivalent to code < 2^L, 2 LUTs), DC symbol <= 11, incomplete
  BITS/HUFFVAL; SOF/SOS exact lengths via the existing rem==1 compares; Tqi<=3; SOS repeated
  component (sused) and every used table defined; RSTn modulo-8 sequence. Zero X/Y (and no SOF)
  flagged ERR_FRAME by the cores (they already compared img_w/img_h with 0).
- **err is now 13 bits**: new ERR_FRAME (11), ERR_TRUNC (12); ERR_DQT/ERR_DHT are the new names of
  bits 2/3 (old names kept as aliases). All users updated: fpga_top (BENCH record {cyc,chk,3'd0,err}),
  jtag_stream_core status {A5, frames, 3'd0, err[12:0], ...}, scripts/jtag_stream.tcl (chars 4..7 &
  0x1FFF), tb_jtag.cpp, uart_bench.py, bench/others/quartus/cmp_wrap.sv.
- **End-of-input contract**: new input `in_last` (last byte of a file). Before EOI -> ERR_TRUNC and the
  parser finishes the image: inside entropy data it appends a marker token (S_TR_EOI; data bits
  in_data with bit 3 forced so it is never an RSTn), after a scan only the eoi pulse, in headers an
  error scan (S_TR_SOS) so frame_done still comes. Contract documented in jpeg_decoder.sv header and
  README ("Completion contract"). Parser now resets only control state (data regs written before use).
- jtag_stream_core: holds the head byte until a byte is behind it or eos (registered `nb`, `dec_v`),
  so the file's last byte carries in_last = eos && !nb. tb_jtag: 64x64 5,780 clocks, rst2 3,902,
  truncated files end with frames=1 and ERR_TRUNC at all JTAG speeds.
- Tests: `tb/make_malformed.py` -> `tb/malformed/` (25 cases + cases.json), `tb/run_malformed_tests.py`
  (in `make test`); tb_jpeg: in_last on the last byte (`--no-last`), `--expect-err-mask`, `--no-pixels`;
  tb_multi: in_last at each file end; Makefile target `jtag` (obj_jtag/Vjtag).
  **Full regression before the last small parser edits (reset trim, token bit-3 trick): 1616/1616,
  80/80, 400/400** (tb/regression_2026-09-30.txt). After those edits only fmcu+mcu malformed
  (100/100) were re-run -> **rerun `make test` first when resuming.**

State when paused that night (all resolved on 2026-10-01, see 7c):
- Area: validation costs ~+100 LEs in the parser (compact parser 442 -> 548 LCs). With CHECKS=1 the
  fast builds need 294 LABs (> 288): **do not fit**. `quartus/fpga_jtag` is now set to
  `set_parameter -name CHECKS 0` (+ AUTO_RESOURCE_SHARING ON; register duplication ON as before):
  last compile **fits (4,526 LEs) but misses 95 MHz by -0.012 ns** (path mcuy_m1 -> my in
  jpeg_dec_fast). Next: try SEED 2..4 / back-annotation, or recover LEs. Its .sof is NOT valid yet.
- `quartus/compile_all_boards.sh [projects]` recompiles one after another -> compile_all_boards.log.
  Earlier attempts (with the first, bigger parser, CHECKS=1): fpga_raster 5,278 LEs (no fit),
  fpga_jtag / fpga_fast_bench / fpga_fast 292-298 LABs (no fit). Not yet recompiled with the current
  RTL: fpga_raster, fpga_raster_box, fpga_raster_ycc, fpga, fpga_fast, fpga_fast_bench, gls, gls_raster,
  gls_fast, fpga_fast_raster, core. The compact fpga_raster (had 23 LEs spare) will likely need
  CHECKS=0 and still may not fit - decide with the owner (lean EP2C5 profile vs validation).
- Then: gate-level sim of the fast build (compile quartus/gls_fast, quartus_eda, then
  `gls/verilator/run_verilator_gls.sh ../../quartus/gls_fast jpeg_gls ../../tb/golden/adp_64x64_q25_420.box.rgb.pnm`
  - note gls and gls_fast share the revision name jpeg_gls / obj dir), board sims (tb/run_board_sim.sh),
  board re-run over JTAG, docs (README build table, CLAUDE.md, BENCHMARKS if numbers change).

### 7c. 2026-10-01: ~100 LEs recovered - every EP2C5 build keeps CHECKS=1 (owner's decision)

Owner: "Recover the 100 logic elements elsewhere. Keep checks=1 for larger FPGAs." Done; CHECKS=1 is
used everywhere (fpga_jtag's QSF says so explicitly).  What recovered the area:
- parser: `rem` loaded with the raw length (+2 offset, last byte at rem == 3) - no subtractor;
  BITS(1..8) for the lookahead fill kept in L bits each (`bitsv`, 36 FFs instead of 64; legal
  trees have BITS(L) < 2^L); the code table stores MAXCODE+1 = code + BITS(L) (the adder `csum`
  exists anyway; jpeg_huffdec / jpeg_coefdec compare `code < entry`); last HUFFVAL byte found with
  `cnt + 1 == ntot`; sampling factors stored as "is 2" only; C4 dropped; only control state reset.
- scan components must be listed in frame order (T.81 B.2.3): `scan_ci` is a constant, so the
  component-lookup multiplexers disappear from the parser and both cores (an out-of-order SOS is
  ERR_SCAN; real encoders never write one).
- huffdec: E1's magnitude bits come from the lookahead shifter (`accx[31:16]`).
- board tops: fpga_top's heartbeat LED is the per-frame toggle (no 26-bit counter);
  jtag_stream_core's status word no longer carries img_w (the host never used it).
- timing: fpga_jtag first missed 95 MHz by 0.228 ns on its only failing path, eos_idle -> the
  global clock buffer's enable (half a clock); `run_en` is now one register computed from the next
  values of in_rst / dec_v / eos_idle -> met.

Results (all compiled 2026-10-01 with Quartus 13.0sp1; compile_all_boards.sh / compile_all_boards.log):

| build | LEs before (CHECKS absent) | LEs now (CHECKS=1) | timing |
|---|---:|---:|---|
| fpga_jtag (fast, JTAG, 95 MHz) | 4,473 | **4,455** | met, +0.316 ns setup, +0.499 hold, Fmax 97.9 |
| fpga_fast_bench (fast, ROM, 95 MHz) | 4,457 | **4,368** | met, +0.126 ns, Fmax 96.2 |
| fpga_fast (fast, 50 MHz) | 4,438 | 4,296 | met, Fmax 72.4 |
| gls_fast | - | 4,337 | met at 50 MHz, Fmax 72.9 |
| fpga_raster (compact, smoothing + RGB) | 4,585 | **4,547** | met at 50 MHz, Fmax 59.6 |
| gls_raster | 4,578 | 4,537 | met, Fmax 60.4 |
| fpga_raster_ycc | 4,363 | 4,454 | met, Fmax 59.6 |
| fpga_raster_box | 4,150 | 4,089 | met, Fmax 64.6 |
| fpga / gls (compact, MCU) | 3,431 / 3,497 | 3,374 / 3,375 | met, Fmax 61.3 / 61.4 |
| fpga_fast_raster (EP4CE10) | 6,851 | 7,004 | met at 50 MHz, Fmax 76.0 |

`quartus/core` (bare jpeg_decoder with ~120 I/O pins) cannot fit: the Web Edition ignores
VIRTUAL_PIN ("Virtual IO is only available with a valid subscription license"); use
`bench/others/quartus/cmp_wrap.sv` (4 pins) for core-only numbers.

Verification of this RTL: `make test` 1616/1616, 80/80, 416/416 (26 malformed files incl.
sos_out_of_order); tb_jtag clock counts = direct simulation (5,780 / 3,902 / 45,761 / truncated and
invalid files); gate level: gls_fast (first GLS of the fast core), gls and gls_raster all PASS
(64x64 0x10137ECE, 352x32 fancy 0x3C7A89E2); on the EP2C5 over JTAG (95 MHz,
`bench/board_jtag_95mhz_2026-10-01.txt`): 6 corpus files, donald.jpg and the owner's 9 full-size
photos PASS (libjpeg's checksum) with unchanged clock counts (donald 2,847,577 = 29.974 ms; phone
photos 203-284 ms), and all 26 malformed / truncated files PASS (frame_done + expected err, no
pixels for header errors) - 42 of 42.  Note: a truncated
scan is completed from zero bits, while libjpeg fills the rest of the scan with uniform grey, so
those pixels differ from libjpeg's (they are to be discarded anyway; documented).

## 7d. 2026-10-03/04: the three decoders on a remote Artix-7; BEBCL-JPEG and its layout

- **Remote board** (fpgas.online, Welland pi46: SQRL Acorn CLE-215+, XC7A200T, Raspberry Pi 5 with
  GPIO JTAG and UART; the Chicago site's Arty A7 boards were unreachable from the site itself).
  New `boards/acorn_cle215/`: vendor-neutral `uart_bench_core.sv` (UART in, FIFO, the decoder under
  test, decoder clock gated by a BUFGCE so the count is the ideal-input decode time, checksum,
  stall watchdog), `acorn_top.sv` (IBUFDS, MMCM 1200 MHz VCO, BUFG/BUFGCE), Vivado 2026.1 batch
  build (needs the free annual "Vivado Basic" licence; libtinfo.so.5 from an unpacked libtinfo5
  .deb on LD_LIBRARY_PATH), host script `pi_bench.py`. Same harness for core_jpeg and aq_djpeg.
  Results (`boards/acorn_cle215/README.md`, `results_2026-10-03.json`): this decoder at 150 MHz
  (WNS +0.418 ns, Fmax 160 MHz; 2,488 LUTs, 17 DSP, 7.5 BRAM with the harness) decoded the owner's 12
  photos and 12 4:2:0 re-encodes identically to libjpeg 9e, 1.005-1.78 clocks/pixel, with exactly
  the EP2C5's clock counts; aq_djpeg (153 MHz) all 24 at 1.37-1.95x our clocks; core_jpeg (95-104
  MHz, run at 92.3) none of the 4:2:2 originals (reads the EXIF thumbnail, stalls; watchdog added
  to the harness for this) and all 12 4:2:0 copies at 2.14-2.19 clocks/pixel. Both others matched
  their own simulations exactly on the board.
- **Vivado lint** found two signals used before their declaration (`jpeg_dec_small.sv` skip_idct,
  `jpeg_raster_fast.sv` pbase_r): declarations moved up; Verilator lint with IMPLICIT warnings clean.
- **BEBCL-JPEG** (owner, 2026-10-04): the library is named BEBCL-JPEG; `main` = the library, this tree =
  branch `BEBCL-JPEG-development` (was `claude_jpeg/`). Layout: `rtl/` holds only the decoder; the
  EP2C5 tops, Quartus projects, host scripts and board simulations moved to `boards/ep2c5/`
  (gate-level flows to `boards/ep2c5/gate_level/`); `quartus/` keeps `core` and `fpga_fast_raster`.
  Test files are made from `test_images/adapter.jpg` only (the 14 files made from screen photos were
  regenerated from it, `scr_*` renamed `adp_*`; the 21 adapter files are byte-identical, so the ROM
  images and checksums are unchanged). `scripts/decode.py` decodes `test_images/` (or given files)
  in simulation; `bench/tools.py` downloads/builds libjpeg 9e and stb_image; the comparison decoders
  are fetched into `bench/others/third_party`. `scripts/export_library.py` writes `main`.
- **Re-verified after the restructure (2026-10-04)**: regression 1616/1616, 80/80, 416/416 (new
  corpus); all 10 EP2C5 projects re-fitted from `boards/ep2c5/` and meet timing with unchanged LE
  counts except `fpga_jtag`, 4,449 LEs (was 4,455), +0.424 ns setup, Fmax 98.99 MHz; board
  simulation (`boards/ep2c5/sim/run_board_sim.sh 1 1`) and the JTAG harness simulation pass.
  `scripts/compare_refs.py` on the 33 supported new corpus files: the model is identical to Pillow,
  OpenCV and libjpeg-turbo in every mode. Gate-level runs of `gls`, `gls_fast`, `gls_raster` pass
  (same checksums as on 2026-10-01). A clone of `main` builds, passes the fast-core regression,
  decodes with `scripts/decode.py`, regenerates BENCHMARKS.md identically and downloads/builds
  libjpeg 9e by itself (`bench/tools.py`).

## 7e. 2026-10-04: three ways to run BEBCL-JPEG, EP2C5 re-run, CPU comparison on the photos

- **SystemVerilog testbench** `tb/tb_jpeg.sv` (+ `tb/sim.sh`: Verilator `--binary --timing`, Vivado
  xsim, Icarus, Questa; `decode.sh`; `tb/run_tests.sh`): the same checks, reset, stall generator
  and clock counts as `tb_jpeg.cpp`/`tb_multi.cpp` (verified file by file, stalled runs included).
  Two Verilator 5.003 problems found on the way and avoided: `ref` arguments of functions are not
  reliable (queues passed by reference, the stall generator) - buffers are module-level and the
  generator uses `inout`; queue `==` is not supported - compared element by element. The bash
  regression reads `tb/expected.txt`, `tb/stream_scenarios.txt`, `tb/malformed/cases.txt`
  (written by `tb/export_expectations.py`) and the golden images, now kept in git (`tb/golden/`).
  C++ option without Python: `make -C tb decode`. `rtl/files.f` lists the RTL in compile order.
- **EP2C5 re-run** with the re-fitted `fpga_jtag` (4,449 LEs): 73/73 pass - 35 test files, 26
  malformed files, the owner's 12 photos; clock counts unchanged and equal to the Artix-7's
  (`bench/board_jtag_95mhz_2026-10-04.txt`). `jtag_decode.py` now expects non-baseline files to be
  rejected (ERR_SOF_TYPE, no pixels).
- **CPU comparison** (`bench/bench_photos_2026-10-04.json`, performance profile, the laptop
  throttles to 2.3-3.9 GHz under sustained load): with every CPU time rescaled to a steady 3.9 GHz
  from its cycle count (corrected 2026-10-04; the first report used the raw throttled times),
  libjpeg-turbo -nosmooth 28-62 ms per 12-megapixel photo, BEBCL-JPEG on the Artix-7 87-154 ms
  (2.2-3.2x longer), 8.2-11.7x fewer clocks per pixel. No FPGA decoder beats libjpeg-turbo, FFmpeg or
  Pillow on single-image time; BEBCL-JPEG beats Go on every photo, stb_image on 20 of 24 and libjpeg 9e
  (default upsampling) on 16 of 24.
- **Vivado's xsim found two RTL portability bugs** that Verilator, Quartus and the hardware never
  showed: module-level loop counters written by several `always` blocks (`i` in jpeg_idct_fast,
  `gi` in jpeg_dec_small, `k` in jpeg_raster, `c`/`k` in jpeg_raster_fast - illegal SystemVerilog,
  xsim refuses to elaborate; now block-local), and `.lastrow(~more_y)` in jpeg_dec_small's raster
  instance, a forward reference that strict tools turn into an undriven implicit net (xsim: X in
  `fmode`, wrong pixels for 4:4:0 / 1x2 chroma; the declaration moved up). Icarus Verilog 11 is too
  old for the RTL (internal errors on the fast raster core, wrong pixels from the compact core).
  After the fixes: regression 1616/80/416 with both testbenches on Verilator, a 396-run subset on
  xsim, all 10 EP2C5 builds re-fitted (LE counts unchanged except fpga_jtag 4,450, +0.33 ns), the
  three gate-level runs and the EP2C5 board (62/62, bench/board_jtag_95mhz_2026-10-04b.txt) pass.
- **Git**: remote `origin` = github.com/merajhasan88/BEBCL-JPEG-Decoder (renamed by the owner from
  jpegdecoder-systemverilog on 2026-10-04; main = the owner's 2022-23 work, tag `original-2023`); `main` (BEBCL-JPEG) sits on top of origin/main, so the push is a
  fast-forward. The remote-board client stays out of the repositories (owner's decision).

## 7f. 2026-10-10: the review of 2026-10-10 on the EP2C5

The fixes (README "Completion contract", CLAUDE.md "Since 2026-10-10"): frames end at the image's EOI,
segment-length / DRI / component-id / AC-symbol checks, RGB-coded files by libjpeg 9e's rule. The first
version (7c7e3f2) grew the parser from 633 to 746 LUTs and `fpga_jtag` needed 291 of 288 LABs; the
parser was made smaller with the same behaviour (c68ac30: six 7-bit id compares instead of twelve 8-bit
ones, the APP0/APP14 byte index in `k`, one Adobe flag, one marker dispatch). Re-fit with
`compile_all.sh` (Quartus 13.0sp1):

| build | LEs 2026-10-04 | LEs 2026-10-10 | timing |
|---|---:|---:|---|
| fpga_raster | 4,547 | **4,587** (21 free) | met at 50 MHz, Fmax 60.5 |
| fpga_jtag | 4,425 | **4,481** | met at 95 MHz, +0.448 ns, Fmax 99.2 |
| fpga_fast_bench | 4,368 | 4,420 | met at 95 MHz, +0.547 ns, Fmax 100.2 |
| fpga_fast | 4,296 | 4,433 | met, Fmax 74.3 |
| gls_fast | 4,337 | 4,410 | met, Fmax 75.2 |
| gls_raster | 4,537 | 4,573 | met, Fmax 59.8 |
| fpga_raster_ycc | 4,454 | 4,358 | met, Fmax 58.0 |
| fpga_raster_box | 4,089 | 4,132 | met, Fmax 62.8 |
| fpga / gls | 3,374 / 3,375 | 3,469 / 3,454 | met, Fmax 59.7 / 57.3 |

On the board (`fpga_jtag`, USB-Blaster, `bench/board_jtag_95mhz_2026-10-10.txt`): the 12 photos with
the same clock counts and checksums as on 2026-10-04 (the fixes cost nothing on ordinary files); the new
RGB-coded file and the comment-tail file with libjpeg 9e's checksum; six of the new malformed cases with
their expected error bits (a file ending inside a comment after its scan: ERR_TRUNC with libjpeg's
pixels). The board-tested bitstreams of 2026-10-04 are kept in `boards/ep2c5/*/output_files_2026-10-04/`.
Also re-run on the fixed RTL the same evening: the SystemVerilog testbench on Verilator (`tb/run_tests.sh`),
all 3,060 runs; the wide core on the 24 photo files (`model/perf/check_wide.py`), identical to libjpeg 9e
with the clock counts of 2026-10-04 (`model/perf/wide_photos_sim_2026-10-04.json`), file for file.

## 8. Open items (in order)

1. (done) Board run of `quartus/fpga_jtag`: `quartus_pgm -m jtag -o "p;quartus/fpga_jtag/output_files/jpeg_fpga_jtag.sof"`,
   then `python3 scripts/jtag_decode.py <files>` (needs `$BENCH_SCRATCH/jpeg9e/inst/bin/djpeg`,
   built by bench/run_bench.py).
2. (done 2026-10-01) Recompiled every board build for the corpus ROM images and the new RTL; the
   gate-level runs pass with the new golden files (7c).  `tb/run_board_sim.sh` (RTL board sims) not
   re-run - the gate-level runs of the same tops cover it.
3. (done 2026-10-01) Review P0: header/table validation (CHECKS) and the end-of-input contract
   (in_last, ERR_TRUNC) - sections 7b, 7c.  Remaining review ideas (P2): stall profiling, entropy
   speed-ups, valid/ready assertions, coefficient/workspace bound proofs, an Adobe-RGB policy.
4. (done) CPU benchmarks on the owner's photos, at full clock (section 7).
5. (done 2026-10-01) Portability: the fast raster module now synthesizes with sv2v + Yosys
   (`synth_xilinx`, `synth_ecp5`); gate-level simulation of the fast build (`quartus/gls_fast`) passes.
6. (done 2026-10-03) Licence: Apache-2.0, copyright Meraj Hasan (LICENSE, NOTICE.md).
7. Remote hardware (done for the Artix-7 XC7A200T on 2026-10-03, section 7d; Chicago's Arty A7
   boards - XC7A35T or XC7A100T - still to do when the site is reachable again; review `../Reviews/remote_rentable_fpga_resources_2026-09-30.md`, checked
   2026-09-30): first target fpgas.online Artix-7 (Arty A7-35T: FT2232 JTAG + UART; Acorn
   XC7A200T / LiteFury XC7A100T: Pi GPIO JTAG + UART; no login, SSH/SFTP to the Pi). Needs a Xilinx
   board top (MMCM, BUFGCE clock gate, UART or BSCANE2 input) and a toolchain: Vivado ML Standard
   (free for Artix-7, large install) or openXC7 (Yosys + nextpnr-xilinx). Intel DevCloud (Arria 10)
   in the review is out of date: the service closed on 2024-10-31. ORI Remote Labs is aimed at open
   amateur-radio projects. AWS F2 (~$1.98/h) only with the owner's go-ahead.
   Status 2026-10-01: Vitis/Vivado 2026.1 is installed locally (devices Artix-7, Zynq-7000, Zynq
   UltraScale+ MPSoC, Kintex/Virtex UltraScale, Kintex/Virtex/Artix UltraScale+ incl. HBM;
   `vivado -version` runs; the optional `Vitis/scripts/installLibs.sh` apt step was not run).
   Source its `Vivado/settings64.sh` only inside the command that uses it; never alongside Quartus.
   Next: a Xilinx board top (MMCM, BUFGCE clock gate, UART or BSCANE2 input) for the Arty A7-35T.
   Plan agreed 2026-10-03 (waiting for the owner's go-ahead): use the Chicago site (ps1.fpgas.online,
   Arty A7 boards pi2 pi3 pi5 pi7 pi9 pi11 pi13 pi21 pi23; direct `ssh -p <port> pi@ps1.fpgas.online`,
   public password in the login banner, no key needed) and test one board per distinct FPGA part (owner: different boards, or for the same board type different chip versions; read each board's IDCODE first). Welland needs a key
   (generated: /root/.ssh/fpgas_online_ed25519) and IPv6, which this laptop lacks.
   Scope (owner, 2026-10-03): also run the two competitors (core_jpeg, aq_djpeg; fetched by
   bench/others/fetch.sh, not committed) on every Chicago board, each in the same clock-gated
   UART wrapper at its own Vivado Fmax, with the owner's photos in ../test_images (originals may be
   uploaded; delete everything from each Pi afterwards; one board at a time, be a polite user).

## 9. Commands

```sh
cd claude_jpeg/tb
make && python3 run_tests.py                                # everything, 8 configs (~30 min)
python3 run_tests.py --configs=fmcu,frbox,frfancy          # fast core only (~3 min, 534 runs)
./obj_fmcu/Vjpeg_decoder in.jpg out.pnm --golden golden/<name>.box.rgb.pnm --stall 30
#   (golden files are golden/<image>.<box|fancy>.<rgb|ycbcr|y>.pnm; a missing file = no compare)
./run_board_sim.sh 1 1 /tmp/b1        # board-level sim, fast core, BENCH mode (0 0 = compact, pixels)
cd ../bench && python3 bench_fpga.py bench.json --only FAST && python3 bench_report.py bench.json
export PATH=/root/altera/13.0sp1/quartus/bin:$PATH
cd ../quartus/fpga_fast_bench && nice quartus_sh --flow compile jpeg_fpga   # EP2C5 @ 95 MHz, ~9 min
quartus_sta -t ../sta_paths.tcl       # worst path per (from, to) pair -> sta_paths.txt
quartus_pow jpeg_fpga                 # PowerPlay estimate
```

obj_frfancy_pp / obj_frfancy_sb (benchmark raster builds with big row buffers) are built by hand:
`verilator $(VFLAGS) -GFAST=1 -GRASTER_OUT=1 -GFANCY_UPSAMPLE=1 -GCC_TURBO=1 -GROWBUF_Y_BYTES=73728
-GROWBUF_C_BYTES=20480 -Mdir obj_frfancy_pp ...` (sb: 36864 / 10240), same command line as the
Makefile's pattern rule otherwise.
