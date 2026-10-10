# AWS F2 harness (Task B) - in progress

Nothing here has run on AWS; nothing is set up there without the owner's go-ahead (ROADMAP.md, Task B,
where the harness designs are compared). What is here is the vendor-neutral part of option 1 (the HBM
job engine), simulated with Verilator: the host's view (registers) and the lanes' memory side (AXI4).

| file | what it is |
|---|---|
| `mem_lane.sv` | one decoder lane that works from memory: a job (file address and length, output area) is read with an AXI4 read master, decoded by the wide core (`jpeg_decoder FAST=2`, RGB) and written as 16-byte records {x, y, 4 x RGB} with an AXI4 write master (256- or 512-bit data); reports clocks, input / output waits, pixels, records, error bits and a hash that binds each colour to its position. Jobs run back to back without a reset; a job's inputs are sampled at its start; the lane stops reading at the frame's end and says done only when no burst is in flight; a job can be aborted (a file without an SOI never ends a frame) |
| `f2_regs.sv` | the register file on an AXI-Lite slave (on F2: the shell's OCL port): per lane the next job, a tag, start / abort, status, results, and the engine clock at start and at done; globally an ID, the lane count, a free-running 64-bit clock, DONE / BUSY masks. Map in the file's header |
| `jpeg_f2_engine.sv` | `f2_regs` plus NL lanes, each with its own AXI4 master port (on F2: one HBM channel per lane) |
| `sim/tb_mem_lane.cpp` | one lane, a list of jobs back to back, against an AXI4 memory model with random delays and gaps on every channel: every pixel placed by x and y and compared with the golden image, the hash recomputed; the job inputs change and a start is pulsed while a job runs; at done nothing may be outstanding on the memory side |
| `sim/run_lane_tests.py` | the job list: every corpus file (the 2 unsupported ones must end with ERR_SOF_TYPE and no pixels), the 50 malformed cases (bits and pixels as `tb/malformed/cases.json`), files with zeros after their EOI, a file without an SOI and three mid-frame aborts, an output area too small (res_ovf) - each special job followed by a clean file; 256- and 512-bit data, with 0, 30 (two seeds) and 60 % gaps |
| `sim/tb_engine.cpp`, `sim/run_engine_tests.py` | the engine driven as the host would: files into memory first (on F2: PCIS writes), jobs by register (every access waits `--host-lat` clocks, a stand-in for a PCIe round trip), DONE polled, results and records read and checked as above; also the tags, the start counters, a start written while busy (ignored and counted), the ID / scratch / clock registers. Jobs in file order or largest first; reports the batch's wall clocks (engine clock, first start to last done) against the lower bound max(longest job, sum / NL) |

```sh
cd boards/aws_f2/sim && make           # obj_lane, obj_lane256 (one lane), obj_eng (4 x 512 bits), obj_eng3 (3 x 256 bits)
python3 run_lane_tests.py [--photos ../../../test_images/adapter.jpg ...]
python3 run_engine_tests.py [--photos ...]
```

Results (2026-10-10): lane 1,240/1,240 jobs (155 per list x 2 widths x 4 gap settings); engine 620/620 jobs
in 4 batches (4 x 512 and 3 x 256 bits, both orders, with and without gaps) with every check passed.
Found by these tests and fixed: a job's late read data could reach the next job when the frame ended
before the file did; a mid-frame abort left a pixel beat in the decoder that the next job counted in the
clock before the decoder's reset acted (the lane now ignores the decoder in that clock; with the fix
removed, the stalled runs fail 1-3 jobs of 155). On the corpus the 4 lanes are busy 45-58 % of the batch:
its files take thousands of clocks and each job costs the host about 20 register accesses; with
photos (millions of clocks each) that cost is small, and a descriptor queue would remove it for small files.

Not here (F2-specific, on AWS's build image): the shell's ports, the HBM IP and its AXI3 ports (each lane
keeps INCR bursts of at most 16 beats inside 4 KB and a single ID, which AXI3 slaves accept; WID tied
off), clock crossings, PCIS into HBM, and the host program.
