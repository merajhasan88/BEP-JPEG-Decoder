// sh_ddr_sim.sv - simulation only (Verilator): a stand-in for AWS's sh_ddr with the same module name and ports
// (the HDK's sh_ddr.stub.sv), so that the CL's real top level (../cl_jpeg/design/cl_jpeg.sv with the HDK's
// cl_ports.vh) is simulated unchanged. The DDR4 itself is a model in the testbench (tb_cl.cpp, ddr_step): every
// clock this module hands it the inputs and takes the next value of every output, so all outputs are registers.
// The pins (M_*) are left alone.
module sh_ddr #(
  parameter DDR_PRESENT  = 1,
  parameter DDR_IO       = 1,
  parameter DATA_WIDTH   = 512,
  parameter ADDR_WIDTH   = 64,
  parameter ID_WIDTH     = 16,
  parameter LEN_WIDTH    = 8,
  parameter AXUSER_WIDTH = 1
) (
  input                             clk,
  input                             rst_n,
  input                             stat_clk,
  input                             stat_rst_n,
  input logic                       CLK_DIMM_DP,
  input logic                       CLK_DIMM_DN,
  output logic                      M_ACT_N,
  output logic [17:0]               M_MA,
  output logic [1:0]                M_BA,
  output logic [1:0]                M_BG,
  output logic [1:0]                M_CKE,
  output logic [1:0]                M_ODT,
  output logic [1:0]                M_CS_N,
  output logic [1:0]                M_CLK_DN,
  output logic [1:0]                M_CLK_DP,
  output logic                      M_PAR,
  inout        [63:0]               M_DQ,
  inout        [7:0]                M_ECC,
  inout        [17:0]               M_DQS_DP,
  inout        [17:0]               M_DQS_DN,
  output logic                      cl_RST_DIMM_N,
  input logic [ID_WIDTH-1:0]        cl_sh_ddr_axi_awid,
  input logic [ADDR_WIDTH-1:0]      cl_sh_ddr_axi_awaddr,
  input logic [LEN_WIDTH-1:0]       cl_sh_ddr_axi_awlen,
  input logic [2:0]                 cl_sh_ddr_axi_awsize,
  input logic                       cl_sh_ddr_axi_awvalid,
  input logic [1:0]                 cl_sh_ddr_axi_awburst,
  input logic                       cl_sh_ddr_axi_awuser,
  output logic                      cl_sh_ddr_axi_awready,
  input logic [DATA_WIDTH-1:0]      cl_sh_ddr_axi_wdata,
  input logic [(DATA_WIDTH>>3)-1:0] cl_sh_ddr_axi_wstrb,
  input logic                       cl_sh_ddr_axi_wlast,
  input logic                       cl_sh_ddr_axi_wvalid,
  output logic                      cl_sh_ddr_axi_wready,
  output logic [ID_WIDTH-1:0]       cl_sh_ddr_axi_bid,
  output logic [1:0]                cl_sh_ddr_axi_bresp,
  output logic                      cl_sh_ddr_axi_bvalid,
  input logic                       cl_sh_ddr_axi_bready,
  input logic [ID_WIDTH-1:0]        cl_sh_ddr_axi_arid,
  input logic [ADDR_WIDTH-1:0]      cl_sh_ddr_axi_araddr,
  input logic [LEN_WIDTH-1:0]       cl_sh_ddr_axi_arlen,
  input logic [2:0]                 cl_sh_ddr_axi_arsize,
  input logic                       cl_sh_ddr_axi_arvalid,
  input logic [1:0]                 cl_sh_ddr_axi_arburst,
  input logic                       cl_sh_ddr_axi_aruser,
  output logic                      cl_sh_ddr_axi_arready,
  output logic [ID_WIDTH-1:0]       cl_sh_ddr_axi_rid,
  output logic [DATA_WIDTH-1:0]     cl_sh_ddr_axi_rdata,
  output logic [1:0]                cl_sh_ddr_axi_rresp,
  output logic                      cl_sh_ddr_axi_rlast,
  output logic                      cl_sh_ddr_axi_rvalid,
  input logic                       cl_sh_ddr_axi_rready,
  input logic [7:0]                 sh_ddr_stat_bus_addr,
  input logic [31:0]                sh_ddr_stat_bus_wdata,
  input logic                       sh_ddr_stat_bus_wr,
  input logic                       sh_ddr_stat_bus_rd,
  output logic                      sh_ddr_stat_bus_ack,
  output logic [31:0]               sh_ddr_stat_bus_rdata,
  output logic [7:0]                ddr_sh_stat_int,
  output logic                      sh_cl_ddr_is_ready
);
  import "DPI-C" function void ddr_step(
    input  bit         rst,
    input  bit         awvalid, input bit [15:0] awid, input longint unsigned awaddr, input bit [7:0] awlen,
    input  bit [2:0]   awsize,  input bit [1:0] awburst,
    input  bit         wvalid,  input bit [511:0] wdata, input bit [63:0] wstrb, input bit wlast,
    input  bit         bready,
    input  bit         arvalid, input bit [15:0] arid, input longint unsigned araddr, input bit [7:0] arlen,
    input  bit [2:0]   arsize,  input bit [1:0] arburst,
    input  bit         rready,
    input  bit         stat_wr, input bit stat_rd, input bit [7:0] stat_addr,
    output bit         o_awready, output bit o_wready,
    output bit         o_bvalid, output bit [15:0] o_bid, output bit [1:0] o_bresp,
    output bit         o_arready,
    output bit         o_rvalid, output bit [15:0] o_rid, output bit [511:0] o_rdata, output bit [1:0] o_rresp,
    output bit         o_rlast,
    output bit         o_stat_ack, output bit [31:0] o_stat_rdata, output bit o_ready);

  assign M_ACT_N = 1'b1; assign M_MA = '0; assign M_BA = '0; assign M_BG = '0; assign M_CKE = '0; assign M_ODT = '0;
  assign M_CS_N = '1; assign M_CLK_DN = '0; assign M_CLK_DP = '0; assign M_PAR = 1'b0; assign cl_RST_DIMM_N = 1'b1;
  assign ddr_sh_stat_int = 8'd0;

  bit         t_awready, t_wready, t_bvalid, t_arready, t_rvalid, t_rlast, t_stat_ack, t_ready;
  bit [15:0]  t_bid, t_rid;
  bit [1:0]   t_bresp, t_rresp;
  bit [511:0] t_rdata;
  bit [31:0]  t_stat_rdata;
  always @(posedge clk) begin
    ddr_step(!rst_n,
             cl_sh_ddr_axi_awvalid, cl_sh_ddr_axi_awid, cl_sh_ddr_axi_awaddr, cl_sh_ddr_axi_awlen,
             cl_sh_ddr_axi_awsize, cl_sh_ddr_axi_awburst,
             cl_sh_ddr_axi_wvalid, cl_sh_ddr_axi_wdata, cl_sh_ddr_axi_wstrb, cl_sh_ddr_axi_wlast,
             cl_sh_ddr_axi_bready,
             cl_sh_ddr_axi_arvalid, cl_sh_ddr_axi_arid, cl_sh_ddr_axi_araddr, cl_sh_ddr_axi_arlen,
             cl_sh_ddr_axi_arsize, cl_sh_ddr_axi_arburst,
             cl_sh_ddr_axi_rready,
             sh_ddr_stat_bus_wr, sh_ddr_stat_bus_rd, sh_ddr_stat_bus_addr,
             t_awready, t_wready, t_bvalid, t_bid, t_bresp, t_arready,
             t_rvalid, t_rid, t_rdata, t_rresp, t_rlast, t_stat_ack, t_stat_rdata, t_ready);
    cl_sh_ddr_axi_awready <= t_awready;
    cl_sh_ddr_axi_wready  <= t_wready;
    cl_sh_ddr_axi_bvalid  <= t_bvalid;
    cl_sh_ddr_axi_bid     <= t_bid;
    cl_sh_ddr_axi_bresp   <= t_bresp;
    cl_sh_ddr_axi_arready <= t_arready;
    cl_sh_ddr_axi_rvalid  <= t_rvalid;
    cl_sh_ddr_axi_rid     <= t_rid;
    cl_sh_ddr_axi_rdata   <= t_rdata;
    cl_sh_ddr_axi_rresp   <= t_rresp;
    cl_sh_ddr_axi_rlast   <= t_rlast;
    sh_ddr_stat_bus_ack   <= t_stat_ack;
    sh_ddr_stat_bus_rdata <= t_stat_rdata;
    sh_cl_ddr_is_ready    <= t_ready;
  end
endmodule
