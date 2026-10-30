## The decoders on one board: Xilinx Artix-7 XC7A200T

On 2026-10-03 the three decoders - this library's fast core, core_jpeg and aq_djpeg - ran on the
same remote board, and on 2026-10-04 this library's wide core (`FAST=2`, DUT 3) followed on it, an SQRL Acorn CLE-215+ (Artix-7
XC7A200T) at [fpgas.online](https://fpgas.online) (Welland site), each in the same UART harness
(`boards/acorn_cle215/uart_bench_core.sv`): the file arrives over the Raspberry Pi's UART, the
decoder's clock is gated so that it only runs while its next input is waiting, and the board
reports the decoder's own clock count and a checksum of its pixels (a sum over the pixels of
`{(x^y)[7:0], R, G, B}`: it binds the pixel count, not each colour to its position - the pixel-exact
comparison is the simulation of the same files, whose clock counts the board reproduces). Each decoder was built with
Vivado 2026.1 at a clock it meets (-2 speed grade timing). Files: the owner's 12 phone photos
(4:2:2, with EXIF thumbnails) and 4:2:0 re-encodes of them (`cjpeg -baseline -quality 90 -sample
2x2`, no metadata), because core_jpeg does not support 4:2:2. The other decoders' board results
were checked against their own simulations (`bench/others/tb_other.cpp`): identical clock counts
and checksums for every file they decoded.
