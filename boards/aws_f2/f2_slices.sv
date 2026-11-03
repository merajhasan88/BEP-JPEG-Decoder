// f2_slices.sv - register slices of the F2 harness (ROADMAP.md, Task B): every valid, data and ready
// signal leaves a flip-flop, so that a slice can sit on either side of a die (SLR) crossing of the VU47P,
// at full throughput. Vendor-neutral.
//   f2_skid       one channel: a two-entry skid buffer (s_ready, m_valid and m_data are registers)
//   f2_axi_slice  the five channels of an AXI4 port (AW, W, AR forward; B, R backward)
//   f2_axil_slice the five channels of an AXI-Lite port

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
  logic [W-1:0] skid;
  logic         skid_v;
  assign s_ready = !skid_v;
  always_ff @(posedge clk) begin
    if (rst) begin
      m_valid <= 1'b0; skid_v <= 1'b0;
    end else if (m_valid && !m_ready) begin          // the output holds: a beat taken now waits in the skid
      if (s_valid && !skid_v) begin skid <= s_data; skid_v <= 1'b1; end
    end else if (skid_v) begin                        // the output is free: the skid first (no input taken now)
      m_valid <= 1'b1; m_data <= skid; skid_v <= 1'b0;
    end else begin
      m_valid <= s_valid;
      if (s_valid) m_data <= s_data;
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
