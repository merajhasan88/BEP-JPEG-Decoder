// f2_axi_mux.sv - NM AXI4 masters onto one AXI4 slave (on F2: the decoder lanes and the host's PCIS port
// onto the DDR4 controller), INCR bursts of 64-byte beats. Vendor-neutral.
//   - AR and AW: round robin, decided one clock before the transfer (the grant is a register), so a
//     request takes two clocks and the master's valid stays up meanwhile (AXI: valid is held until ready).
//     The masters' valids are registered here first (they come from far away: 2026-11-03, the round robin on
//     them failed timing on the F2 at -0.389 ns), so a request is seen a clock later; the master granted in a
//     clock is left out of the next clock's copy, as its valid may drop after the handshake.
//     The slave side's ID is the master's index; the slave may answer different IDs in any order.
//   - W: the data of the bursts in the order their addresses went out (AXI4 has no WID): the index of each
//     granted AW burst is queued (WQ entries; AW waits while the queue is full) and the head's master
//     sends its beats until wlast.
//   - R and B: routed back by ID; data and response go to every master, valid only to its owner.
// Each master's transactions complete in order (one ID per master), as mem_lane.sv and f2_pcis.sv need.
// Every output to the slave is a register; the masters' ready signals are combinations of registers.
module f2_axi_mux #(
  parameter int NM  = 16,
  parameter int IDW = 16,
  parameter int AW  = 64,
  parameter int DW  = 512,
  parameter int WQ  = 16
) (
  input  logic                    clk,
  input  logic                    rst,
  // the masters
  input  logic [NM-1:0]           up_arvalid,
  output logic [NM-1:0]           up_arready,
  input  logic [NM-1:0][AW-1:0]   up_araddr,
  input  logic [NM-1:0][7:0]      up_arlen,
  output logic [NM-1:0]           up_rvalid,
  input  logic [NM-1:0]           up_rready,
  output logic [DW-1:0]           up_rdata,
  output logic [1:0]              up_rresp,
  output logic                    up_rlast,
  input  logic [NM-1:0]           up_awvalid,
  output logic [NM-1:0]           up_awready,
  input  logic [NM-1:0][AW-1:0]   up_awaddr,
  input  logic [NM-1:0][7:0]      up_awlen,
  input  logic [NM-1:0]           up_wvalid,
  output logic [NM-1:0]           up_wready,
  input  logic [NM-1:0][DW-1:0]   up_wdata,
  input  logic [NM-1:0][DW/8-1:0] up_wstrb,
  input  logic [NM-1:0]           up_wlast,
  output logic [NM-1:0]           up_bvalid,
  input  logic [NM-1:0]           up_bready,
  output logic [1:0]              up_bresp,
  // the slave
  output logic                    dn_arvalid,
  input  logic                    dn_arready,
  output logic [IDW-1:0]          dn_arid,
  output logic [AW-1:0]           dn_araddr,
  output logic [7:0]              dn_arlen,
  input  logic                    dn_rvalid,
  output logic                    dn_rready,
  input  logic [IDW-1:0]          dn_rid,
  input  logic [DW-1:0]           dn_rdata,
  input  logic [1:0]              dn_rresp,
  input  logic                    dn_rlast,
  output logic                    dn_awvalid,
  input  logic                    dn_awready,
  output logic [IDW-1:0]          dn_awid,
  output logic [AW-1:0]           dn_awaddr,
  output logic [7:0]              dn_awlen,
  output logic                    dn_wvalid,
  input  logic                    dn_wready,
  output logic [DW-1:0]           dn_wdata,
  output logic [DW/8-1:0]         dn_wstrb,
  output logic                    dn_wlast,
  input  logic                    dn_bvalid,
  output logic                    dn_bready,
  input  logic [IDW-1:0]          dn_bid,
  input  logic [1:0]              dn_bresp
);
  localparam int MB = (NM > 1) ? $clog2(NM) : 1;
  localparam int QB = $clog2(WQ);

  // the next requester after `last` in round-robin order (unused when req is 0)
  function automatic logic [MB-1:0] rr_pick(input logic [NM-1:0] req, input logic [MB-1:0] last);
    logic [MB-1:0] k;
    integer i;
    rr_pick = last;
    for (i = NM; i >= 1; i = i - 1) begin
      k = MB'((32'(last) + i) % NM);
      if (req[k]) rr_pick = k;
    end
  endfunction

  // ================================================================ AR
  logic [MB-1:0] ar_g, ar_last;
  logic          ar_gv, ar_free;
  logic [NM-1:0] ar_req;                         // up_arvalid one clock ago, without the master granted then
  assign ar_free = !dn_arvalid || dn_arready;
  always_comb begin : p_arready
    integer i;
    for (i = 0; i < NM; i = i + 1) up_arready[i] = ar_gv && ar_free && (ar_g == MB'(i));
  end
  always_ff @(posedge clk) begin
    if (rst) begin
      ar_gv <= 1'b0; ar_g <= '0; ar_last <= MB'(NM - 1); dn_arvalid <= 1'b0; ar_req <= '0;
    end else begin
      ar_req <= up_arvalid & ~((ar_gv && ar_free) ? (NM'(1) << ar_g) : '0);
      if (dn_arvalid && dn_arready) dn_arvalid <= 1'b0;
      if (ar_gv) begin
        if (ar_free) begin
          dn_arvalid <= 1'b1; dn_arid <= IDW'(ar_g); dn_araddr <= up_araddr[ar_g]; dn_arlen <= up_arlen[ar_g];
          ar_gv <= 1'b0; ar_last <= ar_g;
        end
      end else if (|ar_req) begin
        ar_g <= rr_pick(ar_req, ar_last); ar_gv <= 1'b1;
      end
    end
  end

  // ================================================================ R: by ID
  logic [MB-1:0] r_own;
  assign r_own    = dn_rid[MB-1:0];
  assign up_rdata = dn_rdata;
  assign up_rresp = dn_rresp;
  assign up_rlast = dn_rlast;
  always_comb begin : p_rvalid
    integer i;
    for (i = 0; i < NM; i = i + 1) up_rvalid[i] = dn_rvalid && (r_own == MB'(i));
  end
  assign dn_rready = up_rready[r_own];

  // ================================================================ AW, and the order of the W bursts
  logic [MB-1:0] aw_g, aw_last;
  logic          aw_gv, aw_free;
  logic [NM-1:0] aw_req;                         // up_awvalid one clock ago, without the master granted then
  logic [MB-1:0] wq [0:WQ-1];
  logic [QB-1:0] wq_wp, wq_rp;
  logic [QB:0]   wq_n;
  logic          wq_full, aw_take, w_take, w_pop;
  assign wq_full = (wq_n == (QB+1)'(WQ));
  assign aw_free = (!dn_awvalid || dn_awready) && !wq_full;
  assign aw_take = aw_gv && aw_free;                      // the granted master's AW goes out now
  always_comb begin : p_awready
    integer i;
    for (i = 0; i < NM; i = i + 1) up_awready[i] = aw_take && (aw_g == MB'(i));
  end
  always_ff @(posedge clk) begin
    if (rst) begin
      aw_gv <= 1'b0; aw_g <= '0; aw_last <= MB'(NM - 1); dn_awvalid <= 1'b0; aw_req <= '0;
    end else begin
      aw_req <= up_awvalid & ~(aw_take ? (NM'(1) << aw_g) : '0);
      if (dn_awvalid && dn_awready) dn_awvalid <= 1'b0;
      if (aw_gv) begin
        if (aw_take) begin
          dn_awvalid <= 1'b1; dn_awid <= IDW'(aw_g); dn_awaddr <= up_awaddr[aw_g]; dn_awlen <= up_awlen[aw_g];
          aw_gv <= 1'b0; aw_last <= aw_g;
        end
      end else if (|aw_req) begin
        aw_g <= rr_pick(aw_req, aw_last); aw_gv <= 1'b1;
      end
    end
  end

  // ================================================================ W: the head burst's master
  logic [MB-1:0] w_m;
  logic          w_any, w_free;
  assign w_m    = wq[wq_rp];
  assign w_any  = (wq_n != '0);
  assign w_free = !dn_wvalid || dn_wready;
  always_comb begin : p_wready
    integer i;
    for (i = 0; i < NM; i = i + 1) up_wready[i] = w_any && w_free && (w_m == MB'(i));
  end
  assign w_take = w_any && w_free && up_wvalid[w_m];
  assign w_pop  = w_take && up_wlast[w_m];
  always_ff @(posedge clk) begin
    if (rst) begin
      dn_wvalid <= 1'b0; wq_wp <= '0; wq_rp <= '0; wq_n <= '0;
    end else begin
      if (dn_wvalid && dn_wready) dn_wvalid <= 1'b0;
      if (w_take) begin
        dn_wvalid <= 1'b1; dn_wdata <= up_wdata[w_m]; dn_wstrb <= up_wstrb[w_m]; dn_wlast <= up_wlast[w_m];
      end
      if (aw_take) begin wq[wq_wp] <= aw_g; wq_wp <= wq_wp + 1'b1; end
      if (w_pop) wq_rp <= wq_rp + 1'b1;
      wq_n <= wq_n + (aw_take ? 1'b1 : 1'b0) - (w_pop ? 1'b1 : 1'b0);
    end
  end

  // ================================================================ B: by ID
  logic [MB-1:0] b_own;
  assign b_own    = dn_bid[MB-1:0];
  assign up_bresp = dn_bresp;
  always_comb begin : p_bvalid
    integer i;
    for (i = 0; i < NM; i = i + 1) up_bvalid[i] = dn_bvalid && (b_own == MB'(i));
  end
  assign dn_bready = up_bready[b_own];
endmodule
