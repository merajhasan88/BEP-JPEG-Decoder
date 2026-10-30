// tb_jpeg.sv - SystemVerilog testbench for jpeg_decoder, for any simulator with file I/O
// (Verilator --binary --timing, Vivado xsim, Questa, ...); tb/sim.sh builds and runs it.
//
// One file (plusargs):
//   +JPEG=in.jpg  [+OUT=out.pnm] [+GOLDEN=ref.pnm] [+FMT=rgb|ycbcr|y] [+STALL=N]
//   [+EXPECT_ERR=hex] [+EXPECT_ERR_MASK=hex] [+NO_PIXELS] [+NO_LAST] [+MAX_CYCLES=N] [+QUIET]
// Streams the file into the decoder one byte per clock (with optional random input stalls and
// output back-pressure, N % of cycles), rebuilds the image from the pixel stream and writes it
// as PNM: rgb -> P6 (P5 for a grey image when the golden is P5), ycbcr -> P6 holding Y,Cb,Cr,
// y -> P5.  Checks: every pixel exactly once, px_sof only on (0,0), px_eol exactly on x = W-1,
// and with RASTER_OUT=1 strict raster order.  +GOLDEN compares the image byte for byte.
// +EXPECT_ERR: the frame must end with exactly these err bits and no pixels.  +EXPECT_ERR_MASK:
// the frame must end (frame_done) with at least these err bits (pixels allowed unless +NO_PIXELS).
// in_last is raised on the file's last byte unless +NO_LAST.  The summary line
//   cycles=<n> bytes_consumed=<n>/<n> pixels=<n> dup= oob= order_err= flag_err= err=0x<e> checksum=0x<c>
// gives the decode time in clocks (from reset release to frame_done) and the boards' pixel
// checksum: the sum over all pixels of {(x ^ y)[7:0], c0, c1, c2} mod 2^32.
//
// Several files back to back without a reset (the decoder must not carry state between images):
//   +FILES=a.jpg,b.jpg,...  +GOLDENS=a.pnm,-,...  [+FMT=..] [+STALL=N]       ("-" = no golden)
// prints "frame <k>: <W>x<H>, <n> pixels, err=0x<e>, MATCH | DIFFERS (<n> bytes) | no golden".
//
// The same results as the C++ harness used during development (same reset, same stall sequence).
`timescale 1ns/1ps
module tb_jpeg;
  parameter int FAST           = 0;
  parameter bit RASTER_OUT     = 1'b0;
  parameter int ROWBUF_BYTES   = 16384;
  parameter bit FANCY_UPSAMPLE = 1'b0;
  parameter bit CC_TURBO       = 1'b0;
  parameter bit RGB_OUT        = 1'b1;
  parameter bit CHECKS         = 1'b1;

  logic        clk = 1'b0, rst = 1'b1;
  logic        in_valid = 1'b0, in_last = 1'b0, in_ready;
  logic [7:0]  in_data = 8'd0;
  logic [1:0]  out_fmt = 2'd0;
  logic        px_valid, px_ready = 1'b0, px_sof, px_eol;
  logic [15:0] px_x, px_y, img_w, img_h;
  localparam int NPIX = (FAST == 2) ? 4 : 1;   // pixels per output beat
  logic [8*NPIX-1:0] px_c0, px_c1, px_c2;
  logic [2:0]  px_n;
  logic        frame_start, frame_done;
  logic [12:0] err;

  jpeg_decoder #(.FAST(FAST), .RASTER_OUT(RASTER_OUT), .ROWBUF_BYTES(ROWBUF_BYTES),
                 .FANCY_UPSAMPLE(FANCY_UPSAMPLE), .CC_TURBO(CC_TURBO), .RGB_OUT(RGB_OUT),
                 .CHECKS(CHECKS)) dut (
    .clk(clk), .rst(rst), .in_valid(in_valid), .in_data(in_data), .in_last(in_last),
    .in_ready(in_ready), .out_fmt(out_fmt), .px_valid(px_valid), .px_ready(px_ready),
    .px_x(px_x), .px_y(px_y), .px_n(px_n), .px_c0(px_c0), .px_c1(px_c1), .px_c2(px_c2), .px_sof(px_sof),
    .px_eol(px_eol), .img_w(img_w), .img_h(img_h), .frame_start(frame_start),
    .frame_done(frame_done), .err(err));

  // interface assertions (jpeg_checker.sv): a violation ends the run with $fatal
  jpeg_checker #(.NPIX(NPIX)) u_chk (
    .clk(clk), .rst(rst), .in_valid(in_valid), .in_ready(in_ready), .in_last(in_last), .in_data(in_data),
    .out_fmt(out_fmt), .px_valid(px_valid), .px_ready(px_ready), .px_x(px_x), .px_y(px_y), .px_n(px_n),
    .px_c0(px_c0), .px_c1(px_c1), .px_c2(px_c2), .px_sof(px_sof), .px_eol(px_eol), .img_w(img_w),
    .img_h(img_h), .frame_start(frame_start), .frame_done(frame_done), .err(err));

  always #5 clk = ~clk;

  // ------------------------------------------------------------------ helpers
  // Buffers live at module level and are passed to no function by reference (ref arguments are
  // not handled the same way by every simulator).
  byte unsigned data_q[$], gold_q[$], out_q[$], tmp_q[$];
  byte unsigned img_a[];
  byte unsigned seen_a[];               // (bytes, not bits: Icarus 11 cannot make dynamic arrays of bits)

  function automatic void read_file(input string path);       // -> tmp_q
    int fd, c;
    tmp_q.delete();
    fd = $fopen(path, "rb");
    if (fd == 0) $fatal(1, "cannot open %s", path);
    c = $fgetc(fd);
    while (c >= 0) begin
      tmp_q.push_back(c[7:0]);
      c = $fgetc(fd);
    end
    $fclose(fd);
  endfunction

  string names_q[$], gnames_q[$];
  function automatic void split(input string s, input bit to_gold);   // comma list -> names_q / gnames_q
    int st;
    st = 0;
    for (int i = 0; i <= s.len(); i++)
      if (i == s.len() || s[i] == ",") begin
        if (to_gold) gnames_q.push_back(s.substr(st, i - 1)); else names_q.push_back(s.substr(st, i - 1));
        st = i + 1;
      end
  endfunction

  // the C++ harness's generator: rng = rng * 1103515245 + 12345, stall when (rng >> 16) % 100 < N
  int unsigned rng;                     // generator state (module level: function ports are inputs only)
  function automatic bit draw(input int pct);
    int unsigned v;
    rng = rng * 32'd1103515245 + 32'd12345;
    v = (rng >> 16) % 100;
    return v < pct;
  endfunction

  // PNM image of img_a into out_q: P5 when one_ch (first channel only), else P6
  function automatic void make_pnm(input int w, input int h, input bit one_ch);
    string hdr;
    hdr = $sformatf("%s\n%0d %0d\n255\n", one_ch ? "P5" : "P6", w, h);
    out_q.delete();
    for (int i = 0; i < hdr.len(); i++) out_q.push_back(hdr[i]);
    for (longint i = 0; i < w * h; i++) begin
      out_q.push_back(img_a[i*3]);
      if (!one_ch) begin out_q.push_back(img_a[i*3+1]); out_q.push_back(img_a[i*3+2]); end
    end
  endfunction

  function automatic bit out_is_gold();
    if (out_q.size() != gold_q.size()) return 1'b0;
    foreach (out_q[i]) if (out_q[i] != gold_q[i]) return 1'b0;
    return 1'b1;
  endfunction

  // inputs for the next clock edge (set 1 ns after an edge), outputs sampled at the falling edge
  // (settled, before the next rising edge), state updates taken 1 ns after the rising edge
  int fmt_code;
  string fmt;

  initial begin
    string jpeg, files;
    fmt = "rgb";
    if ($value$plusargs("FMT=%s", fmt)) ;
    fmt_code = (fmt == "ycbcr") ? 1 : (fmt == "y") ? 2 : 0;
    out_fmt = fmt_code[1:0];
    if ($value$plusargs("FILES=%s", files)) run_multi(files);
    else if ($value$plusargs("JPEG=%s", jpeg)) run_single(jpeg);
    else $fatal(1, "usage: +JPEG=file.jpg [+OUT=..] [+GOLDEN=..] ... or +FILES=a.jpg,b.jpg +GOLDENS=a.pnm,-");
  end

  task automatic do_reset();
    rst = 1'b1; in_valid = 1'b0; in_data = 8'd0; in_last = 1'b0; px_ready = 1'b0;
    repeat (4) @(posedge clk);
    #1 rst = 1'b0;
  endtask

  // ------------------------------------------------------------------ one file
  task automatic run_single(input string jpeg);
    string outp, gpath;
    int stall = 0, n, pos = 0, W = 0, H = 0, rc = 0, fo, maxd, m, d, x, y, c0, c1, c2, pn, xi;
    bit in_st, out_st, in_fire, px_fire, fs, fd, sof, eol, gray, stop;
    logic [7:0] xy8;
    longint idx, ndiff, first;
    int unsigned expect_err = 0, expect_mask = 0, chk = 0;
    bit has_err = 0, has_mask = 0, no_last, no_pixels, quiet, have_dims = 0, done = 0, one_ch, as_ycbcr;
    longint npx = 0, dup = 0, oob = 0, order_err = 0, flag_err = 0, next_raster = 0, missing = 0;
    longint cycles = 0, last_progress = 0, max_cycles = 400000000;
    outp = ""; gpath = ""; stop = 0; rng = 12345;
    if ($value$plusargs("OUT=%s", outp)) ;
    if ($value$plusargs("GOLDEN=%s", gpath)) ;
    if ($value$plusargs("STALL=%d", stall)) ;
    if ($value$plusargs("MAX_CYCLES=%d", max_cycles)) ;
    has_err  = $value$plusargs("EXPECT_ERR=%h", expect_err);
    has_mask = $value$plusargs("EXPECT_ERR_MASK=%h", expect_mask);
    no_last = $test$plusargs("NO_LAST"); no_pixels = $test$plusargs("NO_PIXELS"); quiet = $test$plusargs("QUIET");
    as_ycbcr = !RGB_OUT && fmt == "rgb";             // RGB_OUT=0 builds deliver YCbCr for FMT_RGB
    read_file(jpeg); data_q = tmp_q; gold_q.delete();
    n = data_q.size();
    do_reset();
    while (!done && !stop && cycles < max_cycles) begin
      in_st = 0; out_st = 0;
      if (stall != 0) begin in_st = draw(stall); out_st = draw(stall); end
      in_valid = (pos < n) && !in_st;
      in_data  = (pos < n) ? data_q[pos] : 8'd0;
      in_last  = !no_last && (pos + 1 == n);
      px_ready = !out_st;
      @(negedge clk);
      in_fire = in_valid && in_ready; px_fire = px_valid && px_ready;
      x = px_x; y = px_y; c0 = px_c0; c1 = px_c1; c2 = px_c2; pn = px_n; sof = px_sof; eol = px_eol;
      fs = frame_start; fd = frame_done;
      @(posedge clk);
      #1;
      cycles++;
      if (in_fire) pos++;
      if (fs) begin
        W = img_w; H = img_h; have_dims = 1;
        img_a = new[W * H * 3]; seen_a = new[W * H];
        if (!quiet) $display("frame_start: %0dx%0d at cycle %0d", W, H, cycles);
      end
      if (px_fire) begin
        // a beat: pn pixels from (x, y); fewer than NPIX only where the image row ends
        if (pn < 1 || pn > NPIX || (have_dims && pn < NPIX && x + pn != W)) begin
          if (flag_err < 3) $display("beat at (%0d,%0d): px_n=%0d", x, y, pn);
          flag_err++;
        end else if (have_dims && (sof != (x == 0 && y == 0) || eol != (x + pn - 1 == W - 1))) begin
          if (flag_err < 3) $display("flags at (%0d,%0d): sof=%0d eol=%0d", x, y, sof, eol);
          flag_err++;
        end
        for (int i = 0; i < pn && i < NPIX; i++) begin
          xi = x + i;
          if (!have_dims || xi >= W || y >= H) oob++;
          else begin
            idx = y; idx = idx * W + xi;
            if (seen_a[idx]) dup++;
            if (RASTER_OUT && idx != next_raster) begin
              if (order_err < 3) $display("order: got (%0d,%0d), expected pixel #%0d", xi, y, next_raster);
              order_err++;
            end
            next_raster = idx + 1;
            seen_a[idx] = 8'd1; img_a[idx*3] = c0[8*i +: 8]; img_a[idx*3+1] = c1[8*i +: 8]; img_a[idx*3+2] = c2[8*i +: 8];
            xy8 = xi[7:0] ^ y[7:0];
            chk += {xy8, c0[8*i +: 8], c1[8*i +: 8], c2[8*i +: 8]};
            npx++; last_progress = cycles;
          end
        end
      end
      if (fd) begin done = 1; if (!quiet) $display("frame_done at cycle %0d", cycles); end
      if (have_dims && cycles - last_progress > 20000000) begin
        $display("no progress for 20M cycles, giving up"); stop = 1;
      end
    end
    $display("cycles=%0d bytes_consumed=%0d/%0d pixels=%0d dup=%0d oob=%0d order_err=%0d flag_err=%0d err=0x%04x checksum=0x%08x",
             cycles, pos, n, npx, dup, oob, order_err, flag_err, err, chk);
    if (!done) begin $display("FAIL: frame_done never seen"); rc = 1; end
    if (has_mask) begin
      if (done && (err & expect_mask) == expect_mask && !(no_pixels && npx != 0))
        $display("PASS: frame ended with err=0x%04x (expected bits 0x%04x)", err, expect_mask);
      else begin
        $display("FAIL: expected frame_done with err bits 0x%04x, got err=0x%04x done=%0d pixels=%0d", expect_mask, err, done, npx);
        rc = 1;
      end
    end
    else if (has_err) begin
      if (err == expect_err && npx == 0 && done) $display("PASS: expected err=0x%03x, no pixels", expect_err);
      else begin $display("FAIL: expected err=0x%03x and no pixels", expect_err); rc = 1; end
    end
    else begin
      if (dup || oob || order_err || flag_err) begin $display("FAIL: stream checks"); rc = 1; end
      if (have_dims) begin
        foreach (seen_a[i]) if (!seen_a[i]) missing++;
        if (missing) begin $display("FAIL: %0d pixels never produced", missing); rc = 1; end
        if (gpath != "") begin read_file(gpath); gold_q = tmp_q; end
        if (fmt == "y") one_ch = 1;
        else if (fmt == "ycbcr" || as_ycbcr) one_ch = 0;
        else begin                                       // rgb: P5 for grey images
          gray = 1;
          for (longint i = 0; i < W * H && gray; i++)
            gray = img_a[i*3] == img_a[i*3+1] && img_a[i*3+1] == img_a[i*3+2];
          one_ch = gray && (gold_q.size() == 0 ? 1'b1 : (gold_q.size() > 1 && gold_q[1] == "5"));
        end
        make_pnm(W, H, one_ch);
        if (outp != "") begin
          fo = $fopen(outp, "wb");
          if (fo == 0) $fatal(1, "cannot write %s", outp);
          foreach (out_q[i]) $fwrite(fo, "%c", out_q[i]);
          $fclose(fo);
        end
        if (gold_q.size() != 0) begin
          if (out_is_gold()) $display("PASS: output matches golden (%0d bytes)", out_q.size());
          else begin
            ndiff = 0; first = -1; maxd = 0;
            m = (gold_q.size() < out_q.size()) ? gold_q.size() : out_q.size();
            for (int i = 0; i < m; i++)
              if (gold_q[i] != out_q[i]) begin
                d = gold_q[i]; d = d - out_q[i];
                if (first < 0) first = i;
                ndiff++; if (d < 0) d = -d; if (d > maxd) maxd = d;
              end
            $display("FAIL: output differs from golden: sizes %0d vs %0d, %0d differing bytes, max abs diff %0d, first at byte %0d",
                     out_q.size(), gold_q.size(), ndiff, maxd, first);
            rc = 1;
          end
        end
      end
      if (err) begin $display("FAIL: decoder reported errors: 0x%03x", err); rc = 1; end
    end
    finish(rc);
  endtask

  // ------------------------------------------------------------------ several files back to back
  task automatic run_multi(input string files);
    string goldens;
    longint ends[$];
    int stall = 0, pos = 0, frame = 0, W = 0, H = 0, fails = 0, x, y, c0, c1, c2, pn;
    longint npx = 0, cycles = 0, last = 0, k, diff;
    bit in_st, out_st, in_fire, px_fire, fs, fd, lastb, one, stop;
    string verdict;
    goldens = ""; stop = 0; rng = 777;
    if ($value$plusargs("STALL=%d", stall)) ;
    if ($value$plusargs("GOLDENS=%s", goldens)) ;
    names_q.delete(); gnames_q.delete(); split(files, 0); split(goldens, 1);
    if (gnames_q.size() != names_q.size()) $fatal(1, "+GOLDENS needs one entry per file (- for none)");
    data_q.delete();
    foreach (names_q[j]) begin
      read_file(names_q[j]);
      foreach (tmp_q[i]) data_q.push_back(tmp_q[i]);
      ends.push_back(data_q.size() - 1);
    end
    do_reset();
    while (frame < names_q.size() && !stop) begin
      in_st = 0; out_st = 0; lastb = 0;
      if (stall != 0) begin in_st = draw(stall); out_st = draw(stall); end
      foreach (ends[i]) if (ends[i] == pos) lastb = 1;
      in_valid = pos < data_q.size() && !in_st;
      in_data  = pos < data_q.size() ? data_q[pos] : 8'd0;
      in_last  = lastb;
      px_ready = !out_st;
      @(negedge clk);
      in_fire = in_valid && in_ready; px_fire = px_valid && px_ready;
      x = px_x; y = px_y; c0 = px_c0; c1 = px_c1; c2 = px_c2; pn = px_n; fs = frame_start; fd = frame_done;
      @(posedge clk);
      #1;
      cycles++;
      if (in_fire) begin pos++; last = cycles; end
      if (fs) begin W = img_w; H = img_h; img_a = new[W * H * 3]; npx = 0; end
      if (px_fire)
        for (int i = 0; i < pn && i < NPIX; i++)
          if (x + i < W && y < H) begin
            k = y; k = (k * W + x + i) * 3;
            img_a[k] = c0[8*i +: 8]; img_a[k+1] = c1[8*i +: 8]; img_a[k+2] = c2[8*i +: 8]; npx++; last = cycles;
          end
      if (fd) begin
        verdict = "no golden";
        if (gnames_q[frame] != "-") begin
          read_file(gnames_q[frame]); gold_q = tmp_q;
          one = gold_q.size() > 1 && gold_q[1] == "5";
          make_pnm(W, H, one);
          if (out_is_gold()) verdict = "MATCH";
          else begin
            diff = 0;
            for (int i = 0; i < out_q.size() && i < gold_q.size(); i++) diff += (out_q[i] != gold_q[i]);
            verdict = $sformatf("DIFFERS (%0d bytes)", diff); fails++;
          end
        end
        $display("frame %0d: %0dx%0d, %0d pixels, err=0x%04x, %s", frame + 1, W, H, npx, err, verdict);
        frame++;
      end
      if (cycles - last > 2000000) begin
        $display("stalled: no progress for 2M clocks in frame %0d", frame + 1); fails++; stop = 1;
      end
    end
    $display("frames: %0d", frame);
    finish(fails != 0);
  endtask

  task automatic finish(input int rc);
    if (rc != 0) $fatal(1, "FAIL");
    $finish;
  endtask
endmodule
