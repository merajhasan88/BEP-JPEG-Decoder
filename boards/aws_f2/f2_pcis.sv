// f2_pcis.sv - the host's memory port of the F2 harness (ROADMAP.md, Task B): the shell's PCIS port
// (AppPF BAR4: the host's reads and writes, 512-bit AXI4, IDs from the shell) turned into one master of
// the memory multiplexer (f2_axi_mux.sv, no IDs). Vendor-neutral.
//   - Each beat is 64 bytes (AxSIZE 6, the shell's only size; a single narrower beat works too, its bytes
//     sit on their own byte lanes). The address is aligned down to 64 bytes: the first beat's byte strobes
//     (writes) or byte lanes (reads) already say which bytes count, so nothing changes for the host. The
//     address is reduced to the memory's size (MAW bits: aliases above it).
//   - The shell's IDs are kept in order in two FIFOs: every transaction of this port reaches the memory
//     with the same ID, so the memory completes them in order, and the answers carry their own IDs back.
//   - Until the memory is ready (mem_ready, on F2 the DDR4's calibration), a request is not left waiting
//     (the shell would end it after 8 us and the port stays broken until the image is loaded again): it is
//     answered here with SLVERR (reads return zeros) and counted. The port switches to the memory once,
//     between two transactions. The host checks the STATUS register (f2_regs.sv) before using BAR4.
module f2_pcis #(
  parameter int IDW = 16,
  parameter int MAW = 36,                  // memory address bits (64 GiB)
  parameter int DW  = 512,
  parameter int IDQ = 32                   // transactions in flight per direction (the shell issues at most 32)
) (
  input  logic                clk,
  input  logic                rst,
  input  logic                mem_ready,
  output logic                mem_on,      // the port reaches the memory
  output logic [31:0]         err_cnt,     // requests answered with SLVERR before mem_on
  // from the shell (through a register slice)
  input  logic                s_awvalid,
  output logic                s_awready,
  input  logic [IDW-1:0]      s_awid,
  input  logic [63:0]         s_awaddr,
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
  input  logic [63:0]         s_araddr,
  input  logic [7:0]          s_arlen,
  output logic                s_rvalid,
  input  logic                s_rready,
  output logic [IDW-1:0]      s_rid,
  output logic [DW-1:0]       s_rdata,
  output logic [1:0]          s_rresp,
  output logic                s_rlast,
  // to the memory multiplexer
  output logic                m_awvalid,
  input  logic                m_awready,
  output logic [63:0]         m_awaddr,
  output logic [7:0]          m_awlen,
  output logic                m_wvalid,
  input  logic                m_wready,
  output logic [DW-1:0]       m_wdata,
  output logic [DW/8-1:0]     m_wstrb,
  output logic                m_wlast,
  input  logic                m_bvalid,
  output logic                m_bready,
  input  logic [1:0]          m_bresp,
  output logic                m_arvalid,
  input  logic                m_arready,
  output logic [63:0]         m_araddr,
  output logic [7:0]          m_arlen,
  input  logic                m_rvalid,
  output logic                m_rready,
  input  logic [DW-1:0]       m_rdata,
  input  logic [1:0]          m_rresp,
  input  logic                m_rlast
);
  localparam int QB = $clog2(IDQ);

  // ---- the two ID FIFOs (write: AW accepted -> B returned; read: AR accepted -> last R beat returned)
  logic [IDW-1:0] wid_q [0:IDQ-1];
  logic [IDW-1:0] rid_q [0:IDQ-1];
  logic [QB-1:0]  wid_wp, wid_rp, rid_wp, rid_rp;
  logic [QB:0]    wid_n, rid_n;
  logic           wid_full, rid_full;
  assign wid_full = (wid_n == (QB+1)'(IDQ));
  assign rid_full = (rid_n == (QB+1)'(IDQ));

  // ---- the local answer before the memory is ready: one write and one read at a time
  logic           lw_act, lw_resp, lr_act;      // a write takes its data / waits for its B; a read sends beats
  logic [IDW-1:0] lw_id, lr_id;
  logic [7:0]     lr_left;
  logic           l_idle;
  assign l_idle = !lw_act && !lw_resp && !lr_act;

  // ---- the two paths
  logic aw_go, ar_go, b_go, r_go, r_last_go;
  assign m_awvalid = mem_on && s_awvalid && !wid_full;
  assign m_awaddr  = {{(64-MAW){1'b0}}, s_awaddr[MAW-1:6], 6'd0};
  assign m_awlen   = s_awlen;
  assign m_wvalid  = mem_on && s_wvalid;
  assign m_wdata   = s_wdata;
  assign m_wstrb   = s_wstrb;
  assign m_wlast   = s_wlast;
  assign m_arvalid = mem_on && s_arvalid && !rid_full;
  assign m_araddr  = {{(64-MAW){1'b0}}, s_araddr[MAW-1:6], 6'd0};
  assign m_arlen   = s_arlen;
  assign m_bready  = mem_on && s_bready;
  assign m_rready  = mem_on && s_rready;

  assign s_awready = mem_on ? (m_awready && !wid_full) : (l_idle && !mem_ready);
  assign s_wready  = mem_on ? m_wready : lw_act;
  assign s_bvalid  = mem_on ? m_bvalid : lw_resp;
  assign s_bid     = mem_on ? wid_q[wid_rp] : lw_id;
  assign s_bresp   = mem_on ? m_bresp : 2'b10;
  assign s_arready = mem_on ? (m_arready && !rid_full) : (l_idle && !mem_ready);
  assign s_rvalid  = mem_on ? m_rvalid : lr_act;
  assign s_rid     = mem_on ? rid_q[rid_rp] : lr_id;
  assign s_rdata   = mem_on ? m_rdata : '0;
  assign s_rresp   = mem_on ? m_rresp : 2'b10;
  assign s_rlast   = mem_on ? m_rlast : (lr_left == 8'd0);

  assign aw_go     = mem_on && m_awvalid && m_awready;
  assign ar_go     = mem_on && m_arvalid && m_arready;
  assign b_go      = mem_on && m_bvalid && m_bready;
  assign r_go      = mem_on && m_rvalid && m_rready;
  assign r_last_go = r_go && m_rlast;

  always_ff @(posedge clk) begin
    if (rst) begin
      mem_on <= 1'b0; err_cnt <= '0;
      wid_wp <= '0; wid_rp <= '0; wid_n <= '0; rid_wp <= '0; rid_rp <= '0; rid_n <= '0;
      lw_act <= 1'b0; lw_resp <= 1'b0; lr_act <= 1'b0; lw_id <= '0; lr_id <= '0; lr_left <= '0;
    end else begin
      // the switch to the memory: once, between transactions (the local side accepts nothing once mem_ready is up)
      if (!mem_on && mem_ready && l_idle) mem_on <= 1'b1;
      // the memory path's ID FIFOs
      if (aw_go) begin wid_q[wid_wp] <= s_awid; wid_wp <= wid_wp + 1'b1; end
      if (b_go) wid_rp <= wid_rp + 1'b1;
      wid_n <= wid_n + (aw_go ? 1'b1 : 1'b0) - (b_go ? 1'b1 : 1'b0);
      if (ar_go) begin rid_q[rid_wp] <= s_arid; rid_wp <= rid_wp + 1'b1; end
      if (r_last_go) rid_rp <= rid_rp + 1'b1;
      rid_n <= rid_n + (ar_go ? 1'b1 : 1'b0) - (r_last_go ? 1'b1 : 1'b0);
      // the local answers
      if (!mem_on) begin
        err_cnt <= err_cnt + 32'(s_awvalid && s_awready) + 32'(s_arvalid && s_arready);
        if (s_awvalid && s_awready) begin lw_act <= 1'b1; lw_id <= s_awid; end
        if (lw_act && s_wvalid && s_wlast) begin lw_act <= 1'b0; lw_resp <= 1'b1; end
        if (lw_resp && s_bready) lw_resp <= 1'b0;
        if (s_arvalid && s_arready) begin lr_act <= 1'b1; lr_id <= s_arid; lr_left <= s_arlen; end
        if (lr_act && s_rready) begin
          if (lr_left == 8'd0) lr_act <= 1'b0;
          else lr_left <= lr_left - 8'd1;
        end
      end
    end
  end
endmodule
