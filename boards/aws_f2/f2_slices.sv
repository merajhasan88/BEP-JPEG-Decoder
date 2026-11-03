// f2_slices.sv - register slices of the F2 harness (ROADMAP.md, Task B): every valid, data and ready
// signal leaves a flip-flop, so that a slice can sit on either side of a die (SLR) crossing of the VU47P,
// at full throughput. Vendor-neutral.
//   f2_skid       one channel: a two-entry skid buffer (s_ready, m_valid and m_data are registers)
//   f2_axi_slice  the five channels of an AXI4 port (AW, W, AR forward; B, R backward)
//   f2_axil_slice the five channels of an AXI-Lite port
//   f2_pipe       a plain pipeline of registers
//   f2_link_tx / f2_link_rx            one channel over a long distance, with credits (below)
//   f2_axi_link_m / f2_axi_link_s      an AXI4 port over five such links
//   f2_axil_link_m / f2_axil_link_s    an AXI-Lite port over five such links

module f2_skid #(
  parameter int W = 8
) (
  input  logic         clk,
  input  logic         rst,
  input  logic         s_valid,
  output logic         s_ready,
  input  logic [W-1:0] s_data,
  output logic         m_valid,
  input  logic         m_ready,
  output logic [W-1:0] m_data
);
  // The data registers' enables depend on this side's registers and on m_ready only, never on s_valid: the
  // skid loads whenever it is empty and the output whenever it is free (2026-11-03: on the VU47P a valid or
  // ready that comes from far away cannot also drive hundreds of enables). s_valid reaches m_valid and skid_v.
  logic [W-1:0] skid;
  logic         skid_v;
  assign s_ready = !skid_v;
  always_ff @(posedge clk) begin
    if (!skid_v) skid <= s_data;                      // kept only when skid_v is set below
    if (!m_valid || m_ready) m_data <= skid_v ? skid : s_data;
    if (rst) begin
      m_valid <= 1'b0; skid_v <= 1'b0;
    end else if (m_valid && !m_ready) begin          // the output holds: a beat taken now waits in the skid
      if (s_valid && !skid_v) skid_v <= 1'b1;
    end else begin                                    // the output is free: the skid first (no input taken then)
      m_valid <= skid_v || s_valid;
      skid_v  <= 1'b0;
    end
  end
endmodule

// AXI4 with INCR bursts of 64-byte beats (the shell's and the DDR's only size): AW/AR carry {id, addr, len}
module f2_axi_slice #(
  parameter int IDW = 16,
  parameter int AW  = 64,
  parameter int DW  = 512
) (
  input  logic                clk,
  input  logic                rst,
  // slave side (from the requester)
  input  logic                s_awvalid,
  output logic                s_awready,
  input  logic [IDW-1:0]      s_awid,
  input  logic [AW-1:0]       s_awaddr,
  input  logic [7:0]          s_awlen,
  input  logic                s_wvalid,
  output logic                s_wready,
  input  logic [DW-1:0]       s_wdata,
  input  logic [DW/8-1:0]     s_wstrb,
  input  logic                s_wlast,
  output logic                s_bvalid,
  input  logic                s_bready,
  output logic [IDW-1:0]      s_bid,
  output logic [1:0]          s_bresp,
  input  logic                s_arvalid,
  output logic                s_arready,
  input  logic [IDW-1:0]      s_arid,
  input  logic [AW-1:0]       s_araddr,
  input  logic [7:0]          s_arlen,
  output logic                s_rvalid,
  input  logic                s_rready,
  output logic [IDW-1:0]      s_rid,
  output logic [DW-1:0]       s_rdata,
  output logic [1:0]          s_rresp,
  output logic                s_rlast,
  // master side (to the completer)
  output logic                m_awvalid,
  input  logic                m_awready,
  output logic [IDW-1:0]      m_awid,
  output logic [AW-1:0]       m_awaddr,
  output logic [7:0]          m_awlen,
  output logic                m_wvalid,
  input  logic                m_wready,
  output logic [DW-1:0]       m_wdata,
  output logic [DW/8-1:0]     m_wstrb,
  output logic                m_wlast,
  input  logic                m_bvalid,
  output logic                m_bready,
  input  logic [IDW-1:0]      m_bid,
  input  logic [1:0]          m_bresp,
  output logic                m_arvalid,
  input  logic                m_arready,
  output logic [IDW-1:0]      m_arid,
  output logic [AW-1:0]       m_araddr,
  output logic [7:0]          m_arlen,
  input  logic                m_rvalid,
  output logic                m_rready,
  input  logic [IDW-1:0]      m_rid,
  input  logic [DW-1:0]       m_rdata,
  input  logic [1:0]          m_rresp,
  input  logic                m_rlast
);
  f2_skid #(.W(IDW + AW + 8)) u_aw (.clk(clk), .rst(rst),
    .s_valid(s_awvalid), .s_ready(s_awready), .s_data({s_awid, s_awaddr, s_awlen}),
    .m_valid(m_awvalid), .m_ready(m_awready), .m_data({m_awid, m_awaddr, m_awlen}));
  f2_skid #(.W(DW + DW/8 + 1)) u_w (.clk(clk), .rst(rst),
    .s_valid(s_wvalid), .s_ready(s_wready), .s_data({s_wdata, s_wstrb, s_wlast}),
    .m_valid(m_wvalid), .m_ready(m_wready), .m_data({m_wdata, m_wstrb, m_wlast}));
  f2_skid #(.W(IDW + 2)) u_b (.clk(clk), .rst(rst),
    .s_valid(m_bvalid), .s_ready(m_bready), .s_data({m_bid, m_bresp}),
    .m_valid(s_bvalid), .m_ready(s_bready), .m_data({s_bid, s_bresp}));
  f2_skid #(.W(IDW + AW + 8)) u_ar (.clk(clk), .rst(rst),
    .s_valid(s_arvalid), .s_ready(s_arready), .s_data({s_arid, s_araddr, s_arlen}),
    .m_valid(m_arvalid), .m_ready(m_arready), .m_data({m_arid, m_araddr, m_arlen}));
  f2_skid #(.W(IDW + DW + 2 + 1)) u_r (.clk(clk), .rst(rst),
    .s_valid(m_rvalid), .s_ready(m_rready), .s_data({m_rid, m_rdata, m_rresp, m_rlast}),
    .m_valid(s_rvalid), .m_ready(s_rready), .m_data({s_rid, s_rdata, s_rresp, s_rlast}));
endmodule

module f2_axil_slice #(
  parameter int AW = 32
) (
  input  logic          clk,
  input  logic          rst,
  input  logic          s_awvalid,
  output logic          s_awready,
  input  logic [AW-1:0] s_awaddr,
  input  logic          s_wvalid,
  output logic          s_wready,
  input  logic [31:0]   s_wdata,
  input  logic [3:0]    s_wstrb,
  output logic          s_bvalid,
  input  logic          s_bready,
  output logic [1:0]    s_bresp,
  input  logic          s_arvalid,
  output logic          s_arready,
  input  logic [AW-1:0] s_araddr,
  output logic          s_rvalid,
  input  logic          s_rready,
  output logic [31:0]   s_rdata,
  output logic [1:0]    s_rresp,
  output logic          m_awvalid,
  input  logic          m_awready,
  output logic [AW-1:0] m_awaddr,
  output logic          m_wvalid,
  input  logic          m_wready,
  output logic [31:0]   m_wdata,
  output logic [3:0]    m_wstrb,
  input  logic          m_bvalid,
  output logic          m_bready,
  input  logic [1:0]    m_bresp,
  output logic          m_arvalid,
  input  logic          m_arready,
  output logic [AW-1:0] m_araddr,
  input  logic          m_rvalid,
  output logic          m_rready,
  input  logic [31:0]   m_rdata,
  input  logic [1:0]    m_rresp
);
  f2_skid #(.W(AW)) u_aw (.clk(clk), .rst(rst), .s_valid(s_awvalid), .s_ready(s_awready), .s_data(s_awaddr),
    .m_valid(m_awvalid), .m_ready(m_awready), .m_data(m_awaddr));
  f2_skid #(.W(36)) u_w (.clk(clk), .rst(rst), .s_valid(s_wvalid), .s_ready(s_wready), .s_data({s_wdata, s_wstrb}),
    .m_valid(m_wvalid), .m_ready(m_wready), .m_data({m_wdata, m_wstrb}));
  f2_skid #(.W(2)) u_b (.clk(clk), .rst(rst), .s_valid(m_bvalid), .s_ready(m_bready), .s_data(m_bresp),
    .m_valid(s_bvalid), .m_ready(s_bready), .m_data(s_bresp));
  f2_skid #(.W(AW)) u_ar (.clk(clk), .rst(rst), .s_valid(s_arvalid), .s_ready(s_arready), .s_data(s_araddr),
    .m_valid(m_arvalid), .m_ready(m_arready), .m_data(m_araddr));
  f2_skid #(.W(34)) u_r (.clk(clk), .rst(rst), .s_valid(m_rvalid), .s_ready(m_rready), .s_data({m_rdata, m_rresp}),
    .m_valid(s_rvalid), .m_ready(s_rready), .m_data({s_rdata, s_rresp}));
endmodule

// a plain pipeline of STAGES registers (cleared by rst): for buses whose timing does not matter, e.g. the
// shell's DDR4 statistics bus
module f2_pipe #(
  parameter int W      = 1,
  parameter int STAGES = 2
) (
  input  logic         clk,
  input  logic         rst,
  input  logic [W-1:0] d,
  output logic [W-1:0] q
);
  logic [W-1:0] p [0:STAGES-1];
  always_ff @(posedge clk) begin : g_p
    integer i;
    if (rst) for (i = 0; i < STAGES; i = i + 1) p[i] <= '0;
    else begin
      p[0] <= d;
      for (i = 1; i < STAGES; i = i + 1) p[i] <= p[i-1];
    end
  end
  assign q = p[STAGES-1];
endmodule

// ================================================================ links over a long distance (2026-11-03)
// f2_link_tx / f2_link_rx: one valid/ready channel between two distant places (across a die, or between the
// dies of the VU47P) in which nothing that comes from far away drives more than a few flip-flops. The sender
// holds credits for the receiver's FIFO (DEPTH entries) and sends a beat only with a credit; the receiver
// returns a credit for every beat it hands on. Every wire between the two halves leaves a register and enters
// one: STAGES registers on the way there and STAGES on the credit's way back, so the first may sit at a die
// crossing and the last next to the FIFO. A credit is back after 2 * STAGES + 4 clocks: DEPTH >= 2 * STAGES + 4
// keeps a beat per clock (DEPTH a power of two). The two halves must leave reset together, or the receiver first.
// Why: in the first build on AWS (2026-11-03) a register slice's 577 enables were driven by a ready that came,
// through the multiplexer's logic, from half a die away: -0.881 ns at 250 MHz. A register slice cannot avoid that
// (its output register must hold when the far side is not ready); credits can.
module f2_link_tx #(
  parameter int W     = 8,
  parameter int DEPTH = 8
) (
  input  logic         clk,
  input  logic         rst,
  input  logic         s_valid,
  output logic         s_ready,
  input  logic [W-1:0] s_data,
  output logic         l_valid,                  // to the receiver (registers)
  output logic [W-1:0] l_data,
  input  logic         l_credit                  // from the receiver (a register there): one beat handed on
);
  localparam int CB = $clog2(DEPTH + 1);
  logic [CB-1:0] crd;                            // credits: free entries of the receiver's FIFO
  logic          cr_q;
  assign s_ready = !rst && (crd != '0);           // nothing is taken in reset: it could not be sent
  always_ff @(posedge clk) begin
    l_data <= s_data;                            // every clock: the receiver looks at it only with l_valid
    if (rst) begin
      crd <= CB'(DEPTH); cr_q <= 1'b0; l_valid <= 1'b0;
    end else begin
      cr_q    <= l_credit;
      l_valid <= s_valid && s_ready;
      crd     <= crd - CB'(s_valid && s_ready) + CB'(cr_q);
    end
  end
endmodule

module f2_link_rx #(
  parameter int W      = 8,
  parameter int DEPTH  = 8,
  parameter int STAGES = 2
) (
  input  logic         clk,
  input  logic         rst,
  input  logic         l_valid,                  // from the sender's registers
  input  logic [W-1:0] l_data,
  output logic         l_credit,                 // to the sender (a register)
  output logic         m_valid,
  input  logic         m_ready,
  output logic [W-1:0] m_data
);
  localparam int AB = $clog2(DEPTH);
  logic [STAGES-1:0] v_p, c_p;                   // the beat's way in, the credit's way out
  logic [W-1:0]      d_p [0:STAGES-1];
  logic [W-1:0]      mem [0:DEPTH-1];
  logic [AB-1:0]     wp, rp;
  logic [AB:0]       cnt;
  logic              take;
  assign m_valid  = (cnt != '0);
  assign m_data   = mem[rp];
  assign take     = m_valid && m_ready;
  assign l_credit = c_p[STAGES-1];
  always_ff @(posedge clk) begin : g_rx
    integer i;
    d_p[0] <= l_data;
    for (i = 1; i < STAGES; i = i + 1) d_p[i] <= d_p[i-1];
    if (v_p[STAGES-1]) mem[wp] <= d_p[STAGES-1];
    if (rst) begin
      v_p <= '0; c_p <= '0; wp <= '0; rp <= '0; cnt <= '0;
    end else begin
      v_p[0] <= l_valid;
      c_p[0] <= take;
      for (i = 1; i < STAGES; i = i + 1) begin v_p[i] <= v_p[i-1]; c_p[i] <= c_p[i-1]; end
      if (v_p[STAGES-1]) wp <= wp + 1'b1;
      if (take) rp <= rp + 1'b1;
      cnt <= cnt + (v_p[STAGES-1] ? 1'b1 : 1'b0) - (take ? 1'b1 : 1'b0);
    end
  end
endmodule

// An AXI4 port (INCR bursts of 64-byte beats: AW/AR {id, addr, len}, W {data, strb, last}, R {id, data, resp, last},
// B {id, resp}) over five links. f2_axi_link_m sits next to the master (its s_ side is the master's port),
// f2_axi_link_s next to the slave (its m_ side drives the slave). Between them two buses:
//   fwd (master to slave): {AW, W, AR beats, the R and B credits}
//   bwd (slave to master): {the AW, W, AR credits, R and B beats}
// Widths: f2_axi_link_fw / f2_axi_link_bw below (the same formulas in both modules).
module f2_axi_link_m #(
  parameter int IDW    = 16,
  parameter int AW     = 64,
  parameter int DW     = 512,
  parameter int DEPTH  = 8,
  parameter int STAGES = 2,
  parameter int FW     = 3 + 2 * (IDW + AW + 8) + (DW + DW / 8 + 1) + 2,
  parameter int BW     = 3 + 2 + (IDW + DW + 3) + (IDW + 2)
) (
  input  logic                clk,
  input  logic                rst,
  input  logic                s_awvalid,
  output logic                s_awready,
  input  logic [IDW-1:0]      s_awid,
  input  logic [AW-1:0]       s_awaddr,
  input  logic [7:0]          s_awlen,
  input  logic                s_wvalid,
  output logic                s_wready,
  input  logic [DW-1:0]       s_wdata,
  input  logic [DW/8-1:0]     s_wstrb,
  input  logic                s_wlast,
  output logic                s_bvalid,
  input  logic                s_bready,
  output logic [IDW-1:0]      s_bid,
  output logic [1:0]          s_bresp,
  input  logic                s_arvalid,
  output logic                s_arready,
  input  logic [IDW-1:0]      s_arid,
  input  logic [AW-1:0]       s_araddr,
  input  logic [7:0]          s_arlen,
  output logic                s_rvalid,
  input  logic                s_rready,
  output logic [IDW-1:0]      s_rid,
  output logic [DW-1:0]       s_rdata,
  output logic [1:0]          s_rresp,
  output logic                s_rlast,
  output logic [FW-1:0]       fwd,
  input  logic [BW-1:0]       bwd
);
  localparam int AWB = IDW + AW + 8, WB = DW + DW / 8 + 1, RB = IDW + DW + 3, BB = IDW + 2;
  logic           aw_v, w_v, ar_v, r_v, b_v, aw_c, w_c, ar_c, r_c, b_c;
  logic [AWB-1:0] aw_d, ar_d;
  logic [WB-1:0]  w_d;
  logic [RB-1:0]  r_d;
  logic [BB-1:0]  b_d;
  assign fwd = {aw_v, aw_d, w_v, w_d, ar_v, ar_d, r_c, b_c};
  assign {aw_c, w_c, ar_c, r_v, r_d, b_v, b_d} = bwd;
  f2_link_tx #(.W(AWB), .DEPTH(DEPTH)) u_aw (.clk(clk), .rst(rst), .s_valid(s_awvalid), .s_ready(s_awready),
    .s_data({s_awid, s_awaddr, s_awlen}), .l_valid(aw_v), .l_data(aw_d), .l_credit(aw_c));
  f2_link_tx #(.W(WB), .DEPTH(DEPTH)) u_w (.clk(clk), .rst(rst), .s_valid(s_wvalid), .s_ready(s_wready),
    .s_data({s_wdata, s_wstrb, s_wlast}), .l_valid(w_v), .l_data(w_d), .l_credit(w_c));
  f2_link_tx #(.W(AWB), .DEPTH(DEPTH)) u_ar (.clk(clk), .rst(rst), .s_valid(s_arvalid), .s_ready(s_arready),
    .s_data({s_arid, s_araddr, s_arlen}), .l_valid(ar_v), .l_data(ar_d), .l_credit(ar_c));
  f2_link_rx #(.W(RB), .DEPTH(DEPTH), .STAGES(STAGES)) u_r (.clk(clk), .rst(rst), .l_valid(r_v), .l_data(r_d),
    .l_credit(r_c), .m_valid(s_rvalid), .m_ready(s_rready), .m_data({s_rid, s_rdata, s_rresp, s_rlast}));
  f2_link_rx #(.W(BB), .DEPTH(DEPTH), .STAGES(STAGES)) u_b (.clk(clk), .rst(rst), .l_valid(b_v), .l_data(b_d),
    .l_credit(b_c), .m_valid(s_bvalid), .m_ready(s_bready), .m_data({s_bid, s_bresp}));
endmodule

module f2_axi_link_s #(
  parameter int IDW    = 16,
  parameter int AW     = 64,
  parameter int DW     = 512,
  parameter int DEPTH  = 8,
  parameter int STAGES = 2,
  parameter int FW     = 3 + 2 * (IDW + AW + 8) + (DW + DW / 8 + 1) + 2,
  parameter int BW     = 3 + 2 + (IDW + DW + 3) + (IDW + 2)
) (
  input  logic                clk,
  input  logic                rst,
  input  logic [FW-1:0]       fwd,
  output logic [BW-1:0]       bwd,
  output logic                m_awvalid,
  input  logic                m_awready,
  output logic [IDW-1:0]      m_awid,
  output logic [AW-1:0]       m_awaddr,
  output logic [7:0]          m_awlen,
  output logic                m_wvalid,
  input  logic                m_wready,
  output logic [DW-1:0]       m_wdata,
  output logic [DW/8-1:0]     m_wstrb,
  output logic                m_wlast,
  input  logic                m_bvalid,
  output logic                m_bready,
  input  logic [IDW-1:0]      m_bid,
  input  logic [1:0]          m_bresp,
  output logic                m_arvalid,
  input  logic                m_arready,
  output logic [IDW-1:0]      m_arid,
  output logic [AW-1:0]       m_araddr,
  output logic [7:0]          m_arlen,
  input  logic                m_rvalid,
  output logic                m_rready,
  input  logic [IDW-1:0]      m_rid,
  input  logic [DW-1:0]       m_rdata,
  input  logic [1:0]          m_rresp,
  input  logic                m_rlast
);
  localparam int AWB = IDW + AW + 8, WB = DW + DW / 8 + 1, RB = IDW + DW + 3, BB = IDW + 2;
  logic           aw_v, w_v, ar_v, r_v, b_v, aw_c, w_c, ar_c, r_c, b_c;
  logic [AWB-1:0] aw_d, ar_d;
  logic [WB-1:0]  w_d;
  logic [RB-1:0]  r_d;
  logic [BB-1:0]  b_d;
  assign {aw_v, aw_d, w_v, w_d, ar_v, ar_d, r_c, b_c} = fwd;
  assign bwd = {aw_c, w_c, ar_c, r_v, r_d, b_v, b_d};
  f2_link_rx #(.W(AWB), .DEPTH(DEPTH), .STAGES(STAGES)) u_aw (.clk(clk), .rst(rst), .l_valid(aw_v), .l_data(aw_d),
    .l_credit(aw_c), .m_valid(m_awvalid), .m_ready(m_awready), .m_data({m_awid, m_awaddr, m_awlen}));
  f2_link_rx #(.W(WB), .DEPTH(DEPTH), .STAGES(STAGES)) u_w (.clk(clk), .rst(rst), .l_valid(w_v), .l_data(w_d),
    .l_credit(w_c), .m_valid(m_wvalid), .m_ready(m_wready), .m_data({m_wdata, m_wstrb, m_wlast}));
  f2_link_rx #(.W(AWB), .DEPTH(DEPTH), .STAGES(STAGES)) u_ar (.clk(clk), .rst(rst), .l_valid(ar_v), .l_data(ar_d),
    .l_credit(ar_c), .m_valid(m_arvalid), .m_ready(m_arready), .m_data({m_arid, m_araddr, m_arlen}));
  f2_link_tx #(.W(RB), .DEPTH(DEPTH)) u_r (.clk(clk), .rst(rst), .s_valid(m_rvalid), .s_ready(m_rready),
    .s_data({m_rid, m_rdata, m_rresp, m_rlast}), .l_valid(r_v), .l_data(r_d), .l_credit(r_c));
  f2_link_tx #(.W(BB), .DEPTH(DEPTH)) u_b (.clk(clk), .rst(rst), .s_valid(m_bvalid), .s_ready(m_bready),
    .s_data({m_bid, m_bresp}), .l_valid(b_v), .l_data(b_d), .l_credit(b_c));
endmodule

// An AXI-Lite port (32-bit data) over five links, as above: AW {addr}, W {data, strb}, AR {addr}, R {data, resp},
// B {resp}.
module f2_axil_link_m #(
  parameter int AW     = 32,
  parameter int DEPTH  = 8,
  parameter int STAGES = 2,
  parameter int FW     = 3 + 2 * AW + 36 + 2,
  parameter int BW     = 3 + 2 + 34 + 2
) (
  input  logic          clk,
  input  logic          rst,
  input  logic          s_awvalid,
  output logic          s_awready,
  input  logic [AW-1:0] s_awaddr,
  input  logic          s_wvalid,
  output logic          s_wready,
  input  logic [31:0]   s_wdata,
  input  logic [3:0]    s_wstrb,
  output logic          s_bvalid,
  input  logic          s_bready,
  output logic [1:0]    s_bresp,
  input  logic          s_arvalid,
  output logic          s_arready,
  input  logic [AW-1:0] s_araddr,
  output logic          s_rvalid,
  input  logic          s_rready,
  output logic [31:0]   s_rdata,
  output logic [1:0]    s_rresp,
  output logic [FW-1:0] fwd,
  input  logic [BW-1:0] bwd
);
  logic          aw_v, w_v, ar_v, r_v, b_v, aw_c, w_c, ar_c, r_c, b_c;
  logic [AW-1:0] aw_d, ar_d;
  logic [35:0]   w_d;
  logic [33:0]   r_d;
  logic [1:0]    b_d;
  assign fwd = {aw_v, aw_d, w_v, w_d, ar_v, ar_d, r_c, b_c};
  assign {aw_c, w_c, ar_c, r_v, r_d, b_v, b_d} = bwd;
  f2_link_tx #(.W(AW), .DEPTH(DEPTH)) u_aw (.clk(clk), .rst(rst), .s_valid(s_awvalid), .s_ready(s_awready),
    .s_data(s_awaddr), .l_valid(aw_v), .l_data(aw_d), .l_credit(aw_c));
  f2_link_tx #(.W(36), .DEPTH(DEPTH)) u_w (.clk(clk), .rst(rst), .s_valid(s_wvalid), .s_ready(s_wready),
    .s_data({s_wdata, s_wstrb}), .l_valid(w_v), .l_data(w_d), .l_credit(w_c));
  f2_link_tx #(.W(AW), .DEPTH(DEPTH)) u_ar (.clk(clk), .rst(rst), .s_valid(s_arvalid), .s_ready(s_arready),
    .s_data(s_araddr), .l_valid(ar_v), .l_data(ar_d), .l_credit(ar_c));
  f2_link_rx #(.W(34), .DEPTH(DEPTH), .STAGES(STAGES)) u_r (.clk(clk), .rst(rst), .l_valid(r_v), .l_data(r_d),
    .l_credit(r_c), .m_valid(s_rvalid), .m_ready(s_rready), .m_data({s_rdata, s_rresp}));
  f2_link_rx #(.W(2), .DEPTH(DEPTH), .STAGES(STAGES)) u_b (.clk(clk), .rst(rst), .l_valid(b_v), .l_data(b_d),
    .l_credit(b_c), .m_valid(s_bvalid), .m_ready(s_bready), .m_data(s_bresp));
endmodule

module f2_axil_link_s #(
  parameter int AW     = 32,
  parameter int DEPTH  = 8,
  parameter int STAGES = 2,
  parameter int FW     = 3 + 2 * AW + 36 + 2,
  parameter int BW     = 3 + 2 + 34 + 2
) (
  input  logic          clk,
  input  logic          rst,
  input  logic [FW-1:0] fwd,
  output logic [BW-1:0] bwd,
  output logic          m_awvalid,
  input  logic          m_awready,
  output logic [AW-1:0] m_awaddr,
  output logic          m_wvalid,
  input  logic          m_wready,
  output logic [31:0]   m_wdata,
  output logic [3:0]    m_wstrb,
  input  logic          m_bvalid,
  output logic          m_bready,
  input  logic [1:0]    m_bresp,
  output logic          m_arvalid,
  input  logic          m_arready,
  output logic [AW-1:0] m_araddr,
  input  logic          m_rvalid,
  output logic          m_rready,
  input  logic [31:0]   m_rdata,
  input  logic [1:0]    m_rresp
);
  logic          aw_v, w_v, ar_v, r_v, b_v, aw_c, w_c, ar_c, r_c, b_c;
  logic [AW-1:0] aw_d, ar_d;
  logic [35:0]   w_d;
  logic [33:0]   r_d;
  logic [1:0]    b_d;
  assign {aw_v, aw_d, w_v, w_d, ar_v, ar_d, r_c, b_c} = fwd;
  assign bwd = {aw_c, w_c, ar_c, r_v, r_d, b_v, b_d};
  f2_link_rx #(.W(AW), .DEPTH(DEPTH), .STAGES(STAGES)) u_aw (.clk(clk), .rst(rst), .l_valid(aw_v), .l_data(aw_d),
    .l_credit(aw_c), .m_valid(m_awvalid), .m_ready(m_awready), .m_data(m_awaddr));
  f2_link_rx #(.W(36), .DEPTH(DEPTH), .STAGES(STAGES)) u_w (.clk(clk), .rst(rst), .l_valid(w_v), .l_data(w_d),
    .l_credit(w_c), .m_valid(m_wvalid), .m_ready(m_wready), .m_data({m_wdata, m_wstrb}));
  f2_link_rx #(.W(AW), .DEPTH(DEPTH), .STAGES(STAGES)) u_ar (.clk(clk), .rst(rst), .l_valid(ar_v), .l_data(ar_d),
    .l_credit(ar_c), .m_valid(m_arvalid), .m_ready(m_arready), .m_data(m_araddr));
  f2_link_tx #(.W(34), .DEPTH(DEPTH)) u_r (.clk(clk), .rst(rst), .s_valid(m_rvalid), .s_ready(m_rready),
    .s_data({m_rdata, m_rresp}), .l_valid(r_v), .l_data(r_d), .l_credit(r_c));
  f2_link_tx #(.W(2), .DEPTH(DEPTH)) u_b (.clk(clk), .rst(rst), .s_valid(m_bvalid), .s_ready(m_bready),
    .s_data(m_bresp), .l_valid(b_v), .l_data(b_d), .l_credit(b_c));
endmodule
