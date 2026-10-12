# WIDE core (FAST=2): plan, decisions and resume notes

Owner's decision (2026-10-04): "Model first then wide RTL. Afterwards, some other time we take up
multi-decoder." The question behind it: today's fast core needs 1.0-1.8 clocks per pixel, so one
laptop core with libjpeg-turbo -nosmooth at 3.9 GHz decodes a 12 MP photo 2.2-3.2x faster than the
core at 150 MHz on the Artix-7; can a wider core doing several pixels per clock beat it?

This file is the hand-over note for that work, in the style of FAST_STATUS.md.

## 1. The model (done, `model/perf/`)

`model/perf/blockstats.c` + `perf_model.py`: a clock-level model of today's fast core, driven by the
per-block Huffman statistics of real files; it reproduces the 24 photos measured on the Artix-7
within 1.14 % (mean 0.28 %) and cycle-exact simulations within 0.61 % (details and tables:
`model/perf/README.md`). Variants on the owner's 12 photos and their 4:2:0 copies, MCU order:

| configuration | clocks/pixel, 4:2:2 photos | 4:2:0 copies | ms at 150 MHz | x libjpeg-turbo -nosmooth (3.9 GHz) | x fastest CPU decoder (3.9 GHz) |
|---|---:|---:|---:|---:|---:|
| today's fast core | 1.18-1.76 | 1.00-1.36 | 87-152 | 2.22-3.17 | 2.23-3.46 |
| W2: 1 symbol/clock, IDCT 16 clocks/block, 2 pixels/clock | 0.54-0.61 | 0.50-0.52 | 44-52 | 0.78-1.59 | 0.78-1.73 |
| **W4: 1 symbol/clock, IDCT 8 clocks/block, 4 pixels/clock** | **0.31-0.52** | **0.25-0.40** | **22-45** | **0.63-0.80** | **0.63-0.90** |

CPU times at a steady 3.9 GHz (each run's cycles / 3.9 GHz; the laptop throttled to 2.3-3.9 GHz), the
like-for-like reference being libjpeg-turbo -nosmooth. W4 matches libjpeg-turbo on every photo from
120 MHz and the fastest CPU decoder (libjpeg-turbo or FFmpeg) from 135 MHz; W2 would need 238 / 259 MHz.
W4 is the target. (First version: raw throttled times of turbo's default mode, "106 MHz" - corrected
2026-10-04 after the owner questioned the comparison.)

Sizing of W4 (model, 1-byte/clock input, all 24 files; worst case = busiest photo):

| choice | effect |
|---|---|
| lookahead table 8 / 9 / 10 bits | 0.55 / 0.54 / 0.53 clocks/pixel worst case: **8 bits** (the parser already builds these tables) |
| codes longer than the table: today's search (L-1 clocks) / L-6 / 3 / 2 clocks | worst 0.63 / 0.56 / 0.55 / 0.54: **<= 3 clocks** (parallel MAXCODE compare) |
| clocks between blocks in the Huffman decoder: 0 / 1 / 3 | worst 0.51 / 0.54 / 0.60: **<= 1** (needs the next block's descriptor queued: sequencer change) |
| coefficient slots 4 / 8 / 16 | no difference: **4**, cleared at once by valid-bit masks (no zeroer) |
| MCU buffers 2 / 3 / 4 | within 4 %: **3** |
| IDCT 16 clocks/block | worst 0.62: the IDCT must do **8 clocks per block** (two 1-D cores, 1 column + 1 row per clock) |
| 2 pixels/clock output | 0.53-0.60: the output must do **4 pixels per clock** |
| input 1 byte/clock vs 4 | ~4 %: symbols average ~5 bits, so **the 8-bit input stays** |

Side finding for today's core: on 4:2:2 photos its slot zeroer (2 coefficients per clock, paused by
every coefficient write) is the bottleneck, not the Huffman decoder; valid-bit masks would make the
smooth 4:2:2 photos ~9 % faster, but cost ~300 LEs the EP2C5 does not have.

## 2. Decisions

- A new core behind the same wrapper: `jpeg_decoder #(.FAST(2))`, MCU order only (RASTER_OUT=1 with
  FAST=2 is not supported yet), `NPIX = 4` pixels per output beat. FAST=0 and FAST=1 and every
  EP2C5 build stay as they are.
- Interface: `jpeg_decoder` gets parameter `NPIX` (1 for FAST=0/1); `px_c0/px_c1/px_c2` become
  `[8*NPIX-1:0]` (pixel i in bits 8i+7..8i), `px_x` is the x of pixel 0, new output `px_n` = number of
  valid pixels in the beat (1..NPIX; fewer only at the right edge of the image). With NPIX = 1 the
  ports are unchanged apart from `px_n` (always 1). The input stays one byte per clock.
- Arithmetic copied from the bit-exact modules (jpeg_idct_fast for the IDCT, jpeg_mcuout for colour
  conversion and formats, jpeg_huffdec for EXTEND / prediction / dequantisation / saturation): the
  goldens stay the same.
- Contracts copied deliberately (they are what the malformed and stream suites check): zero fill of the
  bit window after the end of data and after `in_last` (as jpeg_bitwin), ERR_HUFF exactly as F.2.2 in
  jpeg_huffdec (no code within 16 bits, run past k = 63, ZRL past k = 47), `frame_done` exactly once
  per frame, `out_fmt = Y` still decodes chroma but does not transform it, restart handling, CHECKS.
- Target platform: Artix-7 class (the Acorn CLE-215+ at fpgas.online Welland); the core is still
  vendor-neutral SystemVerilog in the project's Quartus-13 subset.

## 3. Work order (each step bit-exact under the regression, and checked against the model)

0. Timing probe: the 1-symbol/clock loop alone (64-bit window, next 8 bits, async 1024 x 12 table,
   L + S, bit count, refill) in Vivado out of context at 150 MHz. Decides whether the parser must
   precompute L + S and whether 150 MHz is realistic.
1. Interface + wide output: `NPIX`, `px_n`, `jpeg_mcuout_wide` (4 pixels/clock, 3 MCU buffers) on top of
   today's entropy decoder and IDCT; every instantiation updated (list below); C++ and SV testbenches
   and `tb_multi.cpp` take NPIX-pixel beats; regression config `wmcu`. Model oracle: px_clk=4, halves=3.
2. `jpeg_idct_wide`: 8 clocks per block, 4 slots with valid masks, two 1-D cores, register transpose.
   Model oracle: + period=1, zero_rate=0.
3. `jpeg_huffdec_wide` + sequencer: 1 symbol/clock, next block's descriptor queued (<= 1 clock between
   blocks), long codes <= 3 clocks. Model oracle: full W4.
4. Clock counts of the photos in simulation vs the model; Vivado build of the Acorn harness with the
   wide DUT (checksum folds `px_n` pixels per beat; `pi_bench.py` pixel count); board-level sim; run at
   Welland; BENCHMARKS / README.
5. Because the wrapper changes: all EP2C5 builds re-fitted (`boards/ep2c5/compile_all.sh`, LE counts
   expected unchanged), the three gate-level runs, full regression (1616 / 80 / 416 + the new config),
   xsim subset.

Instantiations of `jpeg_decoder` (2026-10-04): `boards/ep2c5/rtl/fpga_top.sv`, `boards/ep2c5/rtl/jtag_stream_core.sv`,
`boards/acorn_cle215/uart_bench_core.sv`, `bench/others/quartus/cmp_wrap.sv`, `tb/tb_jpeg.sv`; Verilator harnesses with
`jpeg_decoder` as top: `tb/tb_jpeg.cpp`, `tb/tb_multi.cpp` (and `boards/ep2c5/sim/tb_fpga.cpp` through fpga_top). With
NPIX = 1 the pixel ports keep their widths and the new output `px_n` may stay unconnected (named connections: no
implicit net), so the RTL tops need no change; the harnesses get NPIX-pixel beats (C++: `-DNPIX=4` from the Makefile
config; SV testbench: parameter derived from FAST); the Acorn harness folds `px_n` pixels per beat for FAST=2.

## 4. Progress log

- 2026-10-04: model built and validated, W4 chosen, sizing done (sections 1-2).
- Timing probe 1 (scratchpad `probe/hufloop_probe.sv`, Vivado 2026.1 out of context, xc7a200t-2, 150 MHz):
  the loop as in jpeg_huffdec but in one clock - LSB-aligned 64-bit window, 80-bit shifter to the next 8
  bits, one 1024 x 12 asynchronous table, L + S adder, bit count, `have` compare - **fails by 3.05 ns**:
  9.67 ns, 12 logic levels, 77 % routing (wcnt fan-out 61, table address fan-out 98) = ~103 MHz.
  Probe 2: MSB-aligned window (table address = top 8 bits, no shifter before the table), n = L + S stored
  in the table, four 256-entry tables selected late by {AC, Th}, refill merge and `have` from registers only:
  **meets 150 MHz** (+0.095 ns: 6.53 ns, 7 logic levels, 80 % routing; 993 LUTs of which 416 as memory,
  160 flip-flops). Both probes and the Tcl script: `model/perf/probes/` (`vivado -mode batch -source probe.tcl`).
  Decision: the wide Huffman decoder uses probe 2's structure. The parser stays unchanged: the decoder
  keeps its own copy of the lookahead tables and derives {n = L + S, EOB} when an entry is written.
- **Step 1 done**: `rtl/jpeg_dec_wide.sv` (input side of jpeg_dec_fast in MCU order, three MCU buffers),
  `rtl/jpeg_mcuout_wide.sv` (4 pixels per beat), wrapper `FAST` now `int` with `NPIX`/`px_n`, testbenches
  (`tb_jpeg.cpp`, `tb_multi.cpp` with `-DNPIX=4`; `tb_jpeg.sv`), regression config `wmcu` (in every default
  list: C++ regression **1818/1818, 90/90, 468/468** = 9 configurations, log `tb/regression_2026-10-04c.txt`;
  SV testbench on `wmcu` 202/202, 10/10, 52/52). Clock counts vs the model (px_clk=4, halves=3): traced crop
  +0.02 %, flat images +0.00-0.01 %, crops -0.12 to -0.61 % (the same residual as today's core). Flat 4:2:0
  1.011 -> 0.780 clocks/pixel (now the IDCT's 0.75 limits it); photos unchanged, as the model said.
- **Step 2 done**: `rtl/jpeg_idct1d.sv` (one 8-point 1-D IDCT per clock, the arithmetic of jpeg_idct_fast,
  five registers), `rtl/jpeg_idct_wide.sv` (8 row banks + valid masks, 3 workspace buffers - 2 would limit it
  to ~11 clocks/block because of the 15-clock pass-1 latency - 64-bit sample words, 8 clocks per block);
  MCU buffer of jpeg_dec_wide in 64-bit words. Bit-exact on the first build: wmcu 202/202, 10/10, 52/52 with
  both testbenches. The model got the measured latencies (`IDCT_WIDE` in perf_model.py: pass 2 >= pass 1
  + 15, workspace free 9 clocks after pass 2 starts, last row written 14 after): traced crop +0.03 %, flat
  images +0.01 %, crops -0.20 to -0.75 %. Clocks/pixel: flat 4:4:4 1.553 -> 0.569, 4:2:2 1.038 -> 0.381,
  4:2:0 0.780 -> 0.288; photo crops 1.19 -> 0.85 (smooth) and 1.67 -> 1.67 (busy): jpeg_huffdec's
  3 clocks per symbol now limits.
- **Step 3 done**: `rtl/jpeg_huffdec_wide.sv` (bit window + decoder: probe 2's loop, the contracts of
  jpeg_bitwin / jpeg_huffdec, one symbol per clock, long codes by a parallel MAXCODE compare in 5 clocks,
  copies of the lookahead tables / MAXCODE written from the parser's ports); jpeg_dec_wide queues block
  descriptors (2 entries) instead of starting blocks one at a time and waits for the decoder only at
  restarts and at the end of the scan (the parser's lookahead and MAXCODE RAMs are gone from this core).
  wmcu 202/202, 10/10, 52/52 with both testbenches. One bug found by the stream suite (an image with
  restarts followed by one without): the decoder reset its slot pointer at the end of a frame, the IDCT
  did not, so the next image's blocks were taken in rotated order - fixed (the pointer survives `clear`).
  Model (sym_clk=1, look=8, long codes 5 clocks, no gap between blocks, 4 slots, 3 MCU buffers, 1 byte
  per clock, IDCT_WIDE): traced crop +0.06 %, flat images +0.01 %, crops -0.15 to -0.85 %. Clocks/pixel:
  photo crops 0.275 / 0.382 / 0.523 (today's core 1.19 / 1.39 / 1.67); flat 4:4:4 0.381 (IDCT), 4:2:0 0.260
  (output).
- **Step 4 (in progress)**: the 24 photos in cycle-exact simulation (`python3 model/perf/check_wide.py`,
  results `model/perf/wide_photos_sim_2026-10-04.json`): **all 24 identical to libjpeg 9e** (`djpeg -dct int
  -nosmooth`), 0.29-0.55 clocks/pixel on the owner's 12 photos (4:2:2; the fast core 1.18-1.78) and 0.25-0.41
  on the 4:2:0 copies (1.005-1.37); the model is 0.01-1.59 % low. Against libjpeg-turbo on one laptop core
  (`bench/bench_photos_2026-10-04.json`: 38-66 ms on the photos at a measured 3.5-3.9 GHz, 32-56 ms on the
  copies at 3.0-3.7 GHz). Like for like - every CPU time at a steady 3.9 GHz, libjpeg-turbo -nosmooth -
  the wide core at 150 MHz takes 0.64-0.77x libjpeg-turbo's time on the photos and 0.64-0.80x on the
  copies, and 0.64-0.88x the time of the fastest CPU decoder on each file (FFmpeg on three of them);
  it matches libjpeg-turbo on every file from 120 MHz and the fastest CPU decoder from 131 MHz. (CPU decoders
  re-measured on 2026-10-12, `bench/bench_photos_2026-10-12.json`: 0.63-0.82x libjpeg-turbo's time, 0.64-0.82x
  the fastest CPU decoder's - libjpeg-turbo on every file - and every CPU decoder beaten from 123 MHz.)
  Board harness: DUT 3 = `jpeg_decoder #(.FAST(2))` in `boards/acorn_cle215/uart_bench_core.sv` (checksum
  of up to 4 pixels per beat in a 3-stage pipeline; the clock count stops at frame_done as for DUT 0);
  `build.tcl` reads `rtl/files.f`; `make_expected.py --duts 3` (clocks from tb/obj_wmcu). Harness simulation
  (`sim/obj_dut3`): 4 corpus files, clocks = the decoder simulation, checksums = libjpeg 9e.
  Vivado 2026.1, Artix-7 harness with DUT 3 at 150 MHz (xc7a200t-2 timing):
  - build 1: **-1.465 ns** (~123 MHz), 183 failing endpoints; worst: the long-code path (block state ->
    MAXCODE compare -> offset add -> HUFFVAL RAM address in one clock, 7.6 ns) and the run-length control
    (phase_ac -> table -> k + r -> compares -> k, 7.1 ns). Decoder: 5,748 LUTs (504 as RAM), 6,621 FFs,
    33 DSP48E1, 3 RAMB36 + 10 RAMB18.
  - fixes (commit 9f33f67): MAXCODE entries registered at the miss, compare/select and offset add in
    separate clocks (long codes 6 clocks instead of 5); 63 - k kept in a register so the block-end tests
    are 4-bit compares. wmcu still 202/202, 10/10, 52/52.
  - build 2: **-0.100 ns** (~147.8 MHz), 4 failing endpoints, all in the symbol loop (window top bits ->
    lookahead RAM, address fan-out 81 -> table select -> n, fan-out 70 -> 64-bit shift -> window; 8 levels,
    81 % routing) and one from it to the descriptor queue. Decoder 5,787 LUTs, 6,830 FFs.
  - build 3: the same RTL with `VIVADO_EFFORT=high` (ExtraTimingOpt placement, AggressiveExplore routing and
    physical optimisation): **+0.128 ns at 150 MHz** (~153 MHz). Harness + decoder 6,178 LUTs, 7,607 FFs,
    9 BRAM tiles, 33 DSP48E1; the decoder alone 5,794 LUTs (504 as RAM), 6,863 FFs, 3 RAMB36 + 10 RAMB18.
  - build 4, after the xsim fixes (commit 6846718), `VIVADO_EFFORT=high`: **+0.013 ns** at 150 MHz; harness +
    decoder 6,211 LUTs, 7,575 FFs, 9 BRAM tiles, 33 DSPs; the decoder alone 5,827 LUTs, 6,831 FFs. Board re-run
    (owner: "using fpgas.online again but with fewer pictures"): 3 files (adapter.jpg, IMG20260716020409.jpg,
    adapter_420.jpg; 7.4 MB) with the reworked client (one terminal session, 2-minute polling): **3/3 PASS**,
    clocks and checksums identical to the simulation and to the 24-file run; about 3 minutes on the site.
- **Step 4 done (board, 2026-10-04)**: fpgas.online Welland, the Acorn now at board page `pi-sw2-p46`
  (the site had renamed its pages and upload form; the private client in /root/fpgas_online_tools was
  adapted). **24/24 PASS**: every clock count = the simulation of the final RTL, every checksum = libjpeg
  9e, no error bits (`boards/acorn_cle215/results_2026-10-04.json`). 0.295-0.561 clocks/pixel on the
  owner's photos, 0.255-0.417 on the 4:2:0 copies, 22.0-48.6 ms per 12 MP photo at 150 MHz, 3.0-4.0x
  fewer clocks than the fast core. Against one laptop core at a steady 3.9 GHz: **0.64-0.80x the time of
  libjpeg-turbo -nosmooth (1.24-1.57x faster) and 0.64-0.88x the time of the fastest CPU decoder on each
  photo** - faster than every CPU decoder on every photo. (Single-image time; a multi-core CPU decoding
  several photos at once still has more throughput.) Final RTL photo simulation:
  `model/perf/wide_photos_sim_2026-10-04.json` (24/24 identical, model within 1.6 %).
- Step 5 (in progress): after the wrapper change (FAST int, NPIX, px_n) all 10 EP2C5 builds re-fitted
  and meet timing (`boards/ep2c5/compile_all.log`, 2026-10-04 15:39-16:22): LE counts unchanged except
  fpga_jtag 4,425 (was 4,450; +0.39 ns at 95 MHz, Fmax 98.7 MHz) - Quartus 13 accepts the wrapper's
  untaken FAST=2 branch without the wide files in its project. Gate-level runs of the new netlists
  (`boards/ep2c5/gate_level/verilator/gls_2026-10-04c.txt`): gls, gls_fast, gls_raster PASS with the same
  checksums (0x10137ECE, 0x10137ECE, 0x3C7A89E2). Full regression on the final RTL, 9 configurations:
  C++ testbench **1818/1818, 90/90, 468/468** (`tb/regression_2026-10-04d.txt`), SystemVerilog testbench on
  Verilator the same (`tb/regression_sv_2026-10-04c.txt`).
  **xsim (Vivado 2026.1) found two problems in the wide core that Verilator and the board did not show:**
  1. *frame_done never came* (every wmcu file): jpeg_idct1d's valid pipeline had no reset; in a 4-state
     simulator its X reached the IDCT's busy count (n1 += in - out) in the first clock after reset and
     stayed there. Fix: reset the five valid bits (a real RTL weakness - on hardware they power up 0 on
     Xilinx/Intel, but nothing guaranteed it).
  2. *RGB wrong, YCbCr right* (all colour files): an xsim bug - inside a procedural `for` loop it evaluates
     `tab[idx[k]]` as `tab[k]` (reproduced in a 20-line test in the scratchpad: entries 0,3,6,9 instead
     of 300,303,306,309; explicit statements or a generate loop give the right values). The colour table
     lookups of jpeg_mcuout_wide got entries 0-3. Fix: jpeg_mcuout_wide's per-pixel work moved into a
     generate loop (one process per pixel, constant indexes); same logic. Both rules are now in
     DEVELOPMENT.md. After the fixes: wmcu 202/202, 10/10, 52/52 on Verilator; 4 files x RGB/YCbCr PASS on
     xsim; xsim regression for wmcu + fmcu (quick): **202/202, 10/10, 52/52** (`tb/regression_xsim_2026-10-04b.txt`).
  The board run (24/24) used the RTL before these two fixes; the fixes change no clock count and no
  pixel (Verilator, cycle-exact), and the Vivado build is to be repeated to confirm timing.
