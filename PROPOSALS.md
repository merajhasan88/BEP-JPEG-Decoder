# Proposals A and B: research, measurements, estimates and plan

Development branch only. 2026-10-04. The owner's names (ROADMAP.md): **Proposal A** = split the stream
of one image that has no restart markers, so several decoders share one photo; **Proposal B** = a way
around the Huffman loop limit ("each code's length must be known before the next code can start").
Everything below is measured on the owner's 24 photo files (the 12 photos in `test_images/` and their
4:2:0 copies) except the rows marked *estimate*: those are the validated performance model
(`model/perf/`, within 1.6 % of the board on today's wide core) applied to designs that are not built.
No RTL has been written for either proposal.

## Summary

Single-photo decode time at 150 MHz (the Artix-7 clock) divided by that of the fastest CPU decoder on
one core, per photo. "Desktop" = a hypothetical core 2.04x the laptop's i7-8550U (the ratio of
libjpeg-turbo's tjbench on OpenBenchmarking: Core Ultra 9 285K 359 vs 176 Mpixel/s - a different
benchmark, not measured on these files).

| design | clocks / pixel | vs laptop core (3.9 GHz) | vs hypothetical 2.04x core | needs |
|---|---|---|---|---|
| today's wide core (measured) | 0.255-0.561 | 0.64-0.88 | 1.30-1.79 | - |
| A, 2 segments | 0.19-0.54 | 0.59-0.77 | 1.20-1.57 | the whole file in memory, a resume mode, 2 cores |
| **A, 4 segments** | 0.09-0.27 | **0.30-0.39** | **0.60-0.79** | ... 4 cores |
| A, 4 segments, pass 1 at 2 symbols/clock | 0.08-0.22 | 0.24-0.31 | 0.48-0.63 | ... + a 2-symbol skimmer |
| **A, 8 segments** | 0.05-0.14 | **0.15-0.19** | **0.30-0.39** | ... 8 cores |
| B, 2 symbols per clock only | 0.25-0.41 | 0.49-0.87 | 0.99-1.78 | a multi-symbol Huffman decoder |
| B, 2 symbols/clock, every stage widened (input 4 bytes, long codes 1 clock, IDCT x2, 8 pixels/beat) | 0.13-0.29 | 0.32-0.48 | 0.66-0.98 | a new "W8" core, ~2x the area |
| B, 4 symbols/clock, every stage widened | 0.13-0.19 | 0.24-0.46 | 0.49-0.94 | ... larger still |

(All rows except the first are estimates. A's rows include the measured synchronisation overlap.)
Raw numbers: `model/perf/proposals_2026-10-04.json` (`model/perf/proposals.py`).

**Reading:** Proposal A scales with the number of segments using the existing, board-verified wide
core; Proposal B alone gains little because, once the Huffman decoder is faster, the other stages
limit (below). On the clock-rate side of Proposal B, the timing probes (2026-10-05) favour a C-slow
loop: two streams in turn at 252 MHz, 1.52x the symbol rate of today's loop in the same area -
streams that Proposal A's segments provide.

## Research

- **Klein and Wiseman, "Parallel Huffman decoding with applications to JPEG files"** (The Computer
  Journal 46(5), 2003): Huffman codes tend to resynchronise; each processor decodes a segment and
  continues into the next until it meets the next processor's decoding, which corrects the next
  processor's wrong start. Adapted to JPEG.
- **Weissenberger and Schmidt, "Accelerating JPEG Decompression on GPUs"** (HiPC 2021,
  arXiv:2111.09219): a full GPU decoder on that idea. A decoder state is (bit position, symbol count,
  component, zig-zag index); subsequence i is decoded from the initial guess (first component, z = 0),
  the decoder of subsequence i-1 "overflows" into it until its state equals the one stored for the
  same point; DC differences are undone afterwards with a prefix sum. Up to 51x libjpeg-turbo and 8x
  nvJPEG on an A100. Restart markers, they note, are "not used in JPEG-encoded images by most
  libraries and cameras" - as in the owner's photos.
- **Multi-symbol hardware decoders** (e.g. Nikara, Vassiliadis, Takala, Liuha, "Multiple-symbol
  parallel decoding for variable length codes", IEEE TVLSI 2004): decode every codeword of an n-bit
  block at once; 4.8 codewords per cycle on MPEG-2 streams, at a large area.
- **C-slow pipelining** (a standard retiming technique): a feedback loop cut by C registers runs
  C independent streams in turn at a higher clock; it needs independent streams, which Proposal A's
  segments (or the batched mode's photos) provide.

## Measurements (`model/perf/syncstats.c`, 2,000 random start points per file)

- **No restart markers** in any of the 24 files: each photo is one entropy-coded segment.
- **Synchronisation distance** of a decoder started at a random bit with the GPU paper's guess (first
  block of an MCU, DC code next) until it is in the true decoder's state at the same bit:

  | files | median | 99th percentile | worst | never in sync |
  |---|---|---|---|---|
  | the 12 photos | 106-257 bits | 1,218-2,310 bits | 3,968 bits | 0 of 24,000 |
  | their 4:2:0 copies | 266-1,098 bits | 3,732-9,937 bits | 17,344 bits | 0 of 24,000 |
  | either, best of the MCU's block phases | 35-98 bits | 186-1,088 bits | 9,095 bits | 0 |

  The files' scans have 6.3-35.3 Mbit: with 8 segments the overlap is at most 0.47 % of a segment at
  the 99th percentile and 1.08 % in the worst case measured (both on the smallest 4:2:0 copies).
- **DC differences are not additive through the IDCT**: in 2,326 of 3,000 random blocks a change of
  the DC coefficient does not shift all 64 pixels by the same amount (jidctint's rounding and the
  range limit). A segment's pixels therefore need its true DC predictors before the IDCT: Proposal A
  takes **two passes** (or would have to buffer whole segments of coefficients).
- **Symbols per clock** of a greedy multi-symbol decoder (8-bit tables, a 32/48/64-bit window): 1.96-1.99
  for 2 symbols, 3.74-3.94 for 4; codes longer than 8 bits are 0.9-4.9 % of the symbols.
- **What limits once the Huffman decoder is faster**: codes longer than 8 bits (6 clocks each today),
  the decoder's 1-byte-per-clock input (adapter.jpg needs 0.272 bytes per pixel, so at most 1/0.272
  pixels per clock), the 4-pixel output (0.25 clocks per pixel) and the IDCT (8 clocks per block).

## Proposal A: design sketch

1. **Pass 1 (index).** P skimmers (the wide core's Huffman decoder in a decode-only mode) start at
   bit i x (scan bits / P) with the guess (block 0, DC next). Skimmer i+1 logs its symbol starts
   (bit, block phase, zig-zag index, running block count and DC sums) for its first 32 kbit (twice
   the worst measured distance); skimmer i, after its own segment, continues until its state matches
   a logged entry: the sync point. A segment that has not synchronised within its log falls back to
   being decoded from the previous sync point (correct, only slower).
2. **Prefix** (P steps): absolute DC predictors, MCU index and decoder state at each sync point.
3. **Pass 2 (decode).** P wide cores resume at their sync points (bit position, block phase, DC
   predictors, MCU index) and stop at the next one; each emits its own band of MCUs.

**Prerequisites and consequences.**
- The whole compressed file must be in random-access memory before decoding starts. The XC7A200T has
  1.6 MB of block RAM, less than the photos (1.7-4.7 MB; the 4:2:0 copies 0.8-3.2 MB): on the Acorn this means its DDR3
  through Xilinx's memory controller (vendor IP, in the board harness only), on AWS F2 the shell's
  DDR/HBM. **AWS (Task B) is the natural first board for it.**
- The library gains a second top level (a split decoder: file in memory, P output bands); today's
  stream interface (bytes in, pixels out) stays as it is.
- The wide core needs two new modes: decode-only (pass 1) and resume-at-a-bit (pass 2).

**Steps.** (1) A C reference of the two-pass split decode, bit-exact against libjpeg 9e on all 24
files with P = 2-16 (no RTL; it proves the sync logs, the fallback and the DC prefix). (2) RTL of the
two modes and the split controller, Verilator against the same files. (3) A board: AWS F2, or the
Acorn with DDR3.

## Proposal B: findings and design sketch

- **More symbols per clock alone gains little** (1.0-1.5x today's wide core; nothing on the 4:2:0
  copies that already run at the output's limit): long codes, the 1-byte input, the 4-pixel output and
  the IDCT take over. With every stage widened (2 symbols per clock, 4-byte input, long codes in one
  clock, two IDCT pairs, 8 pixels per beat) the estimate is 1.7-2.1x today's wide core - a new "W8"
  core of roughly twice the area.
- **A higher clock instead** keeps today's clocks per pixel. Three loops probed out of context on the
  XC7A200T-2 with the same script (`model/perf/probes/probe_fmax.tcl`, default effort, 2026-10-05):

  | loop | Fmax | LUTs (of them LUTRAM) | symbols per second |
  |---|---|---|---|
  | probe 2: today's loop (window -> table -> n -> barrel shift) | 165.9 MHz | 1,053 (416) | 166 M, one stream |
  | probe 3: the same loop cut by one register, two streams in turn (C-slow) | 252.0 MHz | 830 (320) | 252 M, two streams: 1.52x |
  | probe 4: tables looked up at every offset of a word-aligned window | 155.9 MHz | 17,946 (14,336) | 156 M, one stream |

  The C-slow loop's worst path is now the stream select in front of the window refill, not the
  loop. Probe 4 fails on its own large mux (the entry at the pointer) and the fan-out of the window
  move to every registered entry, at 17 times the area: rejected on this family, and with it the
  multi-symbol decoders that need the same lookups at many offsets. (Probe 3 leaves out the
  long-code path, which in probe 2 adds only registered terms; in the full wide core today's loop
  meets 150 MHz with high effort, below the isolated loop's 166 MHz.)
- **Where B fits:** after A, as its C-slow form: one Huffman decoder serving two of A's segments (or
  two of the batched mode's photos) at 1.5x the loop clock in the area of one. The rest of the core
  must then take two streams at that clock (two back ends, or one at twice the rate), which a
  further probe of the IDCT and output paths would have to show before any design.

## Recommendation

Proposal A first: step 1 (the C reference) is cheap, needs no board and decides whether the method is
sound on these files; the estimates say 4 segments beat the hypothetical 2.04x desktop core on every photo
(0.60-0.79x its time) and 8 segments take a third of its time - on any board that holds the file in
memory, which points to AWS F2. For Proposal B, the C-slow loop (252 MHz for two streams, 1.52x
today's loop) is the option worth carrying into A's design; the all-offsets loop is not.

## Probe runs

`model/perf/probes/probe_fmax.tcl` (out of context, default effort, XC7A200T-2, one Vivado at a time):
probe 2 at 5.0 ns (WNS -1.028 ns), probes 3 and 4 at 4.0 ns (WNS +0.031 and -2.415 ns).
