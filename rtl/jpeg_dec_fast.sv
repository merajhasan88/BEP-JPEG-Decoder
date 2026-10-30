// jpeg_dec_fast.sv - high-throughput core of jpeg_decoder (FAST = 1).
//
//   bytes -> jpeg_parser (+ Huffman lookahead tables) -> jpeg_bitwin -> jpeg_huffdec
//         -> 4 coefficient slots -> jpeg_idct_fast (32 clocks per block) -> one sample RAM per
//            component -> RASTER_OUT = 0: jpeg_mcuout      (MCU order, two MCU halves)
//                         RASTER_OUT = 1: jpeg_raster_fast (raster order, MCU-row planes)
//
// The stages run concurrently on different blocks, coupled only by handshakes: the entropy
// decoder works up to four blocks ahead of the IDCT; the IDCT writes a block only where the
// output stage allows (p2_ok): MCU order - the other half of the MCU buffer while MCU m is
// emitted; raster order - MCU row n+1 (or n+2 with two planes) while row n is emitted.
// Pixels, errors and handshakes are identical to the compact core (jpeg_dec_small).
//
// Raster row buffer: one RAM for component 0 (ROWBUF_Y_BYTES, default ROWBUF_BYTES/2) and one for
// each of components 1 and 2 (ROWBUF_C_BYTES, default ROWBUF_BYTES/4), 32-bit words.  Per component: the plane of one MCU row (two when both fit: then decoding row
// n+1 overlaps the output of row n) followed by 2 or 3 line buffers that keep the last sample
// row of recent MCU rows for the vertical filter (written by the IDCT, so no copy pass).
module jpeg_dec_fast #(
  parameter bit RASTER_OUT     = 1'b0,
  parameter int ROWBUF_BYTES   = 16384,
  parameter int ROWBUF_Y_BYTES = 0,          // 0: ROWBUF_BYTES/2
  parameter int ROWBUF_C_BYTES = 0,          // 0: ROWBUF_BYTES/4 (each chroma component)
  parameter bit FANCY_UPSAMPLE = 1'b0,
  parameter bit CC_TURBO       = 1'b0,
  parameter bit RGB_OUT        = 1'b1,
  parameter bit CHECKS         = 1'b1
) (
  input  logic        clk,
  input  logic        rst,
  input  logic        in_valid,
  input  logic [7:0]  in_data,
  input  logic        in_last,
  output logic        in_ready,
  input  logic [1:0]  out_fmt,
  output logic        px_valid,
  input  logic        px_ready,
  output logic [15:0] px_x,
  output logic [15:0] px_y,
  output logic [7:0]  px_c0,
  output logic [7:0]  px_c1,
  output logic [7:0]  px_c2,
  output logic        px_sof,
  output logic        px_eol,
  output logic [15:0] img_w,
  output logic [15:0] img_h,
  output logic        frame_start,
  output logic        frame_done,
  output logic [12:0] err
);
  import jpeg_pkg::*;

  localparam bit FANCY = FANCY_UPSAMPLE & RASTER_OUT;
  localparam int RBW_Y = ((ROWBUF_Y_BYTES > 0) ? ROWBUF_Y_BYTES : ROWBUF_BYTES / 2) / 4;   // words, component 0
  localparam int RBW_C = ((ROWBUF_C_BYTES > 0) ? ROWBUF_C_BYTES : ROWBUF_BYTES / 4) / 4;   // words, components 1, 2
  localparam int RBW_M = (RBW_Y > RBW_C) ? RBW_Y : RBW_C;
  localparam int AWR   = (RBW_M > 2) ? $clog2(RBW_M) : 1;
  localparam int SAW   = RASTER_OUT ? AWR : 7;                  // sample-RAM word address width
  // block descriptor: {LB index, MCU row mod 4, last block of MCU / MCU row, LB copy, block row,
  //                    scan component, word offset}
  localparam int D_COMP = SAW, D_VV = SAW + 2, D_LBEN = SAW + 3, D_LAST = SAW + 4, D_ROW = SAW + 5, D_LBI = SAW + 7;
  localparam int DW     = SAW + 9;

  // ---------------------------------------------------------------- parser + tables
  logic        p_in_valid, p_in_ready, p_idle, p_soi;
  logic        dqt_we, hc_we, hv_we, lut_we;
  logic [7:0]  dqt_waddr, dqt_wdata, hv_wdata;
  logic [5:0]  hc_waddr;
  logic [24:0] hc_wdata;
  logic [8:0]  hv_waddr;
  logic [9:0]  lut_waddr;
  logic [11:0] lut_wdata;
  logic [1:0]  nf, ns;
  logic        cs_rgb;           // RGB image (parser): no colour conversion
  logic [11:0] comp_h, comp_v;
  logic [7:0]  comp_tq, scan_ci;
  logic [3:0]  scan_td, scan_ta;
  logic [15:0] ri;
  logic        scan_start, eoi;
  logic        tok_valid, tok_ready;
  logic [8:0]  tok_data;
  logic [12:0] err_set;
  logic        decoding;
  logic        skip_img, eoi_seen;   // unusable image: consume its scans until its EOI

  assign p_in_valid = in_valid & ~(decoding & p_idle);
  assign in_ready   = p_in_ready & ~(decoding & p_idle);

  jpeg_parser #(.LUT_EN(1'b1), .CHECKS(CHECKS)) u_parser (
    .clk(clk), .rst(rst),
    .in_valid(p_in_valid), .in_data(in_data), .in_last(in_last), .in_ready(p_in_ready), .idle(p_idle),
    .dqt_we(dqt_we), .dqt_waddr(dqt_waddr), .dqt_wdata(dqt_wdata),
    .hc_we(hc_we), .hc_waddr(hc_waddr), .hc_wdata(hc_wdata),
    .hv_we(hv_we), .hv_waddr(hv_waddr), .hv_wdata(hv_wdata),
    .lut_we(lut_we), .lut_waddr(lut_waddr), .lut_wdata(lut_wdata),
    .img_w(img_w), .img_h(img_h), .nf(nf), .cs_rgb(cs_rgb), .comp_h(comp_h), .comp_v(comp_v), .comp_tq(comp_tq),
    .ns(ns), .scan_ci(scan_ci), .scan_td(scan_td), .scan_ta(scan_ta), .ri(ri), .scan_start(scan_start),
    .tok_valid(tok_valid), .tok_data(tok_data), .tok_ready(tok_ready),
    .eoi(eoi), .soi(p_soi), .err_set(err_set));

  logic [7:0]  dqt_raddr, dqt_rdata, hv_rdata;
  logic [5:0]  hc_raddr;
  logic [24:0] hc_rdata;
  logic [8:0]  hv_raddr;
  logic [9:0]  lut_raddr;
  logic [11:0] lut_rdata;
  // (all table RAMs are read through the block RAMs' output registers: 2 clocks)
  jpeg_sdp_ram #(.WIDTH(8),  .DEPTH_LOG2(8), .OUT_REG(1'b1)) u_dqt (.clk(clk), .we(dqt_we), .waddr(dqt_waddr), .wdata(dqt_wdata), .raddr(dqt_raddr), .rdata(dqt_rdata));
  jpeg_sdp_ram #(.WIDTH(25), .DEPTH_LOG2(6), .OUT_REG(1'b1))  u_hc  (.clk(clk), .we(hc_we),  .waddr(hc_waddr),  .wdata(hc_wdata),  .raddr(hc_raddr),  .rdata(hc_rdata));
  jpeg_sdp_ram #(.WIDTH(8),  .DEPTH_LOG2(9), .OUT_REG(1'b1))  u_hv  (.clk(clk), .we(hv_we),  .waddr(hv_waddr),  .wdata(hv_wdata),  .raddr(hv_raddr),  .rdata(hv_rdata));
  jpeg_sdp_ram #(.WIDTH(12), .DEPTH_LOG2(10), .OUT_REG(1'b1)) u_lut (.clk(clk), .we(lut_we), .waddr(lut_waddr), .wdata(lut_wdata), .raddr(lut_raddr), .rdata(lut_rdata));

  // ---------------------------------------------------------------- bit window + block decoder
  logic [47:0] acc;
  logic [5:0]  wcnt;
  logic        eod, w_consume, restart_req, restart_done, err_pad, br_clear, br_at_end;
  logic [4:0]  w_n;
  jpeg_bitwin u_win (
    .clk(clk), .rst(rst), .clear(br_clear),
    .tok_valid(tok_valid), .tok_data(tok_data), .tok_ready(tok_ready),
    .acc(acc), .wcnt(wcnt), .eod(eod), .consume(w_consume), .n(w_n),
    .restart_req(restart_req), .restart_done(restart_done), .err_pad(err_pad), .at_end(br_at_end));

  logic        hd_start, hd_idle, hd_done, hd_err, pred_clear, hd_wr;
  logic        cw_we;
  logic [5:0]  cw_addr;
  logic signed [15:0] cw_data;
  logic [1:0]  cur_ci, cd_tq;
  logic        cd_dc, cd_ac;
  jpeg_huffdec u_hd (
    .clk(clk), .rst(rst),
    .start(hd_start), .comp(cur_ci), .dc_tbl(cd_dc), .ac_tbl(cd_ac), .tq(cd_tq), .wr_en(hd_wr), .pred_clear(pred_clear),
    .idle(hd_idle), .done(hd_done), .err_huff(hd_err),
    .acc(acc), .wcnt(wcnt), .consume(w_consume), .n(w_n),
    .lut_raddr(lut_raddr), .lut_rdata(lut_rdata), .hc_raddr(hc_raddr), .hc_rdata(hc_rdata),
    .hv_raddr(hv_raddr), .hv_rdata(hv_rdata), .dqt_raddr(dqt_raddr), .dqt_rdata(dqt_rdata),
    .cw_we(cw_we), .cw_addr(cw_addr), .cw_data(cw_data));

  // ---------------------------------------------------------------- IDCT
  // tag carried through pass 2: {MCU half (MCU order), last block of MCU / MCU row, component}
  logic           cw_ready, cw_commit, p2_pending, p2_ok, smp_we, blk_done, id_busy, p2_lb_en;
  logic [DW-1:0]  cw_desc, p2_desc;
  logic [3:0]     p2_tag, smp_tag, blk_tag;
  logic [SAW-1:0] p2_base, p2_pitch, p2_lbase, smp_addr;
  logic [31:0]    smp_data;
  assign p2_tag = {RASTER_OUT ? 1'b0 : p2_desc[6], p2_desc[D_LAST], p2_desc[D_COMP +: 2]};
  jpeg_idct_fast #(.DW(DW), .TW(4), .SAW(SAW)) u_idct (
    .clk(clk), .rst(rst),
    .cw_ready(cw_ready), .cw_we(cw_we), .cw_addr(cw_addr), .cw_data(cw_data), .cw_commit(cw_commit), .cw_desc(cw_desc),
    .p2_pending(p2_pending), .p2_desc(p2_desc), .p2_ok(p2_ok), .p2_base(p2_base), .p2_pitch(p2_pitch),
    .p2_lb_en(p2_lb_en), .p2_lbase(p2_lbase), .p2_tag(p2_tag),
    .smp_we(smp_we), .smp_addr(smp_addr), .smp_data(smp_data), .smp_tag(smp_tag),
    .blk_done(blk_done), .blk_tag(blk_tag), .busy(id_busy));

  // ---------------------------------------------------------------- frame state
  logic        gray, hmax2, vmax2, suppress, defer, w_err;
  logic [2:0]  h2, v2, uh_r, uv_r, hf_r, vf_r;
  logic [1:0]  fmt_r, nstore;
  logic        out_fin;                      // output side finished with the frame
  logic        out_idle;                     // output pipeline empty

  // ---------------------------------------------------------------- input side: block sequencing
  typedef enum logic [3:0] { S_IDLE, S_SETUP, S_GEO1, S_GEO2, S_GEO3, S_GEO4, S_GEO5,
                             S_BLK, S_BLK_WAIT, S_RESTART, S_DRAIN, S_SKIP, S_DONE } state_t;
  state_t state;

  logic [1:0]  j;
  logic        vv, hh;
  logic [15:0] mcu_w, mcu_h;
  logic [15:0] rst_cnt;
  logic [12:0] mx, my, mcux_m1, mcuy_m1;
  logic [13:0] mcux;
  logic        in_half;                      // MCU order: buffer half of the MCU being decoded
  logic [1:0]  in_lbi;                       // raster: line buffer of the MCU row being decoded
  logic        cur_skip;
  logic [DW-1:0] cur_desc;
  integer      gi;

  function automatic logic is2(input logic [11:0] hv, input logic [1:0] c);
    is2 = (hv[3*c +: 3] == 3'd2);
  endfunction
  function automatic logic [1:0] ci_of(input logic [7:0] sc, input logic [1:0] jj);
    ci_of = sc[2*jj +: 2];
  endfunction
  logic hmax2_c, vmax2_c;
  assign hmax2_c = (nf == 2'd1) ? 1'b0 : (is2(comp_h, ci_of(scan_ci, 2'd0)) | is2(comp_h, ci_of(scan_ci, 2'd1)) | is2(comp_h, ci_of(scan_ci, 2'd2)));
  assign vmax2_c = (nf == 2'd1) ? 1'b0 : (is2(comp_v, ci_of(scan_ci, 2'd0)) | is2(comp_v, ci_of(scan_ci, 2'd1)) | is2(comp_v, ci_of(scan_ci, 2'd2)));

  logic cur_h2, cur_v2, last_blk_of_comp, last_comp, skip_idct, more_x, more_y, last_nonskip;
  logic [15:0] wm1_c, hm1_c;
  localparam logic [12:0] hdr_err_mask = (13'd1 << ERR_SOF_TYPE) | (13'd1 << ERR_PRECISION) | (13'd1 << ERR_DQT)
                                       | (13'd1 << ERR_DHT) | (13'd1 << ERR_NCOMP) | (13'd1 << ERR_SAMPLING)
                                       | (13'd1 << ERR_SCAN) | (13'd1 << ERR_FRAME) | (13'd1 << ERR_TRUNC);
  assign cur_ci   = ci_of(scan_ci, j);
  assign cur_h2   = h2[j];
  assign cur_v2   = v2[j];
  assign cd_dc    = scan_td[j];
  assign cd_ac    = scan_ta[j];
  assign cd_tq    = comp_tq[2*cur_ci +: 2];
  assign wm1_c    = img_w - 16'd1;
  assign hm1_c    = img_h - 16'd1;
  assign last_blk_of_comp = (hh == cur_h2) && (vv == cur_v2);
  assign last_comp        = (j == ns - 2'd1);
  assign skip_idct        = ((fmt_r == FMT_Y) && (j != 2'd0)) || (RASTER_OUT && suppress);
  assign last_nonskip     = last_blk_of_comp && ((fmt_r == FMT_Y) ? (j == 2'd0) : last_comp);
  assign more_x           = (mx != mcux_m1);
  assign more_y           = (my != mcuy_m1);
  assign hd_wr            = ~skip_idct;

  // ---- raster geometry (words; 24-bit arithmetic, mcux <= 8192): per component c
  //   pw = mcux*2*Hc words per plane row, plane = pw*8*Vc, line buffers after 1 or 2 planes
  logic [23:0] pw24 [0:2], pl24 [0:2], need1 [0:2], need2 [0:2];
  logic        nslots2;                      // two planes: decoding overlaps the output
  logic [SAW-1:0] pw_w [0:2], pl_w [0:2], lb0_w [0:2];
  function automatic logic [SAW-1:0] tr(input logic [23:0] v);
    tr = v[SAW-1:0];
  endfunction
  function automatic logic [1:0] lb_next(input logic [1:0] i, input logic two);
    lb_next = (i == (two ? 2'd2 : 2'd1)) ? 2'd0 : i + 2'd1;          // modulo 2 or 3 line buffers
  endfunction
  function automatic logic [SAW-1:0] lb_addr(input logic [SAW-1:0] lb0, input logic [SAW-1:0] pw, input logic [1:0] i);
    lb_addr = lb0 + (i[1] ? {pw[SAW-2:0], 1'b0} : {SAW{1'b0}}) + (i[0] ? pw : {SAW{1'b0}});
  endfunction

  // ---- descriptor of the current block
  logic [5:0]     blk_off;                   // MCU order: word offset in the component's plane
  logic [31:0]    colw;                      // raster: word column of the block in the plane row
  logic [31:0]    moff;                      // MCU order: {half, blk_off}
  logic [SAW-1:0] d_off;
  assign blk_off = (vv ? (cur_h2 ? 6'd32 : 6'd16) : 6'd0) + (hh ? 6'd2 : 6'd0);
  assign colw    = (cur_h2 ? {18'd0, mx, hh} : {19'd0, mx}) << 1;
  assign moff    = {25'd0, in_half, blk_off};
  assign d_off   = RASTER_OUT ? colw[SAW-1:0] : moff[SAW-1:0];

  // commit a decoded block to the IDCT in the cycle its decoder finishes (wp advances at once)
  assign cw_commit = (state == S_BLK_WAIT) && hd_done && !cur_skip;
  assign cw_desc   = cur_desc;

  always_ff @(posedge clk) begin
    hd_start <= 1'b0; pred_clear <= 1'b0; frame_start <= 1'b0; frame_done <= 1'b0; br_clear <= 1'b0; w_err <= 1'b0;
    if (rst) begin
      state <= S_IDLE; decoding <= 1'b0; restart_req <= 1'b0; err <= '0; skip_img <= 1'b0; eoi_seen <= 1'b0;
      j <= '0; vv <= 1'b0; hh <= 1'b0; mcu_w <= '0; mcu_h <= '0; rst_cnt <= '0;
      gray <= 1'b0; hmax2 <= 1'b0; vmax2 <= 1'b0; h2 <= '0; v2 <= '0; fmt_r <= FMT_RGB; nstore <= 2'd3;
      mx <= '0; my <= '0; mcux <= '0; mcux_m1 <= '0; mcuy_m1 <= '0; in_half <= 1'b0; in_lbi <= '0;
      cur_skip <= 1'b0; cur_desc <= '0;
      uh_r <= '0; uv_r <= '0; hf_r <= '0; vf_r <= '0; suppress <= 1'b0; defer <= 1'b0; nslots2 <= 1'b0;
      for (gi = 0; gi < 3; gi = gi + 1) begin
        pw24[gi] <= '0; pl24[gi] <= '0; need1[gi] <= '0; need2[gi] <= '0; pw_w[gi] <= '0; pl_w[gi] <= '0; lb0_w[gi] <= '0;
      end
    end else begin
      // errors of the current image: cleared when the next image's SOI is accepted (the parser
      // is held at that SOI until frame_done, so err describes the last frame until then)
      err <= (p_soi ? 13'd0 : err) | err_set | ({12'd0, hd_err} << ERR_HUFF) | ({12'd0, err_pad & (state != S_DRAIN) & (state != S_SKIP)} << ERR_MARKER)
                 | ({12'd0, w_err} << ERR_WIDTH);

      if (eoi) eoi_seen <= 1'b1;
      case (state)
        S_IDLE: if (scan_start) begin
          decoding <= 1'b1; frame_start <= 1'b1; eoi_seen <= 1'b0;
          if (img_w == 16'd0 || img_h == 16'd0) err[ERR_FRAME] <= 1'b1;   // X or Y = 0 (DNL), or no SOF
          if (cs_rgb && out_fmt != FMT_RGB) err[ERR_SOF_TYPE] <= 1'b1;     // an RGB image: RGB output only
          if (img_w == 16'd0 || img_h == 16'd0 || (hdr_err_mask & (err_set | err)) != 13'd0 || (cs_rgb && out_fmt != FMT_RGB)) begin
            skip_img <= 1'b1; state <= S_DRAIN;               // no pixels: consume the image's scans
          end else state <= S_SETUP;
        end
        S_SETUP: begin
          gray   <= (nf == 2'd1);
          fmt_r  <= cs_rgb ? FMT_YCBCR : out_fmt;   // RGB image: no colour conversion
          nstore <= ((nf == 2'd1) || (out_fmt == FMT_Y)) ? 2'd1 : 2'd3;
          hmax2  <= hmax2_c; vmax2 <= vmax2_c;
          mcu_w  <= hmax2_c ? 16'd16 : 16'd8;
          mcu_h  <= vmax2_c ? 16'd16 : 16'd8;
          mcux   <= hmax2_c ? ({2'b00, img_w[15:4]} + {13'd0, |img_w[3:0]}) : ({1'b0, img_w[15:3]} + {13'd0, |img_w[2:0]});
          mcux_m1 <= hmax2_c ? {1'b0, wm1_c[15:4]} : wm1_c[15:3];
          mcuy_m1 <= vmax2_c ? {1'b0, hm1_c[15:4]} : hm1_c[15:3];
          if (nf == 2'd1) begin h2 <= 3'b000; v2 <= 3'b000; end
          else begin
            h2 <= {is2(comp_h, ci_of(scan_ci, 2'd2)), is2(comp_h, ci_of(scan_ci, 2'd1)), is2(comp_h, ci_of(scan_ci, 2'd0))};
            v2 <= {is2(comp_v, ci_of(scan_ci, 2'd2)), is2(comp_v, ci_of(scan_ci, 2'd1)), is2(comp_v, ci_of(scan_ci, 2'd0))};
          end
          mx <= '0; my <= '0; j <= '0; vv <= 1'b0; hh <= 1'b0; in_half <= 1'b0; in_lbi <= '0;
          rst_cnt <= ri; pred_clear <= 1'b1; suppress <= 1'b0; nslots2 <= 1'b0;
          state <= S_GEO1;
        end
        S_GEO1: begin
          for (gi = 0; gi < 3; gi = gi + 1) begin
            uh_r[gi] <= hmax2 & ~h2[gi];
            uv_r[gi] <= vmax2 & ~v2[gi];
            // libjpeg-turbo: the horizontal / 2x2 filters need a component wider than 2 samples
            hf_r[gi] <= FANCY & (hmax2 & ~h2[gi]) & (img_w > 16'd4);
            vf_r[gi] <= FANCY & (vmax2 & ~v2[gi]) & (~(hmax2 & ~h2[gi]) | (img_w > 16'd4));
            pw24[gi] <= {10'd0, mcux} << (1 + h2[gi]);
          end
          state <= RASTER_OUT ? S_GEO2 : S_BLK;
        end
        // ---- raster: row-buffer layout and fit
        S_GEO2: begin
          defer <= (nstore == 2'd1) ? vf_r[0] : |vf_r;
          for (gi = 0; gi < 3; gi = gi + 1) pl24[gi] <= pw24[gi] << (3 + v2[gi]);
          state <= S_GEO3;
        end
        S_GEO3: begin
          for (gi = 0; gi < 3; gi = gi + 1) begin
            need1[gi] <= pl24[gi] + (defer ? {pw24[gi][22:0], 1'b0} : 24'd0);
            need2[gi] <= {pl24[gi][22:0], 1'b0} + (defer ? {pw24[gi][22:0], 1'b0} + pw24[gi] : 24'd0);
          end
          state <= S_GEO4;
        end
        S_GEO4: begin
          nslots2 <= (need2[0] <= RBW_Y) && ((nstore == 2'd1) || ((need2[1] <= RBW_C) && (need2[2] <= RBW_C)));
          if (!((need1[0] <= RBW_Y) && ((nstore == 2'd1) || ((need1[1] <= RBW_C) && (need1[2] <= RBW_C))))) begin
            suppress <= 1'b1; w_err <= 1'b1;                   // MCU row does not fit: no pixels
          end
          state <= S_GEO5;
        end
        S_GEO5: begin
          for (gi = 0; gi < 3; gi = gi + 1) begin
            pw_w[gi]  <= tr(pw24[gi]);
            pl_w[gi]  <= tr(pl24[gi]);
            lb0_w[gi] <= nslots2 ? tr({pl24[gi][22:0], 1'b0}) : tr(pl24[gi]);
          end
          state <= S_BLK;
        end
        S_BLK: if (hd_idle && (skip_idct || cw_ready)) begin
          hd_start <= 1'b1; cur_skip <= skip_idct;
          cur_desc <= {in_lbi, my[1:0], last_nonskip && (!RASTER_OUT || !more_x),
                       RASTER_OUT && defer && (vv == cur_v2), vv, j, d_off};
          state <= S_BLK_WAIT;
        end
        S_BLK_WAIT: if (hd_done) begin
          if (!last_blk_of_comp) begin
            if (hh == cur_h2) begin hh <= 1'b0; vv <= 1'b1; end
            else hh <= 1'b1;
            state <= S_BLK;
          end else if (!last_comp) begin
            hh <= 1'b0; vv <= 1'b0; j <= j + 2'd1; state <= S_BLK;
          end else begin                                       // MCU complete
            hh <= 1'b0; vv <= 1'b0; j <= '0; in_half <= ~in_half;
            rst_cnt <= rst_cnt - 16'd1;
            if (more_x || more_y) begin
              if (more_x) mx <= mx + 13'd1;
              else begin mx <= '0; my <= my + 13'd1; in_lbi <= lb_next(in_lbi, nslots2); end
              state <= (ri != 16'd0 && rst_cnt == 16'd1) ? S_RESTART : S_BLK;
            end else state <= S_DRAIN;
          end
        end
        S_RESTART: begin                                        // T.81 F.2.2.5 / B.2.4.4
          restart_req <= 1'b1;
          if (restart_done) begin
            restart_req <= 1'b0; pred_clear <= 1'b1; rst_cnt <= ri; state <= S_BLK;
          end
        end
        S_DRAIN: begin                                          // skip to the marker ending the scan
          restart_req <= 1'b1;
          if (restart_done) begin
            restart_req <= 1'b0;
            if (br_at_end) begin
              br_clear <= 1'b1; state <= S_SKIP;          // then the rest of the image, up to its EOI
            end
          end
        end
        // after the scan: consume the rest of the image (e.g. a COM segment after the scan) and end
        // the frame once, at its EOI - or at the EOI the parser appends when in_last comes first
        // (ERR_TRUNC), so frame_done always carries the image's final error.  An unusable image
        // (e.g. progressive) may have more scans: drain them; a second scan after a decoded one is
        // not supported (ERR_SCAN).
        S_SKIP: if (eoi_seen || eoi) begin skip_img <= 1'b0; state <= S_DONE; end
                else if (scan_start) begin
                  if (!skip_img) err[ERR_SCAN] <= 1'b1;
                  skip_img <= 1'b1; state <= S_DRAIN;
                end
        S_DONE: if (out_fin && !id_busy && out_idle) begin      // wait for the last pixel
          frame_done <= 1'b1; decoding <= 1'b0; br_clear <= 1'b1; state <= S_IDLE;
        end
        default: state <= S_IDLE;
      endcase
    end
  end

  // ================================================================ output side
  genvar gc;
  generate
    if (!RASTER_OUT) begin : g_mcu
      // ---- MCU buffer: one RAM per component, two halves of 64 words
      logic [1:0]  mcu_full, mcu_started;    // per half: complete / being emitted
      logic [6:0]  mo_raddr [0:2];
      logic [31:0] mo_rdata [0:2];
      for (gc = 0; gc < 3; gc = gc + 1) begin : g_mbuf
        jpeg_sdp_ram #(.WIDTH(32), .DEPTH_LOG2(7)) u_mb (
          .clk(clk), .we(smp_we && smp_tag[1:0] == gc), .waddr(smp_addr[6:0]), .wdata(smp_data),
          .raddr(mo_raddr[gc]), .rdata(mo_rdata[gc]));
      end
      assign p2_base  = p2_desc[SAW-1:0];
      assign p2_pitch = h2[p2_desc[D_COMP +: 2]] ? 7'd4 : 7'd2;
      assign p2_ok    = ~mcu_full[p2_desc[6]];
      assign p2_lb_en = 1'b0;
      assign p2_lbase = '0;

      logic        mo_start, mo_done, mo_idle, mo_ready;
      logic        os_half, od_half;         // half of the next MCU to start / to finish
      logic [12:0] omx, omy;
      logic [15:0] ox0, oy0, ow, ol;
      logic        out_expect, all_started;
      logic [4:0]  mo_width, mo_lines;
      assign ow       = img_w - ox0;
      assign ol       = img_h - oy0;
      assign mo_width = (ow > mcu_w) ? mcu_w[4:0] : ow[4:0];
      assign mo_lines = (ol > mcu_h) ? mcu_h[4:0] : ol[4:0];
      assign mo_start = out_expect && !all_started && mo_ready && mcu_full[os_half] && !mcu_started[os_half];
      assign out_fin  = all_started;
      assign out_idle = mo_idle;

      jpeg_mcuout #(.CC_TURBO(CC_TURBO), .RGB_OUT(RGB_OUT)) u_mo (
        .clk(clk), .rst(rst), .start(mo_start), .half(os_half), .x0(ox0), .y0(oy0), .width(mo_width), .nlines(mo_lines),
        .done(mo_done), .idle(mo_idle), .ready(mo_ready),
        .img_w(img_w), .gray(gray), .fmt(fmt_r), .uh(uh_r), .uv(uv_r), .h2(h2),
        .raddr0(mo_raddr[0]), .raddr1(mo_raddr[1]), .raddr2(mo_raddr[2]),
        .rdata0(mo_rdata[0]), .rdata1(mo_rdata[1]), .rdata2(mo_rdata[2]),
        .px_valid(px_valid), .px_ready(px_ready), .px_x(px_x), .px_y(px_y),
        .px_c0(px_c0), .px_c1(px_c1), .px_c2(px_c2), .px_sof(px_sof), .px_eol(px_eol));

      always_ff @(posedge clk) begin
        if (rst) begin
          mcu_full <= '0; mcu_started <= '0; os_half <= 1'b0; od_half <= 1'b0;
          omx <= '0; omy <= '0; ox0 <= '0; oy0 <= '0; all_started <= 1'b1; out_expect <= 1'b0;
        end else if (state == S_IDLE && scan_start) begin
          out_expect <= 1'b0; all_started <= 1'b1;             // until S_SETUP: nothing to emit
        end else if (state == S_SETUP) begin
          mcu_full <= '0; mcu_started <= '0; os_half <= 1'b0; od_half <= 1'b0;
          omx <= '0; omy <= '0; ox0 <= '0; oy0 <= '0; all_started <= 1'b0; out_expect <= 1'b1;
        end else begin
          if (blk_done && blk_tag[2]) mcu_full[blk_tag[3]] <= 1'b1;
          if (mo_start) begin
            mcu_started[os_half] <= 1'b1; os_half <= ~os_half;
            if (omx != mcux_m1) begin omx <= omx + 13'd1; ox0 <= ox0 + mcu_w; end
            else begin
              omx <= '0; ox0 <= '0;
              if (omy != mcuy_m1) begin omy <= omy + 13'd1; oy0 <= oy0 + mcu_h; end
              else all_started <= 1'b1;                        // last MCU started
            end
          end
          if (mo_done) begin
            mcu_full[od_half] <= 1'b0; mcu_started[od_half] <= 1'b0; od_half <= ~od_half;
          end
        end
      end
    end else begin : g_raster
      // ---- row buffer: one RAM per component
      logic [3*SAW-1:0] rs_raddr, rs_pbase, rs_lbase, rs_pw;
      logic [95:0]      rs_rdata;
      jpeg_sdp_ram #(.WIDTH(32), .DEPTH_LOG2(SAW), .DEPTH(RBW_Y)) u_rb0 (
        .clk(clk), .we(smp_we && smp_tag[1:0] == 2'd0), .waddr(smp_addr), .wdata(smp_data),
        .raddr(rs_raddr[SAW-1:0]), .rdata(rs_rdata[31:0]));
      jpeg_sdp_ram #(.WIDTH(32), .DEPTH_LOG2(SAW), .DEPTH(RBW_C)) u_rb1 (
        .clk(clk), .we(smp_we && smp_tag[1:0] == 2'd1), .waddr(smp_addr), .wdata(smp_data),
        .raddr(rs_raddr[2*SAW-1:SAW]), .rdata(rs_rdata[63:32]));
      jpeg_sdp_ram #(.WIDTH(32), .DEPTH_LOG2(SAW), .DEPTH(RBW_C)) u_rb2 (
        .clk(clk), .we(smp_we && smp_tag[1:0] == 2'd2), .waddr(smp_addr), .wdata(smp_data),
        .raddr(rs_raddr[3*SAW-1:2*SAW]), .rdata(rs_rdata[95:64]));

      // ---- pass-2 destination of the next block
      logic [1:0] r_allow;                   // MCU rows < r_allow (mod 4) may be written
      logic [1:0] p2c;
      logic       p2_slot;
      assign p2c      = p2_desc[D_COMP +: 2];
      assign p2_slot  = nslots2 & p2_desc[D_ROW];
      assign p2_base  = (p2_slot ? pl_w[p2c] : {SAW{1'b0}})
                      + (p2_desc[D_VV] ? {pw_w[p2c][SAW-4:0], 3'b000} : {SAW{1'b0}}) + p2_desc[SAW-1:0];
      assign p2_pitch = pw_w[p2c];
      assign p2_lb_en = p2_desc[D_LBEN];
      assign p2_lbase = lb_addr(lb0_w[p2c], pw_w[p2c], p2_desc[D_LBI +: 2]) + p2_desc[SAW-1:0];
      assign p2_ok    = (r_allow - p2_desc[D_ROW +: 2]) != 2'd0;

      // ---- MCU rows in order: deferred last line of the previous row, then this row's lines
      typedef enum logic [2:0] { O_FIN, O_WAIT, O_DEF, O_DEF_W, O_LINES, O_LINES_W } ostate_t;
      ostate_t     ost;
      logic [1:0]  rows_ready;               // MCU rows complete in the row buffer, not yet emitted
      logic [12:0] orow;
      logic [15:0] oy0, oh;
      logic [1:0]  o_lbi, o_lbprev;
      logic        defer_pending, o_last, rs_start, rs_done, rs_idle, o_slot;
      logic [1:0]  rs_mode;
      logic [4:0]  rs_nlines;
      logic [15:0] rs_y0;
      assign o_last   = (orow == mcuy_m1);
      assign o_slot   = nslots2 & orow[0];
      assign oh       = img_h - oy0;
      assign out_fin  = (ost == O_FIN);
      for (gc = 0; gc < 3; gc = gc + 1) begin : g_cmd
        assign rs_pbase[gc*SAW +: SAW] = o_slot ? pl_w[gc] : {SAW{1'b0}};
        assign rs_lbase[gc*SAW +: SAW] = lb_addr(lb0_w[gc], pw_w[gc], o_lbprev);
        assign rs_pw[gc*SAW +: SAW]    = pw_w[gc];
      end

      jpeg_raster_fast #(.AW(SAW), .FANCY(FANCY), .CC_TURBO(CC_TURBO), .RGB_OUT(RGB_OUT)) u_rs (
        .clk(clk), .rst(rst),
        .start(rs_start), .mode(rs_mode), .nlines(rs_nlines), .y0(rs_y0), .first_row(orow == 13'd0), .lastrow(o_last),
        .pbase(rs_pbase), .lbase(rs_lbase), .done(rs_done), .idle(rs_idle),
        .img_w(img_w), .img_h(img_h), .nproc(nstore), .gray(gray), .fmt(fmt_r),
        .uh(uh_r), .uv(uv_r), .hf(hf_r), .vf(vf_r), .pw(rs_pw),
        .raddr(rs_raddr), .rdata(rs_rdata),
        .px_valid(px_valid), .px_ready(px_ready), .px_x(px_x), .px_y(px_y),
        .px_c0(px_c0), .px_c1(px_c1), .px_c2(px_c2), .px_sof(px_sof), .px_eol(px_eol));
      assign out_idle = rs_idle;

      logic row_in, row_out;
      assign row_in  = blk_done && blk_tag[2];
      assign row_out = (ost == O_LINES_W) && rs_done;
      always_ff @(posedge clk) begin
        rs_start <= 1'b0;
        if (rst) begin
          ost <= O_FIN; rows_ready <= '0; orow <= '0; oy0 <= '0; o_lbi <= '0; o_lbprev <= '0; defer_pending <= 1'b0;
          r_allow <= 2'd1; rs_mode <= CMD_LINES; rs_nlines <= '0; rs_y0 <= '0;
        end else if (state == S_GEO5) begin                    // frame start (geometry known)
          ost <= suppress ? O_FIN : O_WAIT;
          rows_ready <= '0; orow <= '0; oy0 <= '0; o_lbi <= '0; o_lbprev <= '0; defer_pending <= 1'b0;
          r_allow <= nslots2 ? 2'd2 : 2'd1;
        end else if (state == S_IDLE && scan_start) begin
          ost <= O_FIN;                                         // until S_GEO5: nothing to emit
        end else begin
          rows_ready <= rows_ready + {1'b0, row_in} - {1'b0, row_out};
          case (ost)
            O_WAIT: if (rows_ready != 2'd0) ost <= O_DEF;
            O_DEF: begin
              if (defer_pending) begin                          // last line of the previous MCU row
                rs_start <= 1'b1; rs_mode <= CMD_DEFER; rs_y0 <= oy0 - 16'd1; ost <= O_DEF_W;
              end else ost <= O_LINES;
            end
            O_DEF_W: if (rs_done) ost <= O_LINES;
            O_LINES: begin
              rs_start <= 1'b1; rs_mode <= CMD_LINES; rs_y0 <= oy0;
              if (o_last)     rs_nlines <= oh[4:0];               // last MCU row: all remaining lines
              else if (defer) rs_nlines <= mcu_h[4:0] - 5'd1;     // keep the last line for later
              else            rs_nlines <= mcu_h[4:0];
              ost <= O_LINES_W;
            end
            O_LINES_W: if (rs_done) begin
              r_allow <= r_allow + 2'd1;                        // this row's plane may be reused
              defer_pending <= defer && !o_last;
              orow <= orow + 13'd1; oy0 <= oy0 + mcu_h;
              o_lbprev <= o_lbi; o_lbi <= lb_next(o_lbi, nslots2);
              ost <= o_last ? O_FIN : O_WAIT;
            end
            default: ;
          endcase
        end
      end
    end
  endgenerate
endmodule
