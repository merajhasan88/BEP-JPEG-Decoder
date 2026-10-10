## Performance by image

Four pixels per output beat is the wide core's peak, not its rate (review of 2026-10-10). The tables give
the fast (`FAST=1`) and wide (`FAST=2`) cores' clocks in simulation (Verilator, MCU order, RGB output),
split into the **setup**, until `frame_start` (the headers, read at a byte per clock, and the Huffman
lookahead tables built from them), and the **scan**, from `frame_start` to the image's EOI. Measured by
`bench/perf_by_image.py` (`bench/perf_by_image_2026-10-10.json`); the photos' clocks are those of
`model/perf/wide_photos_sim_2026-10-04.json`, which the RTL with the review's fixes reproduced exactly on
2026-10-10.

- **Small images: the latency is the setup**, 682-2,025 clocks before the first pixel in both cores
  (682-842 for the grey images with two Huffman tables, 1,321-1,639 for the colour ones with four,
  2,025 when an EXIF thumbnail has to be skipped). A 1x1 image takes 1,721 clocks on the wide core: 11.5 us at 150 MHz.
- **Large images: the rate follows the compressed size.** On the 24 photo files the wide core takes 0.255
  clocks per pixel at 0.5 compressed bits per pixel (3.9 pixels per clock, close to the output's peak of
  4) and up to 0.561 at 2.7 bits per pixel (1.8 pixels per clock), where the Huffman decoder, one symbol
  per clock, sets the pace. 4:2:2 files have a third more blocks per pixel than 4:2:0 ones and mostly
  need more clocks at the same bits per pixel.
- The fast core: 1.0-1.8 clocks per pixel on the photos; 1.0-3.0 in the scans of the corpus images from
  8x8 pixels up.
