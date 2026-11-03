// f2_regs.sv - the register file of the F2 harness (ROADMAP.md, Task B): an AXI-Lite slave (on F2 the
// shell's OCL port, AppPF BAR0) through which the host gives each lane (mem_lane.sv) its jobs and reads
// their results. Separate from the lanes, so that another input path can replace the lanes' memory side
// without changing the host's view.
//
// Register map (byte addresses, 32-bit registers; other addresses read 0 and ignore writes; byte strobes
// are ignored: whole words are written):
//   0x000 ID        0x4A504547 ("JPEG")              0x004 VERSION   2
//   0x008 LANES     NL                               0x00C DW        the lanes' AXI data width in bits
//   0x010 CLOCK_LO  free-running clock count, low word; reading it latches the high word for CLOCK_HI
//   0x014 CLOCK_HI  the high word latched by the last CLOCK_LO read
//   0x018 DONE_LO   bit i: lane i is done (lanes 0-31)   0x01C DONE_HI   lanes 32-63
//   0x020 BUSY_LO   bit i: lane i is busy                0x024 BUSY_HI
//   0x028 SCRATCH   read / write (the host's first check of the path)
//   0x02C STATUS    bit 0: the memory is ready (on F2: the DDR4 is calibrated); the host must not touch the
//                   memory (on F2: BAR4) before
//   0x030 COMMIT    the first 8 hex digits of the source commit the design was built from (0: not stamped)
//   0x034 MEM_ERR   memory accesses of the host answered with an error because the memory was not ready
// Lane i at 0x100 + 0x80 * i:
//   +0x00 IN_ADDR_LO  +0x04 IN_ADDR_HI  +0x08 IN_LEN  +0x0C OUT_ADDR_LO  +0x10 OUT_ADDR_HI  +0x14 OUT_MAX
//         the next job (read / write; the lane samples them when it accepts a start, so the host may
//         write the next job while one runs)
//   +0x18 TAG         read / write: the next job's tag (any value)
//   +0x1C CTRL        write: bit 0 start, bit 1 abort (mem_lane.sv, job_abort)
//                     read: {starts ignored because the lane was busy [31:16], starts accepted [15:0]}
//   +0x20 STATUS      bit 0 busy, bit 1 done, bit 2 records dropped (out_max), bit 3 AXI error,
//                     bit 4 aborted, bits 28:16 the decoder's error bits
//   +0x24 RUN_TAG     the tag of the last accepted start: the job the results below belong to
//   +0x28 CYCLES  +0x2C IN_WAIT  +0x30 OUT_WAIT  +0x34 PIXELS  +0x38 RECORDS  +0x3C SIZE {height, width}
//   +0x40 HASH_LO  +0x44 HASH_HI
//   +0x48 T_START_LO  +0x4C T_START_HI   the clock count when the start was written
//   +0x50 T_DONE_LO   +0x54 T_DONE_HI    the clock count when done reached the register file
// Results stay until the lane accepts the next start. One write and one read are handled at a time; a write
// takes effect one clock after its response is given (its decoding is registered first), a read answers three
// clocks after its address is accepted (each lane's register is selected first, then the lane). The job and
// result registers have no reset (the host writes a job before starting it; results are read after a job);
// only the control state is reset (2026-11-03: the reset of 15 lanes' job registers failed timing on the F2).
// The lanes may sit a few registers away: a start goes out as a pulse with the job, and the lane answers
// with acc (the start was accepted) or ign (the lane was busy); the start's tag and time are kept here
// until that answer, so the bookkeeping is exact whatever the delay (one start per lane in flight: the
// next CTRL write comes many clocks later).
module f2_regs #(
  parameter int          NL     = 4,         // lanes, 1-64
  parameter int          DW     = 512,       // the lanes' AXI data width (reported in DW)
  parameter int          ALW    = 16,        // AXI-Lite address bits used (0x100 + 0x80 * NL must fit)
  parameter logic [31:0] COMMIT = 32'h0
) (
  input  logic                  clk,
  input  logic                  rst,
  // AXI-Lite slave
  input  logic                  s_awvalid,
  output logic                  s_awready,
  input  logic [ALW-1:0]        s_awaddr,
  input  logic                  s_wvalid,
  output logic                  s_wready,
  input  logic [31:0]           s_wdata,
  input  logic [3:0]            s_wstrb,
  output logic                  s_bvalid,
  input  logic                  s_bready,
  output logic [1:0]            s_bresp,
  input  logic                  s_arvalid,
  output logic                  s_arready,
  input  logic [ALW-1:0]        s_araddr,
  output logic                  s_rvalid,
  input  logic                  s_rready,
  output logic [31:0]           s_rdata,
  output logic [1:0]            s_rresp,
  // global status
  input  logic                  mem_ready,
  input  logic [31:0]           mem_err,
  // the lanes
  output logic [NL-1:0]         start,
  output logic [NL-1:0]         job_abort,
  output logic [NL-1:0][63:0]   in_addr,
  output logic [NL-1:0][31:0]   in_len,
  output logic [NL-1:0][63:0]   out_addr,
  output logic [NL-1:0][31:0]   out_max,
  input  logic [NL-1:0]         acc,         // the lane accepted a start (pulse)
  input  logic [NL-1:0]         ign,         // the lane ignored a start: it was busy (pulse)
  input  logic [NL-1:0]         busy,
  input  logic [NL-1:0]         done,
  input  logic [NL-1:0][12:0]   res_err,
  input  logic [NL-1:0]         res_ovf,
  input  logic [NL-1:0]         res_axi_err,
  input  logic [NL-1:0]         res_abort,
  input  logic [NL-1:0][31:0]   res_cycles,
  input  logic [NL-1:0][31:0]   res_in_wait,
  input  logic [NL-1:0][31:0]   res_out_wait,
  input  logic [NL-1:0][31:0]   res_pixels,
  input  logic [NL-1:0][31:0]   res_records,
  input  logic [NL-1:0][63:0]   res_hash,
  input  logic [NL-1:0][15:0]   res_w,
  input  logic [NL-1:0][15:0]   res_h
);
  localparam int LB = (NL > 1) ? $clog2(NL) : 1;
  assign s_bresp = 2'b00;
  assign s_rresp = 2'b00;

  logic [63:0]          clock_cnt;
  logic [31:0]          clock_hi_l, scratch;
  logic [NL-1:0][31:0]  tag_r, tag_p, run_tag;
  logic [NL-1:0][15:0]  n_acc, n_ign;
  logic [NL-1:0][63:0]  t_p, t_start, t_done;
  logic [NL-1:0]        done_q;
  logic [63:0]          done64, busy64;
  always_comb begin : p_masks
    integer i;
    done64 = '0; busy64 = '0;
    for (i = 0; i < NL; i = i + 1) begin done64[i] = done[i]; busy64[i] = busy[i]; end
  end

  // ---- write: address and data together, then the response; the decoded write is registered, then done
  logic           w_glob, w_lane;
  logic [LB-1:0]  wl;
  logic [ALW-1:0] w_off;
  assign w_glob = (s_awaddr < ALW'(32'h100));
  assign w_off  = s_awaddr - ALW'(32'h100);
  assign w_lane = !w_glob && (32'(w_off >> 7) < 32'(NL));
  assign wl     = LB'(w_off >> 7);
  logic wr_en;
  assign wr_en     = s_awvalid && s_wvalid && !s_bvalid;
  assign s_awready = wr_en;
  assign s_wready  = wr_en;
  logic           we_q, wglob_q, wlane_q;
  logic [LB-1:0]  wl_q;
  logic [4:0]     wf_q;                          // the lane's register: offset [6:2]
  logic [5:0]     wg_q;                          // the global register: address [7:2]
  logic [31:0]    wd_q;
  always_ff @(posedge clk) begin
    we_q <= !rst && wr_en;
    wglob_q <= w_glob; wlane_q <= w_lane; wl_q <= wl; wf_q <= w_off[6:2]; wg_q <= s_awaddr[7:2]; wd_q <= s_wdata;
  end

  always_ff @(posedge clk) begin : p_ctrl     // the control state (reset)
    integer i;
    start <= '0; job_abort <= '0;
    if (rst) begin
      s_bvalid <= 1'b0; clock_cnt <= '0; scratch <= '0; n_acc <= '0; n_ign <= '0; done_q <= '0;
    end else begin
      clock_cnt <= clock_cnt + 64'd1;
      if (s_bvalid && s_bready) s_bvalid <= 1'b0;
      if (wr_en) s_bvalid <= 1'b1;
      if (we_q && wglob_q && wg_q == 6'h0A) scratch <= wd_q;
      if (we_q && wlane_q && wf_q == 5'h07) begin start[wl_q] <= wd_q[0]; job_abort[wl_q] <= wd_q[1]; end
      // the lane's answer to a start (it comes after the start, with the lane's own decision)
      for (i = 0; i < NL; i = i + 1) begin
        if (acc[i]) n_acc[i] <= n_acc[i] + 16'd1;
        if (ign[i]) n_ign[i] <= n_ign[i] + 16'd1;
        done_q[i] <= done[i];
      end
    end
  end
  always_ff @(posedge clk) begin : p_data     // the jobs and the bookkeeping (no reset)
    integer i;
    if (we_q && wlane_q)
      case (wf_q)
        5'h00: in_addr[wl_q][31:0]   <= wd_q;
        5'h01: in_addr[wl_q][63:32]  <= wd_q;
        5'h02: in_len[wl_q]          <= wd_q;
        5'h03: out_addr[wl_q][31:0]  <= wd_q;
        5'h04: out_addr[wl_q][63:32] <= wd_q;
        5'h05: out_max[wl_q]         <= wd_q;
        5'h06: tag_r[wl_q]           <= wd_q;
        5'h07: if (wd_q[0]) begin tag_p[wl_q] <= tag_r[wl_q]; t_p[wl_q] <= clock_cnt; end
        default: ;
      endcase
    for (i = 0; i < NL; i = i + 1) begin
      if (acc[i]) begin run_tag[i] <= tag_p[i]; t_start[i] <= t_p[i]; end
      if (done[i] && !done_q[i]) t_done[i] <= clock_cnt;
    end
  end

  // ---- read: the address is accepted and decoded (registers); next clock each lane's register and the global
  // register are selected (registers: one word per lane, near the lane); next clock the lane; then the answer
  logic           r_p1, r_p2;
  logic           rglob_q, rlane_q;
  logic [LB-1:0]  rl_q;
  logic [4:0]     rf_q;                          // the lane's register: offset [6:2]
  logic [5:0]     rg_q;                          // the global register: address [7:2]
  logic [ALW-1:0] r_off;
  assign r_off = s_araddr - ALW'(32'h100);
  logic [31:0]          g_val, g_q;
  logic [NL-1:0][31:0]  l_val, l_q;
  always_comb begin : p_gmux
    g_val = 32'd0;
    case (rg_q)
      6'h00: g_val = 32'h4A504547;
      6'h01: g_val = 32'd2;
      6'h02: g_val = 32'(NL);
      6'h03: g_val = 32'(DW);
      6'h04: g_val = clock_cnt[31:0];
      6'h05: g_val = clock_hi_l;
      6'h06: g_val = done64[31:0];
      6'h07: g_val = done64[63:32];
      6'h08: g_val = busy64[31:0];
      6'h09: g_val = busy64[63:32];
      6'h0A: g_val = scratch;
      6'h0B: g_val = {31'd0, mem_ready};
      6'h0C: g_val = COMMIT;
      6'h0D: g_val = mem_err;
      default: ;
    endcase
  end
  always_comb begin : p_lmux
    integer i;
    for (i = 0; i < NL; i = i + 1) begin
      l_val[i] = 32'd0;
      case (rf_q)
        5'h00: l_val[i] = in_addr[i][31:0];
        5'h01: l_val[i] = in_addr[i][63:32];
        5'h02: l_val[i] = in_len[i];
        5'h03: l_val[i] = out_addr[i][31:0];
        5'h04: l_val[i] = out_addr[i][63:32];
        5'h05: l_val[i] = out_max[i];
        5'h06: l_val[i] = tag_r[i];
        5'h07: l_val[i] = {n_ign[i], n_acc[i]};
        5'h08: l_val[i] = {3'd0, res_err[i], 11'd0, res_abort[i], res_axi_err[i], res_ovf[i], done[i], busy[i]};
        5'h09: l_val[i] = run_tag[i];
        5'h0A: l_val[i] = res_cycles[i];
        5'h0B: l_val[i] = res_in_wait[i];
        5'h0C: l_val[i] = res_out_wait[i];
        5'h0D: l_val[i] = res_pixels[i];
        5'h0E: l_val[i] = res_records[i];
        5'h0F: l_val[i] = {res_h[i], res_w[i]};
        5'h10: l_val[i] = res_hash[i][31:0];
        5'h11: l_val[i] = res_hash[i][63:32];
        5'h12: l_val[i] = t_start[i][31:0];
        5'h13: l_val[i] = t_start[i][63:32];
        5'h14: l_val[i] = t_done[i][31:0];
        5'h15: l_val[i] = t_done[i][63:32];
        default: ;
      endcase
    end
  end
  assign s_arready = !s_rvalid && !r_p1 && !r_p2;
  always_ff @(posedge clk) begin
    g_q <= g_val; l_q <= l_val;
    if (s_arvalid && s_arready) begin
      rglob_q <= (s_araddr < ALW'(32'h100)); rlane_q <= (s_araddr >= ALW'(32'h100)) && (32'(r_off >> 7) < 32'(NL));
      rl_q <= LB'(r_off >> 7); rf_q <= r_off[6:2]; rg_q <= s_araddr[7:2];
    end
    if (rst) begin s_rvalid <= 1'b0; s_rdata <= '0; clock_hi_l <= '0; r_p1 <= 1'b0; r_p2 <= 1'b0; end
    else begin
      r_p1 <= s_arvalid && s_arready;
      r_p2 <= r_p1;
      if (r_p1 && rglob_q && rg_q == 6'h04) clock_hi_l <= clock_cnt[63:32];   // CLOCK_LO read: g_q holds the low word
      if (r_p2) begin
        s_rvalid <= 1'b1;
        s_rdata  <= rglob_q ? g_q : (rlane_q ? l_q[rl_q] : 32'd0);
      end else if (s_rvalid && s_rready) s_rvalid <= 1'b0;
    end
  end
endmodule
