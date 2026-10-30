// uart_batch_core.sv - the batched harness: N decoder lanes (bench_lane.sv) behind one UART. The host
// sends the files of a batch in packets, lane after lane, so all lanes decode at the same time; each
// lane's clock is gated by its own input (see bench_lane.sv), so its clock count is its decode time
// with an ideal input. A result comes back as soon as a lane has finished. Vendor-neutral; the board
// top supplies N gated clocks. The single-decoder harness is uart_bench_core.sv.
//
// Protocol (8N1 at BAUD; multi-byte fields big-endian):
//   host -> FPGA  file header  0x55 0xAA 'J' 'B' lane len[31:0]   a new file of len bytes for the lane
//                                                                   (resets the lane's decoder)
//                 data packet  0x55 0xAA 'J' 'D' lane n[15:0], then n bytes of that lane's file
//                 broadcast    0x55 0xAA 'J' 'M' mask[31:0] n[15:0], then n bytes for every lane i with
//                              mask bit i (the same file decoded by several lanes at once)
//   FPGA -> host  per file, when the lane's frame is done or its watchdog fires, 32 bytes, as in
//                 uart_bench_core.sv with the lane number in byte 5:
//     'R' 'E' 'S' DUT | flags | lane 0 0 | clocks[31:0] | checksum[31:0] | err[15:0] | width[15:0] |
//     height[15:0] | pixels[31:0] | bytes[31:0] | 0 0
//   DUT = 3 for FAST=2 lanes, 0 for FAST=1; flags: bit 0 FIFO overflow, bit 1 watchdog, bit 2 done.
// A lane takes a new file header once its result is out. Packets for a lane without a file in
// progress, or beyond the file's length, are dropped.
module uart_batch_core #(
  parameter int N        = 16,                 // lanes (at most 32)
  parameter int FAST     = 2,
  parameter int CLK_HZ   = 100_000_000,
  parameter int BAUD     = 1_000_000,
  parameter int FIFO_AW  = 12,
  parameter int WATCHDOG = 1 << 26
) (
  input  logic         clk,
  input  logic         rst,                    // clk domain, synchronous
  input  logic [N-1:0] dclk,                   // lane i: clk gated by run_en[i]
  output logic [N-1:0] run_en,
  input  logic         uart_rx,
  output logic         uart_tx,
  output logic [3:0]   led
);
  localparam int DIV = (CLK_HZ + BAUD / 2) / BAUD;   // clocks per bit
  localparam logic [7:0] DUT_ID = (FAST == 2) ? 8'd3 : 8'd0;
  localparam int LW = (N > 1) ? $clog2(N) : 1;        // lane index width

  // ================================================================ UART receiver
  logic [2:0]  rxs;
  logic        rxd, rbusy, rx_v;
  logic [15:0] rcnt;
  logic [3:0]  rbit;
  logic [7:0]  rsh, rx_b;
  always_ff @(posedge clk) rxs <= {rxs[1:0], uart_rx};
  assign rxd = rxs[2];
  always_ff @(posedge clk) begin
    rx_v <= 1'b0;
    if (rst) begin rbusy <= 1'b0; rcnt <= '0; rbit <= '0; end
    else if (!rbusy) begin
      if (!rxd) begin rbusy <= 1'b1; rcnt <= DIV[15:0] / 16'd2; rbit <= 4'd0; end
    end else if (rcnt != 16'd0) rcnt <= rcnt - 16'd1;
    else begin
      rcnt <= DIV[15:0] - 16'd1;
      if (rbit == 4'd0) begin if (rxd) rbusy <= 1'b0; else rbit <= 4'd1; end   // middle of the start bit
      else if (rbit <= 4'd8) begin rsh <= {rxd, rsh[7:1]}; rbit <= rbit + 4'd1; end
      else begin rbusy <= 1'b0; if (rxd) begin rx_v <= 1'b1; rx_b <= rsh; end end   // stop bit
    end
  end

  // ================================================================ protocol
  typedef enum logic [2:0] { H0, H1, H2, H3, LANE, MASK, LEN, DATA } pstate_t;
  pstate_t     ps;
  logic        is_file;                         // header 'B' (file) or 'D' / 'M' (data packet)
  logic [7:0]  lane;
  logic [1:0]  lk;
  logic [31:0] mask;                            // the lanes a data packet goes to
  logic [31:0] hlen;                            // the header's length field
  logic [15:0] dleft;                           // bytes left in the data packet
  logic [31:0] flen [0:N-1];                    // per lane: file length, bytes received
  logic [31:0] nrx  [0:N-1];
  logic [N-1:0] eos, active, restart_v, push_v, tgt;
  logic [7:0]  push_b;
  logic        lane_ok;
  logic [LW-1:0] li;                            // the lane as an index (valid when lane_ok)
  assign lane_ok = ({24'd0, lane} < N);
  assign li      = lane[LW-1:0];
  assign tgt     = mask[N-1:0] & active;        // the lanes this data byte goes to
  always_ff @(posedge clk) begin
    restart_v <= '0; push_v <= '0;
    if (rst) begin
      ps <= H0; eos <= '0; active <= '0; lk <= '0;
    end else if (rx_v) begin
      case (ps)
        H0:   ps <= (rx_b == 8'h55) ? H1 : H0;
        H1:   ps <= (rx_b == 8'hAA) ? H2 : (rx_b == 8'h55) ? H1 : H0;
        H2:   ps <= (rx_b == 8'h4A) ? H3 : H0;
        H3:   if (rx_b == 8'h42 || rx_b == 8'h44) begin is_file <= (rx_b == 8'h42); ps <= LANE; end
              else if (rx_b == 8'h4D) begin is_file <= 1'b0; lk <= '0; ps <= MASK; end
              else ps <= H0;
        LANE: begin
          lane <= rx_b; lk <= '0; hlen <= '0; ps <= LEN;
          mask <= ({24'd0, rx_b} < N) ? (32'd1 << rx_b[4:0]) : 32'd0;
        end
        MASK: begin
          mask <= {mask[23:0], rx_b}; lk <= lk + 2'd1;
          if (lk == 2'd3) begin lk <= '0; hlen <= '0; ps <= LEN; end
        end
        LEN:  begin
          hlen <= {hlen[23:0], rx_b}; lk <= lk + 2'd1;
          if (is_file && lk == 2'd3) begin
            ps <= H0;
            if (lane_ok) begin
              flen[li] <= {hlen[23:0], rx_b}; nrx[li] <= '0; restart_v[li] <= 1'b1;
              active[li] <= ({hlen[23:0], rx_b} != 32'd0); eos[li] <= ({hlen[23:0], rx_b} == 32'd0);
            end
          end else if (!is_file && lk == 2'd1) begin
            dleft <= {hlen[7:0], rx_b};
            ps <= ({hlen[7:0], rx_b} == 16'd0) ? H0 : DATA;
          end
        end
        DATA: begin : p_data
          integer i;
          dleft <= dleft - 16'd1;
          if (dleft == 16'd1) ps <= H0;
          push_v <= tgt; push_b <= rx_b;
          for (i = 0; i < N; i = i + 1)
            if (tgt[i]) begin
              nrx[i] <= nrx[i] + 32'd1;
              if (nrx[i] + 32'd1 == flen[i]) begin eos[i] <= 1'b1; active[i] <= 1'b0; end
            end
        end
        default: ps <= H0;
      endcase
    end
  end

  // ================================================================ the lanes
  logic [N-1:0]  res_v, l_ovf, l_wdog;
  logic [31:0]   l_cyc [0:N-1];
  logic [31:0]   l_chk [0:N-1];
  logic [31:0]   l_npx [0:N-1];
  logic [12:0]   l_err [0:N-1];
  logic [15:0]   l_w   [0:N-1];
  logic [15:0]   l_h   [0:N-1];
  genvar gi;
  generate
    for (gi = 0; gi < N; gi = gi + 1) begin : g_lane
      bench_lane #(.FAST(FAST), .FIFO_AW(FIFO_AW), .WATCHDOG(WATCHDOG)) u_lane (
        .clk(clk), .rst(rst), .dclk(dclk[gi]), .run_en(run_en[gi]),
        .restart(restart_v[gi]), .push(push_v[gi]), .push_b(push_b), .eos(eos[gi]),
        .res_v(res_v[gi]), .ovf(l_ovf[gi]), .wdog_hit(l_wdog[gi]),
        .cyc(l_cyc[gi]), .chk(l_chk[gi]), .npx(l_npx[gi]), .err(l_err[gi]), .w_(l_w[gi]), .h_(l_h[gi]));
    end
  endgenerate

  // ================================================================ results (one at a time, lowest lane first)
  logic [N-1:0] sent_r;                         // the lane's result is out (until its next file)
  logic [N-1:0] ready;
  assign ready = res_v & eos & ~sent_r & ~restart_v;
  logic [255:0] res;
  logic [5:0]   ti;                             // byte being sent
  logic         tbusy, tsend;
  logic [9:0]   tsh;
  logic [15:0]  tcnt;
  logic [3:0]   tbit;
  always_ff @(posedge clk) begin : p_tx
    integer i;
    logic   found;
    logic [LW-1:0] sel;
    if (rst) begin sent_r <= '0; tsend <= 1'b0; ti <= '0; tbusy <= 1'b0; uart_tx <= 1'b1; end
    else begin
      sent_r <= sent_r & ~restart_v;
      if (!tsend) begin
        // the lowest lane with a result, then its record read once by index: assigning the whole
        // record inside the loop made Vivado's synthesis of 15 lanes need more than 9 GB
        found = 1'b0; sel = '0;
        for (i = 0; i < N; i = i + 1)
          if (!found && ready[i]) begin found = 1'b1; sel = i[LW-1:0]; end
        if (found) begin
          sent_r[sel] <= 1'b1; tsend <= 1'b1; ti <= '0;
          res <= {8'h52, 8'h45, 8'h53, DUT_ID, {5'd0, 1'b1, l_wdog[sel], l_ovf[sel]}, {{(8-LW){1'b0}}, sel}, 16'd0,
                  l_cyc[sel], l_chk[sel], {3'd0, l_err[sel]}, l_w[sel], l_h[sel], l_npx[sel], nrx[sel], 16'd0};
        end
      end
      if (tsend && !tbusy) begin
        if (ti == 6'd32) tsend <= 1'b0;
        else begin
          tsh <= {1'b1, res[255 - 8*ti -: 8], 1'b0}; tbusy <= 1'b1; tbit <= '0; tcnt <= DIV[15:0] - 16'd1; ti <= ti + 6'd1;
        end
      end
      if (tbusy) begin
        uart_tx <= tsh[0];
        if (tcnt != 16'd0) tcnt <= tcnt - 16'd1;
        else begin
          tcnt <= DIV[15:0] - 16'd1; tsh <= {1'b1, tsh[9:1]}; tbit <= tbit + 4'd1;
          if (tbit == 4'd9) begin tbusy <= 1'b0; uart_tx <= 1'b1; end
        end
      end else uart_tx <= 1'b1;
    end
  end

  // LEDs: heartbeat, every lane idle with its result out, data arriving, any overflow
  logic [25:0] hb;
  always_ff @(posedge clk) hb <= hb + 26'd1;
  assign led = {|l_ovf, ps == DATA, &(sent_r | ~(active | eos)), hb[25]};
endmodule
