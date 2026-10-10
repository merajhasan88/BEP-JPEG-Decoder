// mem_lane.sv - one decoder lane that works from memory: the core of the F2 harness (ROADMAP.md, Task B),
// usable with any AXI4 memory (on F2: HBM or DDR4 through the shell, or host memory through PCIM).
//
// A job names a JPEG file in memory (address, length) and an output area. The lane reads the file
// with an AXI4 read master, decodes it with the wide core (jpeg_decoder FAST = 2, RGB output) and
// writes every output beat as a 16-byte record with an AXI4 write master:
//   bytes 0-1 x, bytes 2-3 y (little-endian), then R, G, B of the pixels (x, y) .. (x+3, y);
//   fewer than 4 only at the image's right edge (the host knows the width; the other bytes are 0).
// The records come in the decoder's order (MCU order); the host places them by x and y and so
// compares every pixel. The lane reports the clocks from the start to the end of the frame, the
// clocks the decoder waited for input and for the writer, the pixel and record counts, the error
// bits, and a hash of the pixels that binds each colour to its position: the sum modulo 2^64 of
// mix({y, x, 0, R, G, B}) over the pixels (mix below; the host computes the same).
// AXI4: INCR bursts of up to BURST beats (fewer at the end of the data and at 4 KB boundaries), one
// ID, addresses aligned to DW/8 bytes; one read burst in flight (the decoder takes at most a byte
// per clock), up to WOUT write bursts in flight (records come at up to 16 bytes per clock); a burst's
// write data follows its accepted address.
// Jobs: the job inputs are sampled at an accepted start (start while busy is ignored), so the next
// job may be written while one runs. The frame ends at the file's EOI (or, for a truncated file, at
// its last byte); the bytes after it are not read. done comes when every burst in flight is complete
// (read data in, write responses back), so a job's late read data can never reach the next job. A file
// without an SOI never ends a frame (jpeg_parser: in_last before an SOI has no effect): the host aborts
// such a job (job_abort: no new requests, the bursts in flight complete, then done with res_abort; the
// records of an aborted job are incomplete).
module mem_lane #(
  parameter int AW    = 64,
  parameter int DW    = 512,          // AXI data width in bits: 256 or 512
  parameter int BURST = 16,           // beats per burst, at most (16 keeps AXI3 slaves happy)
  parameter int WOUT  = 8             // write bursts in flight, at most
) (
  input  logic          clk,
  input  logic          rst,
  // job (sampled at an accepted start)
  input  logic          start,        // pulse: begin a job (ignored while busy)
  input  logic          job_abort,        // pulse: end the running job (see the header)
  input  logic [AW-1:0] in_addr,
  input  logic [31:0]   in_len,       // bytes of the file
  input  logic [AW-1:0] out_addr,
  input  logic [31:0]   out_max,      // bytes of room for records (a multiple of DW/8)
  output logic          busy,
  output logic          done,         // the job is over, results valid until the next start
  output logic [12:0]   res_err,      // the decoder's error bits at frame_done
  output logic          res_ovf,      // records beyond out_max were dropped
  output logic          res_axi_err,  // an AXI response other than OKAY
  output logic          res_abort,    // the job was aborted
  output logic [31:0]   res_cycles,   // clocks from start to frame_done
  output logic [31:0]   res_in_wait,  // of them: the decoder asked for input and had none
  output logic [31:0]   res_out_wait, // of them: an output beat waited for the writer
  output logic [31:0]   res_pixels,
  output logic [31:0]   res_records,
  output logic [63:0]   res_hash,
  output logic [15:0]   res_w,
  output logic [15:0]   res_h,
  // AXI4 read master
  output logic          arvalid,
  input  logic          arready,
  output logic [AW-1:0] araddr,
  output logic [7:0]    arlen,
  output logic [2:0]    arsize,
  output logic [1:0]    arburst,
  input  logic          rvalid,
  output logic          rready,
  input  logic [DW-1:0] rdata,
  input  logic          rlast,
  input  logic [1:0]    rresp,
  // AXI4 write master
  output logic          awvalid,
  input  logic          awready,
  output logic [AW-1:0] awaddr,
  output logic [7:0]    awlen,
  output logic [2:0]    awsize,
  output logic [1:0]    awburst,
  output logic          wvalid,
  input  logic          wready,
  output logic [DW-1:0] wdata,
  output logic [DW/8-1:0] wstrb,
  output logic          wlast,
  input  logic          bvalid,
  output logic          bready,
  input  logic [1:0]    bresp
);
  import jpeg_pkg::*;
  localparam int BYTES = DW / 8;                 // bytes per beat
  localparam int BB    = $clog2(BYTES);
  localparam int RPW   = DW / 128;               // records per beat (2 or 4)
  localparam int RB    = $clog2(RPW);
  localparam int FD    = 2 * BURST;              // FIFO depths, in beats
  localparam int FB    = $clog2(FD);
  localparam int QB    = $clog2(WOUT);
  assign arsize = 3'(BB); assign arburst = 2'b01;
  assign awsize = 3'(BB); assign awburst = 2'b01;
  assign rready = 1'b1;                          // FIFO space was reserved before the burst was asked for
  assign bready = 1'b1;

  logic [31:0]   len_r;                          // the job's file length
  logic          fin;                            // frame_done seen (or the job aborted)
  logic          flushing;                       // fin and the last partial beat queued: drain the writes
  logic          dec_rst;                        // the decoder's reset, in the first clock of every job: until it
  always_ff @(posedge clk) dec_rst <= rst || (start && !busy);   // has acted, the decoder's outputs are the last job's


  // ================================================================ read: file -> beat FIFO -> bytes
  logic [AW-1:0] rd_addr;
  logic [31:0]   rd_left;                        // bytes not yet requested
  logic [FB:0]   r_resv;                         // beats in the FIFO + beats requested, not arrived
  logic [DW-1:0] rf_mem [0:FD-1];
  logic [FB-1:0] rf_wp, rf_rp;
  logic [FB:0]   rf_cnt;
  logic          ar_busy;                        // a read burst is in flight
  logic [12:0]   to_4k_r;
  logic [31:0]   left_beats;
  logic [8:0]    ar_n;                           // beats of the next read burst
  assign to_4k_r    = 13'd4096 - {1'b0, rd_addr[11:0]};
  assign left_beats = (rd_left + 32'(BYTES - 1)) >> BB;
  always_comb begin
    ar_n = 9'(BURST);
    if (left_beats < 32'(ar_n)) ar_n = 9'(left_beats);
    if (13'(to_4k_r >> BB) < 13'(ar_n)) ar_n = 9'(to_4k_r >> BB);
  end
  logic          ar_issue, r_push;
  assign ar_issue = busy && !fin && !ar_busy && !arvalid && (rd_left != 32'd0) && (32'(r_resv) + 32'(ar_n) <= 32'(FD));
  assign r_push   = rvalid && rready;
  // the serializer: one beat at a time, its bytes one per accepted clock
  logic [DW-1:0] cur;
  logic          cur_v;
  logic [BB-1:0] cur_i;                          // the next byte of cur
  logic [31:0]   fed;                            // bytes given to the decoder
  logic          in_valid, in_ready, in_last, take, used_up, r_pop;
  logic [7:0]    in_data;
  assign in_valid = busy && !dec_rst && cur_v && (fed < len_r);
  assign in_data  = cur[8*cur_i +: 8];
  assign in_last  = (fed + 32'd1 == len_r);
  assign take     = in_valid && in_ready;
  assign used_up  = !cur_v || (take && (cur_i == BB'(BYTES - 1)));
  assign r_pop    = busy && used_up && (rf_cnt != '0) && ((fed + (take ? 32'd1 : 32'd0)) < len_r);

  // ================================================================ the decoder
  logic        px_valid, px_ready, px_sof, px_eol, frame_start, frame_done;
  logic [15:0] px_x, px_y, img_w, img_h;
  logic [2:0]  px_n;
  logic [31:0] px_c0, px_c1, px_c2;
  logic [12:0] dec_err;
  jpeg_decoder #(.FAST(2)) u_dec (
    .clk(clk), .rst(dec_rst),
    .in_valid(in_valid), .in_data(in_data), .in_last(in_last), .in_ready(in_ready),
    .out_fmt(FMT_RGB),
    .px_valid(px_valid), .px_ready(px_ready), .px_x(px_x), .px_y(px_y), .px_n(px_n),
    .px_c0(px_c0), .px_c1(px_c1), .px_c2(px_c2), .px_sof(px_sof), .px_eol(px_eol),
    .img_w(img_w), .img_h(img_h), .frame_start(frame_start), .frame_done(frame_done), .err(dec_err));

  // ================================================================ records -> beats -> write FIFO
  logic [127:0] rec;
  always_comb begin : g_rec
    integer i;
    rec = '0;
    rec[15:0] = px_x; rec[31:16] = px_y;
    for (i = 0; i < 4; i = i + 1)
      if (i < px_n) begin
        rec[32 + 24*i +: 8] = px_c0[8*i +: 8];
        rec[40 + 24*i +: 8] = px_c1[8*i +: 8];
        rec[48 + 24*i +: 8] = px_c2[8*i +: 8];
      end
  end
  logic [DW-1:0] pk;                             // the beat being packed
  logic [RB:0]   pk_n;                           // records in it
  logic [DW-1:0] wf_mem [0:FD-1];
  logic [RB:0]   wf_nr  [0:FD-1];                // records in each queued beat
  logic [FB-1:0] wf_wp, wf_rp;
  logic [FB:0]   wf_cnt;                         // beats in the FIFO
  logic [FB:0]   wf_free;                        // of them: not yet given to an AW burst
  logic [31:0]   out_max_beats, out_beats;       // room and beats queued so far
  logic          px_fire, pk_full, pk_last, w_push;
  assign px_ready = busy && !dec_rst && !fin && (wf_cnt < FB'(FD - 1));   // room for the beat this record may complete
                                                 // (not from a decoder still holding an aborted job's beat)
  assign px_fire  = px_valid && px_ready;
  assign pk_full  = px_fire && (pk_n == (RB+1)'(RPW - 1));     // this record completes a beat
  assign pk_last  = fin && !flushing && (pk_n != '0) && (wf_cnt < (FB+1)'(FD));   // the last, partial beat
  assign w_push   = (pk_full || pk_last) && (out_beats < out_max_beats);
  // write bursts
  logic [AW-1:0] wr_addr;
  logic [12:0]   to_4k_w;
  logic [8:0]    aw_n;
  assign to_4k_w = 13'd4096 - {1'b0, wr_addr[11:0]};
  always_comb begin
    aw_n = 9'(BURST);
    if (9'(wf_free) < aw_n) aw_n = 9'(wf_free);
    if (13'(to_4k_w >> BB) < 13'(aw_n)) aw_n = 9'(to_4k_w >> BB);
  end
  logic [8:0]    bq [0:WOUT-1];                  // lengths of the issued bursts, for the W channel
  logic [QB-1:0] bq_wp, bq_rp;
  logic [QB:0]   bq_cnt, b_out;                  // bursts waiting for W; bursts waiting for B
  logic [8:0]    w_left;                         // beats left in the current W burst (0: none)
  logic          aw_go, aw_acc, w_pop, bq_take, b_fire;
  assign aw_go   = busy && !awvalid && (bq_cnt < (QB+1)'(WOUT)) && (b_out < (QB+1)'(WOUT)) && (wf_free != '0)
                   && ((32'(wf_free) >= 32'(BURST)) || flushing || (13'(to_4k_w >> BB) <= 13'(wf_free)));
  assign aw_acc  = awvalid && awready;
  assign wvalid  = (w_left != 9'd0);
  assign wdata   = wf_mem[wf_rp];
  assign wlast   = (w_left == 9'd1);
  assign w_pop   = wvalid && wready;
  assign bq_take = (w_left == 9'd0) && (bq_cnt != '0);
  assign b_fire  = bvalid && bready;
  always_comb begin : g_wstrb
    integer i;
    for (i = 0; i < BYTES; i = i + 1) wstrb[i] = (32'(i >> 4) < 32'(wf_nr[wf_rp]));
  end

  // ================================================================ position-binding hash
  // mix: a splitmix-style finaliser with shift-adds in place of its multiplications (no DSP blocks)
  function automatic logic [63:0] mix(input logic [63:0] v);
    logic [63:0] z;
    z = v + 64'h9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) + (z << 7);
    z = (z ^ (z >> 27)) + (z << 13);
    return z ^ (z >> 31);
  endfunction
  logic [63:0] hv [0:3];                         // stage 1: the beat's pixels, mixed
  logic [3:0]  hm;                               //          which of them exist
  logic [63:0] hs;                               // stage 2: their sum
  logic        h1, h2;
  always_ff @(posedge clk) begin : g_hash
    integer i;
    h1 <= px_fire; h2 <= h1;
    for (i = 0; i < 4; i = i + 1) begin
      hv[i] <= mix({px_y, px_x + 16'(i), 8'd0, px_c0[8*i +: 8], px_c1[8*i +: 8], px_c2[8*i +: 8]});
      hm[i] <= (i < px_n);
    end
    hs <= (hm[0] ? hv[0] : 64'd0) + (hm[1] ? hv[1] : 64'd0) + (hm[2] ? hv[2] : 64'd0) + (hm[3] ? hv[3] : 64'd0);
  end

  // ================================================================ control
  always_ff @(posedge clk) begin
    if (rst || (start && !busy)) begin
      busy <= !rst; done <= 1'b0; fin <= 1'b0; flushing <= 1'b0;
      rd_addr <= in_addr; rd_left <= in_len; len_r <= in_len; wr_addr <= out_addr;
      out_max_beats <= out_max >> BB; out_beats <= '0;
      arvalid <= 1'b0; araddr <= '0; arlen <= '0; ar_busy <= 1'b0;
      awvalid <= 1'b0; awaddr <= '0; awlen <= '0;
      rf_wp <= '0; rf_rp <= '0; rf_cnt <= '0; r_resv <= '0; cur <= '0; cur_v <= 1'b0; cur_i <= '0; fed <= '0;
      wf_wp <= '0; wf_rp <= '0; wf_cnt <= '0; wf_free <= '0; pk <= '0; pk_n <= '0;
      bq_wp <= '0; bq_rp <= '0; bq_cnt <= '0; b_out <= '0; w_left <= '0;
      res_err <= '0; res_ovf <= 1'b0; res_axi_err <= 1'b0; res_abort <= 1'b0; res_cycles <= '0; res_in_wait <= '0; res_out_wait <= '0;
      res_pixels <= '0; res_records <= '0; res_hash <= '0; res_w <= '0; res_h <= '0;
    end else if (busy) begin
      // ---- read: a burst when the FIFO has room for it; the beats into the FIFO; one beat out to the serializer
      if (ar_issue) begin
        arvalid <= 1'b1; araddr <= rd_addr; arlen <= 8'(ar_n - 9'd1);
        rd_addr <= rd_addr + (AW'(ar_n) << BB);
        rd_left <= (rd_left > (32'(ar_n) << BB)) ? rd_left - (32'(ar_n) << BB) : 32'd0;
      end
      if (arvalid && arready) begin arvalid <= 1'b0; ar_busy <= 1'b1; end
      if (r_push) begin
        rf_mem[rf_wp] <= rdata; rf_wp <= rf_wp + 1'b1;
        if (rresp != 2'b00) res_axi_err <= 1'b1;
        if (rlast) ar_busy <= 1'b0;
      end
      rf_cnt <= rf_cnt + (r_push ? 1'b1 : 1'b0) - (r_pop ? 1'b1 : 1'b0);
      r_resv <= r_resv + (ar_issue ? (FB+1)'(ar_n) : '0) - (r_pop ? 1'b1 : 1'b0);
      if (take) fed <= fed + 32'd1;
      if (r_pop) begin cur <= rf_mem[rf_rp]; cur_v <= 1'b1; cur_i <= '0; rf_rp <= rf_rp + 1'b1; end
      else if (take) begin
        if (cur_i == BB'(BYTES - 1)) cur_v <= 1'b0;
        else cur_i <= cur_i + 1'b1;
      end
      // ---- the decoder's results
      if (frame_start && !dec_rst) begin res_w <= img_w; res_h <= img_h; end
      if (!fin) begin
        res_cycles <= res_cycles + 32'd1;
        if (!dec_rst && in_ready && !in_valid && fed < len_r) res_in_wait <= res_in_wait + 32'd1;
        if (!dec_rst && px_valid && !px_ready) res_out_wait <= res_out_wait + 32'd1;
      end
      if (px_fire) begin res_pixels <= res_pixels + 32'(px_n); res_records <= res_records + 32'd1; end
      if (h2) res_hash <= res_hash + hs;
      if (frame_done && !dec_rst) begin fin <= 1'b1; res_err <= dec_err; end
      else if (job_abort && !fin) begin fin <= 1'b1; flushing <= 1'b1; res_abort <= 1'b1; res_err <= dec_err; end   // a partial beat is dropped
      // ---- records into beats; beats into the write FIFO (beyond out_max: dropped, res_ovf)
      if (px_fire) begin
        pk[128*pk_n[RB-1:0] +: 128] <= rec;
        pk_n <= pk_full ? '0 : pk_n + 1'b1;
      end
      if (pk_last) pk_n <= '0;
      if (w_push) begin
        wf_mem[wf_wp] <= pk_full ? {rec, pk[DW-129:0]} : pk;
        wf_nr[wf_wp]  <= pk_full ? (RB+1)'(RPW) : pk_n;
        wf_wp <= wf_wp + 1'b1; out_beats <= out_beats + 32'd1;
      end else if (pk_full || pk_last) res_ovf <= 1'b1;
      if (fin && !flushing && (pk_n == '0 || pk_last)) flushing <= 1'b1;
      // ---- write bursts: AW when a whole burst is queued (or a boundary / the end limits it); W in AW order
      if (aw_go) begin
        awvalid <= 1'b1; awaddr <= wr_addr; awlen <= 8'(aw_n - 9'd1);
        wr_addr <= wr_addr + (AW'(aw_n) << BB);
      end
      if (aw_acc) begin                          // the burst's data may go now
        awvalid <= 1'b0;
        bq[bq_wp] <= 9'(awlen) + 9'd1; bq_wp <= bq_wp + 1'b1;
      end
      if (bq_take) begin w_left <= bq[bq_rp]; bq_rp <= bq_rp + 1'b1; end
      else if (w_pop) w_left <= w_left - 9'd1;
      if (w_pop) wf_rp <= wf_rp + 1'b1;
      wf_cnt  <= wf_cnt + (w_push ? 1'b1 : 1'b0) - (w_pop ? 1'b1 : 1'b0);
      wf_free <= wf_free + (w_push ? 1'b1 : 1'b0) - (aw_go ? (FB+1)'(aw_n) : '0);
      bq_cnt  <= bq_cnt + (aw_acc ? 1'b1 : 1'b0) - (bq_take ? 1'b1 : 1'b0);
      b_out   <= b_out + (aw_acc ? 1'b1 : 1'b0) - (b_fire ? 1'b1 : 1'b0);
      if (b_fire && bresp != 2'b00) res_axi_err <= 1'b1;
      // ---- the end: frame done, every beat written and acknowledged, no read burst in flight, the hash complete
      if (flushing && wf_cnt == '0 && bq_cnt == '0 && w_left == 9'd0 && b_out == '0 && !awvalid && !arvalid && !ar_busy
          && !h1 && !h2) begin
        busy <= 1'b0; done <= 1'b1;
      end
    end
  end
endmodule
