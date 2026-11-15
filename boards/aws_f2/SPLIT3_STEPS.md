# Split 3 on AWS F2: the HBM with Proposal A and the batch engine - the plan

The owner's order (2026-11-03): image 1 = the batch engine on the DDR4 (built, AFI available), image 2 = Proposal A on
the DDR4 (built, AFI available), **image 3 = the HBM with Proposal A and the batch engine (Task A's 15 wide lanes)**,
one HBM port per lane. Asked for on 2026-11-15 ("plan first to reduce money wastage to zero"). This file is the plan;
nothing is built or launched until the owner has decided the points under "Decisions". Like image 2, the design lives on
the local branch `proposals-AB` (it contains Proposal A); this file and the results go on the development branch.

## What AWS's kit and AMD's IP fix (read 2026-11-15)

Sources: the kit 2.3.5 (c34f88e), AWS's IP repository `aws-fpga-resources` at the commit below, the IP's own simulation
sources (readable SystemVerilog and C++). AMD's PG276 could not be fetched (its site is a script application), so the
rules below cite AMD's model code and AWS's own designs instead.

- **The HBM IP is AWS's `cl_hbm`** (AMD `hbm` 1.0 revision 18, generated in Vivado 2025.2) on branch
  `Vivado_2025.2-hdk/common/ip`, **commit 6d32be97** - the one split 2's instance checked out on 2026-11-11.
  `hdk_setup.sh` takes the branch head, so the head is checked just before the launch and again on the instance.
  Its settings (`cl_hbm.xci`): 16 GB in both stacks, **the switch on** (every port reaches all 16 GB), the predefined
  ROW_BANK_COLUMN map (not the "customer address map", whose aliasing bug is AWS errata 1), **ECC off** (no scrubbing,
  no initialisation: reading memory nobody wrote returns data, not errors), byte masks on, DBI on, 32 AXI3 ports at
  **450 MHz**, the monitor APB enabled.
- **Port rules**: 256-bit data, ARLEN/AWLEN 4 bits (1-16 beats) and no WID (the IP's port template); burst size 32
  bytes only ("HBM IP only supports burst size as 32 Bytes", AMD's model `hbmChannel.cpp`), FIXED bursts unsupported,
  INCR supported; pseudo channel = address bits [33:29], 512 MB each (`hbmModel.cpp`: 8-high stacks). AWS's
  `cl_mem_perf`, measured at about 430 GB/s on the cards, drives every port with INCR bursts of up to 16 x 32 bytes.
- **The monitor.** The shell has two HBM monitor APB interfaces (`hbm_apb_*_0/1`, on clk_hbm_ref) that must be wired to
  the IP's `MON_APB` ports, the resets `hbm_apb_preset_n_*` directly with no logic between: "Failing to connect these HBM
  monitor interfaces ... will result in an AFI creation error". AWS's example wrapper does it.
- **AWS's wrapper** `cl/examples/cl_dram_hbm_dma/design/cl_hbm_wrapper.sv`: the IP, its 450 MHz MMCM `cl_hbm_mmcm` on
  clk_hbm_ref, reset synchronisers, a status register (soft reset, both stacks initialised, MMCM locked) and the monitor
  wiring; ports 0..N-1 used, the rest tied off; `AXI4_INTERFACE = 0` takes AXI3 directly. Used unmodified, read from the
  kit by path.
- **Start-up needs no host sequence**: the soft-reset bit powers up 0, so after the shell's reset the APB reset, then the
  450 MHz reset, release; the IP initialises both stacks (`apb_complete_0/1`) and the wrapper raises `o_hbm_ready` in
  clk_main_a0. The host polls that bit before the first HBM access. The soft-reset bit is not offered to the host: it
  resets only the HBM side of the bridges, not the lanes.
- **The DONT_TOUCH workaround (AWS errata 9)** in AWS's own build script applies only at the path
  `WRAPPER/CL/CL_HBM/HBM_PRESENT_EQ_1.HBM_WRAPPER_I/HBM_CORE_I/inst`: our CL keeps exactly that hierarchy (an instance
  `CL_HBM`, a generate block `HBM_PRESENT_EQ_1`, AWS's wrapper as `HBM_WRAPPER_I`); otherwise it silently does nothing.
  The synthesis script reads `cl_hbm.xci` and `cl_hbm_mmcm.xci` with the example's `read_ip` lines, copied verbatim.
- **Clocks.** The example's constraints put clk_main_a0, clk_hbm_ref and the 450 MHz clock in asynchronous clock groups;
  we do not copy that (a clock group would also void our FIFOs' max-delay bounds). The IP's fabric logic runs on the
  APB clock only (100 MHz); its AXI ports go straight into the hard HBM block. AWS's wrapper crosses clocks in three
  places: two AMD XPM reset synchronisers (they carry their own constraints), one two-flip-flop synchroniser of
  `apb_complete` (100 -> 250 MHz) and the MMCM's safe start (the example's false path). Those get cell-scoped exceptions
  matching AWS's intent; our own crossings get cell-scoped max-delay bounds of the faster clock's period. Each clock is
  selected by its MMCM's output pin: split 2's `-include_generated_clocks clk_hbm_ref` would now also catch 450 MHz.
- **Several MMCMs on clk_hbm_ref** are AWS's own topology (`cl_mem_perf` feeds AWS_CLK_GEN's MMCMs and its HBM MMCM from
  it; the shell marks the clock for cascading), so split 2's 125 MHz controller MMCM can stay.
- **No DDR4**: AWS requires `sh_ddr` in every CL; without DDR it is instantiated with `DDR_PRESENT(0)`
  (`Supported_DDR_Modes.md`), so no DDR4 controller is built and AWS's XSIM test needs no DDR4 start.
- **Simulation.** AWS's XSIM has no fast HBM model: its HBM tests need VCS or Questa (`Makefile.tests`: "XSIM does not
  support HBM"); AMD's model is the HBM controller primitive with a DRAM responder (see "The real HBM model" below).
  AWS's `cl_mem_perf` keeps the HBM out of its XSIM runs with a define (`DONT_COMPILE_HBM`); split 3 does the same in
  AWS's paid XSIM test, so the instance never elaborates the real model.

## The design (on `proposals-AB`)

- **CL `cl_jpeg_hbm`** (`boards/aws_f2/cl_hbm3/`): `cl_split.sv`'s shell side (OCL and PCIS slices, the credit links
  between the dies, `shreg_extract` off), `sh_ddr` with `DDR_PRESENT(0)`, the core, the HBM block.
- **HBM ports** (17 of 32): 0-14 the batch lanes (`mem_lane.sv`, DW 256, bursts of up to 16, inside 4 KB, already
  AXI3-legal), 15 Proposal A's shared reader (DW 256), 16 the host (PCIS: 512-bit AXI4 -> 256-bit AXI3, bursts split to
  16 beats). Lane p's files and output in pseudo channel p (512 MB at p x 512 MB), A's files in PC 15; the host reaches
  every PC through the switch.
- **A bridge per port** (`f2h_axi3_bridge.sv`, new): the five AXI channels through `jpeg_cdc_fifo` (split 2's FIFOs),
  250 or 125 MHz on the lane's side, 450 MHz on the HBM side with one register stage at the port; 34-bit addresses
  checked. The 450 MHz side stays in SLR0 next to its port.
- **Clocks**: clk_main_a0 250 MHz (shell ports, lanes), A's controller 125 MHz (split 2's MMCM on clk_hbm_ref), 450 MHz
  (AWS's `cl_hbm_mmcm`), clk_hbm_ref 100 MHz (HBM reference, APB, monitor).
- **Registers (OCL)**: split 2's front (ID, VERSION 4, CLK_MHZ, STATUS with HBM ready and the MMCMs' lock, COMMIT, XERR,
  MEM_ERR), then windows for image 1's lane registers (`f2_regs.sv`), A's registers (`f2s_cregs`) and AWS's HBM status
  register (read-only).
- **Output**: the batch lanes keep both modes per job (image 1): hash only (output area 0 bytes) or every pixel written
  into HBM and read back by the host over PCIS; A hashes only (its lanes have no writer).
- **Floorplan**: from measured block sizes (step 1), not assumed. Split 1's 15 lanes were about 170k LUTs and filled
  70 % of SLR2's CLBs (SSI spreading); the CL's part of SLR0 is about 25 clock regions against SLR2's 32, so the 15
  lanes plus A do not fit SLR0 at a routable density. Rule: only 250 and 125 MHz signals cross an SLR (on the proven
  credit links); the 450 MHz logic and the bridges' far sides sit in SLR0 by their ports.
- **PCIe IDs**: new for image 3 (proposed 0xF0A3/0x1D0F, 0x1D53/0xFEDC).

## Decisions for the owner (defaults in bold)

1. Lanes: **15 batch lanes + Proposal A's 8 (as images 1 and 2, so the three images compare)**, or more batch lanes
   (HBM has 32 ports; more area and build time).
2. A's controller clock: **125 MHz (split 2's MMCM)**, or 100 MHz straight from clk_hbm_ref (simpler, 12-20 % slower A).
3. Money cap: **$3** (estimate below: about $1.4-1.7 for one build that meets timing).
4. **New PCI IDs 0xF0A3/0x1D53** (or keep one of the earlier pairs).
5. **Proposal A's sources to the private AWS instance, the private S3 bucket and a private AFI** again (as for split 2).

## Free steps, in order (each must pass before the next)

0. Merge development into `proposals-AB` (`SPLIT2_STEPS.md` and the README's F2 sections conflict as added on both
   sides: take development's text).
1. Block sizes first (KU5P -2, synthesis): one batch lane at 256 bits, Proposal A at 256 bits -> the floorplan, which
   decides where the links go (RTL), before the rest is written.
2. The bridge in Verilator against our model of an HBM port that asserts every rule above (and WRAP / FIXED absent,
   no 4 KB or pseudo-channel crossing, write data in address order), at 250:450 and 125:450 with random stalls on both
   sides. If AMD's real model runs (below), the same stimulus against it too.
3. The host path (PCIS 512 -> 256 bits, bursts split) against the same model; partial strobes, 1-512-byte writes.
4. Proposal A at 256 bits (its reader has run at 128 and 512 only): corpus, photos, restart copies, 4:2:0 copies,
   fallback, all = libjpeg 9e.
5. The batch lane at 256 bits through the bridge and the HBM model: the lane regression (4,920 jobs).
6. The whole CL in Verilator: AWS's wrapper unmodified with our models of `cl_hbm` (32 ports, switch, init delay,
   the rules above; ports generated from the IP's `.veo`) and `cl_hbm_mmcm` beneath it - if Verilator 5.003 compiles
   the wrapper (it has an unpacked struct and an interface port: linted first; if not, the Verilator runs model at the
   `CL_HBM` level and the 4-state run of step 8 must drive all 17 ports through the real wrapper); the shell model of
   images 1 and 2; files written over PCIS; 15 lanes (hash-only and full-output jobs, the output read back and compared
   with libjpeg 9e) and A (split, whole, restart, aborts) together; the photos; both A clock variants.
7. Local Vivado (KU5P -2, the IP and AWS's MMCM as black boxes): elaboration (every cell the placement constraints
   name, `CL_HBM/HBM_PRESENT_EQ_1.HBM_WRAPPER_I/HBM_CORE_I` present, the monitor wired straight through), synthesis
   (every crossing in our cells under its bound, AWS's cells only under AWS's exceptions; no SRLs in the links), the
   scoped link as the HDK links it, and placement: **the bridges' 450 MHz side at least +0.45 ns at 2.222 ns** (split
   2's decoders were +0.503 ns placed here and +0.055 ns routed on AWS: about 0.45 ns of optimism). If it misses that
   margin, the owner decides before any launch.
8. 4-state xsim of the real top level (Xilinx's MMCM and BUFG models, AWS's real `cl_hbm_mmcm` model, AWS's wrapper):
   no X in any register read, decodes = golden, every port used.
9. AWS's XSIM test, in the exact configuration of the instance (the HBM model define on), run to completion against our
   stand-in with AWS's task headers.
10. The gates proven here on a passing design and on deliberately broken ones (the monitor reset through a register,
    the hierarchy renamed); the tarball (`package.sh`); the build script; `/root/aws_f2_tools/image3_build.sh` (state3,
    key and security group `bepjpeg-build3`, S3 prefixes `dcp3/` and `logs3/`).

## The paid run (one r6i.2xlarge; terminated in every case)

- G0: just before the launch, the IP branch head = 6d32be97 (`git ls-remote` from the laptop); on the instance, the
  submodule's commit = 6d32be97 and both `.xci` files present before XSIM starts. Else stop.
- G1: AWS's XSIM test passes (about 20 min, as split 2 with the IP compile).
- G2, new, after synthesis and before placement, in a second Vivado beside the build on `post_synth.dcp`: AWS's log line
  "HBM found, setting DONT_TOUCH to 0"; `hbm_apb_preset_n_0/1` reach `MON_APB_0/1_PRESET_N` with no cell between; every
  monitor output driven - any failure or script error stops the build (an AFI would be refused). That `HBM_CORE_I` is
  the real IP (its hard block present) cannot be tried here (no VU47P): it reports only.
- G3: after logic optimisation WNS >= -0.5 ns; G4: after placement WNS >= -0.15 ns (as splits 1 and 2).
- After routing, if met: the crossing check on the routed design (every crossing of our cells bounded, none of ours
  inside an exception), fetch, terminate, AFI (free), poll until available.
- **Cost**: the instance about $0.53/h. Split 1 (15 lanes) built in 1 h 19 min, split 2 (8 lanes + controller) in
  1 h 11 min; split 3 has both plus the HBM, so about 2-2.5 h, plus 25 min of setup and XSIM: **about $1.4-1.7** for a
  build that meets timing, about $0.8 if a gate stops it at placement. No second paid attempt without the owner's yes.

## Not covered before the card

The real HBM: AWS's XSIM does not run it, and AMD's model needs more memory than this laptop has free (below). Our
model follows AMD's model code and AWS's proven traffic; the first contact with the real HBM is the run on the card (a
host program and the F-instance quota of 24 vCPUs first, each after the owner's go-ahead).

## The real HBM model (2026-11-15)

AMD's model (the IP's simulation sources at 6d32be97, compiled here with Vivado 2026.1 in 9 s) is the encrypted HBM
controller primitive (`secureip`) with a DRAM responder. Elaborating it alone was stopped by its 10 GB memory cap (10.5
GB at 13 minutes); retried in the owner's idle window (performance mode) with a 12.5 GB cap: stopped by that cap after 26 minutes,
in its code generation (peak 12.48 GB). It does not fit this laptop (15 GB); so no real-model run before the card.
Files: `/root/aws_f2_tools/local/hbm_sim/` (the fetcher, the smoke testbench generator, the run script; outside the
repository).
