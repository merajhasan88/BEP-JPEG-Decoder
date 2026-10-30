// test_checker.cpp - the assertions of jpeg_checker.sv must fire: each scenario drives the checker's inputs
// directly (no decoder) with one violation of one rule, and must end with that rule's $fatal; scenario
// "clean" follows every rule and must run to the end. run_checker_tests.py runs each in its own process.
//   Vchk SCENARIO
#include "Vjpeg_checker.h"
#include "verilated.h"
#include <cstdio>
#include <cstring>
#include <string>

static Vjpeg_checker* d;
static void tick() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); }
static void idle_inputs() {
    d->in_valid = 0; d->in_last = 0; d->in_ready = 1; d->in_data = 0; d->px_valid = 0; d->px_ready = 1;
    d->frame_start = 0; d->frame_done = 0;
}
static void byte(int v, bool last = false) {          // one accepted input byte
    d->in_valid = 1; d->in_ready = 1; d->in_data = v; d->in_last = last; tick();
    d->in_valid = 0; d->in_last = 0;
}
static void soi() { byte(0xFF); byte(0xD8); }
static void frame_start(int w, int h) { d->img_w = w; d->img_h = h; d->frame_start = 1; tick(); d->frame_start = 0; }
static void frame_done() { d->frame_done = 1; tick(); d->frame_done = 0; }
static void beat(int x, int y, int n, int w, bool take = true) {
    d->px_valid = 1; d->px_x = x; d->px_y = y; d->px_n = n; d->px_c0 = 0x10 + x; d->px_c1 = 0x20 + y; d->px_c2 = 0x30;
    d->px_sof = (x == 0 && y == 0); d->px_eol = (x + n == w); d->px_ready = take; tick();
    d->px_valid = 0; d->px_ready = 1;
}
// a tiny 2x1 image: SOI, a few header bytes, frame_start, two beats, EOI (with in_last), frame_done
static void clean_image() {
    soi();
    byte(0xFF); byte(0xFE); byte(0x00); byte(0x03); byte(0x41);     // COM, length 3, one byte
    frame_start(2, 1);
    beat(0, 0, 1, 2); beat(1, 0, 1, 2);
    byte(0xFF); byte(0xD9, true);                                 // EOI, the file's last byte
    frame_done();
    for (int i = 0; i < 8; i++) tick();
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 2) { fprintf(stderr, "usage: %s scenario\n", argv[0]); return 2; }
    std::string s = argv[1];
    d = new Vjpeg_checker;
    idle_inputs(); d->err = 0; d->img_w = 0; d->img_h = 0; d->out_fmt = 0;
    d->rst = 1; for (int i = 0; i < 3; i++) tick(); d->rst = 0; tick();
    if (s == "clean") {                                           // two images back to back, with stalls
        clean_image();
        soi(); frame_start(2, 1);
        d->px_valid = 1; d->px_x = 0; d->px_y = 0; d->px_n = 1; d->px_c0 = 7; d->px_sof = 1; d->px_eol = 0;
        d->px_ready = 0; tick(); tick();                          // the beat waits, unchanged
        d->px_ready = 1; tick(); d->px_valid = 0;
        beat(1, 0, 1, 2); byte(0xFF); byte(0xD9, true); frame_done();
        for (int i = 0; i < 8; i++) tick();
        printf("CLEAN END\n"); delete d; return 0;
    }
    else if (s == "a1_drop") {                                    // a waiting beat disappears
        soi(); frame_start(2, 1);
        d->px_valid = 1; d->px_x = 0; d->px_y = 0; d->px_n = 1; d->px_sof = 1; d->px_eol = 0; d->px_ready = 0; tick();
        d->px_valid = 0; tick();
    }
    else if (s == "a1_change") {                                  // a waiting beat changes its pixel
        soi(); frame_start(2, 1);
        d->px_valid = 1; d->px_x = 0; d->px_y = 0; d->px_n = 1; d->px_c0 = 5; d->px_sof = 1; d->px_eol = 0; d->px_ready = 0; tick();
        d->px_c0 = 6; tick();
    }
    else if (s == "a2_start_twice") { soi(); frame_start(2, 1); frame_start(2, 1); }
    else if (s == "a2_done_alone") { soi(); frame_done(); }
    else if (s == "a3_outside") { soi(); beat(0, 0, 1, 2); }                    // pixel before frame_start
    else if (s == "a3_beyond") { soi(); frame_start(2, 1); beat(0, 0, 1, 2); beat(2, 0, 1, 3); }   // x = W
    else if (s == "a3_eol") { soi(); frame_start(4, 1); d->px_valid = 1; d->px_x = 3; d->px_y = 0; d->px_n = 1;
                              d->px_sof = 0; d->px_eol = 0; tick(); }           // the row's last pixel without px_eol
    else if (s == "a4_soi_open") {                                // the next SOI while the frame is still open
        soi(); frame_start(2, 1); beat(0, 0, 1, 2); beat(1, 0, 1, 2);
        byte(0xFF); byte(0xD9, true);                             // the image's EOI, but no frame_done yet
        soi();
    }
    else if (s == "a4_err_changes") {                             // err changes after frame_done
        clean_image(); d->err = 0x0004; tick(); tick();
    }
    else if (s == "a4_err_kept") {                                // the next SOI does not clear err
        soi(); frame_start(2, 1); beat(0, 0, 1, 2); beat(1, 0, 1, 2); d->err = 0x0200; tick();
        byte(0xFF); byte(0xD9, true); frame_done();
        soi(); for (int i = 0; i < 8; i++) tick();
    }
    else if (s == "a5_no_done") {                                 // the file ends inside an image, no frame_done
        soi(); byte(0xFF); byte(0xDB, true);
        for (long i = 0; i < 1100000; i++) tick();
    }
    else { fprintf(stderr, "unknown scenario %s\n", s.c_str()); return 2; }
    printf("NO ASSERTION FIRED in %s\n", s.c_str());
    delete d;
    return 0;
}
