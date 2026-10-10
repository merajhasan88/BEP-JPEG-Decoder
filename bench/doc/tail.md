
## What the numbers say

### Against CPU decoders

1. **At full clock, one laptop core beats the EP2C5 on every image.** All CPU times in these
   comparisons are taken at a steady 3.9 GHz, the laptop's highest measured clock: the runs were
   measured at 3.4-3.9 GHz (the laptop throttles), so each is rescaled from its cycle count (the
   CPU's best case). libjpeg-turbo -nosmooth (the same pixels as this decoder) decodes donald.jpg in
   6.8 ms against the EP2C5's 30.0 ms (4.4x faster), the 12-megapixel phone photos in 53-68 ms
   against 203-284 ms (3.8-4.1x) and the 4:4:4 portrait in 16.7 ms against 88.3 ms (5.3x). Even the
   slowest CPU decoder on each large photo is 1.4-1.9x faster than the EP2C5 (libjpeg 9e with its
   default upsampling, or stb_image, depending on the image). Apart from the pure-Python reference model, the only CPU
   result the FPGA beats is Pillow on the 64x64 image, where Python's per-call overhead dominates.
2. **Per clock, the FPGA does about 10x more work.** It needs 1.0-2.25 clocks per pixel. libjpeg-turbo
   with SIMD (AVX2) needs 8-22 CPU clocks per pixel, and libjpeg 9e and stb_image need 20-52 on the
   large photos. But
   the laptop's clock is 40x higher (3.9 GHz against 95 MHz). At the laptop's power-saver clock
   (~1 GHz) libjpeg-turbo and the EP2C5 are close. The CPU is 7-47 % faster on six images and level
   (3 %) on the 320x240 image. It takes 21 % longer on the 64x64 image (see the last table of the
   results).
3. **Energy per image is the FPGA's clear advantage.** donald.jpg costs ~4.4 mJ on the EP2C5
   (PowerPlay estimate 147 mW x 30 ms). libjpeg-turbo uses 124 mJ of CPU package energy at full
   clock and 65 mJ in the power-saver profile, so the FPGA uses 15-28x less. Both figures are
   rough: the FPGA's is a vectorless estimate that includes I/O, and the CPU's is RAPL package
   energy that includes background power.
4. **Correction.** Earlier versions of this file, README.md and the project notes said the EP2C5
   at 95 MHz decodes donald.jpg faster than libjpeg-turbo, FFmpeg and Pillow on one laptop core
   (30.0 ms against 32.8-42.6 ms). Those CPU numbers were measured with the laptop in its
   power-saver profile (~0.8-1 GHz), and so was the first run on 2026-09-30. FFmpeg was also
   measured without its RGB conversion. **That claim is withdrawn.** At full clock the laptop is
   3-6x faster. What still holds is the per-clock and energy comparison above.
5. **The decode time is the decoder alone.** On this board the file arrives over JTAG at ~35 KB/s
   (170 s for a 5.9 MB photo), and the pixels are checked on the chip. To keep up with the
   decoder, a system needs an input path of ~8 MB/s (donald.jpg) to ~21 MB/s (the dense phone
   photo). It also needs a consumer that takes 42-93 Mpixel/s in 8x8 / 16x16 tiles.
6. **The compact core** (`FAST=0`, 3.4k LEs, 50 MHz) needs 12.8-21 clocks/pixel (0.75 s for
   donald.jpg). Use it when area matters more than speed. It is also the core that fits the EP2C5
   with raster output and Pillow-exact smoothing (up to 352 pixels wide for 4:2:0).
7. **Among the CPU decoders** at 3.9 GHz (on the 320x240 image and the large photos),
   libjpeg-turbo is the fastest. Pillow (which uses it inside) takes 1.14-1.47x as long. OpenCV
   takes 1.45-2.29x and FFmpeg (its own decoder, plus the RGB conversion) 1.18-2.91x. libjpeg 9e
   takes 1.89-2.16x (`-nosmooth`) and stb_image 2.04-2.67x; neither has SIMD. (On some of the
   owner's photos below FFmpeg is faster than libjpeg-turbo.)

8. **On the owner's photos (2026-10-04, the section above), none of the FPGA decoders measured on
   2026-10-03 beats the fast CPU decoders on single-image time.** At a steady 3.9 GHz (the runs
   measured 2.3-3.9 GHz) one laptop core decodes a 12-megapixel photo in 28-62 ms with libjpeg-turbo
   -nosmooth, 25-80 ms with FFmpeg, 48-112 ms with zune-jpeg (Rust) and 54-95 ms with Pillow.
   BEBCL-JPEG (`FAST=1`) takes 87-154 ms on the Artix-7 at 150 MHz (2.2-3.2x libjpeg-turbo
   -nosmooth's time) and 137-243 ms on the EP2C5 at 95 MHz; aq_djpeg 119-295 ms, core_jpeg 301-308 ms
   (4:2:0 only). BEBCL-JPEG on the Artix-7 is faster than Go's `image/jpeg` (156-305 ms) on every
   photo, than stb_image on 20 of 24 and than libjpeg 9e with its default upsampling on 16 of 24.
   Per clock it does 8.2-11.7x more work than libjpeg-turbo (1.0-1.8 clocks per pixel against
   8.3-18.5 CPU clocks per pixel). What limits it is the clock (150 MHz against 3.9 GHz) and its one
   pixel per clock, not memory.
9. **The wide core (`FAST=2`, 2026-10-04) is faster than every CPU decoder on every photo.** On the
   same Artix-7 board at 150 MHz it decodes the 24 files in 22.0-48.6 ms (0.255-0.561 clocks per
   pixel, 3.0-4.0x fewer clocks than the fast core), with pixels identical to libjpeg 9e and clock
   counts identical to the simulation. That is 0.64-0.80x the time of libjpeg-turbo -nosmooth on one
   laptop core at a steady 3.9 GHz (1.24-1.57x faster) and 0.64-0.88x the time of the fastest CPU
   decoder on each photo (libjpeg-turbo, or FFmpeg on three files). It decodes one Huffman symbol
   per clock and up to four pixels per output beat in 6,211 LUTs and 33 DSPs of the XC7A200T (with the harness);
   at 131 MHz or more it would still beat every CPU decoder on every photo. Single-image time on one
   CPU core is the comparison here: several CPU cores decoding several photos at once outrun one
   decoder in throughput. Several decoders side by side answer that: 15 wide decoders on the same
   board (2026-10-05, `boards/acorn_cle215`, 150 MHz met for the board's -3 grade, 141.5 MHz on -2)
   decoded at the same time with pixels identical to libjpeg 9e; from their clock counts (each lane's
   decode time with an ideal input) that is 372 photos/s on adapter.jpg, 20.7x one laptop core, and
   408 photos/s on the 24 photo files. Three assumptions go with these rates: the counts are active
   decode clocks (the gated clocks leave out the waits for the 1 Mbaud UART); the 15 lanes decoded
   copies of one file sent once, not 15 distinct files; and 408 is a schedule of the 24 single-file
   times on 15 lanes, longest first (371.5 in file order, 470.8 with ideal balance). Feeding 372
   adapter-sized photos/s takes about 1.3 GB/s of JPEG in and 14.5 GB/s of RGB out. The laptop's whole CPU, measured on the same 24 files
   (`bench_multicore.py`, `bench_multicore_2026-10-05.json`; libjpeg-turbo -nosmooth, one worker per
   logical CPU, performance profile): 23.4 photos/s on one core at 3.92 GHz, 62.6 on 4 cores and
   74.5 on 8 threads - under all-core load this 15 W chip holds only 2.35-2.63 GHz at ~18 W (93.0 and
   123.5 photos/s if it held 3.9 GHz). So the batch is 5.5x the whole laptop CPU as measured, 3.3x its
   best case. Estimate only: about half of a 16-core CPU whose cores are each a hypothetical core 2.04x the laptop's (the libjpeg-turbo tjbench ratio of a Core Ultra 9 285K to the i7-8550U on OpenBenchmarking, 359 vs 176 Mpixel/s; not measured on these files).
10. **Correction (2026-10-04).** Until then this file and README.md compared the FPGA with CPU
   times as measured while the laptop throttled (2.3-3.9 GHz), and with libjpeg-turbo's default
   (smoothing) mode: "libjpeg-turbo 1.9-2.7x faster than BEBCL-JPEG on the Artix-7", "faster than
   stb_image on every photo". With every CPU time at a steady 3.9 GHz and libjpeg-turbo -nosmooth,
   which gives the same pixels as this decoder, these are 2.2-3.2x and 20 of 24 (the owner spotted
   the throttled comparison). Per-clock figures were always computed from cycle counts and stand.

### Against other FPGA decoders

- **Neither core_jpeg nor aq_djpeg fits the EP2C5.** On the EP2C35 they need 7.0k-9.5k logic
  elements and 34-64 9-bit multiplier elements; the EP2C5 has 4,608 and 26. This decoder is the
  only one of the three that runs on the owner's board.
- **On the larger Cyclone II this decoder leads on every measure but one.** It has the highest Fmax
  (103.8 MHz against 60.2 and 40.1-40.4 MHz) and the fewest clocks per pixel on every image. It
  uses the fewest logic elements (4.4k against 7.0k-9.5k) and multipliers (26 against 34-64). It
  uses the most block-RAM bits (55.6 kbit against 27.5-51.2 kbit). It is the only one whose pixels
  are identical to libjpeg's; the others differ by up to 14 (core_jpeg) and 32 (aq_djpeg) levels,
  PSNR 42-51 dB. donald.jpg takes 30.0 ms on the EP2C5 board at 95 MHz, against 66.4 ms for
  aq_djpeg (60 MHz) and 148 ms for core_jpeg (40 MHz).
- **core_jpeg fails on the owner's phone photos.** It decodes the 512x384 EXIF thumbnail inside the
  APP1 segment instead of the photo. It also mis-decodes the 4:4:4 portrait and the q6 strip, and
  it does not support 4:2:2 or restart markers.
- **aq_djpeg decodes every file**, at 1.4-5.0 clocks/pixel. That makes it 3.0-3.3x slower than this
  decoder on the phone photos.
- **On the same Artix-7 board** (XC7A200T, the table above) this decoder runs at 150 MHz (Fmax
  160 MHz), aq_djpeg at 150 MHz (153 MHz) and core_jpeg at 92.3 MHz (95-104 MHz). On every one of
  the 24 files this decoder needs the fewest clocks: aq_djpeg needs 1.37-1.95x as many, and
  core_jpeg 1.6-2.1x on the 4:2:0 copies, which at its lower clock makes it 2.6-3.5x slower per
  photo. core_jpeg decoded none of the 4:2:2 originals (it reads the EXIF thumbnail's header and
  stalls). This decoder is also the smallest in logic (2,488 LUTs against 4,919 and 6,681, harness
  included); aq_djpeg uses fewer block RAMs (4 tiles against 7.5) and DSP blocks (14 against 17).
- Commercial cores were not available for testing. CAST's JPEG-DX-F data sheet quotes 2-32
  samples per clock (e.g. 300 Msamples/s) with 6,700 ALMs on Cyclone V or 18,250 LUT4 on ECP5 at
  70 MHz. These are vendor figures for larger devices, not measured on the same files.

## Where more speed would come from

- **On the EP2C5 this design is close to the ceiling.** The fast core uses 4,473 of 4,608 LEs and
  all 26 multiplier elements, and each of its three limits would need more logic or multipliers
  than the device has:
  - the output, at 1 pixel per clock (4:2:0 photos such as donald.jpg);
  - the IDCT, with 13 multipliers and 32 clocks per block, which is 1.5 clocks per pixel for 4:4:4;
  - the Huffman decoder, at 3 clocks per coded coefficient (the dense phone photos).
- **Matching one laptop core at full clock** (~400 Mpixel/s on donald.jpg) needs ~4 pixels per clock
  at 100 MHz. There are two ways to get there on a larger FPGA:
  - a wider decoder: 2 coefficients per clock in the Huffman decoder, more IDCT lanes, and 2-4
    pixels per clock out;
  - several decoders working on different images (an MJPEG stream, a batch).

  A single image without restart markers cannot simply be split between decoders, because its
  Huffman-coded data has to be decoded in order. None of the owner's photos has restart markers.
- **Newer FPGA families** would run the same RTL at a higher clock (not measured here).

## Reproduce

```sh
cd tb && make obj_mcu/Vjpeg_decoder obj_fmcu/Vjpeg_decoder
cd ../bench                              # tools.py fetches libjpeg 9e and stb_image, and Go (~280 MB)
                                         # when `go` is not on PATH; zune-jpeg needs cargo (Rust 1.74+)
BENCH_POWER_PROFILE=performance python3 run_bench.py bench.json [image.jpg ...]   # CPU decoders, full clock
python3 bench_fpga.py bench.json         # this decoder's clock counts (cycle-exact simulation)
python3 ../boards/ep2c5/scripts/jtag_decode.py <files> > board_jtag_95mhz.txt   # EP2C5, fpga_jtag loaded
cd others && ./fetch.sh && ./build.sh && python3 run_others.py others.json
./quartus/make_projects.sh && ./quartus/compile_all.sh
./quartus/make_projects.sh EP2C35F672C8 35 && SUF=35 ./quartus/compile_all.sh
cd .. && python3 make_benchmarks_md.py   # -> ../BENCHMARKS.md
# Artix-7 board: boards/acorn_cle215/README.md (build.tcl, pi_bench.py, make_expected.py, report.py)
```

`bench_powersaver.json` holds the CPU runs in the laptop's power-saver profile. Its libjpeg-turbo
`-nosmooth` rows were re-run with the clock recorded (`BENCH_ONLY="libjpeg-turbo (nosmooth)"
python3 run_bench.py bench_powersaver.json`). Caveats: CPU decoders ran single-threaded on one
pinned core, and RAPL energy includes background package power.
