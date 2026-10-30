# BEP-JPEG-development

This branch is the full working tree behind the BEP-JPEG library (called BEBCL-JPEG until 2026-10-30). The `main` branch (the library) is
exported from it by `scripts/export_library.py` and is a strict subset, so every file of `main` is
developed and verified here first.

## What is only here

| path | contents |
|---|---|
| `FAST_STATUS.md` | design of the fast core (`FAST=1`), timing-closure history on the EP2C5, verification log, open items |
| `WIDE_STATUS.md` | the wide core (`FAST=2`, 4 pixels per clock): the model that chose it, timing probes, steps, results |
| `PROPOSALS.md` | Proposals A and B: research, measurements on the photos (`model/perf/syncstats.c`), estimates (`model/perf/proposals.py`), design sketches, plan |
| `ROADMAP.md` | the next work, in the owner's names: Proposals A and B (splitting a stream without restart markers; a way around the Huffman loop limit), Task A (batched wide decoders on Welland), Task B (all tests on AWS F2) |
| `test_images/` | all of the owner's test photos (12 phone photos; `main` has `adapter.jpg` only) for runs on other boards |
| `boards/ep2c5/gate_level/` | gate-level simulation of the post-fit netlists (Verilator with this project's own Cyclone II cell models, Icarus + SDF, ModelSim-ASE) |
| `boards/ep2c5/gls*/` | fast-UART twins of the EP2C5 builds, for the gate-level runs |
| `boards/ep2c5/fpga_jtag_dbg/` | `fpga_jtag` at 50 MHz (PLL 1/1), used while bringing up the JTAG harness |
| `quartus/core`, `quartus/fpga_fast_raster` | the decoder alone (does not fit the EP2C5 Web Edition flow) and the fast raster core on a Cyclone IV EP4CE10 |
| `tb/regression_*.txt`, `tb/*.txt` | regression logs cited by `FAST_STATUS.md` |
| `boards/ep2c5/*/build_status.txt` | notes of earlier builds |

## Updating `main`

```sh
cd tb && make && make test                      # 1,818 + 90 + 468 runs must pass (9 configurations)
python3 export_expectations.py                  # refresh expected.txt etc. for run_tests.sh when the
./run_tests.sh                                  #   corpus or the configurations change; same 2,376 runs
git add -A && git commit                        # on BEP-JPEG-development
python3 scripts/export_library.py ../BEBCL-JPEG        # ../BEBCL-JPEG is the worktree of main
cd ../BEBCL-JPEG && git add -A && git commit
```
After RTL changes also re-fit the EP2C5 builds (`boards/ep2c5/compile_all.sh`): `fpga_raster` uses
99 % of the device, so any growth on the raster path can break it. After changes to a core's timing,
compare its clock counts with the performance model (`model/perf/`, e.g. `model/perf/check_wide.py`
for `FAST=2`): the model reproduces the fast and the wide core's counts within 1-2 % (it does not
model the compact core), so a larger difference points at an unintended stall.

## RTL conventions

* The SystemVerilog-2005 subset that Quartus II 13.0sp1 accepts: no size casts (`32'(x)`), no
  `string` parameters, no part-selects of parameters, `import pkg::*;` inside the module body,
  `integer` loop variables, `always_ff` with synchronous reset, RAMs in the `jpeg_sdp_ram` style so
  they infer into block RAM, `(* multstyle = "dsp" *)` on the multiplies that must use DSP blocks.
* Declare every signal before its first use, also in the port connections of an instance inside a
  `generate` block: a forward reference there creates an undriven implicit net in strict tools
  (Vivado's xsim showed wrong pixels from `.lastrow(~more_y)`; Verilator and Quartus resolved it).
* Declare loop counters inside each block (`always_comb begin : name integer i; ...`): a
  module-level variable written by more than one `always` block is illegal SystemVerilog (xsim
  refuses to elaborate it). Run `tb/sim.sh -s xsim` on a few files after RTL changes.
* Do not index an array with another array's element inside a procedural `for` loop
  (`q[k] <= tab[idx[k]]`): Vivado 2026.1's xsim evaluates it as `tab[k]` (it gave the wide core's
  colour conversion the table entries 0-3). Write one process per element with a `generate` loop.
* Reset the valid bits of every pipeline, even when nothing else needs a reset: a 4-state simulator
  starts them as X, and an X that reaches a counter stays there (the wide IDCT's busy count hung
  xsim this way while Verilator, which starts registers at 0, passed).
* Every arithmetic detail follows the reference libraries - libjpeg 9e (`jidctint.c`,
  `jdcolor.c`, `jdsample.c`) for the default profile, libjpeg-turbo 2.1 (`jdsample.c` fancy
  upsampling, `FIX(0.34414)`) for `FANCY_UPSAMPLE`/`CC_TURBO` - so the golden comparisons stay
  exact; if you change arithmetic, change `model/jpeg_golden.py` too and re-run
  `scripts/compare_refs.py` and `make test`.
* Comment with T.81 section numbers (B.2.x headers, C Huffman tables, F.2.2 decode procedures).
* `set_parameter` values in a `.qsf` must be plain decimal integers (Quartus 13 turns a Verilog
  literal into a string without warning).
* Keep the RTL vendor-neutral: inferred RAMs/ROMs/multipliers only; Quartus attributes are fine as
  hints. Vendor primitives (PLLs, clock buffers, JTAG) belong in `boards/<board>/`.
* Test images: generate with libjpeg-turbo `cjpeg -baseline ...` (without `-baseline`, quality
  below ~25 silently produces SOF1 files with 16-bit tables, which are unsupported). Files in the
  repository come only from the owner's photos.
