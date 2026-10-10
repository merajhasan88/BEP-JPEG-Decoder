# Acorn CLE-215+ (Xilinx Artix-7 XC7A200T): decoders measured over a UART

A board build that runs one JPEG decoder at a time on real hardware and reports its clock count,
a checksum of its pixels and its error bits for each file sent over a UART. It was written for
the remote boards of [fpgas.online](https://fpgas.online) (Welland site: SQRL Acorn CLE-215+ with
an Artix-7 XC7A200T, wired to a Raspberry Pi 5 that loads the FPGA over GPIO JTAG and talks to it
over its UART), and it measures this library's decoder and, for comparison, two other open-source
FPGA JPEG decoders under identical conditions. A second build runs 15 of this library's wide decoders
at the same time (batched mode, see the last section).

| `DUT` | decoder | source |
|---:|---|---|
| 0 | this library, fast core (`jpeg_decoder #(.FAST(1))`, MCU order, RGB) | `../../rtl` |
| 1 | ultraembedded core_jpeg (`jpeg_core`, `SUPPORT_WRITABLE_DHT=1`) | not part of this library: `../../bench/others/fetch.sh` |
| 2 | H. Ishihara's aq_djpeg (via ultraembedded/legacy_jpeg_decoder) | not part of this library: `../../bench/others/fetch.sh` |
| 3 | this library, wide core (`jpeg_decoder #(.FAST(2))`, 4 pixels per beat, MCU order, RGB) | `../../rtl` |

## Files

| file | contents |
|---|---|
| `uart_bench_core.sv` | vendor-neutral: UART receiver and transmitter, 4 KB input FIFO, protocol, the decoder under test, counters |
| `acorn_top.sv` | the Xilinx-specific part: 200 MHz differential input buffer, MMCM (1200 MHz VCO / `CLKOUT_DIV`), `BUFG`, and the `BUFGCE` that gates the decoder's clock |
| `acorn.xdc` | pins: clock J19/H19 (DIFF_SSTL15), UART J2 (FPGA RX) / K2 (FPGA TX), LEDs G3 H3 G4 H4 |
| `build.tcl` | Vivado non-project batch build |
| `pi_bench.py` | host side (any Linux host with the UART; needs pyserial): sends files, prints one result line per file |
| `sim/` | Verilator simulation of the whole harness (`uart_sim_top.sv` models the gated clock buffer, `tb_uart.cpp` sends files over the simulated UART) |
| `make_expected.py` | expected results: libjpeg 9e checksums and RTL clock counts for this library, the other decoders' own simulations (and their accuracy against libjpeg 9e) |
| `report.py` | markdown tables from a results file |
| `bench_lane.sv`, `uart_batch_core.sv`, `acorn_batch_top.sv`, `build_batch.tcl`, `pi_batch.py`, `sim/batch_sim_top.sv`, `sim/tb_batch.cpp` | batched mode: N decoder lanes behind one UART (last section) |
| `results_batch_2026-10-05.json` | the batched run on fpgas.online, Welland: 15 wide decoders |
| `results_2026-10-04.json` | the runs on fpgas.online, Welland pi46: DUTs 0-2 on 2026-10-03, DUT 3 on 2026-10-04 (`results_2026-10-03.json`: the first run alone) |

## How the measurement works

The decoder's clock is the core clock gated by a glitch-free clock buffer (`BUFGCE`). The gate is
open only while the decoder's next input is waiting in the FIFO, during its reset, and after the
whole file has arrived until the frame is done. So at every decoder clock the input is available,
and `clocks` is the decode time with an ideal input, independent of the UART speed; it equals
the cycle-exact simulation (`tb/` for this library, `bench/others/tb_other.cpp` for the others).
The checksum is the sum over all pixels of `{(x ^ y)[7:0], R, G, B}` mod 2^32, as on the EP2C5
boards, so it does not depend on the pixel order. It binds the pixel count and catches most errors,
but not colours exchanged between positions (the position and colour terms add separately); the
pixel-by-pixel comparison with libjpeg 9e is the simulation of the same files, whose clock counts the
board reproduces. New harnesses use a position-binding hash and read whole images back. A decoder that stalls is ended after 2^26 of its
clocks without a pixel (flag `watchdog`), so the next file still runs.

Protocol (8N1): host to FPGA `55 AA 'J' 'P' len[31:0]` (big-endian) and the file; FPGA to host,
32 bytes when the frame is done: `'R' 'E' 'S' DUT, flags, 0 0 0, clocks[31:0], checksum[31:0],
err[15:0], width[15:0], height[15:0], pixels[31:0], bytes[31:0], 0 0` (flags: 1 FIFO overflow,
2 watchdog, 4 done).

## Build and run

```sh
# Vivado (tested with 2026.1; it needs a licence file, the free "Vivado Basic" licence covers the
# 7-series; on Ubuntu 22.04 it also needs libtinfo.so.5 from the libtinfo5 package)
vivado -mode batch -source build.tcl -tclargs <DUT> <CLKOUT_DIV> <out_dir>
#   DUT 3 at 150 MHz needs VIVADO_EFFORT=high (stronger placement / routing): +0.013 ns; the default flow
#   gives -0.10 ns (the one-symbol-per-clock Huffman loop is routing-bound)
#   CLKOUT_DIV 8 = 150 MHz (this library, aq_djpeg), 13 = 92.3 MHz (core_jpeg); VIVADO_THREADS limits threads
# load the bitstream into the FPGA's configuration RAM (not its flash), e.g. on the Pi:
openFPGALoader --cable libgpiod --pins 10:9:11:8 acorn_dut0_div8.bit
python3 pi_bench.py /dev/ttyAMA0 1000000 photo1.jpg photo2.jpg
# expected results (libjpeg 9e djpeg built by ../../bench/run_bench.py; tb/obj_fmcu built by `make`)
python3 make_expected.py --djpeg <libjpeg 9e djpeg> --out expected.json photo1.jpg photo2.jpg
# the harness in simulation (8 clocks per UART bit)
cd sim && verilator --top-module uart_sim_top -GDUT=0 -cc <rtl files> ../uart_bench_core.sv uart_sim_top.sv --exe tb_uart.cpp ...
```

Timing is checked against the -2 speed grade (`xc7a200tfbg484-2`); the board's chip is a -3.
To port the harness to another board, keep `uart_bench_core.sv` and replace the top: a clock
source, a glitch-free gated clock buffer for the decoder (Intel `ALTCLKCTRL` with its enable,
Lattice `DCC`, ...) and the pins. Without a gated clock the count would include the time spent
waiting for the UART.

## Results: fpgas.online Welland pi46, 2026-10-03 and 2026-10-04

The owner's 12 phone photos (`test_images/`: 3120x4160 and 4160x3120, 4:2:2 with an EXIF
thumbnail) and 4:2:0 re-encodes of the same photos (libjpeg-turbo `cjpeg -baseline -quality 90
-sample 2x2`, no metadata), sent at 1 Mbaud. Tables: `python3 report.py results_2026-10-04.json`.

Board: SQRL Acorn CLE-215+ (Xilinx Artix-7 XC7A200T-3) at fpgas.online, Welland site, pi46 (Raspberry Pi 5: JTAG and UART on GPIO). Date: 2026-10-03 (DUTs 0-2), 2026-10-04 (DUT 3). Timing: Vivado 2026.1, part xc7a200tfbg484-2 (conservative; the board's chip is -3).

| decoder | board clock | Fmax (Vivado) | LUTs | flip-flops | block RAM (36 kb tiles) | DSP48E1 |
|---|---:|---:|---:|---:|---:|---:|
| this library, fast core (MCU order, RGB) | 150.0 MHz | 160 MHz | 2,488 | 2,663 | 7.5 | 17 |
| ultraembedded core_jpeg (SUPPORT_WRITABLE_DHT=1) | 92.3 MHz | 95-104 MHz (3 builds) | 6,681 | 6,037 | 7 | 32 |
| H. Ishihara aq_djpeg | 150.0 MHz | 153 MHz | 4,919 | 4,933 | 4 | 14 |
| this library, wide core (FAST=2, 4 pixels per beat, MCU order, RGB) | 150.0 MHz | 150 MHz (+0.013 ns) | 6,211 | 7,575 | 9 | 33 |

Areas include the same UART harness (`uart_bench_core.sv`) around each decoder.

| file | size | this library | core_jpeg | aq_djpeg | this library, wide core |
|---|---|---|---|---|---|
| adapter.jpg | 3120x4160 4:2:2 | 1.482 clk/px, 128.2 ms; identical to libjpeg 9e | fails: 0 of 12,979,200 pixels, reported size 128x176 (stalled, watchdog) | 2.870 clk/px, 248.4 ms; = its simulation; vs libjpeg max diff 6, PSNR 43.0 dB | 0.466 clk/px, 40.3 ms; identical to libjpeg 9e |
| IMG20260405182829.jpg | 3120x4160 4:2:2 | 1.611 clk/px, 139.4 ms; identical to libjpeg 9e | fails: 0 of 12,979,200 pixels, reported size 128x176 (stalled, watchdog) | 3.133 clk/px, 271.1 ms; = its simulation; vs libjpeg max diff 5, PSNR 43.1 dB | 0.527 clk/px, 45.6 ms; identical to libjpeg 9e |
| IMG20260405182833.jpg | 3120x4160 4:2:2 | 1.659 clk/px, 143.5 ms; identical to libjpeg 9e | fails: 0 of 12,979,200 pixels, reported size 128x176 (stalled, watchdog) | 3.242 clk/px, 280.5 ms; = its simulation; vs libjpeg max diff 5, PSNR 43.2 dB | 0.546 clk/px, 47.3 ms; identical to libjpeg 9e |
| IMG20260425135544.jpg | 3120x4160 4:2:2 | 1.475 clk/px, 127.6 ms; identical to libjpeg 9e | fails: 0 of 12,979,200 pixels, reported size 128x176 (stalled, watchdog) | 2.625 clk/px, 227.2 ms; = its simulation; vs libjpeg max diff 6, PSNR 41.7 dB | 0.426 clk/px, 36.8 ms; identical to libjpeg 9e |
| IMG20260425135628.jpg | 4160x3120 4:2:2 | 1.780 clk/px, 154.1 ms; identical to libjpeg 9e | fails: 0 of 12,979,200 pixels, reported size 176x128 (stalled, watchdog) | 3.405 clk/px, 294.6 ms; = its simulation; vs libjpeg max diff 6, PSNR 42.2 dB | 0.561 clk/px, 48.6 ms; identical to libjpeg 9e |
| IMG20260425141210.jpg | 4160x3120 4:2:2 | 1.469 clk/px, 127.1 ms; identical to libjpeg 9e | fails: 0 of 12,979,200 pixels, reported size 176x128 (stalled, watchdog) | 2.687 clk/px, 232.5 ms; = its simulation; vs libjpeg max diff 7, PSNR 42.3 dB | 0.442 clk/px, 38.2 ms; identical to libjpeg 9e |
| IMG20260523191343.jpg | 3120x4160 4:2:2 | 1.544 clk/px, 133.6 ms; identical to libjpeg 9e | fails: 0 of 12,979,200 pixels, reported size 128x176 (stalled, watchdog) | 2.930 clk/px, 253.5 ms; = its simulation; vs libjpeg max diff 5, PSNR 42.9 dB | 0.472 clk/px, 40.8 ms; identical to libjpeg 9e |
| IMG20260612210949.jpg | 4160x3120 4:2:2 | 1.310 clk/px, 113.4 ms; identical to libjpeg 9e | fails: 0 of 12,979,200 pixels, reported size 176x128 (stalled, watchdog) | 2.204 clk/px, 190.7 ms; = its simulation; vs libjpeg max diff 5, PSNR 43.1 dB | 0.348 clk/px, 30.1 ms; identical to libjpeg 9e |
| IMG20260716020409.jpg | 4160x3120 4:2:2 | 1.184 clk/px, 102.4 ms; identical to libjpeg 9e | fails: 0 of 12,979,200 pixels, reported size 176x128 (stalled, watchdog) | 1.909 clk/px, 165.2 ms; = its simulation; vs libjpeg max diff 5, PSNR 44.0 dB | 0.295 clk/px, 25.5 ms; identical to libjpeg 9e |
| IMG20260716020422.jpg | 4160x3120 4:2:2 | 1.187 clk/px, 102.7 ms; identical to libjpeg 9e | fails: 0 of 12,979,200 pixels, reported size 176x128 (stalled, watchdog) | 1.916 clk/px, 165.8 ms; = its simulation; vs libjpeg max diff 5, PSNR 46.0 dB | 0.298 clk/px, 25.8 ms; identical to libjpeg 9e |
| IMG20260716020424.jpg | 4160x3120 4:2:2 | 1.184 clk/px, 102.4 ms; identical to libjpeg 9e | fails: 0 of 12,979,200 pixels, reported size 176x128 (stalled, watchdog) | 1.906 clk/px, 164.9 ms; = its simulation; vs libjpeg max diff 5, PSNR 46.2 dB | 0.296 clk/px, 25.6 ms; identical to libjpeg 9e |
| IMG20260723160735.jpg | 4160x3120 4:2:2 | 1.338 clk/px, 115.8 ms; identical to libjpeg 9e | fails: 0 of 12,979,200 pixels, reported size 176x128 (stalled, watchdog) | 2.241 clk/px, 193.9 ms; = its simulation; vs libjpeg max diff 5, PSNR 41.6 dB | 0.362 clk/px, 31.3 ms; identical to libjpeg 9e |
| adapter_420.jpg | 3120x4160 4:2:0 | 1.074 clk/px, 92.9 ms; identical to libjpeg 9e | 2.141 clk/px, 301.1 ms; = its simulation; vs libjpeg max diff 5, PSNR 42.3 dB | 1.984 clk/px, 171.7 ms; = its simulation; vs libjpeg max diff 5, PSNR 42.7 dB | 0.321 clk/px, 27.8 ms; identical to libjpeg 9e |
| IMG20260405182829_420.jpg | 3120x4160 4:2:0 | 1.174 clk/px, 101.5 ms; identical to libjpeg 9e | 2.141 clk/px, 301.0 ms; = its simulation; vs libjpeg max diff 5, PSNR 42.6 dB | 2.194 clk/px, 189.9 ms; = its simulation; vs libjpeg max diff 5, PSNR 42.9 dB | 0.380 clk/px, 32.9 ms; identical to libjpeg 9e |
| IMG20260405182833_420.jpg | 3120x4160 4:2:0 | 1.207 clk/px, 104.4 ms; identical to libjpeg 9e | 2.141 clk/px, 301.0 ms; = its simulation; vs libjpeg max diff 5, PSNR 42.6 dB | 2.271 clk/px, 196.5 ms; = its simulation; vs libjpeg max diff 5, PSNR 43.0 dB | 0.396 clk/px, 34.2 ms; identical to libjpeg 9e |
| IMG20260425135544_420.jpg | 3120x4160 4:2:0 | 1.152 clk/px, 99.7 ms; identical to libjpeg 9e | 2.148 clk/px, 302.0 ms; = its simulation; vs libjpeg max diff 12, PSNR 42.0 dB | 1.967 clk/px, 170.2 ms; = its simulation; vs libjpeg max diff 12, PSNR 42.4 dB | 0.328 clk/px, 28.4 ms; identical to libjpeg 9e |
| IMG20260425135628_420.jpg | 4160x3120 4:2:0 | 1.366 clk/px, 118.2 ms; identical to libjpeg 9e | 2.188 clk/px, 307.7 ms; = its simulation; vs libjpeg max diff 12, PSNR 42.3 dB | 2.614 clk/px, 226.2 ms; = its simulation; vs libjpeg max diff 12, PSNR 42.7 dB | 0.417 clk/px, 36.1 ms; identical to libjpeg 9e |
| IMG20260425141210_420.jpg | 4160x3120 4:2:0 | 1.106 clk/px, 95.7 ms; identical to libjpeg 9e | 2.143 clk/px, 301.3 ms; = its simulation; vs libjpeg max diff 8, PSNR 42.5 dB | 1.947 clk/px, 168.5 ms; = its simulation; vs libjpeg max diff 8, PSNR 42.9 dB | 0.316 clk/px, 27.3 ms; identical to libjpeg 9e |
| IMG20260523191343_420.jpg | 3120x4160 4:2:0 | 1.156 clk/px, 100.1 ms; identical to libjpeg 9e | 2.152 clk/px, 302.6 ms; = its simulation; vs libjpeg max diff 5, PSNR 42.3 dB | 2.072 clk/px, 179.3 ms; = its simulation; vs libjpeg max diff 5, PSNR 42.7 dB | 0.330 clk/px, 28.6 ms; identical to libjpeg 9e |
| IMG20260612210949_420.jpg | 4160x3120 4:2:0 | 1.018 clk/px, 88.1 ms; identical to libjpeg 9e | 2.141 clk/px, 301.0 ms; = its simulation; vs libjpeg max diff 8, PSNR 42.6 dB | 1.492 clk/px, 129.1 ms; = its simulation; vs libjpeg max diff 8, PSNR 43.0 dB | 0.262 clk/px, 22.7 ms; identical to libjpeg 9e |
| IMG20260716020409_420.jpg | 4160x3120 4:2:0 | 1.006 clk/px, 87.1 ms; identical to libjpeg 9e | 2.141 clk/px, 301.0 ms; = its simulation; vs libjpeg max diff 4, PSNR 44.0 dB | 1.379 clk/px, 119.4 ms; = its simulation; vs libjpeg max diff 4, PSNR 44.2 dB | 0.255 clk/px, 22.1 ms; identical to libjpeg 9e |
| IMG20260716020422_420.jpg | 4160x3120 4:2:0 | 1.005 clk/px, 86.9 ms; identical to libjpeg 9e | 2.141 clk/px, 301.0 ms; = its simulation; vs libjpeg max diff 5, PSNR 46.4 dB | 1.397 clk/px, 120.9 ms; = its simulation; vs libjpeg max diff 5, PSNR 46.5 dB | 0.255 clk/px, 22.0 ms; identical to libjpeg 9e |
| IMG20260716020424_420.jpg | 4160x3120 4:2:0 | 1.005 clk/px, 86.9 ms; identical to libjpeg 9e | 2.141 clk/px, 301.0 ms; = its simulation; vs libjpeg max diff 4, PSNR 46.7 dB | 1.388 clk/px, 120.1 ms; = its simulation; vs libjpeg max diff 4, PSNR 46.8 dB | 0.255 clk/px, 22.0 ms; identical to libjpeg 9e |
| IMG20260723160735_420.jpg | 4160x3120 4:2:0 | 1.060 clk/px, 91.8 ms; identical to libjpeg 9e | 2.143 clk/px, 301.3 ms; = its simulation; vs libjpeg max diff 6, PSNR 42.2 dB | 1.643 clk/px, 142.1 ms; = its simulation; vs libjpeg max diff 6, PSNR 42.6 dB | 0.285 clk/px, 24.7 ms; identical to libjpeg 9e |

What the runs show:

- **The wide core (`FAST=2`, DUT 3, run on 2026-10-04) decoded all 24 files with pixels identical to
  libjpeg 9e** at 0.295-0.561 clocks/pixel on the 4:2:2 originals and 0.255-0.417 on the 4:2:0 copies,
  3.0-4.0x fewer clocks than the fast core: 22.0-48.6 ms per 12-megapixel photo at 150 MHz. Every
  clock count equals the cycle-exact simulation. That is 0.64-0.80x the time of libjpeg-turbo
  -nosmooth on one laptop core at 3.9 GHz and 0.64-0.88x that of the fastest CPU decoder on each file
  (`../../BENCHMARKS.md`). With the harness it needs 6,211 LUTs, 33 DSPs and 9 block-RAM tiles (the
  decoder alone 5,827 LUTs, 6,831 flip-flops); 150 MHz is met with `VIVADO_EFFORT=high` (+0.013 ns).
  The 24 files ran on the build before two fixes found by Vivado's xsim (a missing reset of the IDCT
  pipeline's valid bits; a workaround for an xsim bug); the final bitstream was run on 3 of them
  (adapter.jpg, IMG20260716020409.jpg, adapter_420.jpg): 3/3 PASS with identical clocks and checksums.
  The site had renamed the board page to `pi-sw2-p46` by then (the same Acorn).
- **This library decoded all 24 files with pixels identical to libjpeg 9e**, at 1.18-1.78
  clocks/pixel on the 4:2:2 originals and 1.005-1.37 on the 4:2:0 copies, 87-154 ms per
  12-megapixel photo at 150 MHz. Each clock count equals the cycle-exact simulation and the counts
  measured on the Cyclone II EP2C5 board (`adapter.jpg`: 19,234,181 clocks on both).
- **aq_djpeg decoded all 24**, with 1.37-1.95x as many clocks per file as this library, at a similar
  Fmax (153 MHz). Its pixels differ from libjpeg's by up to 4-12 levels (PSNR 41.6-46.8 dB).
- **core_jpeg decoded none of the originals**: it does not support 4:2:2, and on these files it
  reads the header of the EXIF thumbnail (128x176) and then stalls. It decoded all 12 4:2:0 copies
  at a nearly constant 2.14-2.19 clocks/pixel, with the lowest Fmax (95-104 MHz on this part):
  about 301 ms per photo at 92.3 MHz. Its pixels differ by up to 4-12 levels (PSNR 42.0-46.7 dB).
- **Every board result of the other two decoders equals their own simulation** (clock count and
  checksum), so the harness measures each decoder exactly as simulated.
- This library is also the smallest of the three in logic (2,488 LUTs against 4,919 and 6,681,
  harness included); aq_djpeg uses the fewest block RAMs (4 tiles against 7.5) and DSPs (14 against 17).

## Batched mode: 15 wide decoders at the same time (2026-10-05)

`uart_batch_core.sv` puts N decoder lanes (`bench_lane.sv`: input FIFO, `jpeg_decoder`, counters, the
logic of `uart_bench_core.sv`) behind one UART. Each lane has its own gated clock, so each lane's
clock count is its own decode time with an ideal input. The host sends a file header per lane and the
files in packets, lane after lane, so all lanes decode at the same time; a broadcast packet feeds the
same bytes to several lanes (one upload, every lane decoding it). A lane's 32-byte result (the format
of `uart_bench_core.sv`, the lane number in byte 5) comes back as soon as it has finished.

- **15 lanes is the limit of one MMCM**: it can drive only the 16 global clock buffers of its half of
  the device (the core clock and 15 lane gates; the MMCM's feedback is internal). 16 lanes failed
  clock placement; more lanes would need a second MMCM in the other half.
- **Resources (15 x `FAST=2`, harness included)**: 91,949 LUTs (68.7 %), 112,058 flip-flops, 135
  block-RAM tiles, 495 DSP48E1 (66.9 %), 16 BUFGCTRL.
- **Timing at 150 MHz**: met for the board's own speed grade, -3 (+0.339 ns setup, +0.036 ns hold;
  the routed design re-timed with `open_checkpoint -part xc7a200tfbg484-3`). This is the first build
  here signed off at -3: on -2, the grade of the other builds, it reaches 141.5 MHz (-0.399 ns, in
  every lane, on the wide core's Huffman bit-window loop that needs high effort even as a single
  core). The CLE-215+'s grade comes from LiteX's board file; the JTAG IDCODE cannot show it.
- **Build**: `build_batch.tcl` in three Vivado processes (synthesis, placement, routing; 22, 109 and
  138 minutes with `VIVADO_EFFORT=high`, 4 threads). One process grew to 11.9 GB by the end of
  placement; separate processes peaked at 4.5-4.7 GB for placement and routing.
- **Simulation** (3 lanes, Verilator): 24 results in three runs - distinct files in rounds, malformed
  and truncated files with one-byte packets, broadcast rounds - all equal to the decoder's own
  simulation and to libjpeg 9e.
- **Harness change (2026-10-09), after the board run.** `uart_batch_core.sv` now finds the lowest lane
  with a result first and then reads that lane's record once by index; before, it assigned the whole
  256-bit record inside the loop over the lanes, and Vivado's synthesis of that core with 15 lanes
  needed 5.4 GB on its own on the XC7A200T (more than 9 GB on a Kintex UltraScale+ KU5P). Now 2.9 GB
  (3.5 GB on the KU5P), and 1,492 LUTs instead of 1,843 for the core, with the same registers; the
  whole 15-lane build (11.2 GB synthesis peak before) was not re-run. The same 24-result simulation gives identical result records before
  and after the change (all 18 decodable results equal to libjpeg 9e and to the decoder's own clock
  counts, the 6 malformed files with their expected error bits). The bitstream of the board run above
  was built from the previous version.
- **On the board: 18/18 identical to libjpeg 9e, every clock count equal to the simulation.**
  adapter.jpg broadcast to all 15 lanes: 6,049,456 clocks in every lane; then three photos in lanes
  0-2 (IMG20260716020409.jpg 3,825,225, IMG20260716020422_420.jpg 3,304,743,
  IMG20260716020424_420.jpg 3,305,261 clocks).
- **Throughput** (from the measured counts): 15 adapter.jpg in 40.33 ms, 372 photos/s or 4.83
  Gpixel/s, 20.7x one laptop core at a steady 3.9 GHz (libjpeg-turbo -nosmooth, the fastest CPU
  decoder on this photo, 55.5 ms) and about 10x a hypothetical core 2.04x the laptop's (the libjpeg-turbo tjbench ratio of a Core Ultra 9 285K to the i7-8550U on OpenBenchmarking, 359 vs 176 Mpixel/s; not measured on these files). On the 24 photo files (each file's
  measured count, spread over the 15 lanes, longest first) 408 photos/s (371.5 in file order, 470.8
  with ideal balance), 5.5x the laptop's whole CPU measured on the same
  files (74.5 photos/s on 4 cores / 8 threads at 2.35 GHz, its ~18 W limit; `../../bench/bench_multicore.py`).
  A real system has to feed every lane at full speed (here the 1 Mbaud UART cannot; the lanes'
  clocks pause while they wait: the adapter.jpg upload took 35.7 s, its decode 40.33 ms): 372
  adapter-sized photos/s need about 1.3 GB/s of JPEG in and 14.5 GB/s of RGB out. The 15 lanes
  decoded copies of one file sent once (broadcast), not 15 distinct files; these are compute rates.
- **Sources of the results.** Single-lane runs: the 24 files with the RTL before `6846718` (the two
  xsim fixes), the final bitstream (3 files) with `6846718`; the 15-lane batch with `d6448a2`, before
  the UART-core change `6bf75dd`.

```sh
# build (three processes; VIVADO_THREADS, VIVADO_EFFORT=high as for build.tcl)
for st in synth place route; do vivado -mode batch -source build_batch.tcl -tclargs 15 2 8 build/b15 $st; done
# on the Pi: one file broadcast to every lane, then files one per lane
python3 pi_batch.py /dev/ttyAMA0 1000000 15 --broadcast adapter.jpg
python3 pi_batch.py /dev/ttyAMA0 1000000 15 photo1.jpg photo2.jpg photo3.jpg
# the harness in simulation (3 lanes)
cd sim && verilator --top-module batch_sim_top -GN=3 -GFAST=2 -CFLAGS -DNLANES=3 -cc <rtl files> ../bench_lane.sv ../uart_batch_core.sv batch_sim_top.sv --exe tb_batch.cpp -o Vbatch ...
```
