// tb_jpeg.cpp - Verilator testbench for jpeg_decoder (any build configuration).
//
//   Vjpeg_decoder <in.jpg> <out.pnm> [--golden ref.pnm] [--fmt rgb|ycbcr|y] [--raster]
//                 [--stall N] [--expect-err HEX] [--trace out.vcd] [--quiet] [--max-cycles N]
//
// Streams the file into the decoder one byte per clock (with optional random input stalls and
// output back-pressure, N % of cycles), rebuilds the image from the pixel stream and writes it
// as PNM: rgb -> P6 (P5 for grey images when the golden is P5), ycbcr -> P6 holding Y,Cb,Cr,
// y -> P5.  Checks: every pixel exactly once, px_sof only on (0,0), px_eol exactly on x = W-1,
// and with --raster that pixels arrive in strict raster order.  Built with -DNPIX=4 (FAST = 2) it
// takes beats of px_n pixels (pixel i at px_x + i, bits 8i+7..8i), all full except at the right edge.  With --golden the image is
// compared byte for byte against model/jpeg_golden.py (or djpeg / Pillow) output.
// --expect-err: the frame must end with exactly these err bits and produce no pixels.
// --expect-err-mask: the frame must end (frame_done) with at least these err bits; pixels allowed
//   (truncated files: the decoder completes the frame from zero bits) unless --no-pixels.
// in_last is raised on the last byte of the file unless --no-last.
#include <verilated.h>
#include "Vjpeg_decoder.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <fstream>
#if VM_TRACE
#include <verilated_vcd_c.h>
#endif

#ifndef NPIX
#define NPIX 1
#endif

static vluint64_t sim_time = 0;
double sc_time_stamp() { return sim_time; }

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 3) { fprintf(stderr, "usage: %s in.jpg out.pnm [--golden ref.pnm] [--fmt rgb|ycbcr|y] [--raster] [--stall N] [--expect-err HEX] [--trace f.vcd] [--quiet]\n", argv[0]); return 2; }
    std::string in_path = argv[1], out_path = argv[2], golden_path, trace_path, fmt = "rgb";
    int stall = 0; bool raster = false, quiet = false, as_ycbcr = false, no_last = false, no_pixels = false; long expect_err = -1, expect_mask = -1;
    unsigned long long max_cycles = 400000000ULL;
    for (int i = 3; i < argc; i++) {
        if (!strcmp(argv[i], "--golden") && i + 1 < argc) golden_path = argv[++i];
        else if (!strcmp(argv[i], "--trace") && i + 1 < argc) trace_path = argv[++i];
        else if (!strcmp(argv[i], "--stall") && i + 1 < argc) stall = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--fmt") && i + 1 < argc) fmt = argv[++i];
        else if (!strcmp(argv[i], "--expect-err") && i + 1 < argc) expect_err = strtol(argv[++i], nullptr, 16);
        else if (!strcmp(argv[i], "--expect-err-mask") && i + 1 < argc) expect_mask = strtol(argv[++i], nullptr, 16);
        else if (!strcmp(argv[i], "--no-last")) no_last = true;
        else if (!strcmp(argv[i], "--no-pixels")) no_pixels = true;
        else if (!strcmp(argv[i], "--raster")) raster = true;
        else if (!strcmp(argv[i], "--quiet")) quiet = true;
        else if (!strcmp(argv[i], "--as-ycbcr")) as_ycbcr = true;     // RGB_OUT=0 builds: FMT_RGB yields YCbCr
        else if (!strcmp(argv[i], "--max-cycles") && i + 1 < argc) max_cycles = strtoull(argv[++i], nullptr, 10);
    }
    int fmt_code = fmt == "ycbcr" ? 1 : fmt == "y" ? 2 : 0;
    std::ifstream f(in_path, std::ios::binary);
    if (!f) { fprintf(stderr, "cannot open %s\n", in_path.c_str()); return 2; }
    std::vector<unsigned char> data((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());

    Vjpeg_decoder* dut = new Vjpeg_decoder;
#if VM_TRACE
    VerilatedVcdC* tfp = nullptr;
    if (!trace_path.empty()) { Verilated::traceEverOn(true); tfp = new VerilatedVcdC; dut->trace(tfp, 99); tfp->open(trace_path.c_str()); }
#endif
    auto tick = [&]() {
        dut->clk = 0; dut->eval();
#if VM_TRACE
        if (tfp) tfp->dump(sim_time);
#endif
        sim_time++;
        dut->clk = 1; dut->eval();
#if VM_TRACE
        if (tfp) tfp->dump(sim_time);
#endif
        sim_time++;
    };

    dut->clk = 0; dut->rst = 1; dut->in_valid = 0; dut->in_data = 0; dut->in_last = 0; dut->px_ready = 0; dut->out_fmt = fmt_code;
    for (int i = 0; i < 4; i++) tick();
    dut->rst = 0;

    size_t pos = 0;
    int W = 0, H = 0; bool have_dims = false, done = false;
    std::vector<unsigned char> img, seen;
    long long npx = 0, dup = 0, oob = 0, order_err = 0, flag_err = 0;
    long long next_raster = 0;
    unsigned rng = 12345;
    vluint64_t cycles = 0, last_progress = 0;
    const vluint64_t TIMEOUT = max_cycles;

    while (!done && cycles < TIMEOUT) {
        bool in_stall = stall && ((rng = rng * 1103515245u + 12345u) >> 16) % 100 < (unsigned)stall;
        dut->in_valid = (pos < data.size()) && !in_stall;
        dut->in_data  = (pos < data.size()) ? data[pos] : 0;
        dut->in_last  = !no_last && (pos + 1 == data.size());
        bool out_stall = stall && ((rng = rng * 1103515245u + 12345u) >> 16) % 100 < (unsigned)stall;
        dut->px_ready = !out_stall;
        dut->eval();
        bool in_fire = dut->in_valid && dut->in_ready;
        bool px_fire = dut->px_valid && dut->px_ready;
        int px_x = dut->px_x, px_y = dut->px_y, pn = dut->px_n;
        unsigned long long c0 = dut->px_c0, c1 = dut->px_c1, c2 = dut->px_c2;
        bool sof = dut->px_sof, eol = dut->px_eol;
        bool fs = dut->frame_start, fd = dut->frame_done;
        tick();
        cycles++;
        if (in_fire) pos++;
        if (fs) {
            W = dut->img_w; H = dut->img_h; have_dims = true;
            img.assign((size_t)W * H * 3, 0); seen.assign((size_t)W * H, 0);
            if (!quiet) fprintf(stderr, "frame_start: %dx%d at cycle %llu\n", W, H, (unsigned long long)cycles);
        }
        if (px_fire) {
            // a beat: px_n pixels from (px_x, px_y); fewer than NPIX only where the image row ends
            if (pn < 1 || pn > NPIX || (have_dims && pn < NPIX && px_x + pn != W)) {
                if (flag_err < 3) fprintf(stderr, "beat at (%d,%d): px_n=%d\n", px_x, px_y, pn);
                flag_err++;
            } else if (have_dims && (sof != (px_x == 0 && px_y == 0) || eol != (px_x + pn - 1 == W - 1))) {
                if (flag_err < 3) fprintf(stderr, "flags at (%d,%d): sof=%d eol=%d\n", px_x, px_y, sof, eol);
                flag_err++;
            }
            for (int i = 0; i < pn && i < NPIX; i++) {
                int x = px_x + i;
                if (!have_dims || x >= W || px_y >= H) { oob++; continue; }
                size_t idx = (size_t)px_y * W + x;
                if (seen[idx]) dup++;
                if (raster && (long long)idx != next_raster) { if (order_err < 3) fprintf(stderr, "order: got (%d,%d), expected pixel #%lld\n", x, px_y, next_raster); order_err++; }
                next_raster = (long long)idx + 1;
                seen[idx] = 1; img[idx*3] = (c0 >> (8*i)) & 0xFF; img[idx*3+1] = (c1 >> (8*i)) & 0xFF; img[idx*3+2] = (c2 >> (8*i)) & 0xFF; npx++;
                last_progress = cycles;
            }
        }
        if (fd) { done = true; if (!quiet) fprintf(stderr, "frame_done at cycle %llu\n", (unsigned long long)cycles); }
        if (have_dims && cycles - last_progress > 20000000ULL) { fprintf(stderr, "no progress for 20M cycles, giving up\n"); break; }
    }
    unsigned err = dut->err;
    fprintf(stderr, "cycles=%llu bytes_consumed=%zu/%zu pixels=%lld dup=%lld oob=%lld order_err=%lld flag_err=%lld err=0x%04x\n",
            (unsigned long long)cycles, pos, data.size(), npx, dup, oob, order_err, flag_err, err);
#if VM_TRACE
    if (tfp) { tfp->close(); delete tfp; }
#endif
    int rc = 0;
    if (!done) { fprintf(stderr, "FAIL: frame_done never seen\n"); rc = 1; }
    // frame_done may come only once the image has ended: after its EOI (the file's last FF D9), or after
    // its last byte when it has none (in_last: the frame ends with ERR_TRUNC)
    if (done && !no_last) {
        size_t need = data.size();
        for (size_t i = data.size(); i >= 2; i--) if (data[i - 2] == 0xFF && data[i - 1] == 0xD9) { need = i; break; }
        if (pos < need) { fprintf(stderr, "FAIL: frame_done after %zu bytes, before the image's end at %zu\n", pos, need); rc = 1; }
    }
    if (expect_mask >= 0) {
        if (done && ((long)err & expect_mask) == expect_mask && !(no_pixels && npx)) fprintf(stderr, "PASS: frame ended with err=0x%04x (expected bits 0x%04lx)\n", err, expect_mask);
        else { fprintf(stderr, "FAIL: expected frame_done with err bits 0x%04lx, got err=0x%04x done=%d pixels=%lld\n", expect_mask, err, (int)done, npx); rc = 1; }
        delete dut; return rc;
    }
    if (expect_err >= 0) {
        if ((long)err == expect_err && npx == 0 && done) fprintf(stderr, "PASS: expected err=0x%03lx, no pixels\n", expect_err);
        else { fprintf(stderr, "FAIL: expected err=0x%03lx and no pixels\n", expect_err); rc = 1; }
        delete dut; return rc;
    }
    if (dup || oob || order_err || flag_err) { fprintf(stderr, "FAIL: stream checks\n"); rc = 1; }
    if (have_dims) {
        long long missing = 0;
        for (size_t i = 0; i < seen.size(); i++) if (!seen[i]) missing++;
        if (missing) { fprintf(stderr, "FAIL: %lld pixels never produced\n", missing); rc = 1; }
        std::vector<unsigned char> golden;
        if (!golden_path.empty()) {
            std::ifstream gf(golden_path, std::ios::binary);
            if (!gf) { fprintf(stderr, "FAIL: cannot open golden file %s\n", golden_path.c_str()); rc = 1; }
            golden.assign((std::istreambuf_iterator<char>(gf)), std::istreambuf_iterator<char>());
        }
        bool one_ch;
        if (fmt == "y") one_ch = true;
        else if (fmt == "ycbcr" || as_ycbcr) one_ch = false;
        else {                                                  // rgb: P5 for grey images
            bool gray = true;
            for (size_t i = 0; i < (size_t)W * H && gray; i++) gray = img[i*3] == img[i*3+1] && img[i*3+1] == img[i*3+2];
            one_ch = gray && (golden.empty() ? true : (golden.size() > 1 && golden[1] == '5'));
        }
        std::string hdr = (one_ch ? "P5\n" : "P6\n") + std::to_string(W) + " " + std::to_string(H) + "\n255\n";
        std::vector<unsigned char> out(hdr.begin(), hdr.end());
        for (size_t i = 0; i < (size_t)W * H; i++) {
            if (one_ch) out.push_back(img[i*3]);
            else { out.push_back(img[i*3]); out.push_back(img[i*3+1]); out.push_back(img[i*3+2]); }
        }
        std::ofstream of(out_path, std::ios::binary); of.write((const char*)out.data(), out.size());
        if (!golden.empty()) {
            if (golden == out) fprintf(stderr, "PASS: output matches golden (%zu bytes)\n", out.size());
            else {
                rc = 1;
                size_t n = std::min(golden.size(), out.size()); size_t first = n; long long ndiff = 0; int maxd = 0;
                for (size_t i = 0; i < n; i++) if (golden[i] != out[i]) { if (first == n) first = i; ndiff++; int d = abs((int)golden[i] - (int)out[i]); if (d > maxd) maxd = d; }
                fprintf(stderr, "FAIL: output differs from golden: sizes %zu vs %zu, %lld differing bytes, max abs diff %d, first at byte %zu\n",
                        out.size(), golden.size(), ndiff, maxd, first);
                if (first < n) {
                    size_t hl = hdr.size(); size_t p = (first >= hl) ? first - hl : 0; int ch = one_ch ? 1 : 3;
                    fprintf(stderr, "  first diff pixel: x=%zu y=%zu ch=%zu (golden %d, got %d)\n", (p / ch) % W, (p / ch) / W, p % ch, golden[first], out[first]);
                }
            }
        }
    }
    if (err) { fprintf(stderr, "FAIL: decoder reported errors: 0x%03x\n", err); rc = 1; }   // none expected here
    delete dut;
    return rc;
}
