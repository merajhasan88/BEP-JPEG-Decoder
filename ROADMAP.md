# Roadmap: proposals and tasks

Development branch only (not exported to the library). Recorded on 2026-10-04 at the owner's
request; the names are the owner's.

| item | what | state |
|---|---|---|
| **Proposal A** | split the stream of one image that has no restart markers, so several decoders can share one photo | research started 2026-10-04 after 22:40 PKT (owner: "sure go ahead keeping in mind the load on the laptop's cores") |
| **Proposal B** | a way around the Huffman loop limit (one code per clock) | research started with A, in parallel |
| **Task A** | batched mode of the wide core on fpgas.online Welland | **done 2026-10-05**: 15 wide decoders at 150 MHz (-3 grade), 18/18 identical to libjpeg 9e on the board, 372 photos/s on adapter.jpg; details below and in `boards/acorn_cle215/README.md` |
| **Task B** | all tests on AWS F2 | last; nothing is set up on AWS without the owner's go-ahead |
| **Review 2026-10-10** | external review of the 10 October hand-over (`../jpeg-decoder-review-2026-10-10.md`) | four defects: three fixed and verified the same day, the fourth (board checksum) described; see "Review of 2026-10-10" below |

Research, measurements, estimates and the plan for both proposals: `PROPOSALS.md`.

Method for both proposals (the order the owner chose for the wide core, "model first"): published
methods and existing decoders, then estimates with `model/perf`, then a plan with numbers for the
owner, and RTL only after that. The output must stay bit-exact (libjpeg 9e and Pillow profiles).

## Review of 2026-10-10

The review's sequence, and what was done on 2026-10-10 (development branch; `proposals-AB` only had its
document corrected):

| priority | work | state |
|---|---|---|
| 1 | completion, validation, unsupported colour | **done**: frames end at the image's EOI (ERR_TRUNC without one, ERR_SCAN for a second scan); segment lengths, the 4-byte DRI, distinct component ids, the AC symbol domain; RGB-coded files by libjpeg 9e's rule passed through (RGB output only), libjpeg 9's other colour spaces ERR_SOF_TYPE. Regression 1,926 + 234 + 900 runs (37 corpus files, 50 malformed); the review's own probes as expected in all four of its configurations; the SystemVerilog testbench 3,060 / 3,060 on Verilator; the wide core on the 24 photo files with the clocks of 2026-10-04. EP2C5: all ten builds re-fitted with CHECKS=1 (`fpga_raster` 4,587 of 4,608 LEs; `fpga_jtag` 4,481 at 95 MHz) and the board run on `fpga_jtag` 20 / 20 (FAST_STATUS 7f) |
| - | board checksum (a sum of position and colour terms: colours exchanged between positions go unseen) | described where board results are cited; new harnesses use a position-binding hash and read whole images back |
| 2 | freeze profiles, reproducible builds | results name their source commits (acorn README); `scripts/manifest.py` records the commit, tool versions, sha256 of every source and test input, and per EP2C5 build its files, parameters, fit and timing summaries and bitstream hash (`bench/manifest_2026-10-10.json` for tonight's builds and board run) |
| 3 | one FAST=2 decoder with real memory input and RGB output, full readback, wall time | the vendor-neutral part of the F2 harness is built and simulated (`boards/aws_f2`: memory lanes and job engine, full readback and position-binding hash, the engine's own wall clock); the F2-specific part needs AWS (Task B) |
| 4 | equivalent CPU comparison | "desktop" figures are now labelled a hypothetical 2.04x core (a tjbench ratio, not a measurement); the FFmpeg clock pairing is fixed in `bench/run_bench.py`; a re-run and a measured current CPU need the owner's go-ahead (power profile) |
| 5 | Proposal A integrated, four-way then eight-way | not started; the pass-1 reader's malformed-input contract is noted in PROPOSALS.md (proposals-AB) |
| 6 | scale lanes or clocks on measured bottlenecks | after 3 and 5 |

## Proposal A: split a stream without restart markers

Owner: "Lets find a way to split a stream of an image without restart markers."

- **Why.** None of the owner's 24 photo files (`test_images/` and their 4:2:0 copies) has a restart
  interval (no DRI marker), so each photo is one entropy-coded segment that one decoder must read in
  order. A bigger FPGA alone cannot shorten one photo.
- **What a decoder starting in the middle of the stream must recover:** the bit position of the next
  code, its place in the MCU (component, block, coefficient index), and the DC predictor of each
  component (DC values are coded as differences from the previous block of the same component,
  T.81 F.2.2.1).
- **Starting points:** the self-synchronisation of Huffman codes (a decoder started at a wrong bit
  position tends to fall back into step), the speculative parallel decoders used for JPEG on GPUs,
  and fixing up the DC predictors afterwards (a prefix sum of the differences).

## Proposal B: a way around the Huffman loop limit

Owner: "In parallel (pun intended) lets find a way around Huffman loop limitation".

- **The limit.** Each code's length must be known before the next code can start, so the loop (table
  lookup, code length, shift, next lookup) cannot be split into more pipeline stages. The wide core
  (`FAST=2`) decodes one code per clock and closes timing at 150 MHz on the Artix-7 XC7A200T-3;
  estimate 250-350 MHz on the fastest FPGAs.
- **Target.** A hypothetical desktop core 2.04x as fast as the laptop's i7-8550U (the ratio of
  libjpeg-turbo's tjbench on OpenBenchmarking, Core Ultra 9 285K 359 vs 176 Mpixel/s - a different
  benchmark, not measured on our files), so the wide core would need about 270 MHz to beat it on every photo (estimate; at 150 MHz it takes 1.31-1.80x
  that core's time, against 0.64-0.88x of the laptop core's, measured).
- **Ideas to study:** decoding two or more codes per lookup; decoding speculatively at several bit
  positions and keeping the right result; together with Proposal A, letting independent pieces of a
  photo take turns in a loop with more pipeline stages.

## Task A: batched mode of the wide core on Welland

- **Result (2026-10-05).** 15 wide decoders (`boards/acorn_cle215`: `uart_batch_core.sv`,
  `results_batch_2026-10-05.json`), 91,949 LUTs and 495 DSPs, 150 MHz met for the board's -3 grade
  (141.5 MHz on -2). On the board: adapter.jpg broadcast to all 15 lanes, then three photos in three
  lanes - 18/18 identical to libjpeg 9e with every clock count equal to the simulation: 15 photos in
  40.33 ms, 372 photos/s, 20.7x one laptop core. A 133 MHz build for the -2 grade was not completed (its routing was still resolving congestion
  after the 3-hour limit) and is not needed: the 150 MHz bitstream passed on the board.
- **What.** Several wide decoders side by side on one FPGA, each decoding its own photo: throughput
  rather than single-photo time. Owner: "We do have to use that website for the batched mode that is
  deferred at the moment".
- **Board.** SQRL Acorn CLE-215+ (Artix-7 XC7A200T-3) at fpgas.online Welland, `pi-sw2-p46`
  (`pi-sw2-p47` is the same board).
- **Room.** One wide decoder with the test harness takes 6,211 LUTs, 33 DSPs and 9 block-RAM tiles of
  the XC7A200T's 133,800 LUTs, 740 DSPs and 365 tiles: LUTs and DSPs would allow about 20, but each
  lane's gated clock takes a global clock buffer, and the clock generator (MMCM) can drive only the 16
  buffers of its half of the chip: 15 lanes plus the core clock (16 lanes synthesized to 73 % of the
  LUTs, then failed clock placement). More lanes would need a second MMCM in the other half.
- **Open questions.** How to feed many decoders through the board's 1 Mbaud UART (each decoder's
  clock stays gated while it waits for data, as in the current harness, so the clock counts still
  measure decoding only); how to report the results per decoder.
- **Rules for fpgas.online.** Ask the owner before every run; check that the board is free; one
  terminal session per run, slow polling, delete everything afterwards; upload only photos from
  `test_images/` (and their 4:2:0 copies); no remote-board tools in the repositories.

## Task B: all tests on AWS F2

- **When.** Last (owner: "I want to test AWS last"); nothing is set up on AWS without the owner's
  go-ahead.
- **Setup agreed on 2026-10-04.**
  - One f2.6xlarge: one VU47P FPGA, $1.98/h, needs 24 vCPUs of the "Running On-Demand F instances"
    quota (requested by the owner on 2026-10-04).
  - A separate build instance with AWS's FPGA Developer AMI (~$0.5-1/h). Vivado comes licensed
    there for the VU47P; the F2 kit supports Vivado 2024.1-2025.2, not our local 2026.1.
  - No Elastic IP. Every instance and its disks are deleted after each run, nothing is left running
    between rebuilds; the S3 bucket may stay.
  - Budget: ~$2-4 per attempt (build 1.5-3 h, AFI creation 0.5-1 h on AWS's side with no instance
    running, ~0.5 h on the F2).
- **Prepared locally first,** so that the first attempt works: a `boards/aws_f2` harness and host
  program, simulated with Verilator; a timing preview on an UltraScale+ part (done, below).
- **Clock.** F2's FPGA is `xcvu47p-fsvh2892-2-e` (speed grade -2). The shell gives the custom logic
  a fixed 250 MHz main clock (`clk_main_a0`); other clocks come from AWS's clock recipes (for example
  225, 200, 187.5 or 150 MHz) or from our own MMCMs.
- **Timing preview (2026-10-08,** `model/perf/probes/usplus_timing.tcl`, results in
  `model/perf/probes/usplus_timing_2026-10-08.json`). The free Vivado licence does not cover the
  VU47P, so the wide decoder lanes were placed and routed (out of context, high effort) on a Kintex
  UltraScale+ KU5P of the same grade (`xcku5p-ffvb676-2-e`), which it does cover: **250 MHz met** with
  one lane in the batched harness (+0.573 ns) and with 15 lanes side by side (+0.061 ns overall, on a
  lane's reset fan-out; +0.336 ns inside the decoders, on the Huffman decoder's table lookup). The same
  lanes reach 150 MHz (one) and 141.5 MHz (15) on the Artix-7 -2. So F2's fixed 250 MHz clock looks
  reachable: 1.67x the Artix-7's clock, about 13-29 ms per photo instead of 22-49 (estimate). Not
  modelled: the VU47P's three dies, the shell and its memory interfaces.
  Follow-ups (owner's go-ahead, 2026-10-08/09): **one lane at 266.67 MHz** (AWS recipe C3) is met too
  (+0.453 ns, on the Huffman bit-window loop); **24 lanes at 250 MHz** (72 % of the KU5P's LUTs, about
  the Artix-7 batch's 68 %) are met (+0.043 ns overall, a lane's FIFO pointer to its clock gate's
  enable; +0.117 ns inside the decoders). The decoders' margin shrinks as the chip fills (+0.573,
  +0.336, +0.117 ns for 1, 15, 24 lanes), and hold is met but tight in every run (+0.010 to
  +0.019 ns): the real F2 build has to show both again.
- **Harness note (same day).** The batched harness's UART core (`uart_batch_core.sv`) with 15 lanes
  needs more than 9 GB to synthesize on the KU5P even with the lanes left empty (one lane in it:
  3.5 GB; on the XC7A200T the core alone takes 5.4 GB of the batch build's 11.2 GB synthesis peak).
  The 15-lane preview used `usplus_lanes_top.sv` (the lanes without the UART core) instead.
  **Cause (found the same evening):** the result selection in `p_tx`, a loop over the lanes that
  assigns the whole 256-bit result record inside the loop body for the first ready lane, so that 15
  chained 256-bit assignments reach Vivado's RTL Optimization Phase 2. Rewritten to find the lowest
  ready lane first and then read its results once by index (same behaviour), the core with 15 empty
  lanes needs 2.9 GB instead of 5.4 GB on the Artix-7 part (1,492 LUTs instead of 1,843, same
  registers) and 3.5 GB instead of more than 9 GB on the KU5P. Removing the per-lane byte counting or
  writing the lane tables by constant index changed nothing. **Applied 2026-10-09** (owner's
  go-ahead): the 3-lane batch simulation's 24 result records are identical before and after (18
  decodable = libjpeg 9e and the decoder's own clock counts, 6 malformed with their expected error
  bits); the bitstream of the Welland run was built from the previous version. Measurements in
  `model/perf/probes/usplus_timing_2026-10-08.json` (`side_finding`).
- **"All tests" (owner, 2026-10-04):** all 24 photo files on the single core (`FAST=1`), the wide
  core (`FAST=2`) and the batched mode, plus whatever comes out of Proposals A and B; checked against
  libjpeg 9e's checksums and the simulated clock counts, as on Welland.
- **Harness design (2026-10-10, proposed for the owner's decision; nothing built or run on AWS).**
  The review asks for real memory input, RGB output read back in full, wall time, and notes that the
  KU5P previews show timing portability, not an F2 result. What AWS's F2 kit offers (aws-fpga, branch
  f2): the shell's PCIS (512-bit AXI4, host-initiated, reaches the 64 GB DDR4 DIMM and the 16 GB HBM),
  PCIM (512-bit AXI4, the custom logic reads and writes host memory), OCL (AXI-Lite registers),
  250 MHz `clk_main_a0`; HBM: 32 AXI3 channels at 450 MHz, 460 GB/s theoretical, about 430 GB/s
  measured by AWS's `cl_mem_perf` example; the kit supports Vivado 2025.2 (on premises only with a
  Vivado ML Enterprise licence, which we do not have), and its shell simulation model runs on AWS's
  build image, not on our free Vivado 2026.1.
  - Option 1 (recommended): **HBM job engine.** The host writes JPEG files into HBM over PCIS; per lane
    a job register (input address and length, output address) in OCL; each lane reads its file from
    its own HBM channel and writes its RGB there (up to 3 GB/s per lane, far below a channel's
    ~14 GB/s); the host reads the RGB back over PCIS and compares every pixel with libjpeg 9e, and
    reads clocks, errors and a position-binding hash per job. 24 lanes need 24 of the 32 channels.
  - Option 2: AWS's streaming data engine (CL_SDE, over PCIM) feeding the lanes from host memory
    and writing RGB back to it: no device memory, but its host software is the Virtual Ethernet
    application's, a larger software effort.
  - Option 3: the Welland harness with PCIe instead of the UART (host writes into lane FIFOs, results
    by register, pixels only hashed): cheapest, but compute rates only - what the review criticises.
  - Order for option 1: (a) on the F2 instance, run AWS's pre-built `cl_mem_perf` image and measure the
    host <-> HBM paths (no build: about 30 minutes of the f2.6xlarge); (b) write the harness here and
    simulate it with Verilator against our own models of PCIS, OCL and HBM; (c) the DCP build on AWS's
    build image, where the shell simulation can also run first; (d) the run, with full readback.
  - **Built so far (2026-10-10, `boards/aws_f2/`):** the vendor-neutral part of option 1, in Verilator.
    `mem_lane.sv`: one wide decoder fed from memory by an AXI4 read master, its output written as
    {x, y, 4 x RGB} records by an AXI4 write master, with clocks, waits, error bits and a position-binding
    hash; jobs back to back, abort, done only with nothing in flight; 256- or 512-bit data.
    `f2_regs.sv` + `jpeg_f2_engine.sv`: NL lanes, each with its own AXI4 port (one HBM channel each), and
    the host's registers on AXI-Lite (OCL): job, tag, start / abort, status, results, engine clock at
    start and done. Tests against an AXI4 memory model with random gaps on every channel: lane 1,240 /
    1,240 jobs (corpus, the 50 malformed cases, data after the EOI, no SOI, mid-frame aborts, output
    overflow; two widths, four gap settings), engine 620 / 620 jobs in four batches as a host would run
    them; the 24 photo files as one batch on 4 lanes, all identical to libjpeg 9e, in 1.013 (largest
    first) to 1.039 (file order) times the lower bound of the engine clock (memory bandwidth not modelled). Option 2 would replace the lanes' read side only; the registers stay. Not built: the shell,
    HBM and clocking, the host program (on AWS's build image, after the owner's choice).
