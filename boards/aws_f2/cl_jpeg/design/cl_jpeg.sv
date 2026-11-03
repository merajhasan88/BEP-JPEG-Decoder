// cl_jpeg.sv - the custom logic (CL) of the BEP-JPEG F2 image for AWS EC2 F2 (small shell, aws-fpga HDK
// v2.3.5): NL wide decoder lanes working from the FPGA card's DDR4 (ROADMAP.md, Task B; image 1: the batch
// engine on DDR4). The ports are the shell's, from the HDK's cl_ports.vh (included, not copied).
//   - OCL (AppPF BAR0): the registers (../../f2_regs.sv).
//   - PCIS (AppPF BAR4): the host's reads and writes of the DDR4 (../../f2_pcis.sv); BAR4 offset = DDR4 address.
//   - DDR4: AWS's sh_ddr (the HDK's DDR4 controller wrapper, required in every CL), wired as in AWS's examples:
//     its resets from rst_main_n only, its statistics bus through 8 registers each way.
//   - Everything else is tied off; no HBM, no PCIM, no interrupts, no clock generator: one clock, clk_main_a0
//     (250 MHz).
// Placement: the shell's OCL and PCIS ports are on the middle die (SLR1), the DDR4 on the top die (SLR2). The
// first register stage of OCL, PCIS and the reset, and the sending halves of the links to the core (SH_SIDE) stay
// next to the shell; the core (CORE, with the links' receiving halves), its slice to the DDR4 (DDR_SLC), SH_DDR and
// its statistics pipes go to SLR2 (build/constraints/small_shell_cl_pnr_user.xdc). The links (f2_slices.sv) carry
// OCL and PCIS across the dies with credits: every wire between SH_SIDE and CORE leaves a register and enters one.
module cl_jpeg #(
  parameter EN_DDR = 1,
  parameter NL     = 15
) (
  `include "cl_ports.vh"
);
`include "cl_id_defines.vh"
`include "cl_jpeg_defines.vh"

  // ================================================================ globals
  logic flr_q;
  always_ff @(posedge clk_main_a0) begin             // function-level reset: acknowledged, as AWS's examples do
    if (!rst_main_n) begin flr_q <= 1'b0; cl_sh_flr_done <= 1'b0; end
    else begin flr_q <= sh_cl_flr_assert; cl_sh_flr_done <= flr_q && !cl_sh_flr_done; end
  end
  assign cl_sh_status0     = 32'd0;
  assign cl_sh_status1     = 32'd0;
  assign cl_sh_status2     = 32'd0;
  assign cl_sh_id0         = `CL_SH_ID0;
  assign cl_sh_id1         = `CL_SH_ID1;
  assign cl_sh_dma_wr_full = 1'b0;
  assign cl_sh_dma_rd_full = 1'b0;

  // ================================================================ the shell's side: first registers
  logic         core_rst;
  localparam int OFW = 3 + 2 * 32 + 36 + 2, OBW = 3 + 2 + 34 + 2;                 // the OCL link's buses
  localparam int PFW = 3 + 2 * (16 + 64 + 8) + (512 + 64 + 1) + 2;               // the PCIS link's buses
  localparam int PBW = 3 + 2 + (16 + 512 + 3) + (16 + 2);
  logic [OFW-1:0] ocl_fwd;
  logic [OBW-1:0] ocl_bwd;
  logic [PFW-1:0] pcis_fwd;
  logic [PBW-1:0] pcis_bwd;
  f2_shell_side SH_SIDE (.clk(clk_main_a0), .rst_n(rst_main_n), .core_rst(core_rst),
    .ocl_awvalid(ocl_cl_awvalid), .ocl_awready(cl_ocl_awready), .ocl_awaddr(ocl_cl_awaddr),
    .ocl_wvalid(ocl_cl_wvalid), .ocl_wready(cl_ocl_wready), .ocl_wdata(ocl_cl_wdata), .ocl_wstrb(ocl_cl_wstrb),
    .ocl_bvalid(cl_ocl_bvalid), .ocl_bready(ocl_cl_bready), .ocl_bresp(cl_ocl_bresp),
    .ocl_arvalid(ocl_cl_arvalid), .ocl_arready(cl_ocl_arready), .ocl_araddr(ocl_cl_araddr),
    .ocl_rvalid(cl_ocl_rvalid), .ocl_rready(ocl_cl_rready), .ocl_rdata(cl_ocl_rdata), .ocl_rresp(cl_ocl_rresp),
    .pcis_awvalid(sh_cl_dma_pcis_awvalid), .pcis_awready(cl_sh_dma_pcis_awready), .pcis_awid(sh_cl_dma_pcis_awid),
    .pcis_awaddr(sh_cl_dma_pcis_awaddr), .pcis_awlen(sh_cl_dma_pcis_awlen),
    .pcis_wvalid(sh_cl_dma_pcis_wvalid), .pcis_wready(cl_sh_dma_pcis_wready), .pcis_wdata(sh_cl_dma_pcis_wdata),
    .pcis_wstrb(sh_cl_dma_pcis_wstrb), .pcis_wlast(sh_cl_dma_pcis_wlast),
    .pcis_bvalid(cl_sh_dma_pcis_bvalid), .pcis_bready(sh_cl_dma_pcis_bready), .pcis_bid(cl_sh_dma_pcis_bid),
    .pcis_bresp(cl_sh_dma_pcis_bresp),
    .pcis_arvalid(sh_cl_dma_pcis_arvalid), .pcis_arready(cl_sh_dma_pcis_arready), .pcis_arid(sh_cl_dma_pcis_arid),
    .pcis_araddr(sh_cl_dma_pcis_araddr), .pcis_arlen(sh_cl_dma_pcis_arlen),
    .pcis_rvalid(cl_sh_dma_pcis_rvalid), .pcis_rready(sh_cl_dma_pcis_rready), .pcis_rid(cl_sh_dma_pcis_rid),
    .pcis_rdata(cl_sh_dma_pcis_rdata), .pcis_rresp(cl_sh_dma_pcis_rresp), .pcis_rlast(cl_sh_dma_pcis_rlast),
    .ocl_fwd(ocl_fwd), .ocl_bwd(ocl_bwd), .pcis_fwd(pcis_fwd), .pcis_bwd(pcis_bwd));
  assign cl_sh_dma_pcis_ruser = 64'd0;

  // ================================================================ the core (SLR2)
  logic         ddr_ready;
  logic         m_awvalid, m_awready, m_wvalid, m_wready, m_wlast, m_bvalid, m_bready, m_arvalid, m_arready;
  logic         m_rvalid, m_rready, m_rlast;
  logic [15:0]  m_awid, m_bid, m_arid, m_rid;
  logic [63:0]  m_awaddr, m_araddr, m_wstrb;
  logic [7:0]   m_awlen, m_arlen;
  logic [511:0] m_wdata, m_rdata;
  logic [1:0]   m_bresp, m_rresp;
  f2_core #(.NL(NL), .IDW(16), .MAW(36), .COMMIT(`JPEG_F2_COMMIT), .OFW(OFW), .OBW(OBW), .PFW(PFW), .PBW(PBW)) CORE (
    .clk(clk_main_a0), .rst(core_rst),
    .mem_ready(ddr_ready), .vled(cl_sh_status_vled),
    .ocl_fwd(ocl_fwd), .ocl_bwd(ocl_bwd), .pcis_fwd(pcis_fwd), .pcis_bwd(pcis_bwd),
    .mem_awvalid(m_awvalid), .mem_awready(m_awready), .mem_awid(m_awid), .mem_awaddr(m_awaddr), .mem_awlen(m_awlen),
    .mem_wvalid(m_wvalid), .mem_wready(m_wready), .mem_wdata(m_wdata), .mem_wstrb(m_wstrb), .mem_wlast(m_wlast),
    .mem_bvalid(m_bvalid), .mem_bready(m_bready), .mem_bid(m_bid), .mem_bresp(m_bresp),
    .mem_arvalid(m_arvalid), .mem_arready(m_arready), .mem_arid(m_arid), .mem_araddr(m_araddr), .mem_arlen(m_arlen),
    .mem_rvalid(m_rvalid), .mem_rready(m_rready), .mem_rid(m_rid), .mem_rdata(m_rdata), .mem_rresp(m_rresp),
    .mem_rlast(m_rlast));

  // ================================================================ DDR4: a slice next to the controller, then sh_ddr
  logic         d_awvalid, d_awready, d_wvalid, d_wready, d_wlast, d_bvalid, d_bready, d_arvalid, d_arready;
  logic         d_rvalid, d_rready, d_rlast;
  logic [15:0]  d_awid, d_bid, d_arid, d_rid;
  logic [63:0]  d_awaddr, d_araddr, d_wstrb;
  logic [7:0]   d_awlen, d_arlen;
  logic [511:0] d_wdata, d_rdata;
  logic [1:0]   d_bresp, d_rresp;
  logic         ddr_rst;
  f2_axi_slice #(.IDW(16), .AW(64), .DW(512)) DDR_SLC (.clk(clk_main_a0), .rst(ddr_rst),
    .s_awvalid(m_awvalid), .s_awready(m_awready), .s_awid(m_awid), .s_awaddr(m_awaddr), .s_awlen(m_awlen),
    .s_wvalid(m_wvalid), .s_wready(m_wready), .s_wdata(m_wdata), .s_wstrb(m_wstrb), .s_wlast(m_wlast),
    .s_bvalid(m_bvalid), .s_bready(m_bready), .s_bid(m_bid), .s_bresp(m_bresp),
    .s_arvalid(m_arvalid), .s_arready(m_arready), .s_arid(m_arid), .s_araddr(m_araddr), .s_arlen(m_arlen),
    .s_rvalid(m_rvalid), .s_rready(m_rready), .s_rid(m_rid), .s_rdata(m_rdata), .s_rresp(m_rresp), .s_rlast(m_rlast),
    .m_awvalid(d_awvalid), .m_awready(d_awready), .m_awid(d_awid), .m_awaddr(d_awaddr), .m_awlen(d_awlen),
    .m_wvalid(d_wvalid), .m_wready(d_wready), .m_wdata(d_wdata), .m_wstrb(d_wstrb), .m_wlast(d_wlast),
    .m_bvalid(d_bvalid), .m_bready(d_bready), .m_bid(d_bid), .m_bresp(d_bresp),
    .m_arvalid(d_arvalid), .m_arready(d_arready), .m_arid(d_arid), .m_araddr(d_araddr), .m_arlen(d_arlen),
    .m_rvalid(d_rvalid), .m_rready(d_rready), .m_rid(d_rid), .m_rdata(d_rdata), .m_rresp(d_rresp), .m_rlast(d_rlast));

  // sh_ddr's resets come from rst_main_n only (AWS's examples insist on it); synchronous to clk_main_a0 already
  logic [3:0] ddr_rst_n_q;
  always_ff @(posedge clk_main_a0) ddr_rst_n_q <= {ddr_rst_n_q[2:0], rst_main_n};
  assign ddr_rst = !ddr_rst_n_q[3];

  logic [7:0]  stat_addr_q;
  logic        stat_wr_q, stat_rd_q, stat_ack_q;
  logic [31:0] stat_wdata_q, stat_rdata_q;
  logic [7:0]  stat_int_q;
  f2_pipe #(.W(1 + 1 + 8 + 32), .STAGES(8)) PIPE_DDR_STAT0 (.clk(clk_main_a0), .rst(ddr_rst),
    .d({sh_cl_ddr_stat_wr, sh_cl_ddr_stat_rd, sh_cl_ddr_stat_addr, sh_cl_ddr_stat_wdata}),
    .q({stat_wr_q, stat_rd_q, stat_addr_q, stat_wdata_q}));
  f2_pipe #(.W(1 + 8 + 32), .STAGES(8)) PIPE_DDR_STAT1 (.clk(clk_main_a0), .rst(ddr_rst),
    .d({stat_ack_q, stat_int_q, stat_rdata_q}),
    .q({cl_sh_ddr_stat_ack, cl_sh_ddr_stat_int, cl_sh_ddr_stat_rdata}));

  sh_ddr #(.DDR_PRESENT(EN_DDR)) SH_DDR (
    .clk(clk_main_a0), .rst_n(ddr_rst_n_q[3]), .stat_clk(clk_main_a0), .stat_rst_n(ddr_rst_n_q[3]),
    .CLK_DIMM_DP(CLK_DIMM_DP), .CLK_DIMM_DN(CLK_DIMM_DN), .M_ACT_N(M_ACT_N), .M_MA(M_MA), .M_BA(M_BA), .M_BG(M_BG),
    .M_CKE(M_CKE), .M_ODT(M_ODT), .M_CS_N(M_CS_N), .M_CLK_DN(M_CLK_DN), .M_CLK_DP(M_CLK_DP), .M_PAR(M_PAR),
    .M_DQ(M_DQ), .M_ECC(M_ECC), .M_DQS_DP(M_DQS_DP), .M_DQS_DN(M_DQS_DN), .cl_RST_DIMM_N(RST_DIMM_N),
    .cl_sh_ddr_axi_awid(d_awid), .cl_sh_ddr_axi_awaddr(d_awaddr), .cl_sh_ddr_axi_awlen(d_awlen),
    .cl_sh_ddr_axi_awsize(3'd6), .cl_sh_ddr_axi_awvalid(d_awvalid), .cl_sh_ddr_axi_awburst(2'b01),
    .cl_sh_ddr_axi_awuser(1'b0), .cl_sh_ddr_axi_awready(d_awready),
    .cl_sh_ddr_axi_wdata(d_wdata), .cl_sh_ddr_axi_wstrb(d_wstrb), .cl_sh_ddr_axi_wlast(d_wlast),
    .cl_sh_ddr_axi_wvalid(d_wvalid), .cl_sh_ddr_axi_wready(d_wready),
    .cl_sh_ddr_axi_bid(d_bid), .cl_sh_ddr_axi_bresp(d_bresp), .cl_sh_ddr_axi_bvalid(d_bvalid), .cl_sh_ddr_axi_bready(d_bready),
    .cl_sh_ddr_axi_arid(d_arid), .cl_sh_ddr_axi_araddr(d_araddr), .cl_sh_ddr_axi_arlen(d_arlen),
    .cl_sh_ddr_axi_arsize(3'd6), .cl_sh_ddr_axi_arvalid(d_arvalid), .cl_sh_ddr_axi_arburst(2'b01),
    .cl_sh_ddr_axi_aruser(1'b0), .cl_sh_ddr_axi_arready(d_arready),
    .cl_sh_ddr_axi_rid(d_rid), .cl_sh_ddr_axi_rdata(d_rdata), .cl_sh_ddr_axi_rresp(d_rresp), .cl_sh_ddr_axi_rlast(d_rlast),
    .cl_sh_ddr_axi_rvalid(d_rvalid), .cl_sh_ddr_axi_rready(d_rready),
    .sh_ddr_stat_bus_addr(stat_addr_q), .sh_ddr_stat_bus_wdata(stat_wdata_q), .sh_ddr_stat_bus_wr(stat_wr_q),
    .sh_ddr_stat_bus_rd(stat_rd_q), .sh_ddr_stat_bus_ack(stat_ack_q), .sh_ddr_stat_bus_rdata(stat_rdata_q),
    .ddr_sh_stat_int(stat_int_q), .sh_cl_ddr_is_ready(ddr_ready));

  // ================================================================ unused interfaces: idle
  // PCIM (the CL as a requester towards host memory): never used
  assign cl_sh_pcim_awid = 16'd0;    assign cl_sh_pcim_awaddr = 64'd0; assign cl_sh_pcim_awlen = 8'd0;
  assign cl_sh_pcim_awsize = 3'd0;   assign cl_sh_pcim_awburst = 2'd0; assign cl_sh_pcim_awcache = 4'd0;
  assign cl_sh_pcim_awlock = 1'b0;   assign cl_sh_pcim_awprot = 3'd0;  assign cl_sh_pcim_awqos = 4'd0;
  assign cl_sh_pcim_awuser = 55'd0;  assign cl_sh_pcim_awvalid = 1'b0;
  assign cl_sh_pcim_wid = 16'd0;     assign cl_sh_pcim_wdata = 512'd0; assign cl_sh_pcim_wstrb = 64'd0;
  assign cl_sh_pcim_wlast = 1'b0;    assign cl_sh_pcim_wuser = 64'd0;  assign cl_sh_pcim_wvalid = 1'b0;
  assign cl_sh_pcim_bready = 1'b0;
  assign cl_sh_pcim_arid = 16'd0;    assign cl_sh_pcim_araddr = 64'd0; assign cl_sh_pcim_arlen = 8'd0;
  assign cl_sh_pcim_arsize = 3'd0;   assign cl_sh_pcim_arburst = 2'd0; assign cl_sh_pcim_arcache = 4'd0;
  assign cl_sh_pcim_arlock = 1'b0;   assign cl_sh_pcim_arprot = 3'd0;  assign cl_sh_pcim_arqos = 4'd0;
  assign cl_sh_pcim_aruser = 55'd0;  assign cl_sh_pcim_arvalid = 1'b0; assign cl_sh_pcim_rready = 1'b0;
  // SDA (MgmtPF BAR4): not used by this CL
  assign cl_sda_awready = 1'b0; assign cl_sda_wready = 1'b0; assign cl_sda_bvalid = 1'b0; assign cl_sda_bresp = 2'd0;
  assign cl_sda_arready = 1'b0; assign cl_sda_rvalid = 1'b0; assign cl_sda_rdata = 32'd0; assign cl_sda_rresp = 2'd0;
  // interrupts, virtual JTAG
  assign cl_sh_apppf_irq_req = 16'd0;
  assign tdo = 1'b0;
  // HBM monitor: no HBM in this CL (the shell's monitor ports stay unconnected)
  assign hbm_apb_paddr_1 = 22'd0; assign hbm_apb_pprot_1 = 3'd0; assign hbm_apb_psel_1 = 1'b0;
  assign hbm_apb_penable_1 = 1'b0; assign hbm_apb_pwrite_1 = 1'b0; assign hbm_apb_pwdata_1 = 32'd0;
  assign hbm_apb_pstrb_1 = 4'd0; assign hbm_apb_pready_1 = 1'b0; assign hbm_apb_prdata_1 = 32'd0;
  assign hbm_apb_pslverr_1 = 1'b0;
  assign hbm_apb_paddr_0 = 22'd0; assign hbm_apb_pprot_0 = 3'd0; assign hbm_apb_psel_0 = 1'b0;
  assign hbm_apb_penable_0 = 1'b0; assign hbm_apb_pwrite_0 = 1'b0; assign hbm_apb_pwdata_0 = 32'd0;
  assign hbm_apb_pstrb_0 = 4'd0; assign hbm_apb_pready_0 = 1'b0; assign hbm_apb_prdata_0 = 32'd0;
  assign hbm_apb_pslverr_0 = 1'b0;
  // the PCIe pins of the shell's port list that a CL does not drive
  assign PCIE_EP_TXP = 8'd0; assign PCIE_EP_TXN = 8'd0;
  assign PCIE_RP_PERSTN = 1'b0; assign PCIE_RP_TXP = 8'd0; assign PCIE_RP_TXN = 8'd0;
endmodule

// The registers next to the shell: OCL and PCIS each through one register slice, then the sending halves of their
// links to the core (f2_slices.sv), and the core's reset.
module f2_shell_side (
  input  logic          clk,
  input  logic          rst_n,
  output logic          core_rst,
  input  logic          ocl_awvalid,
  output logic          ocl_awready,
  input  logic [31:0]   ocl_awaddr,
  input  logic          ocl_wvalid,
  output logic          ocl_wready,
  input  logic [31:0]   ocl_wdata,
  input  logic [3:0]    ocl_wstrb,
  output logic          ocl_bvalid,
  input  logic          ocl_bready,
  output logic [1:0]    ocl_bresp,
  input  logic          ocl_arvalid,
  output logic          ocl_arready,
  input  logic [31:0]   ocl_araddr,
  output logic          ocl_rvalid,
  input  logic          ocl_rready,
  output logic [31:0]   ocl_rdata,
  output logic [1:0]    ocl_rresp,
  input  logic          pcis_awvalid,
  output logic          pcis_awready,
  input  logic [15:0]   pcis_awid,
  input  logic [63:0]   pcis_awaddr,
  input  logic [7:0]    pcis_awlen,
  input  logic          pcis_wvalid,
  output logic          pcis_wready,
  input  logic [511:0]  pcis_wdata,
  input  logic [63:0]   pcis_wstrb,
  input  logic          pcis_wlast,
  output logic          pcis_bvalid,
  input  logic          pcis_bready,
  output logic [15:0]   pcis_bid,
  output logic [1:0]    pcis_bresp,
  input  logic          pcis_arvalid,
  output logic          pcis_arready,
  input  logic [15:0]   pcis_arid,
  input  logic [63:0]   pcis_araddr,
  input  logic [7:0]    pcis_arlen,
  output logic          pcis_rvalid,
  input  logic          pcis_rready,
  output logic [15:0]   pcis_rid,
  output logic [511:0]  pcis_rdata,
  output logic [1:0]    pcis_rresp,
  output logic          pcis_rlast,
  output logic [104:0]  ocl_fwd,         // the links to the core (f2_axil_link_m, f2_axi_link_m; widths as in cl_jpeg)
  input  logic [40:0]   ocl_bwd,
  output logic [757:0]  pcis_fwd,
  input  logic [553:0]  pcis_bwd
);
  // the reset: the slices next to the shell leave it first, the core one and two clocks later (cl_jpeg's CORE: one
  // register there, then one per block), the links' sending halves here last, so that their receiving halves in
  // the core are always ready first
  logic rst_q1, rst_q2, rst, rst_l1, rst_l2, rst_lnk;
  always_ff @(posedge clk) begin
    rst_q1 <= !rst_n; rst_q2 <= rst_q1; core_rst <= rst_q2;
    rst_l1 <= core_rst; rst_l2 <= rst_l1; rst_lnk <= rst_l2;
  end
  assign rst = rst_q2;
  logic        o_awvalid, o_awready, o_wvalid, o_wready, o_bvalid, o_bready, o_arvalid, o_arready, o_rvalid, o_rready;
  logic [31:0] o_awaddr, o_araddr, o_wdata, o_rdata;
  logic [3:0]  o_wstrb;
  logic [1:0]  o_bresp, o_rresp;
  f2_axil_slice #(.AW(32)) OCL_SLC (.clk(clk), .rst(rst),
    .s_awvalid(ocl_awvalid), .s_awready(ocl_awready), .s_awaddr(ocl_awaddr), .s_wvalid(ocl_wvalid), .s_wready(ocl_wready),
    .s_wdata(ocl_wdata), .s_wstrb(ocl_wstrb), .s_bvalid(ocl_bvalid), .s_bready(ocl_bready), .s_bresp(ocl_bresp),
    .s_arvalid(ocl_arvalid), .s_arready(ocl_arready), .s_araddr(ocl_araddr), .s_rvalid(ocl_rvalid), .s_rready(ocl_rready),
    .s_rdata(ocl_rdata), .s_rresp(ocl_rresp),
    .m_awvalid(o_awvalid), .m_awready(o_awready), .m_awaddr(o_awaddr), .m_wvalid(o_wvalid), .m_wready(o_wready),
    .m_wdata(o_wdata), .m_wstrb(o_wstrb), .m_bvalid(o_bvalid), .m_bready(o_bready), .m_bresp(o_bresp),
    .m_arvalid(o_arvalid), .m_arready(o_arready), .m_araddr(o_araddr), .m_rvalid(o_rvalid), .m_rready(o_rready),
    .m_rdata(o_rdata), .m_rresp(o_rresp));
  f2_axil_link_m #(.AW(32)) OCL_LNK (.clk(clk), .rst(rst_lnk),
    .s_awvalid(o_awvalid), .s_awready(o_awready), .s_awaddr(o_awaddr), .s_wvalid(o_wvalid), .s_wready(o_wready),
    .s_wdata(o_wdata), .s_wstrb(o_wstrb), .s_bvalid(o_bvalid), .s_bready(o_bready), .s_bresp(o_bresp),
    .s_arvalid(o_arvalid), .s_arready(o_arready), .s_araddr(o_araddr), .s_rvalid(o_rvalid), .s_rready(o_rready),
    .s_rdata(o_rdata), .s_rresp(o_rresp), .fwd(ocl_fwd), .bwd(ocl_bwd));
  logic         p_awvalid, p_awready, p_wvalid, p_wready, p_wlast, p_bvalid, p_bready, p_arvalid, p_arready;
  logic         p_rvalid, p_rready, p_rlast;
  logic [15:0]  p_awid, p_bid, p_arid, p_rid;
  logic [63:0]  p_awaddr, p_araddr, p_wstrb;
  logic [7:0]   p_awlen, p_arlen;
  logic [511:0] p_wdata, p_rdata;
  logic [1:0]   p_bresp, p_rresp;
  f2_axi_slice #(.IDW(16), .AW(64), .DW(512)) PCIS_SLC (.clk(clk), .rst(rst),
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
  f2_axi_link_m #(.IDW(16), .AW(64), .DW(512)) PCIS_LNK (.clk(clk), .rst(rst_lnk),
    .s_awvalid(p_awvalid), .s_awready(p_awready), .s_awid(p_awid), .s_awaddr(p_awaddr), .s_awlen(p_awlen),
    .s_wvalid(p_wvalid), .s_wready(p_wready), .s_wdata(p_wdata), .s_wstrb(p_wstrb), .s_wlast(p_wlast),
    .s_bvalid(p_bvalid), .s_bready(p_bready), .s_bid(p_bid), .s_bresp(p_bresp),
    .s_arvalid(p_arvalid), .s_arready(p_arready), .s_arid(p_arid), .s_araddr(p_araddr), .s_arlen(p_arlen),
    .s_rvalid(p_rvalid), .s_rready(p_rready), .s_rid(p_rid), .s_rdata(p_rdata), .s_rresp(p_rresp), .s_rlast(p_rlast),
    .fwd(pcis_fwd), .bwd(pcis_bwd));
endmodule
