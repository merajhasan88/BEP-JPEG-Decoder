# AWS F2 harness (Task B)

**Image 1 (owner, 2026-11-03: "1) DDR4 with Task B. 2) DDR4 with Proposal A. 3) HBM with Proposal A + Task B"):**
the batch engine on the F2 card's DDR4, 15 lanes (`cl_jpeg/`). The first build on AWS (2026-11-03, commit 4d1d7b9)
passed AWS's simulation test but **failed timing at placement** (-0.88 ns at 250 MHz, mostly in `mem_lane.sv`'s
interfaces to the decoder, not in the decoder): no image (AFI) yet. Below, "First build on AWS". Nothing is launched
there without the owner's go-ahead and a cost given first. The vendor-neutral parts were written and simulated first
(2026-10-10: the lanes and the job engine); the custom logic (CL) for AWS's small shell and its tests followed on
2026-11-03.

| file | what it is |
|---|---|
| `mem_lane.sv` | one decoder lane that works from memory: a job (file address and length, output area) is read with an AXI4 read master, decoded by the wide core (`jpeg_decoder FAST=2`, RGB) and written as 16-byte records {x, y, 4 x RGB} with an AXI4 write master (256- or 512-bit data); reports clocks, input / output waits, pixels, records, error bits and a hash that binds each colour to its position. Jobs run back to back without a reset; a job's inputs are sampled at its start; the lane stops reading at the frame's end and says done only when no burst is in flight; a job can be aborted (a file that ends at or before its SOI never ends a frame) |
| `f2_regs.sv` | the register file on an AXI-Lite slave (on F2: the shell's OCL port): per lane the next job, a tag, start / abort, status, results, and the engine clock at start and at done; globally an ID, the lane count, a free-running 64-bit clock, DONE / BUSY masks. Map in the file's header |
| `jpeg_f2_engine.sv` | `f2_regs` plus NL lanes, each with its own AXI4 master port (on F2: one HBM channel per lane) |
| `f2_core.sv` | the CL's logic between the shell's ports and the memory: NL lanes (each with registered job inputs, a register slice on its memory port and its own reset register), `f2_regs` on OCL, `f2_pcis` on PCIS, and `f2_axi_mux` onto one AXI4 port (on F2: the DDR4). Vendor-neutral |
| `f2_axi_mux.sv` | NM AXI4 masters onto one slave: round-robin AR and AW (the grant registered one clock ahead), the W bursts in the order of their addresses (AXI4 has no WID), R and B routed back by ID (the master's index); the slave may reorder answers across IDs and interleave read bursts |
| `f2_pcis.sv` | the host's memory port: the shell's PCIS (BAR4, 512-bit AXI4) as one master of the multiplexer - addresses aligned down to 64 bytes (the byte strobes and byte lanes carry the alignment) and reduced to 64 GiB, the shell's IDs returned in order from two FIFOs; until the memory is ready every request is answered here with SLVERR (reads: zeros) and counted, so no access can hang the shell's 8 us timeout |
| `f2_slices.sv` | register slices (every valid, data and ready leaves a flip-flop) for AXI4 and AXI-Lite, a plain pipeline, and links with credits for long distances (every wire between the two halves leaves a register and enters one; OCL and PCIS cross the dies over them) |
| `cl_jpeg/` | the CL for AWS's HDK (folder name = CL name = top module, as the HDK requires): `design/cl_jpeg.sv` (the shell's ports from the HDK's `cl_ports.vh`, included, not copied; AWS's `sh_ddr` wired as in AWS's examples; every unused interface idle), `design/cl_id_defines.vh` (PCIe IDs 0xF0A1/0x1D0F, 0x1D51/0xFEDC), `design/cl_jpeg_defines.vh` (the commit stamp), `build/` (our `encrypt.tcl` and `synth_cl_jpeg.tcl` for the HDK's flow, the constraints: placement in SLR1 next to the shell and SLR2 next to the DDR4), `verif/` (AWS's XSIM test), `build_on_aws.sh` (the build on AWS's FPGA Developer AMI), `local_check.tcl` (the free checks on this machine) |
| `sim/tb_cl.cpp`, `sim/run_cl_tests.py`, `sim/sh_ddr_sim.sv` | the whole CL, its real top level with `cl_ports.vh`, in Verilator: the testbench plays the F2 host and AWS's shell on every port, with the DDR4 as a model behind a stand-in `sh_ddr` (same module name and ports). Below |
| `sim/tb_mem_lane.cpp` | one lane, a list of jobs back to back, against an AXI4 memory model with random delays and gaps on every channel: every pixel placed by x and y and compared with the golden image, the hash recomputed; the job inputs change and a start is pulsed while a job runs; at done nothing may be outstanding on the memory side |
| `sim/run_lane_tests.py` | the job list: every corpus file (the 2 unsupported ones must end with ERR_SOF_TYPE and no pixels), the 50 malformed cases (bits and pixels as `tb/malformed/cases.json`), the 230 cut files of `tb/run_trunc_tests.py` (ERR_TRUNC; a 1-2 byte cut never starts a frame and is aborted), files with zeros after their EOI, a file without an SOI and three mid-frame aborts, an output area too small (res_ovf) - each special job followed by a clean file; 256- and 512-bit data, with 0, 30 (two seeds) and 60 % gaps |
| `sim/tb_engine.cpp`, `sim/run_engine_tests.py` | the engine driven as the host would: files into memory first (on F2: PCIS writes), jobs by register (every access waits `--host-lat` clocks, a stand-in for a PCIe round trip), DONE polled, results and records read and checked as above; also the tags, the start counters, a start written while busy (ignored and counted), the ID / scratch / clock registers. Jobs in file order or largest first; reports the batch's wall clocks (engine clock, first start to last done) against the lower bound max(longest job, sum / NL) |

```sh
cd boards/aws_f2/sim && make           # obj_lane, obj_lane256 (one lane), obj_eng (4 x 512 bits), obj_eng3 (3 x 256 bits)
python3 run_lane_tests.py [--photos ../../../test_images/adapter.jpg ...]
python3 run_engine_tests.py [--photos ...]
```

Results (2026-10-10): lane 4,920/4,920 jobs (615 per list - with the 230 cut files of
`tb/run_trunc_tests.py` - x 2 widths x 4 gap settings) and 3 photos at both widths with 30 % gaps
(identical to libjpeg 9e, the decoder never waited for the writer); engine 2,460/2,460 jobs in 4 batches
(4 x 512 and 3 x 256 bits, both orders, with and without gaps) with every check passed. Since 2026-10-12
every lane's decoder also runs the interface checker (`../../tb/jpeg_checker.sv`, bound in): lane
4,920/4,920 again, and the engine 3,690/3,690 jobs in 6 batches - the 4 above and 2 in which the host
writes each lane's next job while it still runs and starts it at its done (`--preload`), with every
check passed. The 24 photo files (the 12 photos and their 4:2:0 copies) as one batch on 4 lanes of 512 bits, all
identical to libjpeg 9e: 29.79 M engine clocks from the first start to the last done in file order, 29.04 M
largest file first, against a lower bound of 28.68 M (the lanes' work divided by 4): 1.039 and 1.013 times
the bound, lanes busy 96 and 99 %, with a memory of unlimited bandwidth (40-80 clocks of read latency,
no gaps in this batch) and 100 clocks per register access (0.4 us at 250 MHz; a real OCL round trip
takes 1-2 us, which adds about 0.1-0.2 % per 12 MP photo and dominates for corpus-sized files, as the
corpus batches' 45-58 % show). "Largest first" is largest file first, a stand-in for the decode time.
At F2's 250 MHz (not measured) the 29.04 M clocks would be 116 ms; the records are 4 bytes per pixel,
about 2.7 GB/s per lane at that clock.
The checker's first run here found a decoder bug: the bytes after a file's EOI that a lane feeds before
it sees frame_done (jobs with zeros after the file) set ERR_SYNC on the image after its frame_done; the parser now skips bytes
before an SOI without an error (the lanes had captured the error bits at frame_done, so no job had failed).
Found by these tests and fixed: a job's late read data could reach the next job when the frame ended
before the file did; a mid-frame abort left a pixel beat in the decoder that the next job counted in the
clock before the decoder's reset acted (the lane now ignores the decoder in that clock; with the fix
removed, the stalled runs fail 1-3 jobs of 155). On the corpus the 4 lanes are busy 45-58 % of the batch:
its files take thousands of clocks and each job costs the host about 20 register accesses; with
photos (millions of clocks each) that cost is small, and a descriptor queue would remove it for small files.

Not here (F2-specific, on AWS's build image): the shell's ports, the HBM IP and its AXI3 ports (each lane
keeps INCR bursts of at most 16 beats inside 4 KB and a single ID, which AXI3 slaves accept; WID tied
off), clock crossings, PCIS into HBM, and the host program.

## Image 1: the CL on AWS F2 (DDR4, 15 lanes)

**What it is.** `cl_jpeg/design/cl_jpeg.sv` for AWS's small shell (aws-fpga HDK v2.3.5, shell 0x10212415), one clock
(the shell's `clk_main_a0`, 250 MHz), no HBM, no PCIM, no interrupts:

- The host writes JPEG files into the card's 64 GiB DDR4 through **BAR4** (the shell's PCIS port; a BAR4 offset is a
  DDR4 address).
- It gives each lane a job through **BAR0** (OCL; the register map is in `f2_regs.sv`'s header, version 2).
- Each lane reads its file from DDR4, decodes it with the wide core and writes its pixels back as records. The host
  reads the records over BAR4, or keeps the hash only: the throughput mode, an output area of 0 bytes.
- The DDR4 controller is AWS's `sh_ddr` (AMD's DDR4 IP, AWS's settings), wired as in AWS's examples. Its resets come
  from `rst_main_n` only, and its statistics bus runs through 8 registers each way.
- The global registers hold the ID, VERSION 2, LANES 15 and DW 512, plus:
  - STATUS bit 0: the DDR4 is calibrated. The host must not touch BAR4 before; anything earlier is answered with
    SLVERR and counted in MEM_ERR.
  - COMMIT: the first 8 hex digits of the commit built.
- The virtual LEDs (`fpga-get-virtual-led`) show, from bit 0: DDR4 ready, memory on, any lane busy, any lane done.

**The host's rules on F2** (for the host program, not written yet):
- Check STATUS bit 0 before the first BAR4 access.
- Put each file at a 64-byte-aligned address (mem_lane reads whole beats from its job's address).
- **Pad each file to a whole number of 64-byte beats** with zeros, and **zero each output area once before its first
  job** (full-beat BAR4 writes). The F2 card's DDR4 has ECC, so a write that fills only part of a beat (the last beat
  of a file, the last beat of a job's records) makes the controller read the old contents first. Unwritten memory can
  then report ECC errors.
- Read a job's records up to RECORDS (bytes after them in the last beat are not the job's).

**Bandwidth.** One DDR4 channel gives about 19 GB/s on paper. 15 lanes writing every pixel (4 bytes each as records)
want up to 4 GB/s per lane at 250 MHz, so full-output runs are paced by the memory; the hash-only runs are not (the
lanes read about 0.15 GB/s each). Image 3 (HBM, one channel per lane) removes that limit.

**Placement.** The shell's OCL and PCIS ports sit on the middle die (SLR1), the DDR4 pins on the top die (SLR2):
- `SH_SIDE`, the first register stage of OCL, PCIS and the reset, stays in SLR1.
- The core (`CORE`), its slice to the DDR4 (`DDR_SLC`), `SH_DDR` and its pipes go to SLR2.

So every die crossing runs register to register (`cl_jpeg/build/constraints/small_shell_cl_pnr_user.xdc`).

**Tests here (Verilator, `sim/`).**
```sh
cd boards/aws_f2/sim && make cl HDK=<an aws-fpga v2.3.5 checkout>     # obj_cl (15 lanes), obj_cl2 (2 lanes, a commit stamp)
python3 run_cl_tests.py [--photos]
```

`tb_cl.cpp` simulates the real top level unchanged: `cl_jpeg.sv` with the HDK's `cl_ports.vh`. It plays the host and
AWS's shell on every port, as the shell specification describes them:

- **BAR4 writes** come write-combined: pieces of 1-512 bytes at any alignment, partial byte strobes, never across 4 KB.
  Up to 32 are in flight per direction, the shell's IDs vary, and W data sometimes arrives before its AW.
- **The 8 us limit:** every BAR4 transaction must complete within 2,000 clocks of its valid (the shell's 8 us timeout),
  and must return its own ID.
- **OCL accesses** come one at a time, 100 clocks apart, with AW and W skewed at random.
- **Every channel** has random gaps.
- **The DDR4 model** answers out of order across IDs and interleaves read bursts. It checks every burst: 64-byte
  beats, INCR, aligned, inside 4 KB, IDs of the multiplexer's masters only, wlast on the right beat.
- **Each run also checks:**
  - before the DDR4 is ready: SLVERR, zeros, MEM_ERR counted, the memory untouched;
  - BAR4 at any alignment, 70 KB written and read back in pieces of other sizes;
  - every file arriving intact;
  - the FLR answer and the DDR4 statistics bus through its pipes.
- **The job flow** is `tb_engine.cpp`'s. Each job's hash is compared with the golden image's hash (the F2 host's own
  check), and its records are read back and placed by x and y: from the memory model in full, and over BAR4 for the
  first 2 KB.

**AWS's own test (`cl_jpeg/verif/`).** `cl_jpeg_test.sv` runs in AWS's XSIM testbench on the build machine, before
the DCP build: AWS's shell model, AWS's `sh_ddr` simulation model and the DDR4 DIMM model.
- ID and registers checked.
- The DDR4's calibration started over its statistics bus (register 0x0C written 0, 1, 0, as AWS's own tests do in
  `initialize_ddr()`), then the ready bit polled for at most about 1 ms of simulated time. On the card the shell does
  this when the image is loaded; AWS's shell model does not, and without it the DDR4 never became ready (the first run
  on AWS, 2026-11-03: 85 minutes of a 20 ms wait). The local stand-in `sim/sh_ddr_sim.sv` makes the DDR4 ready after a
  fixed delay instead, which is why the local runs could not catch it.
- Two corpus files (`adp_16x16_q25_420`, `adp_45x37_q30_420_rst2`) written over PCIS, both output areas zeroed (the
  host's rules above), the files read back over PCIS, then decoded at once on lanes 0 and 1.
- Every record read back over PCIS: each pixel exactly once, the hash recomputed = the lane's HASH register = the
  golden image's hash (`verif/tests/cl_jpeg_test_data.svh`, from `verif/scripts/gen_test_data.py`).
- AWS's protocol checkers on the shell's interfaces count as failures.

**Free checks on this machine (`cl_jpeg/local_check.tcl`, Vivado 2026.1, a Kintex UltraScale+ KU5P -2 standing in for
F2's VU47P -2).**
- `elab`: the top level elaborated with the real `cl_ports.vh`, and every cell the placement constraints name present.
- `lane`, `synth`, `place`, `route`: the core with 15 lanes at 4.0 ns.

Each stage runs as its own process, from a clean checkout of one commit (sources checked by
`boards/acorn_cle215/provenance.tcl`).

**What the local check cannot see.** The KU5P is one die without AWS's shell. On the F2's VU47P the core is held in
the top die (SLR2) and AWS's placement directive (`SSI_SpreadLogic_high`) spreads it: in the first AWS build it used 39 %
of SLR2's LUTs but touched 70 % of its CLBs, so the routes were longer. The same paths (`mem_lane`'s byte index
`cur_i`) had +0.254 ns here after placement and -0.722 ns on AWS: about 1 ns apart. Paths that cross between the
dies are not modelled here at all. A local result is therefore a necessary check, not a prediction of AWS's timing.

### Building the image on AWS (the owner's go-ahead first; the cost is given before anything is launched)

1. **Here:** `boards/aws_f2/cl_jpeg/package.sh <commit>` writes `bepjpeg_f2_<8 hex>.tar.gz`. It is that commit's
   `rtl/` and `boards/aws_f2/` plus a file `COMMIT`.
2. **AWS (us-east-1):** launch one r6i.2xlarge (8 vCPUs, 64 GiB; AWS asks for at least 32 GiB) from **FPGA Developer AMI
   1.19.x, Ubuntu 24.04, Vivado 2025.2**. The Marketplace subscription is free; the AMI includes the Vivado licence for
   the VU47P. Allow SSH from one address, no Elastic IP.
3. **Copy and start:** copy the tarball to the instance, unpack it, and inside `tmux` (so a dropped SSH connection does
   not stop it) run `boards/aws_f2/cl_jpeg/build_on_aws.sh`. Its steps:
   - aws-fpga v2.3.5 and `hdk_setup.sh`;
   - the commit stamp;
   - AWS's XSIM test (stops unless "TEST PASSED");
   - the DCP build: `aws_build_dcp_from_cl.py -c cl_jpeg --no-encrypt`; our sources are open; `--place DIRECTIVE`
     sets the placement directive (AWS's default `SSI_SpreadLogic_high`);
   - the gate after placement and physical optimisation (about 70 minutes in): a timing estimate below `--wns-gate`
     (default -0.15 ns) stops the build there, before routing;
   - the timing check: a build that fails timing (`post_route.VIOLATED.dcp`) stops there, and no AFI is made from it
     without the owner's explicit yes.

   It prints the tarball `<tag>.Developer_CL.tar` and its sha256.
4. **Copy back** `~/bepjpeg_f2/logs`, `cl_jpeg/build/reports` and the tarball. They go to
   `/media/developer/HIKSEMI/Vivado/builds/f2_<8 hex>/`, after `mountpoint -q /media/developer/HIKSEMI`.
5. **The AFI.** Upload the tarball to an S3 bucket in us-east-1 (with a logs folder), then:
   `aws ec2 create-fpga-image --region us-east-1 --name bep-jpeg-<8 hex> --description "BEP-JPEG image 1: 15 wide lanes on DDR4, commit <hash>, dcp sha256 <...>" --input-storage-location Bucket=<b>,Key=<folder>/<tar> --logs-storage-location Bucket=<b>,Key=<logs folder>/`
   This works from any machine with the account's credentials. AFI creation is free and takes about an hour on AWS's
   side; `aws ec2 describe-fpga-images --fpga-image-ids <afi-...>` shows when it is `available`.
6. **Terminate the instance** (its disk goes with it). The S3 bucket may stay.

**Cost (2026-11-03 prices, us-east-1):**
- r6i.2xlarge $0.504/h for about 3.5-5 h (setup ~0.5 h, AWS's XSIM test about 4 minutes once the DDR4 is started as
  above, the build 2.5-3.5 h with 15 lanes);
- its disk and public address about $0.03/h;
- S3 a few cents a month;
- AFI creation free.

About $2-3 per attempt. The first build reached the end of placement 70 minutes after it started (synthesis 8 min,
link and opt 12 min, placement 28 min, physical optimisation 21 min): a build whose timing estimate there is clearly
negative should be stopped at that point instead of routed, which saves about an hour: `build_on_aws.sh` does so
since 2026-11-03 (its WNS gate). Running the image needs an f2.6xlarge ($1.98/h) and the F-instance quota of 24 vCPUs
(8 granted as of 2026-11-03).

### First build on AWS (2026-11-03)

One r6i.2xlarge from 10:19 to 14:28 UTC (4.15 h): about **$2.2** in all ($2.09 the instance, $0.09 its disk). No image
was made. Two attempts failed on our mistakes before the third ran (about $1.0 of the $2.2):
- **db65d1b:** AWS's XSIM test waited 20 ms of simulated time for a DDR4 that AWS's shell model never starts (85
  minutes). The test now starts the DDR4 as AWS's tests do (3eb58ef; "AWS's own test" above).
- **3eb58ef:** the test passed, but synthesis stopped in elaboration ("[Synth 8-5809] Error generated from encrypted
  envelope" in `sh_ddr.sv`). AWS's `sh_ddr` also instantiates the IPs `cl_axi_clock_converter` and
  `cl_axi_clock_converter_light`, which our synthesis script did not read; it does since 4d1d7b9
  (`cl_jpeg/build/scripts/synth_cl_jpeg.tcl`).
- **4d1d7b9:**
  - AWS's XSIM test passed (COMMIT 0x4d1d7b94, the DDR4 ready after 24 polls at 31.6 us of simulated time, both
    files decoded = golden);
  - synthesis, placement and physical optimisation completed;
  - after placement WNS -0.989 ns, after physical optimisation **-0.881 ns, TNS -4,134 ns: 15,879 of 708,638
    endpoints of clk_main_a0 failed**, hold -0.245 ns (normal before routing);
  - the route was stopped five minutes in, because routing does not recover 0.9 ns on paths that are 90 % wire.

The same commit's Verilator regressions, from a clean checkout, all passed: CL 3,075/3,075 jobs, lanes 4,920/4,920,
engine 3,690/3,690, CL with the photos 3,147/3,147.

Where the 15,879 endpoints are (a timing analysis of the placed design on the instance; each endpoint counted once,
with its worst path):
- **13,668 in `mem_lane.sv`, the wrapper around each decoder** (every lane; worst -0.742 ns):
  - its byte feed to the decoder: the decoder's `in_ready` into the 512-bit word register `cur`, the byte index and
    the read-FIFO counters, and back (7-14 logic levels; 5,684 endpoints of `cur` alone);
  - its write FIFO: the count into the write enables of the FIFO's distributed RAM (3,424 endpoints, -0.53 ns) and
    into the decoder's output ready (649);
  - its read-address arithmetic: 32-bit `rd_left` into the address and the reservation count (-0.49 ns).
- **98 inside the decoders** (-0.325 ns).
- **About 2,100 in the glue:**
  - 764 from the multiplexer into the host's port: its W-burst queue into the PCIS slice's 577-bit register enables
    is the worst path (-0.881 ns): a ready that is a combination, sent along a long wire;
  - 1,001 of the core's reset, from the shell's die into the register file's wide job registers (-0.448 ns);
  - 300 of the OCL path: its slices between the two dies (94, -0.673 ns) and into the register file (206);
  - 26 in the register file's read multiplexer (-0.515 ns).
- **7 inside AWS's `sh_ddr`**, its statistics path (-0.635 ns), likely the crowding around it.

The reports, the logs, the analysis (`analysis/failing_buckets.txt`) and the checkpoints after synthesis and after
physical optimisation are in `/media/developer/HIKSEMI/Vivado/builds/f2_aws_4d1d7b94/`.

**The changes after it (not yet built on AWS).** Each failing group above, and what changed:
- `mem_lane.sv`:
  - a two-entry register stage on the decoder's input, so `in_valid`, `in_data` and `in_last` are registers and
    `in_ready` reaches nine flip-flops instead of the 512-bit word, the counters and the read FIFO;
  - one on its output, with `px_ready` a register (it fans out widely inside the decoder);
  - the byte count, the room in the output area and in the write FIFO as down-counters with flags;
  - the write into the FIFO one clock after a beat completes;
  - the next read burst's length as a register.
  The lane's clock counts stay within a few dozen clocks of before on the corpus files, and within 30 on the 12 MP
  photos (4.16 million clocks).
- `f2_slices.sv`:
  - `f2_skid` loads its data registers whenever they are free, so a far `s_valid` reaches two flip-flops, not
    hundreds of enables;
  - new links with credits (`f2_link_tx/rx`, and AXI4 / AXI-Lite ports over them): the sender sends only with a
    credit for the receiver's FIFO, and every wire between the two halves leaves a register and enters one (two
    registers in each half, both ways, so that the placer can spread a long distance over them; a 16-entry FIFO keeps
    a beat per clock). OCL and PCIS cross from the shell's die to the core over them; the PCIS slice in the core is
    gone.
- `f2_core.sv`: the reset arrives on one register and goes on through one register per block.
- `f2_regs.sv`:
  - no reset on the job and result registers;
  - writes take effect one clock after the response;
  - reads answer three clocks after the address, each lane's word selected first.
- `f2_axi_mux.sv`: the masters' valids are registered before the round robin.
- Not changed: the decoder (its Huffman loop failed at -0.325 ns, and its output stall from `px_ready` at about
  -0.3 ns) and AWS's `sh_ddr`. Placement is the only lever there; whether they pass is the open question of the next
  build.

The local check of 7b0cc5a (KU5P -2, 15 lanes, post-synthesis estimates at 4.0 ns, against those of 0c688d4, whose
design files the AWS build used):

| paths | 0c688d4: worst slack, levels | 7b0cc5a: worst slack, levels |
|---|---|---|
| all | +0.668 ns, 12 (`rd_left` into the read address) | +1.316 ns, 14 (`wr_addr`'s 64-bit add, 8 of them carry steps) |
| decoder -> lane wrapper | +1.162 ns, 13 (up to 17) | +2.412 ns, 6 |
| lane wrapper -> decoder | +1.353 ns, 11 | +2.112 ns, 7 |
| inside the decoder | +1.415 ns, 9 | +1.404 ns, 8 |
| glue | +2.033 ns, 7 | +1.933 ns, 10 (the multiplexer into `f2_pcis`) |

These estimates know nothing of placement: on AWS the same paths came out about 1 ns slower after placement than
this machine's placed estimate. What they show is the depth taken out of the paths that failed. The elaboration of
the real top level found every cell the placement constraints name. Files:
`/media/developer/HIKSEMI/Vivado/builds/f2_local_7b0cc5a8/` (`levels_vs_0c688d45/`).
