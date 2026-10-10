// tb_mem_lane.cpp - Verilator testbench of mem_lane (../mem_lane.sv) with an AXI4 memory model.
// Runs a list of jobs back to back on one lane, without a reset between them (as the F2 harness will).
// Each JPEG file is put in memory, its job runs, and the records the lane wrote are read back: every
// pixel is placed by its x and y, must be written at most once (exactly once for a clean file), and is
// compared with the golden image (P6, or P5 for a grey image; e.g. libjpeg 9e's djpeg -dct int
// -nosmooth -pnm); the lane's hash is recomputed from the records. The memory answers with random delays
// and random ready / valid gaps on every channel. While a job runs, the job inputs are changed and a
// start is pulsed (both must be ignored); when the lane says done, no read burst and no write response
// may be outstanding (the next job must not see the last one's data).
//   Vmem_lane [--stall PERCENT] [--seed N] [--latency CLOCKS] [--max-cycles N] JOBFILE
// JOBFILE: one job per line, "file golden expect pad [out_max]" (# starts a comment):
//   golden   reference image, or - for none
//   expect   ok           err 0, every pixel once, identical to golden (if given)
//            err:MASK     the frame ends with at least the bits MASK (hex); pixels allowed
//            errnp:MASK   the same, and no pixels
//            abort:N      abort the job N clocks after its start; it must end with res_abort
//   pad      bytes of zeros after the file, included in the job's length
//   out_max  bytes of room for records (default 128 MB); a smaller room must give res_ovf
// Prints one line per job, then "LANE JOBS passed/total"; exit status 0 if all pass.
#include "Vmem_lane.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <algorithm>
#include <deque>
#include <string>
#include <unordered_map>
#include <vector>

#ifndef DW
#define DW 512
#endif
static const int DW_WORDS = DW / 32;             // Verilator VlWide words of the data buses
static const int BYTES = DW / 8;

// ---- sparse byte memory, 4 KB pages
struct Mem {
    std::unordered_map<uint64_t, std::vector<uint8_t>> pages;
    uint8_t* at(uint64_t a) {
        auto& p = pages[a >> 12];
        if (p.empty()) p.assign(4096, 0);
        return &p[a & 4095];
    }
    uint8_t rd(uint64_t a) { return *at(a); }
    void wr(uint64_t a, uint8_t v) { *at(a) = v; }
    void drop(uint64_t a, uint64_t n) { for (uint64_t p = a >> 12; p <= (a + n - 1) >> 12; p++) pages.erase(p); }
};

// the lane's hash, as in mem_lane.sv
static uint64_t mix(uint64_t v) {
    uint64_t z = v + 0x9E3779B97F4A7C15ULL;
    z = (z ^ (z >> 30)) + (z << 7);
    z = (z ^ (z >> 27)) + (z << 13);
    return z ^ (z >> 31);
}

static bool slurp(const char* p, std::vector<uint8_t>& d) {
    FILE* f = fopen(p, "rb"); if (!f) return false;
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    d.resize(n); size_t r = fread(d.data(), 1, n, f); fclose(f); return r == (size_t)n;
}
// P6 / P5 reader: width, height, pixels as R,G,B (a grey P5 image as Y,Y,Y, like the decoder's RGB output)
static bool read_ppm(const char* p, int& w, int& h, std::vector<uint8_t>& px) {
    std::vector<uint8_t> d; if (!slurp(p, d)) return false;
    size_t i = 0; int f[3]; int nf = 0;
    if (d.size() < 2 || d[0] != 'P' || (d[1] != '6' && d[1] != '5')) return false;
    bool grey = (d[1] == '5');
    i = 2;
    while (nf < 3 && i < d.size()) {
        while (i < d.size() && (d[i] == ' ' || d[i] == '\n' || d[i] == '\r' || d[i] == '\t')) i++;
        if (i < d.size() && d[i] == '#') { while (i < d.size() && d[i] != '\n') i++; continue; }
        int v = 0; while (i < d.size() && d[i] >= '0' && d[i] <= '9') v = v * 10 + (d[i++] - '0');
        f[nf++] = v;
    }
    i++;                                          // the single whitespace after maxval
    w = f[0]; h = f[1];
    size_t n = (size_t)w * h;
    if (d.size() < i + n * (grey ? 1 : 3)) return false;
    if (grey) { px.resize(3 * n); for (size_t k = 0; k < n; k++) px[3 * k] = px[3 * k + 1] = px[3 * k + 2] = d[i + k]; }
    else px.assign(d.begin() + i, d.begin() + i + 3 * n);
    return true;
}

struct Job { std::string file, golden, expect; long pad = 0; uint64_t out_max = 0x08000000ULL; };

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    int stall = 0, latency = 40; unsigned seed = 1; uint64_t max_cycles = 400000000ULL; const char* jobfile = nullptr;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--stall") && i + 1 < argc) stall = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--seed") && i + 1 < argc) seed = (unsigned)atoi(argv[++i]);
        else if (!strcmp(argv[i], "--latency") && i + 1 < argc) latency = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--max-cycles") && i + 1 < argc) max_cycles = strtoull(argv[++i], nullptr, 10);
        else if (argv[i][0] != '-' && argv[i][0] != '+') jobfile = argv[i];
    }
    if (!jobfile) { fprintf(stderr, "usage: %s [--stall P] [--seed N] [--latency N] [--max-cycles N] JOBFILE\n", argv[0]); return 2; }
    std::vector<Job> jobs;
    {
        FILE* f = fopen(jobfile, "r"); if (!f) { fprintf(stderr, "cannot read %s\n", jobfile); return 2; }
        char line[4096];
        while (fgets(line, sizeof line, f)) {
            if (line[0] == '#' || line[0] == '\n') continue;
            char a[2048], g[2048], e[64]; long pad = 0; unsigned long long om = 0;
            int n = sscanf(line, "%2047s %2047s %63s %ld %llu", a, g, e, &pad, &om);
            if (n < 4) { fprintf(stderr, "bad job line: %s", line); return 2; }
            Job j; j.file = a; j.golden = g; j.expect = e; j.pad = pad; if (n == 5) j.out_max = om;
            jobs.push_back(j);
        }
        fclose(f);
    }
    unsigned rng = seed * 2654435761u + 12345u;
    auto rnd = [&]() { rng = rng * 1103515245u + 12345u; return (rng >> 16) & 0x7fff; };
    auto gap = [&]() { return stall && (int)(rnd() % 100) < stall; };

    Mem mem;
    Vmem_lane* d = new Vmem_lane;
    d->clk = 0; d->rst = 1; d->start = 0; d->job_abort = 0;
    d->arready = 0; d->rvalid = 0; d->awready = 0; d->wready = 0; d->bvalid = 0;
    auto tick = [&]() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); };
    for (int i = 0; i < 4; i++) tick();
    d->rst = 0; tick();

    // ---- AXI slave state (kept across jobs: a burst left over from a job would show up in the next)
    struct RB { uint64_t addr; int beats; int64_t ready_at; };
    std::deque<RB> rq;                            // accepted read bursts
    struct WB { uint64_t addr; int beats; };
    std::deque<WB> wq;                            // accepted write addresses
    std::deque<int64_t> bq;                       // B responses due at
    int r_beat = 0, w_beat = 0;
    int64_t cyc = 0;
    // one clock of the lane and the memory; false on a protocol error
    auto clock = [&](bool& proto_ok) {
        d->arready = !gap();
        d->awready = !gap();
        d->wready  = !gap();
        bool rv = !rq.empty() && cyc >= rq.front().ready_at && !gap();
        d->rvalid = rv;
        if (rv) {
            uint64_t a = rq.front().addr + (uint64_t)r_beat * BYTES;
            for (int w = 0; w < DW_WORDS; w++) {
                uint32_t v = 0;
                for (int b = 0; b < 4; b++) v |= (uint32_t)mem.rd(a + 4 * w + b) << (8 * b);
                d->rdata[w] = v;
            }
            d->rlast = (r_beat == rq.front().beats - 1);
            d->rresp = 0;
        } else d->rlast = 0;
        bool bv = !bq.empty() && cyc >= bq.front() && !gap();
        d->bvalid = bv; d->bresp = 0;
        d->clk = 0; d->eval();
        bool ar_fire = d->arvalid && d->arready;
        bool r_fire  = rv && d->rready;
        bool aw_fire = d->awvalid && d->awready;
        bool w_fire  = d->wvalid && d->wready;
        bool b_fire  = bv && d->bready;
        uint64_t araddr = d->araddr; int arlen = d->arlen;
        uint64_t awaddr = d->awaddr; int awlen = d->awlen;
        if (w_fire) {
            if (wq.empty()) { fprintf(stderr, "W before AW (allowed by AXI, not by this lane)\n"); proto_ok = false; }
            else {
                uint64_t a = wq.front().addr + (uint64_t)w_beat * BYTES;
                uint64_t st = (uint64_t)d->wstrb;
                for (int w = 0; w < DW_WORDS; w++)
                    for (int b = 0; b < 4; b++)
                        if ((st >> (4 * w + b)) & 1) mem.wr(a + 4 * w + b, (d->wdata[w] >> (8 * b)) & 0xFF);
                bool last_exp = (w_beat == wq.front().beats - 1);
                if (d->wlast != last_exp) { fprintf(stderr, "wlast wrong at beat %d of %d\n", w_beat, wq.front().beats); proto_ok = false; }
                if (++w_beat == wq.front().beats) { w_beat = 0; wq.pop_front(); bq.push_back(cyc + 2 + (int64_t)(rnd() % 8)); }
            }
        }
        d->clk = 1; d->eval();
        cyc++;
        if (ar_fire) {
            if (((araddr & 4095) + (uint64_t)(arlen + 1) * BYTES) > 4096) { fprintf(stderr, "read burst crosses 4 KB\n"); proto_ok = false; }
            if (araddr % BYTES) { fprintf(stderr, "unaligned read address\n"); proto_ok = false; }
            rq.push_back({araddr, arlen + 1, cyc + latency + (int64_t)(rnd() % (latency + 1))});
        }
        if (r_fire && ++r_beat == rq.front().beats) { r_beat = 0; rq.pop_front(); }
        if (aw_fire) {
            if (((awaddr & 4095) + (uint64_t)(awlen + 1) * BYTES) > 4096) { fprintf(stderr, "write burst crosses 4 KB\n"); proto_ok = false; }
            if (awaddr % BYTES) { fprintf(stderr, "unaligned write address\n"); proto_ok = false; }
            wq.push_back({awaddr, awlen + 1});
        }
        if (b_fire) bq.pop_front();
    };

    const uint64_t IN_BASE = 0x100000000ULL, OUT_BASE = 0x1000000000ULL;
    uint64_t in_next = IN_BASE;
    int passed = 0;
    for (size_t j = 0; j < jobs.size(); j++) {
        const Job& J = jobs[j];
        std::vector<uint8_t> jpg;
        if (!slurp(J.file.c_str(), jpg)) { fprintf(stderr, "cannot read %s\n", J.file.c_str()); return 2; }
        uint64_t len = jpg.size() + (uint64_t)J.pad;
        uint64_t in_addr = in_next, out_addr = OUT_BASE + (uint64_t)j * 0x10000000ULL;
        in_next = (in_next + len + 4096 + 4095) & ~4095ULL;          // a page between files
        for (size_t i = 0; i < jpg.size(); i++) mem.wr(in_addr + i, jpg[i]);
        for (long i = 0; i < J.pad; i++) mem.wr(in_addr + jpg.size() + i, 0);
        bool exp_ok = J.expect == "ok", exp_np = J.expect.rfind("errnp:", 0) == 0;
        bool exp_err = J.expect.rfind("err:", 0) == 0 || exp_np, exp_abort = J.expect.rfind("abort:", 0) == 0;
        if (!exp_ok && !exp_err && !exp_abort) { fprintf(stderr, "bad expectation %s\n", J.expect.c_str()); return 2; }
        long mask = exp_err ? strtol(J.expect.c_str() + J.expect.find(':') + 1, nullptr, 16) : 0;
        int64_t abort_at = exp_abort ? atoll(J.expect.c_str() + 6) : -1;

        // a few idle clocks between jobs, then the job
        bool ok = true;
        int idle = (int)(rnd() % 20);
        for (int i = 0; i < idle; i++) clock(ok);
        d->in_addr = in_addr; d->in_len = (uint32_t)len; d->out_addr = out_addr; d->out_max = (uint32_t)J.out_max;
        d->start = 1; clock(ok); d->start = 0;
        // the job inputs change while the job runs (sampled at the start), and a start comes while busy
        d->in_addr = 0x7700000000ULL; d->in_len = 12345; d->out_addr = 0x7800000000ULL; d->out_max = 64;
        int64_t t0 = cyc, poke = 50 + (int64_t)(rnd() % 500);
        bool aborted_by_tb = false;
        while (!d->done && (uint64_t)(cyc - t0) < max_cycles && ok) {
            d->start = (cyc - t0 == poke);
            d->job_abort = (abort_at >= 0 && cyc - t0 == abort_at);
            if (d->job_abort) aborted_by_tb = true;
            clock(ok);
            d->start = 0; d->job_abort = 0;
        }
        if (!d->done) { fprintf(stderr, "%s: no done after %lld clocks\n", J.file.c_str(), (long long)(cyc - t0)); ok = false; }
        // at done nothing may be outstanding on the memory side
        bool drained = rq.empty() && r_beat == 0 && wq.empty() && w_beat == 0 && bq.empty();

        // ---- read the records back: every pixel at most once, by its position
        int W = d->res_w, H = d->res_h;
        uint32_t nrec = d->res_records;
        uint64_t rec_room = J.out_max / 16;
        uint32_t nread = (uint32_t)std::min<uint64_t>(nrec, rec_room);   // records beyond out_max were dropped
        std::vector<uint8_t> img((size_t)W * H * 3, 0), seen((size_t)W * H, 0);
        long long dup = 0, oob = 0, npx = 0;
        uint64_t hash = 0;
        for (uint32_t r = 0; r < nread && !d->res_abort; r++) {
            uint64_t a = out_addr + (uint64_t)r * 16;
            int x = mem.rd(a) | (mem.rd(a + 1) << 8), y = mem.rd(a + 2) | (mem.rd(a + 3) << 8);
            for (int i = 0; i < 4 && x + i < W; i++) {
                if (y >= H) { oob++; continue; }
                size_t p = (size_t)y * W + x + i;
                if (seen[p]) dup++;
                seen[p] = 1; npx++;
                uint8_t R = mem.rd(a + 4 + 3 * i), G = mem.rd(a + 5 + 3 * i), B = mem.rd(a + 6 + 3 * i);
                img[3 * p] = R; img[3 * p + 1] = G; img[3 * p + 2] = B;
                hash += mix(((uint64_t)y << 48) | ((uint64_t)(x + i) << 32) | ((uint64_t)R << 16) | ((uint64_t)G << 8) | B);
            }
        }
        long long missing = 0; for (size_t p = 0; p < seen.size(); p++) if (!seen[p]) missing++;
        bool full = nrec <= rec_room;                // every record is in memory
        bool hash_ok = !full || d->res_abort || hash == (uint64_t)d->res_hash;
        long long diffs = -1;
        if (J.golden != "-" && full && !d->res_abort) {
            int gw, gh; std::vector<uint8_t> g;
            if (!read_ppm(J.golden.c_str(), gw, gh, g)) { fprintf(stderr, "cannot read golden %s\n", J.golden.c_str()); ok = false; }
            else if (gw != W || gh != H) { fprintf(stderr, "golden is %dx%d, the frame %dx%d\n", gw, gh, W, H); ok = false; }
            else { diffs = 0; for (size_t i = 0; i < g.size(); i++) if (g[i] != img[i]) diffs++; }
        }
        // the verdict
        bool ovf_exp = J.out_max < 0x08000000ULL;     // the room was made too small on purpose
        ok = ok && d->done && drained && !d->res_axi_err && !dup && !oob;
        if (exp_abort) ok = ok && d->res_abort && aborted_by_tb;
        else {
            ok = ok && !d->res_abort && hash_ok && (!full || (uint32_t)npx == d->res_pixels);
            if (ovf_exp) ok = ok && d->res_ovf && !full;
            else ok = ok && !d->res_ovf;
            if (exp_ok) ok = ok && d->res_err == 0 && (ovf_exp || (!missing && (J.golden == "-" || diffs == 0)));
            if (exp_err) ok = ok && (((long)d->res_err & mask) == mask) && !(exp_np && (d->res_pixels || nrec));
        }
        printf("%s%s: %dx%d len=%llu cycles=%u in_wait=%u out_wait=%u pixels=%u records=%u err=0x%04x ovf=%d axi_err=%d "
               "abort=%d dup=%lld missing=%lld oob=%lld drained=%d hash=%s%s expect=%s %s\n",
               J.file.c_str(), J.pad ? " (+pad)" : "", W, H, (unsigned long long)len, d->res_cycles, d->res_in_wait,
               d->res_out_wait, d->res_pixels, nrec, d->res_err, d->res_ovf, d->res_axi_err, d->res_abort, dup, missing,
               oob, drained, hash_ok ? "match" : "MISMATCH",
               diffs < 0 ? "" : (diffs == 0 ? " golden=identical" : " golden=DIFFERS"), J.expect.c_str(), ok ? "PASS" : "FAIL");
        fflush(stdout);
        if (ok) passed++;
        mem.drop(out_addr, std::max<uint64_t>(16, std::min<uint64_t>((uint64_t)nrec * 16, J.out_max)));
        mem.drop(in_addr, len);
        if (!d->done) break;                         // the lane is stuck: the following jobs cannot run
    }
    printf("LANE JOBS %d/%zu passed (DW=%d, stall %d%%, seed %u)\n", passed, jobs.size(), DW, stall, seed);
    delete d;
    return passed == (int)jobs.size() ? 0 : 1;
}
