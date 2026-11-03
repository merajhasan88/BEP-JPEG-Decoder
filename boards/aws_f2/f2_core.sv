// f2_core.sv - the F2 harness's logic between the shell's ports and the memory (ROADMAP.md, Task B),
// vendor-neutral: NL decoder lanes (mem_lane.sv), the host's registers (f2_regs.sv) on the OCL port, the
// host's memory port (f2_pcis.sv) on PCIS, and one AXI4 master to the memory (on F2: the DDR4 controller
// sh_ddr) through the multiplexer f2_axi_mux.sv (masters 0..NL-1 the lanes, NL the host).
// The shell's ports come in through register slices on the shell's side of the die crossing (in cl_jpeg.sv);
// here every port has one more slice, every lane has slices on its memory port and registers on its job
// inputs and answers, so that no path inside runs between distant blocks without a register.
// Addresses reach the memory reduced to MAW bits (64 GiB: the DIMM).
module f2_core #(
  parameter int          NL     = 15,
  parameter int          IDW    = 16,        // the shell's and the memory's AXI ID width
  parameter int          MAW    = 36,
  parameter logic [31:0] COMMIT = 32'h0
) (
  input  logic               clk,
  input  logic               rst,
  input  logic               mem_ready,
  output logic [15:0]        vled,
  // OCL (AXI-Lite) from the shell
  input  logic               ocl_awvalid,
  output logic               ocl_awready,
  input  logic [31:0]        ocl_awaddr,
  input  logic               ocl_wvalid,
  output logic               ocl_wready,
  input  logic [31:0]        ocl_wdata,
  input  logic [3:0]         ocl_wstrb,
  output logic               ocl_bvalid,
  input  logic               ocl_bready,
  output logic [1:0]         ocl_bresp,
  input  logic               ocl_arvalid,
  output logic               ocl_arready,
  input  logic [31:0]        ocl_araddr,
  output logic               ocl_rvalid,
  input  logic               ocl_rready,
  output logic [31:0]        ocl_rdata,
  output logic [1:0]         ocl_rresp,
  // PCIS (AXI4) from the shell
  input  logic               pcis_awvalid,
  output logic               pcis_awready,
  input  logic [IDW-1:0]     pcis_awid,
  input  logic [63:0]        pcis_awaddr,
  input  logic [7:0]         pcis_awlen,
  input  logic               pcis_wvalid,
  output logic               pcis_wready,
  input  logic [511:0]       pcis_wdata,
  input  logic [63:0]        pcis_wstrb,
  input  logic               pcis_wlast,
  output logic               pcis_bvalid,
  input  logic               pcis_bready,
  output logic [IDW-1:0]     pcis_bid,
  output logic [1:0]         pcis_bresp,
  input  logic               pcis_arvalid,
  output logic               pcis_arready,
  input  logic [IDW-1:0]     pcis_arid,
  input  logic [63:0]        pcis_araddr,
  input  logic [7:0]         pcis_arlen,
  output logic               pcis_rvalid,
  input  logic               pcis_rready,
  output logic [IDW-1:0]     pcis_rid,
  output logic [511:0]       pcis_rdata,
  output logic [1:0]         pcis_rresp,
  output logic               pcis_rlast,
  // the memory (AXI4 master)
  output logic               mem_awvalid,
  input  logic               mem_awready,
  output logic [IDW-1:0]     mem_awid,
  output logic [63:0]        mem_awaddr,
  output logic [7:0]         mem_awlen,
  output logic               mem_wvalid,
  input  logic               mem_wready,
  output logic [511:0]       mem_wdata,
  output logic [63:0]        mem_wstrb,
  output logic               mem_wlast,
  input  logic               mem_bvalid,
  output logic               mem_bready,
  input  logic [IDW-1:0]     mem_bid,
  input  logic [1:0]         mem_bresp,
  output logic               mem_arvalid,
  input  logic               mem_arready,
  output logic [IDW-1:0]     mem_arid,
  output logic [63:0]        mem_araddr,
  output logic [7:0]         mem_arlen,
  input  logic               mem_rvalid,
  output logic               mem_rready,
  input  logic [IDW-1:0]     mem_rid,
  input  logic [511:0]       mem_rdata,
  input  logic [1:0]         mem_rresp,
  input  logic               mem_rlast
);
  localparam int NM = NL + 1;
  localparam int DW = 512;

  logic mem_ready_q, mem_on;
  logic [31:0] mem_err;
  always_ff @(posedge clk) mem_ready_q <= mem_ready;

  // ================================================================ OCL -> registers
  logic        r_awvalid, r_awready, r_wvalid, r_wready, r_bvalid, r_bready, r_arvalid, r_arready, r_rvalid, r_rready;
  logic [31:0] r_awaddr, r_araddr, r_wdata, r_rdata;
  logic [3:0]  r_wstrb;
  logic [1:0]  r_bresp, r_rresp;
  f2_axil_slice #(.AW(32)) u_ocl_slc (.clk(clk), .rst(rst),
    .s_awvalid(ocl_awvalid), .s_awready(ocl_awready), .s_awaddr(ocl_awaddr), .s_wvalid(ocl_wvalid), .s_wready(ocl_wready),
    .s_wdata(ocl_wdata), .s_wstrb(ocl_wstrb), .s_bvalid(ocl_bvalid), .s_bready(ocl_bready), .s_bresp(ocl_bresp),
    .s_arvalid(ocl_arvalid), .s_arready(ocl_arready), .s_araddr(ocl_araddr), .s_rvalid(ocl_rvalid), .s_rready(ocl_rready),
    .s_rdata(ocl_rdata), .s_rresp(ocl_rresp),
    .m_awvalid(r_awvalid), .m_awready(r_awready), .m_awaddr(r_awaddr), .m_wvalid(r_wvalid), .m_wready(r_wready),
    .m_wdata(r_wdata), .m_wstrb(r_wstrb), .m_bvalid(r_bvalid), .m_bready(r_bready), .m_bresp(r_bresp),
    .m_arvalid(r_arvalid), .m_arready(r_arready), .m_araddr(r_araddr), .m_rvalid(r_rvalid), .m_rready(r_rready),
    .m_rdata(r_rdata), .m_rresp(r_rresp));

  logic [NL-1:0]        start, job_abort, acc, ign, busy, done, res_ovf, res_axi_err, res_abort;
  logic [NL-1:0][63:0]  in_addr, out_addr, res_hash;
  logic [NL-1:0][31:0]  in_len, out_max, res_cycles, res_in_wait, res_out_wait, res_pixels, res_records;
  logic [NL-1:0][12:0]  res_err;
  logic [NL-1:0][15:0]  res_w, res_h;
  f2_regs #(.NL(NL), .DW(DW), .ALW(16), .COMMIT(COMMIT)) u_regs (.clk(clk), .rst(rst),
    .s_awvalid(r_awvalid), .s_awready(r_awready), .s_awaddr(r_awaddr[15:0]), .s_wvalid(r_wvalid), .s_wready(r_wready),
    .s_wdata(r_wdata), .s_wstrb(r_wstrb), .s_bvalid(r_bvalid), .s_bready(r_bready), .s_bresp(r_bresp),
    .s_arvalid(r_arvalid), .s_arready(r_arready), .s_araddr(r_araddr[15:0]), .s_rvalid(r_rvalid), .s_rready(r_rready),
    .s_rdata(r_rdata), .s_rresp(r_rresp),
    .mem_ready(mem_on), .mem_err(mem_err),
    .start(start), .job_abort(job_abort), .in_addr(in_addr), .in_len(in_len), .out_addr(out_addr), .out_max(out_max),
    .acc(acc), .ign(ign), .busy(busy), .done(done), .res_err(res_err), .res_ovf(res_ovf), .res_axi_err(res_axi_err),
    .res_abort(res_abort), .res_cycles(res_cycles), .res_in_wait(res_in_wait), .res_out_wait(res_out_wait),
    .res_pixels(res_pixels), .res_records(res_records), .res_hash(res_hash), .res_w(res_w), .res_h(res_h));

  // ================================================================ the multiplexer's master ports
  logic [NM-1:0]           x_arvalid, x_arready, x_rvalid, x_rready, x_awvalid, x_awready, x_wvalid, x_wready, x_wlast;
  logic [NM-1:0]           x_bvalid, x_bready;
  logic [NM-1:0][63:0]     x_araddr, x_awaddr;
  logic [NM-1:0][7:0]      x_arlen, x_awlen;
  logic [NM-1:0][DW-1:0]   x_wdata;
  logic [NM-1:0][DW/8-1:0] x_wstrb;
  logic [DW-1:0]           x_rdata;
  logic [1:0]              x_rresp, x_bresp;
  logic                    x_rlast;

  // ================================================================ the lanes
  genvar i;
  generate
    for (i = 0; i < NL; i = i + 1) begin : g_lane
      logic        rst_l, start_q, abort_q, busy_l, done_l;
      logic [63:0] in_addr_q, out_addr_q;
      logic [31:0] in_len_q, out_max_q;
      always_ff @(posedge clk) begin
        rst_l <= rst;
        start_q <= start[i] && !rst; abort_q <= job_abort[i] && !rst;
        in_addr_q <= in_addr[i]; in_len_q <= in_len[i]; out_addr_q <= out_addr[i]; out_max_q <= out_max[i];
        acc[i] <= start_q && !busy_l && !rst_l;       // mem_lane takes a start exactly when it is not busy
        ign[i] <= start_q && busy_l && !rst_l;
        busy[i] <= busy_l; done[i] <= done_l;
      end
      // the lane's AXI4 master, then a register slice to the multiplexer
      logic         l_arvalid, l_arready, l_rvalid, l_rready, l_rlast, l_awvalid, l_awready, l_wvalid, l_wready, l_wlast;
      logic         l_bvalid, l_bready;
      logic [63:0]  l_araddr, l_awaddr;
      logic [7:0]   l_arlen, l_awlen;
      logic [2:0]   l_arsize, l_awsize;
      logic [1:0]   l_arburst, l_awburst, l_rresp, l_bresp;
      logic [DW-1:0] l_rdata, l_wdata;
      logic [DW/8-1:0] l_wstrb;
      mem_lane #(.AW(64), .DW(DW), .BURST(16), .WOUT(8)) u_lane (
        .clk(clk), .rst(rst_l),
        .start(start_q), .job_abort(abort_q), .in_addr(in_addr_q), .in_len(in_len_q), .out_addr(out_addr_q),
        .out_max(out_max_q), .busy(busy_l), .done(done_l),
        .res_err(res_err[i]), .res_ovf(res_ovf[i]), .res_axi_err(res_axi_err[i]), .res_abort(res_abort[i]),
        .res_cycles(res_cycles[i]), .res_in_wait(res_in_wait[i]), .res_out_wait(res_out_wait[i]),
        .res_pixels(res_pixels[i]), .res_records(res_records[i]), .res_hash(res_hash[i]),
        .res_w(res_w[i]), .res_h(res_h[i]),
        .arvalid(l_arvalid), .arready(l_arready), .araddr(l_araddr), .arlen(l_arlen), .arsize(l_arsize), .arburst(l_arburst),
        .rvalid(l_rvalid), .rready(l_rready), .rdata(l_rdata), .rlast(l_rlast), .rresp(l_rresp),
        .awvalid(l_awvalid), .awready(l_awready), .awaddr(l_awaddr), .awlen(l_awlen), .awsize(l_awsize), .awburst(l_awburst),
        .wvalid(l_wvalid), .wready(l_wready), .wdata(l_wdata), .wstrb(l_wstrb), .wlast(l_wlast),
        .bvalid(l_bvalid), .bready(l_bready), .bresp(l_bresp));
      logic       s_bid, s_rid, m_awid, m_arid;
      f2_axi_slice #(.IDW(1), .AW(64), .DW(DW)) u_slc (.clk(clk), .rst(rst_l),
        .s_awvalid(l_awvalid), .s_awready(l_awready), .s_awid(1'b0), .s_awaddr(l_awaddr), .s_awlen(l_awlen),
        .s_wvalid(l_wvalid), .s_wready(l_wready), .s_wdata(l_wdata), .s_wstrb(l_wstrb), .s_wlast(l_wlast),
        .s_bvalid(l_bvalid), .s_bready(l_bready), .s_bid(s_bid), .s_bresp(l_bresp),
        .s_arvalid(l_arvalid), .s_arready(l_arready), .s_arid(1'b0), .s_araddr(l_araddr), .s_arlen(l_arlen),
        .s_rvalid(l_rvalid), .s_rready(l_rready), .s_rid(s_rid), .s_rdata(l_rdata), .s_rresp(l_rresp), .s_rlast(l_rlast),
        .m_awvalid(x_awvalid[i]), .m_awready(x_awready[i]), .m_awid(m_awid), .m_awaddr(x_awaddr[i]), .m_awlen(x_awlen[i]),
        .m_wvalid(x_wvalid[i]), .m_wready(x_wready[i]), .m_wdata(x_wdata[i]), .m_wstrb(x_wstrb[i]), .m_wlast(x_wlast[i]),
        .m_bvalid(x_bvalid[i]), .m_bready(x_bready[i]), .m_bid(1'b0), .m_bresp(x_bresp),
        .m_arvalid(x_arvalid[i]), .m_arready(x_arready[i]), .m_arid(m_arid), .m_araddr(x_araddr[i]), .m_arlen(x_arlen[i]),
        .m_rvalid(x_rvalid[i]), .m_rready(x_rready[i]), .m_rid(1'b0), .m_rdata(x_rdata), .m_rresp(x_rresp), .m_rlast(x_rlast));
    end
  endgenerate

  // ================================================================ the host's memory port
  logic             p_awvalid, p_awready, p_wvalid, p_wready, p_wlast, p_bvalid, p_bready, p_arvalid, p_arready;
  logic             p_rvalid, p_rready, p_rlast;
  logic [IDW-1:0]   p_awid, p_bid, p_arid, p_rid;
  logic [63:0]      p_awaddr, p_araddr;
  logic [7:0]       p_awlen, p_arlen;
  logic [DW-1:0]    p_wdata, p_rdata;
  logic [DW/8-1:0]  p_wstrb;
  logic [1:0]       p_bresp, p_rresp;
  f2_axi_slice #(.IDW(IDW), .AW(64), .DW(DW)) u_pcis_slc (.clk(clk), .rst(rst),
    .s_awvalid(pcis_awvalid), .s_awready(pcis_awready), .s_awid(pcis_awid), .s_awaddr(pcis_awaddr), .s_awlen(pcis_awlen),
    .s_wvalid(pcis_wvalid), .s_wready(pcis_wready), .s_wdata(pcis_wdata), .s_wstrb(pcis_wstrb), .s_wlast(pcis_wlast),
    .s_bvalid(pcis_bvalid), .s_bready(pcis_bready), .s_bid(pcis_bid), .s_bresp(pcis_bresp),
    .s_arvalid(pcis_arvalid), .s_arready(pcis_arready), .s_arid(pcis_arid), .s_araddr(pcis_araddr), .s_arlen(pcis_arlen),
    .s_rvalid(pcis_rvalid), .s_rready(pcis_rready), .s_rid(pcis_rid), .s_rdata(pcis_rdata), .s_rresp(pcis_rresp),
    .s_rlast(pcis_rlast),
    .m_awvalid(p_awvalid), .m_awready(p_awready), .m_awid(p_awid), .m_awaddr(p_awaddr), .m_awlen(p_awlen),
    .m_wvalid(p_wvalid), .m_wready(p_wready), .m_wdata(p_wdata), .m_wstrb(p_wstrb), .m_wlast(p_wlast),
    .m_bvalid(p_bvalid), .m_bready(p_bready), .m_bid(p_bid), .m_bresp(p_bresp),
    .m_arvalid(p_arvalid), .m_arready(p_arready), .m_arid(p_arid), .m_araddr(p_araddr), .m_arlen(p_arlen),
    .m_rvalid(p_rvalid), .m_rready(p_rready), .m_rid(p_rid), .m_rdata(p_rdata), .m_rresp(p_rresp), .m_rlast(p_rlast));
  f2_pcis #(.IDW(IDW), .MAW(MAW), .DW(DW), .IDQ(32)) u_pcis (.clk(clk), .rst(rst),
    .mem_ready(mem_ready_q), .mem_on(mem_on), .err_cnt(mem_err),
    .s_awvalid(p_awvalid), .s_awready(p_awready), .s_awid(p_awid), .s_awaddr(p_awaddr), .s_awlen(p_awlen),
    .s_wvalid(p_wvalid), .s_wready(p_wready), .s_wdata(p_wdata), .s_wstrb(p_wstrb), .s_wlast(p_wlast),
    .s_bvalid(p_bvalid), .s_bready(p_bready), .s_bid(p_bid), .s_bresp(p_bresp),
    .s_arvalid(p_arvalid), .s_arready(p_arready), .s_arid(p_arid), .s_araddr(p_araddr), .s_arlen(p_arlen),
    .s_rvalid(p_rvalid), .s_rready(p_rready), .s_rid(p_rid), .s_rdata(p_rdata), .s_rresp(p_rresp), .s_rlast(p_rlast),
    .m_awvalid(x_awvalid[NL]), .m_awready(x_awready[NL]), .m_awaddr(x_awaddr[NL]), .m_awlen(x_awlen[NL]),
    .m_wvalid(x_wvalid[NL]), .m_wready(x_wready[NL]), .m_wdata(x_wdata[NL]), .m_wstrb(x_wstrb[NL]), .m_wlast(x_wlast[NL]),
    .m_bvalid(x_bvalid[NL]), .m_bready(x_bready[NL]), .m_bresp(x_bresp),
    .m_arvalid(x_arvalid[NL]), .m_arready(x_arready[NL]), .m_araddr(x_araddr[NL]), .m_arlen(x_arlen[NL]),
    .m_rvalid(x_rvalid[NL]), .m_rready(x_rready[NL]), .m_rdata(x_rdata), .m_rresp(x_rresp), .m_rlast(x_rlast));

  // ================================================================ the multiplexer, then a slice to the memory
  logic             d_arvalid, d_arready, d_rvalid, d_rready, d_rlast, d_awvalid, d_awready, d_wvalid, d_wready, d_wlast;
  logic             d_bvalid, d_bready;
  logic [IDW-1:0]   d_arid, d_rid, d_awid, d_bid;
  logic [63:0]      d_araddr, d_awaddr;
  logic [7:0]       d_arlen, d_awlen;
  logic [DW-1:0]    d_rdata, d_wdata;
  logic [DW/8-1:0]  d_wstrb;
  logic [1:0]       d_rresp, d_bresp;
  f2_axi_mux #(.NM(NM), .IDW(IDW), .AW(64), .DW(DW), .WQ(16)) u_mux (.clk(clk), .rst(rst),
    .up_arvalid(x_arvalid), .up_arready(x_arready), .up_araddr(x_araddr), .up_arlen(x_arlen),
    .up_rvalid(x_rvalid), .up_rready(x_rready), .up_rdata(x_rdata), .up_rresp(x_rresp), .up_rlast(x_rlast),
    .up_awvalid(x_awvalid), .up_awready(x_awready), .up_awaddr(x_awaddr), .up_awlen(x_awlen),
    .up_wvalid(x_wvalid), .up_wready(x_wready), .up_wdata(x_wdata), .up_wstrb(x_wstrb), .up_wlast(x_wlast),
    .up_bvalid(x_bvalid), .up_bready(x_bready), .up_bresp(x_bresp),
    .dn_arvalid(d_arvalid), .dn_arready(d_arready), .dn_arid(d_arid), .dn_araddr(d_araddr), .dn_arlen(d_arlen),
    .dn_rvalid(d_rvalid), .dn_rready(d_rready), .dn_rid(d_rid), .dn_rdata(d_rdata), .dn_rresp(d_rresp), .dn_rlast(d_rlast),
    .dn_awvalid(d_awvalid), .dn_awready(d_awready), .dn_awid(d_awid), .dn_awaddr(d_awaddr), .dn_awlen(d_awlen),
    .dn_wvalid(d_wvalid), .dn_wready(d_wready), .dn_wdata(d_wdata), .dn_wstrb(d_wstrb), .dn_wlast(d_wlast),
    .dn_bvalid(d_bvalid), .dn_bready(d_bready), .dn_bid(d_bid), .dn_bresp(d_bresp));
  logic [63:0] d_awaddr_m, d_araddr_m;
  assign d_awaddr_m = {{(64-MAW){1'b0}}, d_awaddr[MAW-1:0]};
  assign d_araddr_m = {{(64-MAW){1'b0}}, d_araddr[MAW-1:0]};
  f2_axi_slice #(.IDW(IDW), .AW(64), .DW(DW)) u_mem_slc (.clk(clk), .rst(rst),
    .s_awvalid(d_awvalid), .s_awready(d_awready), .s_awid(d_awid), .s_awaddr(d_awaddr_m), .s_awlen(d_awlen),
    .s_wvalid(d_wvalid), .s_wready(d_wready), .s_wdata(d_wdata), .s_wstrb(d_wstrb), .s_wlast(d_wlast),
    .s_bvalid(d_bvalid), .s_bready(d_bready), .s_bid(d_bid), .s_bresp(d_bresp),
    .s_arvalid(d_arvalid), .s_arready(d_arready), .s_arid(d_arid), .s_araddr(d_araddr_m), .s_arlen(d_arlen),
    .s_rvalid(d_rvalid), .s_rready(d_rready), .s_rid(d_rid), .s_rdata(d_rdata), .s_rresp(d_rresp), .s_rlast(d_rlast),
    .m_awvalid(mem_awvalid), .m_awready(mem_awready), .m_awid(mem_awid), .m_awaddr(mem_awaddr), .m_awlen(mem_awlen),
    .m_wvalid(mem_wvalid), .m_wready(mem_wready), .m_wdata(mem_wdata), .m_wstrb(mem_wstrb), .m_wlast(mem_wlast),
    .m_bvalid(mem_bvalid), .m_bready(mem_bready), .m_bid(mem_bid), .m_bresp(mem_bresp),
    .m_arvalid(mem_arvalid), .m_arready(mem_arready), .m_arid(mem_arid), .m_araddr(mem_araddr), .m_arlen(mem_arlen),
    .m_rvalid(mem_rvalid), .m_rready(mem_rready), .m_rid(mem_rid), .m_rdata(mem_rdata), .m_rresp(mem_rresp),
    .m_rlast(mem_rlast));

  // ================================================================ status LEDs (read with fpga-get-virtual-led)
  always_ff @(posedge clk) vled <= {12'd0, |done, |busy, mem_on, mem_ready_q};
endmodule
