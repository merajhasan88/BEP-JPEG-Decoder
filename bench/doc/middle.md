
## Other FPGA JPEG decoders on the same device family

Open-source FPGA JPEG decoders that are complete, portable and licensed for use: **core_jpeg** by
ultraembedded (Apache-2.0, Verilog, baseline, 4:4:4 / 4:2:0 / grey, no restart markers, no 4:2:2)
and **H. Ishihara's aq_djpeg** (MIT, via ultraembedded/legacy_jpeg_decoder; baseline, all
subsamplings, restart markers). Others were excluded: forks of these two, a VHDL decoder built on
Xilinx-licensed CoreGen modules (not usable on an Intel/Altera device), incomplete student
designs, and HLS libraries for data-centre FPGAs. Their sources are fetched by
`bench/others/fetch.sh` into `bench/others/third_party` (ignored by git) and are not part of this library;
the results hold for exactly these revisions and settings: core_jpeg at commit `bb03cce` (2020-10-26),
legacy_jpeg_decoder at `de6832b` (2020-10-25), each built by `bench/others/quartus/make_projects.sh`
(the same harness, device, optimisation settings and a 95 MHz clock constraint for all). This is not a
survey of all FPGA JPEG IP: commercial cores (CAST's, for example) were not available to test, and their
datasheet figures are not comparable measurements. A file a decoder does not support is listed as such,
apart from slower or inexact decodes.

Method: every decoder is wrapped in the same 4-pin harness (`bench/others/quartus/cmp_wrap.sv`:
input word from a serial pin, every output pixel accepted at once and folded into a checksum on a
pin), compiled with the same Quartus settings for the EP2C5 and, because the others do not fit it,
for the larger Cyclone II EP2C35 (same family and speed grade). Clock counts come from cycle-exact
Verilator simulation on the same files with the input offered as fast as accepted
(`bench/others/tb_other.cpp`, `run_others.py`); accuracy is measured against libjpeg 9e
`djpeg -dct int -nosmooth`, which this decoder reproduces exactly. The other decoders' times use
their own Fmax on the EP2C35; this decoder's times are at the 95 MHz it runs at on the EP2C5 board
(its Fmax on the EP2C35 is 103.8 MHz).
