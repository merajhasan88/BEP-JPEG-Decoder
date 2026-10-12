// jpeg_checker.sv - assertions on jpeg_decoder's interface, checked in every testbench run (the review of
// 2026-10-10: "add assertions for input/output stability, bounded framed-file completion, and frame/error
// ownership"). Bound into jpeg_decoder in the Verilator C++ harness (jpeg_checker_bind.sv) and instantiated
// next to the decoder in tb_jpeg.sv (Verilator, xsim, Icarus). A violation ends the simulation with $fatal.
// Plain clocked checks, no concurrent assertions, so that every simulator runs them. The rules are those of
// README.md (port table and "Completion contract"):
//   A1 output handshake (AXI4-Stream): a beat that is valid and not taken stays valid and unchanged until it
//      is taken (pixel lanes beyond px_n are don't-care)
//   A2 frames: frame_start and frame_done alternate
//   A3 pixels: only inside a frame; x + n <= W and y < H; 1 <= n <= NPIX; px_sof exactly on the beat at (0,0);
//      px_eol exactly on the beat that ends at x = W - 1
//   A4 errors belong to their image: the next image's SOI (found in the accepted bytes by a marker parser
//      that skips segment payloads, B.1.1) is not taken while a frame is open; err is cleared within 4 clocks
//      after it; err does not change from frame_done until that SOI
//   A5 bounded completion: when a file's last byte (in_last) is taken while an image is open (its SOI taken
//      earlier), frame_done follows within 2^20 + 64 x W x H clocks in which the output is not held by px_ready
module jpeg_checker #(
  parameter int NPIX = 1
) (
  input logic              clk,
  input logic              rst,
  input logic              in_valid,
  input logic              in_ready,
  input logic              in_last,
  input logic [7:0]        in_data,
  input logic [1:0]        out_fmt,
  input logic              px_valid,
  input logic              px_ready,
  input logic [15:0]       px_x,
  input logic [15:0]       px_y,
  input logic [2:0]        px_n,
  input logic [8*NPIX-1:0] px_c0,
  input logic [8*NPIX-1:0] px_c1,
  input logic [8*NPIX-1:0] px_c2,
  input logic              px_sof,
  input logic              px_eol,
  input logic [15:0]       img_w,
  input logic [15:0]       img_h,
  input logic              frame_start,
  input logic              frame_done,
  input logic [12:0]       err
);
  localparam logic [2:0] P_OUT = 3'd0, P_MK = 3'd1, P_LEN1 = 3'd2, P_LEN2 = 3'd3, P_SKIP = 3'd4,
                         P_ECS = 3'd5, P_ECS_FF = 3'd6;
  logic              take;
  assign take = in_valid && in_ready;

  // ---- the stream's structure (B.1.1): an image runs from its SOI to its EOI or the file's last byte
  logic [2:0]  ps;                   // where the next accepted byte falls
  logic        prev_ff;              // the last accepted byte was 0xFF
  logic [7:0]  mk;                   // the marker whose segment is being skipped
  logic [15:0] left;                 // segment bytes still to skip
  logic        soi;                  // this accepted byte completes an image's SOI (between images)
  logic [15:0] seglen;
  assign soi    = take && (ps == P_OUT) && prev_ff && (in_data == 8'hD8);
  assign seglen = {left[15:8], in_data};

  // ---- state of the checks
  logic        open;                 // frame_start seen, frame_done not yet
  logic [15:0] fw, fh;               // the open frame's size
  logic        pend;                 // the last clock had a beat that was not taken
  logic [15:0] q_x, q_y;
  logic [2:0]  q_n;
  logic [8*NPIX-1:0] q_c0, q_c1, q_c2;
  logic        q_sof, q_eol;
  logic        hold;                 // from frame_done to the next SOI: err must not change
  logic [12:0] err_done;
  logic [2:0]  clr;                  // clocks left for err to be cleared after an SOI
  logic        waiting;              // in_last taken inside an image: frame_done is due
  logic [39:0] budget, spent;
  logic [63:0] cyc;                  // clocks since reset (the C++ harnesses do not advance $time)

  always @(posedge clk) begin : checks
    integer i;
    logic [16:0] xe;
    logic [15:0] w, h;
    cyc <= rst ? 64'd0 : cyc + 64'd1;
    if (rst) begin
      ps <= P_OUT; prev_ff <= 1'b0; mk <= 8'd0; left <= 16'd0;
      open <= 1'b0; fw <= 16'd0; fh <= 16'd0; pend <= 1'b0; hold <= 1'b0; err_done <= 13'd0; clr <= 3'd0;
      waiting <= 1'b0; budget <= 40'd0; spent <= 40'd0;
    end else begin
      // ---------------------------------------------------------------- A1 output handshake
      if (pend) begin
        if (!px_valid)
          $fatal(1, "jpeg_checker A1 at clock %0d: px_valid dropped before the beat at (%0d,%0d) was taken", cyc, q_x, q_y);
        if (px_x != q_x || px_y != q_y || px_n != q_n || px_sof != q_sof || px_eol != q_eol)
          $fatal(1, "jpeg_checker A1 at clock %0d: the beat at (%0d,%0d) changed while waiting for px_ready", cyc, q_x, q_y);
        for (i = 0; i < NPIX; i = i + 1)
          if (i < q_n && (px_c0[8*i +: 8] != q_c0[8*i +: 8] || px_c1[8*i +: 8] != q_c1[8*i +: 8] || px_c2[8*i +: 8] != q_c2[8*i +: 8]))
            $fatal(1, "jpeg_checker A1 at clock %0d: pixel %0d of the beat at (%0d,%0d) changed while waiting for px_ready", cyc, i, q_x, q_y);
      end
      pend <= px_valid && !px_ready;
      q_x <= px_x; q_y <= px_y; q_n <= px_n; q_c0 <= px_c0; q_c1 <= px_c1; q_c2 <= px_c2; q_sof <= px_sof; q_eol <= px_eol;

      // ---------------------------------------------------------------- A2 frames
      if (frame_start && open && !frame_done)
        $fatal(1, "jpeg_checker A2 at clock %0d: frame_start while a frame is open", cyc);
      if (frame_done && !open && !frame_start)
        $fatal(1, "jpeg_checker A2 at clock %0d: frame_done without a frame_start", cyc);
      if (frame_start) begin fw <= img_w; fh <= img_h; end
      open <= (open || frame_start) && !frame_done;

      // ---------------------------------------------------------------- A3 pixels
      w = frame_start ? img_w : fw;
      h = frame_start ? img_h : fh;
      if (px_valid) begin
        xe = {1'b0, px_x} + {14'd0, px_n};
        if (!(open || frame_start))
          $fatal(1, "jpeg_checker A3 at clock %0d: a pixel beat at (%0d,%0d) outside a frame", cyc, px_x, px_y);
        if (px_n == 3'd0 || {29'd0, px_n} > NPIX)
          $fatal(1, "jpeg_checker A3 at clock %0d: px_n = %0d (NPIX = %0d)", cyc, px_n, NPIX);
        if (xe > {1'b0, w} || px_y >= h)
          $fatal(1, "jpeg_checker A3 at clock %0d: beat at (%0d,%0d) x %0d outside the %0dx%0d frame", cyc, px_x, px_y, px_n, w, h);
        if (px_sof != (px_x == 16'd0 && px_y == 16'd0))
          $fatal(1, "jpeg_checker A3 at clock %0d: px_sof = %0d on the beat at (%0d,%0d)", cyc, px_sof, px_x, px_y);
        if (px_eol != (xe == {1'b0, w}))
          $fatal(1, "jpeg_checker A3 at clock %0d: px_eol = %0d on the beat at (%0d,%0d) x %0d, width %0d", cyc, px_eol, px_x, px_y, px_n, w);
      end

      // ---------------------------------------------------------------- A4 errors belong to their image
      if (soi && open && !frame_done)
        $fatal(1, "jpeg_checker A4 at clock %0d: the next image's SOI was taken while a frame is open", cyc);
      if (hold && err != err_done)
        $fatal(1, "jpeg_checker A4 at clock %0d: err changed after frame_done (0x%04h -> 0x%04h) before the next SOI", cyc, err_done, err);
      if (frame_done) begin hold <= 1'b1; err_done <= err; end
      if (soi) begin hold <= 1'b0; clr <= 3'd4; end
      else if (clr != 3'd0) begin
        if (err == 13'd0) clr <= 3'd0;
        else if (clr == 3'd1)
          $fatal(1, "jpeg_checker A4 at clock %0d: err = 0x%04h still set 4 clocks after the next image's SOI", cyc, err);
        else clr <= clr - 3'd1;
      end

      // ---------------------------------------------------------------- A5 bounded completion
      if (take && in_last && ps != P_OUT && !frame_done && !waiting) begin
        waiting <= 1'b1; spent <= 40'd0;
        budget  <= 40'd1048576 + 40'd64 * {24'd0, w} * {24'd0, h};
      end else if (waiting) begin
        if (frame_done) waiting <= 1'b0;
        else begin
          if (!(px_valid && !px_ready)) spent <= spent + 40'd1;
          if (spent > budget)
            $fatal(1, "jpeg_checker A5 at clock %0d: no frame_done %0d clocks after the file's last byte", cyc, spent);
        end
      end

      // ---------------------------------------------------------------- the stream's structure
      if (take) begin
        if (in_last) begin ps <= P_OUT; prev_ff <= 1'b0; end            // the file ends; the next byte starts one
        else
          case (ps)
            P_OUT: begin
              if (prev_ff && in_data == 8'hD8) ps <= P_MK;
              prev_ff <= (in_data == 8'hFF);
            end
            P_MK, P_ECS_FF: begin
              if (in_data == 8'hFF) prev_ff <= 1'b1;                     // fill bytes (B.1.1.2)
              else if (prev_ff || ps == P_ECS_FF) begin                  // a marker code
                prev_ff <= 1'b0;
                if (ps == P_ECS_FF && (in_data == 8'h00 || (in_data >= 8'hD0 && in_data <= 8'hD7))) ps <= P_ECS;   // stuffing, RSTn
                else if (in_data == 8'hD9) ps <= P_OUT;                  // EOI
                else if (in_data == 8'hD8 || in_data == 8'h01 || (in_data >= 8'hD0 && in_data <= 8'hD7)) ps <= P_MK;
                else begin mk <= in_data; ps <= P_LEN1; end
              end
            end
            P_LEN1: begin left[15:8] <= in_data; ps <= P_LEN2; end
            P_LEN2:
              if (seglen <= 16'd2) ps <= (mk == 8'hDA) ? P_ECS : P_MK;
              else begin left <= seglen - 16'd2; ps <= P_SKIP; end
            P_SKIP: begin
              if (left == 16'd1) ps <= (mk == 8'hDA) ? P_ECS : P_MK;
              left <= left - 16'd1;
            end
            P_ECS: if (in_data == 8'hFF) ps <= P_ECS_FF;
            default: ps <= P_OUT;
          endcase
      end
    end
  end
endmodule
