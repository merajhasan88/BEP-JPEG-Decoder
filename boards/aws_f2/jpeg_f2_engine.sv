// jpeg_f2_engine.sv - the F2 harness's job engine (ROADMAP.md, Task B, option 1), vendor-neutral: NL
// decoder lanes (mem_lane.sv: wide core, file read from memory, RGB records written to memory), each with
// its own AXI4 master port (on F2: one HBM channel per lane), and the register file f2_regs.sv on an
// AXI-Lite slave port (on F2: the shell's OCL port). The host writes the JPEG files into memory, gives
// each lane a job by register, polls DONE, reads the results and the records. Not in here (F2-specific,
// built on AWS's build image): the shell's ports, the HBM, clock and width / AXI3 adaptation (each port
// keeps INCR bursts of at most 16 beats inside 4 KB and a single ID, which AXI3 slaves accept).
module jpeg_f2_engine #(
  parameter int NL    = 4,                     // lanes, 1-64
  parameter int DW    = 512,                   // the lanes' AXI data width: 256 or 512
  parameter int ALW   = 16,                    // AXI-Lite address bits used
  parameter int BURST = 16,
  parameter int WOUT  = 8
) (
  input  logic                    clk,
  input  logic                    rst,
  // AXI-Lite slave: the registers (f2_regs.sv)
  input  logic                    s_awvalid,
  output logic                    s_awready,
  input  logic [ALW-1:0]          s_awaddr,
  input  logic                    s_wvalid,
  output logic                    s_wready,
  input  logic [31:0]             s_wdata,
  input  logic [3:0]              s_wstrb,
  output logic                    s_bvalid,
  input  logic                    s_bready,
  output logic [1:0]              s_bresp,
  input  logic                    s_arvalid,
  output logic                    s_arready,
  input  logic [ALW-1:0]          s_araddr,
  output logic                    s_rvalid,
  input  logic                    s_rready,
  output logic [31:0]             s_rdata,
  output logic [1:0]              s_rresp,
  // one AXI4 master per lane
  output logic [NL-1:0]           m_arvalid,
  input  logic [NL-1:0]           m_arready,
  output logic [NL-1:0][63:0]     m_araddr,
  output logic [NL-1:0][7:0]      m_arlen,
  output logic [NL-1:0][2:0]      m_arsize,
  output logic [NL-1:0][1:0]      m_arburst,
  input  logic [NL-1:0]           m_rvalid,
  output logic [NL-1:0]           m_rready,
  input  logic [NL-1:0][DW-1:0]   m_rdata,
  input  logic [NL-1:0]           m_rlast,
  input  logic [NL-1:0][1:0]      m_rresp,
  output logic [NL-1:0]           m_awvalid,
  input  logic [NL-1:0]           m_awready,
  output logic [NL-1:0][63:0]     m_awaddr,
  output logic [NL-1:0][7:0]      m_awlen,
  output logic [NL-1:0][2:0]      m_awsize,
  output logic [NL-1:0][1:0]      m_awburst,
  output logic [NL-1:0]           m_wvalid,
  input  logic [NL-1:0]           m_wready,
  output logic [NL-1:0][DW-1:0]   m_wdata,
  output logic [NL-1:0][DW/8-1:0] m_wstrb,
  output logic [NL-1:0]           m_wlast,
  input  logic [NL-1:0]           m_bvalid,
  output logic [NL-1:0]           m_bready,
  input  logic [NL-1:0][1:0]      m_bresp,
  // the lanes' state (LEDs, debug)
  output logic [NL-1:0]           lane_busy,
  output logic [NL-1:0]           lane_done
);
  logic [NL-1:0]        start, job_abort, res_ovf, res_axi_err, res_abort;
  logic [NL-1:0][63:0]  in_addr, out_addr, res_hash;
  logic [NL-1:0][31:0]  in_len, out_max, res_cycles, res_in_wait, res_out_wait, res_pixels, res_records;
  logic [NL-1:0][12:0]  res_err;
  logic [NL-1:0][15:0]  res_w, res_h;

  f2_regs #(.NL(NL), .DW(DW), .ALW(ALW)) u_regs (
    .clk(clk), .rst(rst),
    .s_awvalid(s_awvalid), .s_awready(s_awready), .s_awaddr(s_awaddr), .s_wvalid(s_wvalid), .s_wready(s_wready),
    .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_bvalid(s_bvalid), .s_bready(s_bready), .s_bresp(s_bresp),
    .s_arvalid(s_arvalid), .s_arready(s_arready), .s_araddr(s_araddr), .s_rvalid(s_rvalid), .s_rready(s_rready),
    .s_rdata(s_rdata), .s_rresp(s_rresp),
    .start(start), .job_abort(job_abort), .in_addr(in_addr), .in_len(in_len), .out_addr(out_addr), .out_max(out_max),
    .busy(lane_busy), .done(lane_done), .res_err(res_err), .res_ovf(res_ovf), .res_axi_err(res_axi_err),
    .res_abort(res_abort), .res_cycles(res_cycles), .res_in_wait(res_in_wait), .res_out_wait(res_out_wait),
    .res_pixels(res_pixels), .res_records(res_records), .res_hash(res_hash), .res_w(res_w), .res_h(res_h));

  genvar i;
  generate
    for (i = 0; i < NL; i = i + 1) begin : g_lane
      mem_lane #(.AW(64), .DW(DW), .BURST(BURST), .WOUT(WOUT)) u_lane (
        .clk(clk), .rst(rst),
        .start(start[i]), .job_abort(job_abort[i]), .in_addr(in_addr[i]), .in_len(in_len[i]), .out_addr(out_addr[i]),
        .out_max(out_max[i]), .busy(lane_busy[i]), .done(lane_done[i]),
        .res_err(res_err[i]), .res_ovf(res_ovf[i]), .res_axi_err(res_axi_err[i]), .res_abort(res_abort[i]),
        .res_cycles(res_cycles[i]), .res_in_wait(res_in_wait[i]), .res_out_wait(res_out_wait[i]),
        .res_pixels(res_pixels[i]), .res_records(res_records[i]), .res_hash(res_hash[i]),
        .res_w(res_w[i]), .res_h(res_h[i]),
        .arvalid(m_arvalid[i]), .arready(m_arready[i]), .araddr(m_araddr[i]), .arlen(m_arlen[i]),
        .arsize(m_arsize[i]), .arburst(m_arburst[i]),
        .rvalid(m_rvalid[i]), .rready(m_rready[i]), .rdata(m_rdata[i]), .rlast(m_rlast[i]), .rresp(m_rresp[i]),
        .awvalid(m_awvalid[i]), .awready(m_awready[i]), .awaddr(m_awaddr[i]), .awlen(m_awlen[i]),
        .awsize(m_awsize[i]), .awburst(m_awburst[i]),
        .wvalid(m_wvalid[i]), .wready(m_wready[i]), .wdata(m_wdata[i]), .wstrb(m_wstrb[i]), .wlast(m_wlast[i]),
        .bvalid(m_bvalid[i]), .bready(m_bready[i]), .bresp(m_bresp[i]));
    end
  endgenerate
endmodule
