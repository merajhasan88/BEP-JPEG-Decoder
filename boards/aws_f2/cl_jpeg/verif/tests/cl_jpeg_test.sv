// cl_jpeg_test.sv - AWS's XSIM testbench (the HDK's shell model sh_bfm, AWS's sh_ddr simulation model and DDR4 DIMM
// model) with the BEP-JPEG CL: the check on AWS's build image before the DCP build. As the F2 host would:
//   1. ID, VERSION, LANES, DW over OCL; the DDR4 ready (STATUS bit 0, polled);
//   2. two corpus files into DDR4 over PCIS (padded to whole 64-byte beats; write-combined DW writes, 1 KB pieces,
//      never across 4 KB), both output areas zeroed (the host's rules for the ECC DDR4, README.md); the files read
//      back over PCIS;
//   3. both decoded at once (lanes 0 and 1), DONE polled;
//   4. each job's status, pixels and hash; then every record read back over PCIS: every pixel exactly once, the
//      hash recomputed from them = the lane's HASH register = the golden image's hash (cl_jpeg_test_data.svh,
//      libjpeg 9e).
// Unlike the F2 host, the test first starts the DDR4's calibration: on the card the shell does it over the DDR4
// statistics bus when the image is loaded (AWS_Shell_Interface_Specification.md, "DDR4 Stats"); AWS's shell model
// does not, and AWS's own tests do it with the three writes below (initialize_ddr() in the HDK's
// cl_dram_hbm_dma_utils.svh). Without them the DDR4 never became ready (the first run on AWS, 2026-11-03).
`include "common_base_test.svh"

module cl_jpeg_test();
  import tb_type_defines_pkg::*;
  `include "cl_jpeg_test_data.svh"

  localparam logic [63:0] IN0 = 64'h0000_0001_0000_0000, IN1 = 64'h0000_0001_0001_0000;
  localparam logic [63:0] OUT0 = 64'h0000_0002_0000_0000, OUT1 = 64'h0000_0002_0010_0000;

  function automatic logic [63:0] mix(input logic [63:0] v);
    logic [63:0] z;
    z = v + 64'h9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) + (z << 7);
    z = (z ^ (z >> 27)) + (z << 13);
    return z ^ (z >> 31);
  endfunction

  task automatic ocl_wr(input logic [31:0] a, input logic [31:0] v);
    tb.poke_ocl(.addr(64'(a)), .data(v));
  endtask
  task automatic ocl_rd(input logic [31:0] a, output logic [31:0] v);
    logic [63:0] t;
    tb.peek_ocl(.addr(64'(a)), .data(t));
    v = t[31:0];
  endtask
  task automatic check(input string what, input logic [63:0] got, input logic [63:0] exp);
    if (got !== exp) begin
      $error("[%t] ***ERROR*** %s: 0x%0h, expected 0x%0h", $realtime, what, got, exp);
      error_count++;
    end else $display("[%t] %s: 0x%0h ok", $realtime, what, got);
  endtask

  // a file into DDR4 (padded to whole 64-byte beats, as the F2 host writes it): 1 KB pieces of DWs (the shell's
  // write-combined writes), each inside one 4 KB page
  task automatic load(input int k, input logic [63:0] base);
    logic [31:0] q [$];
    int nw, i, p;
    nw = (k == 0) ? NW0 : NW1;
    for (p = 0; p < nw; p += 256) begin
      q.delete();
      for (i = p; i < nw && i < p + 256; i++) begin
        if (k == 0) q.push_back(JPG0[i]);
        else        q.push_back(JPG1[i]);
      end
      tb.poke_pcis_wc(.addr(base + 64'(4 * p)), .data(q));
    end
  endtask

  // the file read back over PCIS, word by word
  task automatic check_load(input int k, input logic [63:0] base);
    logic [511:0] beat;
    logic [31:0]  w;
    int nw, i, bad;
    nw = (k == 0) ? NW0 : NW1;
    bad = 0;
    beat = '0;
    for (i = 0; i < nw; i++) begin
      if (i % 16 == 0) tb.peek_pcis(.addr(base + 64'(4 * i)), .data(beat));
      if (k == 0) w = JPG0[i];
      else        w = JPG1[i];
      if (beat[32 * (i % 16) +: 32] !== w) bad++;
    end
    check($sformatf("file %0d read back over PCIS: words differing", k), bad, 0);
  endtask

  // an output area zeroed before its first job, in whole beats (1 KB pieces)
  task automatic zero(input logic [63:0] base, input int bytes);
    logic [31:0] q [$];
    int p;
    for (p = 0; p < 256; p++) q.push_back(32'h0);
    for (p = 0; p < bytes; p += 1024) tb.poke_pcis_wc(.addr(base + 64'(p)), .data(q));
  endtask

  task automatic job(input int lane, input logic [63:0] in_a, input int len, input logic [63:0] out_a, input logic [31:0] tag);
    logic [31:0] b;
    b = 32'h100 + 32'h80 * lane;
    ocl_wr(b + 32'h00, in_a[31:0]);  ocl_wr(b + 32'h04, in_a[63:32]); ocl_wr(b + 32'h08, len);
    ocl_wr(b + 32'h0C, out_a[31:0]); ocl_wr(b + 32'h10, out_a[63:32]); ocl_wr(b + 32'h14, 32'h0100_0000);
    ocl_wr(b + 32'h18, tag);
    ocl_wr(b + 32'h1C, 32'h1);
  endtask

  // the lane's results, then its records over PCIS
  task automatic verify(input int lane, input logic [63:0] out_a, input int zeroed, input int w, input int h,
                        input logic [63:0] golden, input logic [31:0] tag);
    logic [31:0] b, st, rtag, pixels, records, size, hlo, hhi, cyc;
    logic [511:0] beat;
    logic [63:0] hsum;
    bit seen [];
    int r, i, x, y, n, npx, dup;
    b = 32'h100 + 32'h80 * lane;
    ocl_rd(b + 32'h20, st); ocl_rd(b + 32'h24, rtag); ocl_rd(b + 32'h28, cyc); ocl_rd(b + 32'h34, pixels);
    ocl_rd(b + 32'h38, records); ocl_rd(b + 32'h3C, size); ocl_rd(b + 32'h40, hlo); ocl_rd(b + 32'h44, hhi);
    $display("[%t] lane %0d: status 0x%08h cycles %0d pixels %0d records %0d size %0dx%0d", $realtime, lane, st, cyc,
             pixels, records, size[15:0], size[31:16]);
    check($sformatf("lane %0d STATUS (done, no error bits)", lane), st, 32'h2);
    check($sformatf("lane %0d RUN_TAG", lane), rtag, tag);
    check($sformatf("lane %0d SIZE", lane), size, {16'(h), 16'(w)});
    check($sformatf("lane %0d PIXELS", lane), pixels, w * h);
    check($sformatf("lane %0d HASH register = golden", lane), {hhi, hlo}, golden);
    check($sformatf("lane %0d records inside the zeroed area", lane), 16 * records <= zeroed, 1);
    seen = new[w * h];
    hsum = '0; npx = 0; dup = 0;
    for (r = 0; r < records; r += 4) begin
      tb.peek_pcis(.addr(out_a + 64'(16 * r)), .data(beat));
      for (i = 0; i < 4 && r + i < records; i++) begin
        x = beat[128 * i +: 16]; y = beat[128 * i + 16 +: 16];
        for (n = 0; n < 4 && x + n < w; n++) begin
          if (y >= h) begin dup++; continue; end
          if (seen[y * w + x + n]) dup++;
          seen[y * w + x + n] = 1; npx++;
          hsum += mix({16'(y), 16'(x + n), 8'd0, beat[128 * i + 32 + 24 * n +: 8], beat[128 * i + 40 + 24 * n +: 8],
                       beat[128 * i + 48 + 24 * n +: 8]});
        end
      end
    end
    check($sformatf("lane %0d pixels read back over PCIS", lane), npx, w * h);
    check($sformatf("lane %0d pixels placed twice or outside", lane), dup, 0);
    check($sformatf("lane %0d hash of the records read back = golden", lane), hsum, golden);
  endtask

  initial begin
    logic [31:0] v;
    int t;
    tb.power_up(.clk_recipe_a(ClockRecipe::A1));
    ocl_rd(32'h000, v); check("ID", v, 32'h4A504547);
    ocl_rd(32'h004, v); check("VERSION", v, 32'd2);
    ocl_rd(32'h008, v); $display("[%t] LANES %0d, COMMIT follows", $realtime, v);
    ocl_rd(32'h030, v); $display("[%t] COMMIT 0x%08h", $realtime, v);
    ocl_rd(32'h00C, v); check("DW", v, 32'd512);
    ocl_wr(32'h028, 32'hC0FFEE11); ocl_rd(32'h028, v); check("SCRATCH", v, 32'hC0FFEE11);
    // the DDR4's calibration started as AWS's own tests do (see the top), then STATUS polled as the host does: at most
    // about 1 ms of simulated time (AWS's tests wait 27 us; the DDR4 model simulates at about 4 minutes per ms), and
    // the test ends at once if the DDR4 is not ready
    tb.poke_stat(.addr(8'h0c), .intf("ddr"), .data(32'h0000_0000));
    tb.poke_stat(.addr(8'h0c), .intf("ddr"), .data(32'h0000_0001));
    tb.poke_stat(.addr(8'h0c), .intf("ddr"), .data(32'h0000_0000));
    for (t = 0; t < 1000; t++) begin
      ocl_rd(32'h02C, v);
      if (v[0]) break;
      tb.nsec_delay(1000);
    end
    check("STATUS: DDR4 ready", v[0], 1);
    if (!v[0]) begin
      tb.power_down();
      report_pass_fail_status();
      $finish;
    end
    $display("[%t] DDR4 ready after %0d polls of about 1 us", $realtime, t);
    ocl_rd(32'h034, v); check("MEM_ERR (no BAR4 access before ready)", v, 0);
    load(0, IN0);
    load(1, IN1);
    zero(OUT0, 4096);                // lane 0: 64 records (1 KB)
    zero(OUT1, 16384);               // lane 1: 444 records (7,104 bytes)
    ocl_rd(32'h034, v); check("MEM_ERR after the BAR4 writes", v, 0);
    check_load(0, IN0);
    check_load(1, IN1);
    job(0, IN0, LEN0, OUT0, 32'h00A0);
    job(1, IN1, LEN1, OUT1, 32'h00A1);
    for (t = 0; t < 500; t++) begin
      ocl_rd(32'h018, v);
      if (v[1:0] == 2'b11) break;
      tb.nsec_delay(1000);
    end
    check("DONE (lanes 0 and 1)", v[1:0], 2'b11);
    verify(0, OUT0, 4096, W0, H0, HASH0, 32'h00A0);
    verify(1, OUT1, 16384, W1, H1, HASH1, 32'h00A1);
    tb.power_down();
    report_pass_fail_status();
    $finish;
  end
endmodule
