# Split 2 on AWS F2: Proposal A on the DDR4 - the steps

The owner's order (2026-11-03): 1) DDR4 with the batch engine (Task B), 2) DDR4 with Proposal A, 3) HBM with
Proposal A and the batch engine. The owner's goal for 1 and 2: "compare split 1's decoder time on F2 with split 2's".

This file lists what split 2 needs, in order, so that no money is spent on a run that a free check could have
stopped. It comes from split 1 (`README.md`: "First build on AWS", "Second build on AWS"). Nothing on AWS is
started without the owner's go-ahead and a cost given first.

## Decisions (owner, 2026-11-11)

The owner approved the plan of 2026-11-11 ("Cap of $2 ... proceed"). Where it differs from Step 1 below (written on
11-03), this section holds.

1. **Clocks.** A's controller (pass 1, the reader, the composers) gets its own clock. The 8 lanes' decoders stay on
   `clk_main_a0` (250 MHz).
   - **125 MHz from an MMCM in the CL** if the local estimate (below) gives the controller, with the 512-bit reader, at
     least +1 ns at 8 ns. Otherwise **`clk_hbm_ref` (100 MHz) directly**, with no MMCM.
   - The MMCM takes `clk_hbm_ref` as its input, as AWS's own clock generator does (`aws_clk_gen.sv`, used by
     `cl_mem_perf`).
   - Both shell clocks come from MMCMs inside the shell (`IO_SHIM/MMCM_CLK_HBM_REF`, `IO_SHIM/RL_CLKS/MMCM_CLK_MAIN_A`),
     so a CL MMCM on either one is a cascade. AWS's files show only the one on `clk_hbm_ref`: `mmcm_cascade.xdc`, whose
     read is commented out in v2.3.5's `build_level_1_cl.tcl`.
   - The small shell does run `clk_hbm_ref`. In split 1's build (0aa3cd6, `post_route_timing.rpt`) it comes in on pin
     BJ4, goes through the shell's MMCM_X0Y2 and clocks 232 of the shell's flip-flops.
   - Not AWS_CLK_GEN: it needs the SDA port, more IPs, and a host call to release the resets.
   - Every crossing between the two clocks goes through `jpeg_cdc_fifo`, constrained as on the Acorn
     (`set_max_delay -datapath_only` between the two clocks), with no clock group on that pair.
2. **Pixels:** hash only.
3. **Lanes:** P = 8.
4. **Width:** the reader at 512 bits, in bursts of 4 beats: 256 bytes, the same as the Acorn's 16 x 16 bytes.
5. **Branch:** the development branch is merged into proposals-AB, and split 2 is built from a proposals-AB commit.
   Nothing is pushed.
6. **Proposal A's sources on AWS** (a private instance, the private bucket, a private AFI): asked again with the launch
   quote.
7. **Money:** at most **$2** for split 2 on AWS.
   - No second build without the owner's yes, and a fresh quote before the launch.
   - $2 covers a build stopped by the gate (~$0.7) plus a full build (~$0.9), or two full builds only just.

**Gates before any money is spent.** If one fails, stop and ask the owner.
- Right after the merge, A alone on the KU5P (out of context, after synthesis, the two clocks declared unrelated so
  that the crossings do not hide the rest):
  - the lanes' side at 4.0 ns: at least +1.3 ns. The resume decoder has never been timed on UltraScale+. Split 1 had
    +1.3 ns overall and +1.4 ns inside the decoder after synthesis, and ended at +0.015 ns on AWS.
  - the controller at 8 ns: at least +1 ns, else 100 MHz.
- If the MMCM is used: its lock run in local xsim, to size the AWS test's wait.
- The full CL's local check: every path between the two clocks under the max-delay constraint.

**The prediction behind the clock choice.** Planning estimates of 2026-11-11:
- split 2: `tb/obj_splittop8` of 2026-10-13 (P = 8, DW = 128), the testbench's memory without row-switch cost;
- split 1: its own simulation of 0aa3cd6.

| photo (12 MP) | split 1: one lane per photo, 250 MHz | split 2, controller 100 MHz | 125 MHz | 250 MHz (limit) |
|---|---|---|---|---|
| IMG20260716020409.jpg (1.7 MB) | 15.30 ms | 6.16 ms | 5.44 ms | 4.03 ms |
| adapter.jpg (3.5 MB) | 24.20 ms | 11.39 ms | 9.12 ms | 5.87 ms |

- These are times per photo. Split 1 decodes 15 photos at once, so it stays ahead in photos per second.
- Pass 1 is 51-64 % of split 2's time. It runs on the controller's clock, at about 0.6 byte per clock per skimmer.
- The estimates check out against measurements:
  - pass 1's clocks here equal the Acorn board's (732,940 against 732,974 on adapter.jpg);
  - the one-lane decode equals split 1's simulation to within 2 clocks.

## Where things stand (2026-11-03)

- Split 1: the image is built (commit 0aa3cd6, timing met at 250 MHz with +0.015 ns, AFI afi-0385ad594097d39f3 /
  agfi-0db16f77a44ec64f8). It has not run on an F2 card: there is no host program yet, and an f2.6xlarge needs an
  F-instance quota of 24 vCPUs (8 granted).
- Proposal A lives on the local branch `proposals-AB` (worktree `BEBCL-JPEG-proposals`), which is never merged
  into the other branches, exported or pushed. Its decoder: `rtl/jpeg_split_top.sv` (pass 1, then P lanes on one file),
  `jpeg_split_rd.sv` (one AXI4 read port for everything), `jpeg_split_lane.sv`, `jpeg_split1.sv`. On the Acorn: P = 8,
  AXI data 128 bits, the controller in the DDR3 controller's clock (100 MHz), the lanes' decoders in their own clock
  (150 MHz); pixels hashed, not stored; corpus 66/66 and photos 12/12 in simulation, 16/16 on the board.
- `proposals-AB` does not have the F2 CL yet: it is 20 commits behind the development branch (the CL, the links,
  the build scripts of 2026-11-03).
- The tools from split 1 are kept outside the repositories in `/root/aws_f2_tools/` (see its `README.txt`):
  - the AWS steps `image1_build.sh`;
  - the local checks (`local/`);
  - the analysis scripts for a failed build (`analysis/`);
  - aws-fpga v2.3.5 (`aws-fpga/`, the HDK's port list and simulation headers).

## What went wrong on split 1, and what now prevents it

| what happened (2026-11-03) | lost | what prevents it |
|---|---|---|
| AWS's XSIM test waited 20 ms of simulated time for a DDR4 that AWS's shell model never starts (85 min) | ~$0.90 | the test starts the DDR4 over its statistics bus as AWS's tests do (step 3); every wait in a paid simulation ends in about 1 ms of simulated time (AWS's DDR4 model runs ~4 minutes per simulated ms) |
| synthesis stopped in elaboration: `sh_ddr` also needs `cl_axi_clock_converter` and `_light` | ~$0.13 | the CL's synthesis script reads all three IPs (copy `cl_jpeg/build/scripts/synth_cl_jpeg.tcl`) |
| the instance idle for 34 minutes while a local check finished | ~$0.30 | every local check is finished before the launch (step 4) |
| timing failed at placement (-0.88 ns; the local check had said +0.25) | ~$0.79 | the design rules below; the gate in `build_on_aws.sh` stops a build after placement if WNS < -0.15 ns (saves about an hour); placement `ExtraTimingOpt` |

## Step 1. The owner's decisions (taken 2026-11-11: see "Decisions" above; the options as written on 11-03)

1. **Clocks.** F2's main clock is 250 MHz, and the DDR4's AXI port runs on it. A's controller (pass 1, the reader,
   the lanes' composers) ran at 100 MHz on the Acorn; its pass-1 paths needed about 9 ns. Two ways:
   - (a) A's controller on a slower clock from AWS's clock generator (`aws_clk_gen`; for example 125 MHz:
     `clk_extra_a1` with recipe A1, or `clk_extra_b1` with B0), with a clock converter to the DDR4 port;
   - (b) pipelining pass 1 for 250 MHz, which is much more work.

   Recommended: (a). The lanes' decoders at 250 MHz (`clk_main_a0`), as split 1's lanes, so that the two decoder
   times compare at the same lane clock. Recipes: `hdk/docs/Clock_Recipes_User_Guide.md`.

   A catch with AWS's clock generator: its clocks are held low until its PLL locks. The host must poll
   `MMCM_LOCK_REG` and then release the resets through `SYS_RST_REG` (`hdk/docs/AWS_CLK_GEN_spec.md`). The host
   program and the XSIM test must both do this.
2. **Pixels.** Hash only (as on the Acorn), or stored? 8 lanes' RGB (4-11 GB/s) fits the DDR4. Recommended: hash
   only for the time comparison (split 1's throughput runs hash too), stored later if wanted.
3. **Lanes.** P = 8 (tested; P must be a power of two) or 16 (the VU47P has room). Recommended: 8 first.
4. **Width.** `jpeg_split_rd` at 512 bits (the DDR4's width; its DW is a parameter) or 128 bits with a width
   converter. Recommended: 512, with A's tests rerun at that width.
5. **The branch.**
   - Merge the development branch into `proposals-AB` first. That direction is allowed and was done before (6e6188c).
   - Build split 2 from a `proposals-AB` commit. Its tarball goes to a private instance; the AFI and the S3 bucket
     are private.
   - Nothing is pushed.

## Step 2. The design (on `proposals-AB`)

- A new CL folder `boards/aws_f2/cl_split/`, made like `cl_jpeg/`:
  - `design/cl_split.sv` with the HDK's `cl_ports.vh`;
  - `build/scripts/synth_cl_split.tcl` (the three IPs);
  - the constraints (the shell's side in SLR1, the core in SLR2);
  - `verif/` (AWS's XSIM test);
  - `build_on_aws.sh` (the stop-check after placement and `--place`), and `package.sh`.
- Reuse from split 1:
  - `f2_shell_side` and the links with credits (`f2_slices.sv`) for OCL and PCIS between the dies;
  - `f2_pcis` (the host's DDR4 port, SLVERR until the DDR4 is ready);
  - `f2_axi_mux` with two masters: A's reader (reads only) and PCIS;
  - the reset tree;
  - a register file in the pattern of `f2_regs.sv`:
    - ID, VERSION, COMMIT, STATUS (DDR4 ready), MEM_ERR, SCRATCH;
    - A's job: base, length, `lp_req`, `force_whole`, `no_rsplit`, start;
    - A's results: done, error bits, fallback, `p_eff`, MCUs, the clocks of pass 1, pass 2 and in all, hash, pixels;
    - per lane through `lane_sel`.
- The rules that split 1's timing taught (apply them from the start, not after a failed build):
  - registers on both sides of every decoder (`in_*` and `px_*`), as in `mem_lane.sv` since 7b0cc5a;
  - no ready that is a combination sent along a long wire into a wide register's enables: a link with credits
    (`f2_link_tx/rx`) for every long distance and every crossing between the dies;
  - counters and comparisons kept as registers (down-counters with flags), not 32-bit compares inside a handshake;
  - the reset through one register per block, and none on data registers;
  - `(* shreg_extract = "no" *)` on registers meant to spread a distance: in split 1 Vivado merged the links'
    registers into one shift-register cell, so that hop was not split;
  - outside the decoders, no path deeper than about 6 logic levels in the local post-synthesis estimate (the paths
    that failed on AWS had 7-14; the estimate knows nothing of placement, so depth is what it can check);
  - the clock crossings between A's controller, the lanes and the DDR4 port with their constraints in the CL's
    timing XDC (for example `set_max_delay -datapath_only` on the crossing FIFOs' paths).

## Step 3. The tests (free), in this order

1. A's own simulations at F2's parameters (DW = 512, P = 8, AW of the DDR4): `tb_split_rd`, `tb_split_top`,
   `tb_split_core`, `model/split/run_split_top.py` (corpus, photos, the fallback cases).
2. The whole CL in Verilator at its real top level, as `sim/tb_cl.cpp` does for split 1: the shell's behaviour on
   OCL and PCIS, the DDR4 model behind `sim/sh_ddr_sim.sv`. Make `sh_ddr_sim.sv` require the statistics-bus start
   (0x0C written 0, 1, 0) before it says ready, so that a test without it fails here, not on AWS.
3. AWS's XSIM test, written like `cl_jpeg/verif/tests/cl_jpeg_test.sv`:
   - start the DDR4 over the statistics bus (`tb.poke_stat(.addr(8'h0c), .intf("ddr"), .data(0, then 1, then 0))`);
     with the MMCM (Decisions, 1), its lock bit polled first (a wait sized from the local xsim run);
   - poll for at most about 1 ms of simulated time, and end at once on a failed precondition;
   - load files over PCIS, zero the output areas, read them back;
   - decode a corpus file split and one whole (`force_whole`); check the hash against the golden one.

   Then compile it locally with Vivado's simulator against the stand-in testbench, which has AWS's task headers
   (`/root/aws_f2_tools/local/xsim_mock/`), and compile and elaborate the whole CL with xvlog/xelab
   (`/root/aws_f2_tools/local/xsim_cl/`).
4. Local Vivado (`/root/aws_f2_tools/local/run_local_check.sh <commit>`, from a clean checkout):
   - the elaboration of the real top level: every cell the placement constraints name must exist;
   - the core's synthesis, and its post-synthesis depth (`core_levels.tcl`, `compare.py`).
5. A clean checkout of the commit to be built:
   - all the regressions, for the record (`run_clean_sims.sh`);
   - `package.sh <commit>`, then check the tarball: the `COMMIT` file, the CL's files, its sha256.
6. The cost to the owner (below), then the owner's yes.

## Step 4. The AWS run (the sequence of split 1's second build)

1. `image1_build.sh launch ami-069f868732bb588dc` (FPGA Developer AMI 1.19.2, Vivado 2025.2; r6i.2xlarge, 200 GB
   gp3, SSH from this machine only). Copy the script to `image2_build.sh` first and change its names and the AFI's
   description.
2. At once: `sudo shutdown -h +420` on the instance, and read it back with `shutdown --show`. That is a stop, not a
   termination: the disk bills until the instance is terminated.
3. `start <tarball> --place ExtraTimingOpt` (the gate's default -0.15 ns). Then a watcher that ends by itself (ssh
   plus `tmux has-session` every 5 minutes, capped).
4. Split 1's times, for comparison:
   - setup 2 min;
   - AWS's XSIM test 8 min (with the first compile of AWS's simulation IP);
   - synthesis 9 min, link and opt 12, placement 30, physical optimisation 5, routing 18;
   - about 1.5 h in all, about $0.82.
5. At the end of physical optimisation (`Writing post-phy_opt` in `logs/dcp_build.log`), check the WNS by hand. If
   it is clearly negative and the script has not stopped the build, stop it by hand.
6. If timing fails:
   - fetch the reports, the logs and the checkpoints after synthesis and after physical optimisation;
   - run `/root/aws_f2_tools/analysis/analyse_post_phys_opt.tcl` and `analyse_buckets.tcl` on the instance (the VU47P
     is not in the free licence; about 15 minutes);
   - terminate. No AFI without the owner's yes.
7. If timing is met:
   - fetch, and check the tarball's sha256;
   - **terminate first**: the AFI does not need the instance;
   - from this machine: `afi` (the private S3 bucket), then poll `aws ec2 describe-fpga-images` until
     `available` (free).
8. Record the launch and termination times, the dollars and the AFI's IDs (README, ROADMAP, memory).

**Cost (2026-11-03 prices).**
- An r6i.2xlarge is $0.504/h plus about $0.02/h for its disk.
- A build that meets timing at its first try: about $0.8-1.0.
- One stopped by the gate after placement: about $0.7 (about 80 minutes with the analysis).
- AFI creation is free; S3 costs under a cent a month.

## Step 5. The runs on the F2 card (for splits 1 and 2; not done yet)

- **The quota:** an f2.6xlarge (24 vCPUs, one FPGA; $1.98/h) needs the F-instance quota raised from 8 to 24 vCPUs.
  The owner requests it.
- **A host program** (C, AWS's FPGA SDK):
  - `fpga-load-local-image -S 0 -I <agfi>`;
  - the registers over BAR0 (OCL), the files and results over BAR4 (PCIS);
  - the host's rules for the ECC DDR4: files padded to 64-byte beats, output areas zeroed before a job;
  - for split 2: the STATUS bits first (DDR4 ready; the controller's clock locked and running).
- **The comparison:** decoder time per photo, at the same lane clock. For split 1: one photo per lane, 15 at once.
  For split 2: one photo over 8 lanes. The hashes are checked against libjpeg 9e's images; the comparison uses the
  same photos.
- **Cost:** the instance only while loading and running (about $2/h); terminate at the end.
