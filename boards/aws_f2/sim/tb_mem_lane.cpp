// tb_mem_lane.cpp - Verilator testbench of mem_lane (../mem_lane.sv) with an AXI4 memory model.
// The JPEG file is put in memory, one job runs it, and the records the lane wrote are read back:
// every pixel is placed by its x and y, must be written exactly once, and is compared with the golden
// image (P6, or P5 for a grey image; e.g. libjpeg 9e's djpeg -dct int -nosmooth -pnm); the lane's hash is recomputed from the
// pixels. The memory answers with random delays and random ready / valid gaps on every channel.
//   Vmem_lane file.jpg [--golden ref.ppm] [--stall PERCENT] [--seed N] [--latency CLOCKS] [--max-cycles N]
// Prints one line: cycles, waits, pixels, records, err, hash, then PASS or FAIL (exit status 0 / 1).
#include "Vmem_lane.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <deque>
#include <string>
#include <unordered_map>
#include <vector>

static const int DW_WORDS = 16;                  // 512-bit data = 16 x 32 bits (Verilator VlWide)
static const int BYTES = 64;

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

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 2) { fprintf(stderr, "usage: %s file.jpg [--golden ref.ppm] [--stall P] [--seed N] [--latency N] [--max-cycles N]\n", argv[0]); return 2; }
    const char* golden = nullptr; int stall = 0, latency = 40; unsigned seed = 1; uint64_t max_cycles = 400000000ULL;
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--golden") && i + 1 < argc) golden = argv[++i];
        else if (!strcmp(argv[i], "--stall") && i + 1 < argc) stall = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--seed") && i + 1 < argc) seed = (unsigned)atoi(argv[++i]);
        else if (!strcmp(argv[i], "--latency") && i + 1 < argc) latency = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--max-cycles") && i + 1 < argc) max_cycles = strtoull(argv[++i], nullptr, 10);
    }
    std::vector<uint8_t> jpg;
    if (!slurp(argv[1], jpg)) { fprintf(stderr, "cannot read %s\n", argv[1]); return 2; }
    unsigned rng = seed * 2654435761u + 12345u;
    auto rnd = [&]() { rng = rng * 1103515245u + 12345u; return (rng >> 16) & 0x7fff; };
    auto gap = [&]() { return stall && (int)(rnd() % 100) < stall; };

    const uint64_t IN = 0x10000000ULL, OUT = 0x40000000ULL, OUT_MAX = 0x10000000ULL;   // 256 MB of records
    Mem mem;
    for (size_t i = 0; i < jpg.size(); i++) mem.wr(IN + i, jpg[i]);

    Vmem_lane* d = new Vmem_lane;
    d->clk = 0; d->rst = 1; d->start = 0;
    d->in_addr = IN; d->in_len = (uint32_t)jpg.size(); d->out_addr = OUT; d->out_max = (uint32_t)OUT_MAX;
    d->arready = 0; d->rvalid = 0; d->awready = 0; d->wready = 0; d->bvalid = 0;
    auto tick = [&]() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); };
    for (int i = 0; i < 4; i++) tick();
    d->rst = 0; tick();
    d->start = 1; tick(); d->start = 0;

    // ---- AXI slave state
    struct RB { uint64_t addr; int beats; int64_t ready_at; };
    std::deque<RB> rq;                            // accepted read bursts
    struct WB { uint64_t addr; int beats; };
    std::deque<WB> wq;                            // accepted write addresses
    std::deque<int64_t> bq;                       // B responses due at
    int r_beat = 0, w_beat = 0;
    int64_t cyc = 0;
    bool ok = true;
    while (!d->done && (uint64_t)cyc < max_cycles) {
        // drive this clock's ready / valid from the model, then evaluate the lane's outputs
        d->arready = !gap();
        d->awready = !gap();
        d->wready  = !gap();
        // R: the head burst, after its latency, one beat per clock unless a gap
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
        // sample the handshakes of this clock
        bool ar_fire = d->arvalid && d->arready;
        bool r_fire  = rv && d->rready;
        bool aw_fire = d->awvalid && d->awready;
        bool w_fire  = d->wvalid && d->wready;
        bool b_fire  = bv && d->bready;
        uint64_t araddr = d->araddr; int arlen = d->arlen;
        uint64_t awaddr = d->awaddr; int awlen = d->awlen;
        if (w_fire) {
            if (wq.empty()) { fprintf(stderr, "W before AW (allowed, not modelled)\n"); ok = false; break; }
            uint64_t a = wq.front().addr + (uint64_t)w_beat * BYTES;
            uint64_t st = d->wstrb;
            for (int w = 0; w < DW_WORDS; w++)
                for (int b = 0; b < 4; b++)
                    if ((st >> (4 * w + b)) & 1) mem.wr(a + 4 * w + b, (d->wdata[w] >> (8 * b)) & 0xFF);
            bool last_exp = (w_beat == wq.front().beats - 1);
            if (d->wlast != last_exp) { fprintf(stderr, "wlast wrong at beat %d of %d\n", w_beat, wq.front().beats); ok = false; break; }
            if (++w_beat == wq.front().beats) { w_beat = 0; wq.pop_front(); bq.push_back(cyc + 2 + (int64_t)(rnd() % 8)); }
        }
        d->clk = 1; d->eval();
        cyc++;
        if (ar_fire) {
            if (((araddr & 4095) + (uint64_t)(arlen + 1) * BYTES) > 4096) { fprintf(stderr, "read burst crosses 4 KB\n"); ok = false; break; }
            rq.push_back({araddr, arlen + 1, cyc + latency + (int64_t)(rnd() % (latency + 1))});
        }
        if (r_fire && ++r_beat == rq.front().beats) { r_beat = 0; rq.pop_front(); }
        if (aw_fire) {
            if (((awaddr & 4095) + (uint64_t)(awlen + 1) * BYTES) > 4096) { fprintf(stderr, "write burst crosses 4 KB\n"); ok = false; break; }
            wq.push_back({awaddr, awlen + 1});
        }
        if (b_fire) bq.pop_front();
    }
    if (!d->done) { fprintf(stderr, "FAIL: no done after %lld clocks\n", (long long)cyc); ok = false; }

    // ---- read the records back: every pixel once, by its position
    int W = d->res_w, H = d->res_h;
    uint32_t nrec = d->res_records;
    std::vector<uint8_t> img((size_t)W * H * 3, 0), seen((size_t)W * H, 0);
    long long dup = 0, oob = 0, npx = 0;
    uint64_t hash = 0;
    for (uint32_t r = 0; r < nrec; r++) {
        uint64_t a = OUT + (uint64_t)r * 16;
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
    bool hash_ok = (hash == (uint64_t)d->res_hash);
    long long diffs = -1;
    if (golden) {
        int gw, gh; std::vector<uint8_t> g;
        if (!read_ppm(golden, gw, gh, g)) { fprintf(stderr, "cannot read golden %s\n", golden); ok = false; }
        else if (gw != W || gh != H) { fprintf(stderr, "golden is %dx%d, the frame %dx%d\n", gw, gh, W, H); ok = false; }
        else { diffs = 0; for (size_t i = 0; i < g.size(); i++) if (g[i] != img[i]) diffs++; }
    }
    printf("%s: %dx%d cycles=%u in_wait=%u out_wait=%u pixels=%u records=%u err=0x%04x ovf=%d axi_err=%d "
           "dup=%lld missing=%lld oob=%lld hash=%s%s",
           argv[1], W, H, d->res_cycles, d->res_in_wait, d->res_out_wait, d->res_pixels, nrec, d->res_err,
           d->res_ovf, d->res_axi_err, dup, missing, oob, hash_ok ? "match" : "MISMATCH",
           golden ? (diffs == 0 ? " golden=identical" : " golden=DIFFERS") : "");
    ok = ok && d->done && hash_ok && !dup && !missing && !oob && !d->res_ovf && !d->res_axi_err
         && (uint32_t)npx == d->res_pixels && (!golden || diffs == 0) && d->res_err == 0;
    printf(" %s\n", ok ? "PASS" : "FAIL");
    delete d;
    return ok ? 0 : 1;
}
