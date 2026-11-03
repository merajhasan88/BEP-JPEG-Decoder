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
// Results stay until the lane accepts the next start. One write and one read are handled at a time; a
// read answers two clocks after its address is accepted.
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

  // ---- write: address and data together, then the response
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

  always_ff @(posedge clk) begin : p_write
    integer i;
    start <= '0; job_abort <= '0;
    if (rst) begin
      s_bvalid <= 1'b0; clock_cnt <= '0; scratch <= '0;
      in_addr <= '0; in_len <= '0; out_addr <= '0; out_max <= '0; tag_r <= '0; tag_p <= '0; t_p <= '0;
      run_tag <= '0; n_acc <= '0; n_ign <= '0; t_start <= '0; t_done <= '0; done_q <= '0;
    end else begin
      clock_cnt <= clock_cnt + 64'd1;
      if (s_bvalid && s_bready) s_bvalid <= 1'b0;
      if (wr_en) begin
        s_bvalid <= 1'b1;
        if (w_glob && s_awaddr[7:2] == 6'h0A) scratch <= s_wdata;
        if (w_lane)
          case (w_off[6:2])
            5'h00: in_addr[wl][31:0]   <= s_wdata;
            5'h01: in_addr[wl][63:32]  <= s_wdata;
            5'h02: in_len[wl]          <= s_wdata;
            5'h03: out_addr[wl][31:0]  <= s_wdata;
            5'h04: out_addr[wl][63:32] <= s_wdata;
            5'h05: out_max[wl]         <= s_wdata;
            5'h06: tag_r[wl]           <= s_wdata;
            5'h07: begin
                     start[wl] <= s_wdata[0]; job_abort[wl] <= s_wdata[1];
                     if (s_wdata[0]) begin tag_p[wl] <= tag_r[wl]; t_p[wl] <= clock_cnt; end
                   end
            default: ;
          endcase
      end
      // the lane's answer to a start (it comes after the start, with the lane's own decision)
      for (i = 0; i < NL; i = i + 1) begin
        if (acc[i]) begin n_acc[i] <= n_acc[i] + 16'd1; run_tag[i] <= tag_p[i]; t_start[i] <= t_p[i]; end
        if (ign[i]) n_ign[i] <= n_ign[i] + 16'd1;
        done_q[i] <= done[i];
        if (done[i] && !done_q[i]) t_done[i] <= clock_cnt;
      end
    end
  end

  // ---- read: the address is registered first, the register is read in the next clock
  logic [ALW-1:0] ra;
  logic           r_pend;
  logic           r_glob, r_lane;
  logic [LB-1:0]  rl;
  logic [ALW-1:0] r_off;
  assign r_glob = (ra < ALW'(32'h100));
  assign r_off  = ra - ALW'(32'h100);
  assign r_lane = !r_glob && (32'(r_off >> 7) < 32'(NL));
  assign rl     = LB'(r_off >> 7);
  logic [31:0] rd_val;
  always_comb begin : p_rmux
    rd_val = 32'd0;
    if (r_glob)
      case (ra[7:2])
        6'h00: rd_val = 32'h4A504547;
        6'h01: rd_val = 32'd2;
        6'h02: rd_val = 32'(NL);
        6'h03: rd_val = 32'(DW);
        6'h04: rd_val = clock_cnt[31:0];
        6'h05: rd_val = clock_hi_l;
        6'h06: rd_val = done64[31:0];
        6'h07: rd_val = done64[63:32];
        6'h08: rd_val = busy64[31:0];
        6'h09: rd_val = busy64[63:32];
        6'h0A: rd_val = scratch;
        6'h0B: rd_val = {31'd0, mem_ready};
        6'h0C: rd_val = COMMIT;
        6'h0D: rd_val = mem_err;
        default: ;
      endcase
    else if (r_lane)
      case (r_off[6:2])
        5'h00: rd_val = in_addr[rl][31:0];
        5'h01: rd_val = in_addr[rl][63:32];
        5'h02: rd_val = in_len[rl];
        5'h03: rd_val = out_addr[rl][31:0];
        5'h04: rd_val = out_addr[rl][63:32];
        5'h05: rd_val = out_max[rl];
        5'h06: rd_val = tag_r[rl];
        5'h07: rd_val = {n_ign[rl], n_acc[rl]};
        5'h08: rd_val = {3'd0, res_err[rl], 11'd0, res_abort[rl], res_axi_err[rl], res_ovf[rl], done[rl], busy[rl]};
        5'h09: rd_val = run_tag[rl];
        5'h0A: rd_val = res_cycles[rl];
        5'h0B: rd_val = res_in_wait[rl];
        5'h0C: rd_val = res_out_wait[rl];
        5'h0D: rd_val = res_pixels[rl];
        5'h0E: rd_val = res_records[rl];
        5'h0F: rd_val = {res_h[rl], res_w[rl]};
        5'h10: rd_val = res_hash[rl][31:0];
        5'h11: rd_val = res_hash[rl][63:32];
        5'h12: rd_val = t_start[rl][31:0];
        5'h13: rd_val = t_start[rl][63:32];
        5'h14: rd_val = t_done[rl][31:0];
        5'h15: rd_val = t_done[rl][63:32];
        default: ;
      endcase
  end
  assign s_arready = !s_rvalid && !r_pend;
  always_ff @(posedge clk) begin
    if (rst) begin s_rvalid <= 1'b0; s_rdata <= '0; clock_hi_l <= '0; r_pend <= 1'b0; ra <= '0; end
    else begin
      if (s_arvalid && s_arready) begin ra <= s_araddr; r_pend <= 1'b1; end
      if (r_pend) begin
        r_pend <= 1'b0; s_rvalid <= 1'b1; s_rdata <= rd_val;
        if (r_glob && ra[7:2] == 6'h04) clock_hi_l <= clock_cnt[63:32];
      end else if (s_rvalid && s_rready) s_rvalid <= 1'b0;
    end
  end
endmodule
