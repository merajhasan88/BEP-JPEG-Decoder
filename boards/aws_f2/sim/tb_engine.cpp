// tb_engine.cpp - Verilator testbench of the F2 job engine (../jpeg_f2_engine.sv): it plays the host.
// All JPEG files of a job list are put in memory first (on F2: the host's writes over PCIS), then the host
// gives the lanes their jobs through the AXI-Lite registers (on F2: OCL; every access waits --host-lat
// clocks first, a stand-in for a PCIe round trip), polls DONE, reads each job's results and its records
// (on F2: PCIS reads) and checks them as tb_mem_lane.cpp does. Each lane has its own AXI4 port into one
// memory (on F2: an HBM channel each), with random delays and gaps on every channel. Also checked: the
// tag of every result, the lanes' start counters, a start written while the lane is busy (ignored and
// counted), and that a lane has nothing outstanding on its port when it says done.
//   Vengine [--policy order|size] [--stall P] [--seed N] [--latency N] [--host-lat N] [--max-cycles N] JOBFILE
// JOBFILE: as tb_mem_lane.cpp ("file golden expect pad [out_max]"; abort:N = the host aborts the job N
// clocks after starting it). Policy: jobs in file order, or the largest file first.
// Prints one line per job, then the batch: the engine's clocks from the first start to the last done
// (its own clock counter, read by register), the lanes' busy clocks, and "ENGINE JOBS passed/total".
#include "Vjpeg_f2_engine.h"
#include "verilated.h"
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <deque>
#include <functional>
#include <numeric>
#include <string>
#include <unordered_map>
#include <vector>

#ifndef NL
#define NL 4
#endif
#ifndef DW
#define DW 512
#endif
static const int DW_WORDS = DW / 32;
static const int BYTES = DW / 8;

// ---- bit fields of Verilator port values (scalar types or VlWide)
template <std::size_t N> static uint64_t getb(const VlWide<N>& s, int lsb, int w) {
    uint64_t v = 0;
    for (int i = 0; i < w; i++) { int b = lsb + i; if ((s[b >> 5] >> (b & 31)) & 1u) v |= 1ULL << i; }
    return v;
}
template <typename T> static uint64_t getb(const T& s, int lsb, int w) {
    uint64_t v = (uint64_t)s >> lsb;
    return w >= 64 ? v : (v & ((1ULL << w) - 1));
}
template <std::size_t N> static void setb(VlWide<N>& s, int lsb, int w, uint64_t v) {
    for (int i = 0; i < w; i++) { int b = lsb + i; uint32_t m = 1u << (b & 31); if ((v >> i) & 1) s[b >> 5] |= m; else s[b >> 5] &= ~m; }
}
template <typename T> static void setb(T& s, int lsb, int w, uint64_t v) {
    uint64_t m = (w >= 64 ? ~0ULL : ((1ULL << w) - 1)) << lsb;
    s = (T)(((uint64_t)s & ~m) | ((v << lsb) & m));
}

struct Mem {
    std::unordered_map<uint64_t, std::vector<uint8_t>> pages;
    uint8_t* at(uint64_t a) { auto& p = pages[a >> 12]; if (p.empty()) p.assign(4096, 0); return &p[a & 4095]; }
    uint8_t rd(uint64_t a) { return *at(a); }
    void wr(uint64_t a, uint8_t v) { *at(a) = v; }
    void drop(uint64_t a, uint64_t n) { for (uint64_t p = a >> 12; p <= (a + n - 1) >> 12; p++) pages.erase(p); }
};
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
static bool read_ppm(const char* p, int& w, int& h, std::vector<uint8_t>& px) {
    std::vector<uint8_t> d; if (!slurp(p, d)) return false;
    size_t i = 2; int f[3]; int nf = 0;
    if (d.size() < 2 || d[0] != 'P' || (d[1] != '6' && d[1] != '5')) return false;
    bool grey = (d[1] == '5');
    while (nf < 3 && i < d.size()) {
        while (i < d.size() && (d[i] == ' ' || d[i] == '\n' || d[i] == '\r' || d[i] == '\t')) i++;
        if (i < d.size() && d[i] == '#') { while (i < d.size() && d[i] != '\n') i++; continue; }
        int v = 0; while (i < d.size() && d[i] >= '0' && d[i] <= '9') v = v * 10 + (d[i++] - '0');
        f[nf++] = v;
    }
    i++;
    w = f[0]; h = f[1];
    size_t n = (size_t)w * h;
    if (d.size() < i + n * (grey ? 1 : 3)) return false;
    if (grey) { px.resize(3 * n); for (size_t k = 0; k < n; k++) px[3 * k] = px[3 * k + 1] = px[3 * k + 2] = d[i + k]; }
    else px.assign(d.begin() + i, d.begin() + i + 3 * n);
    return true;
}

// register map (f2_regs.sv)
enum { R_ID = 0x000, R_VERSION = 0x004, R_LANES = 0x008, R_DW = 0x00C, R_CLOCK_LO = 0x010, R_CLOCK_HI = 0x014,
       R_DONE_LO = 0x018, R_DONE_HI = 0x01C, R_SCRATCH = 0x028 };
enum { L_IN_LO = 0x00, L_IN_HI = 0x04, L_LEN = 0x08, L_OUT_LO = 0x0C, L_OUT_HI = 0x10, L_OUT_MAX = 0x14, L_TAG = 0x18,
       L_CTRL = 0x1C, L_STATUS = 0x20, L_RUN_TAG = 0x24, L_CYCLES = 0x28, L_IN_WAIT = 0x2C, L_OUT_WAIT = 0x30,
       L_PIXELS = 0x34, L_RECORDS = 0x38, L_SIZE = 0x3C, L_HASH_LO = 0x40, L_HASH_HI = 0x44, L_T0_LO = 0x48,
       L_T0_HI = 0x4C, L_T1_LO = 0x50, L_T1_HI = 0x54 };
static uint32_t lane_reg(int l, int r) { return 0x100 + 0x80 * l + r; }

struct Job {
    std::string file, golden, expect; long pad = 0; uint64_t out_max = 0x08000000ULL;
    uint64_t len = 0, in_addr = 0, out_addr = 0; uint32_t tag = 0;
    int lane = -1; int64_t host_t0 = 0; bool abort_sent = false, done = false, ok = false;
    uint32_t status = 0, run_tag = 0, cycles = 0, in_wait = 0, out_wait = 0, pixels = 0, records = 0, w = 0, h = 0;
    uint64_t hash = 0, t_start = 0, t_done = 0;
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    int stall = 0, latency = 40, host_lat = 100; unsigned seed = 1; uint64_t max_cycles = 4000000000ULL;
    std::string policy = "order"; const char* jobfile = nullptr;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--stall") && i + 1 < argc) stall = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--seed") && i + 1 < argc) seed = (unsigned)atoi(argv[++i]);
        else if (!strcmp(argv[i], "--latency") && i + 1 < argc) latency = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--host-lat") && i + 1 < argc) host_lat = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--max-cycles") && i + 1 < argc) max_cycles = strtoull(argv[++i], nullptr, 10);
        else if (!strcmp(argv[i], "--policy") && i + 1 < argc) policy = argv[++i];
        else if (argv[i][0] != '-' && argv[i][0] != '+') jobfile = argv[i];
    }
    if (!jobfile || (policy != "order" && policy != "size")) {
        fprintf(stderr, "usage: %s [--policy order|size] [--stall P] [--seed N] [--latency N] [--host-lat N] [--max-cycles N] JOBFILE\n", argv[0]);
        return 2;
    }
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

    // ---- the host puts every file into memory first
    Mem mem;
    const uint64_t IN_BASE = 0x100000000ULL, OUT_BASE = 0x1000000000ULL;
    uint64_t in_next = IN_BASE;
    for (size_t j = 0; j < jobs.size(); j++) {
        std::vector<uint8_t> d;
        if (!slurp(jobs[j].file.c_str(), d)) { fprintf(stderr, "cannot read %s\n", jobs[j].file.c_str()); return 2; }
        Job& J = jobs[j];
        J.len = d.size() + (uint64_t)J.pad; J.in_addr = in_next; J.out_addr = OUT_BASE + (uint64_t)j * 0x10000000ULL;
        J.tag = 0x1000 + (uint32_t)j;
        for (size_t i = 0; i < d.size(); i++) mem.wr(J.in_addr + i, d[i]);
        for (long i = 0; i < J.pad; i++) mem.wr(J.in_addr + d.size() + i, 0);
        in_next = (in_next + J.len + 4096 + 4095) & ~4095ULL;
    }
    std::vector<int> order(jobs.size());
    std::iota(order.begin(), order.end(), 0);
    if (policy == "size") std::stable_sort(order.begin(), order.end(), [&](int a, int b) { return jobs[a].len > jobs[b].len; });

    Vjpeg_f2_engine* d = new Vjpeg_f2_engine;
    d->clk = 0; d->rst = 1;
    d->s_awvalid = 0; d->s_wvalid = 0; d->s_bready = 0; d->s_arvalid = 0; d->s_rready = 0; d->s_wstrb = 0xF;
    setb(d->m_arready, 0, NL, 0); setb(d->m_rvalid, 0, NL, 0); setb(d->m_awready, 0, NL, 0);
    setb(d->m_wready, 0, NL, 0); setb(d->m_bvalid, 0, NL, 0); setb(d->m_rlast, 0, NL, 0);
    setb(d->m_rresp, 0, 2 * NL, 0); setb(d->m_bresp, 0, 2 * NL, 0);

    // ---- memory side: one AXI4 slave per lane, all into the same memory
    struct RB { uint64_t addr; int beats; int64_t ready_at; };
    struct WB { uint64_t addr; int beats; };
    std::deque<RB> rq[NL]; std::deque<WB> wq[NL]; std::deque<int64_t> bq[NL];
    int r_beat[NL] = {0}, w_beat[NL] = {0};
    bool prev_done[NL] = {false};
    int64_t cyc = 0;
    bool proto_ok = true; long long undrained = 0;
    auto tick = [&](const std::function<void()>& sample) {
        uint64_t arr = 0, awr = 0, wrd = 0, rv = 0, rl = 0, bv = 0;
        for (int l = 0; l < NL; l++) {
            if (!gap()) arr |= 1ULL << l;
            if (!gap()) awr |= 1ULL << l;
            if (!gap()) wrd |= 1ULL << l;
            if (!rq[l].empty() && cyc >= rq[l].front().ready_at && !gap()) {
                rv |= 1ULL << l;
                uint64_t a = rq[l].front().addr + (uint64_t)r_beat[l] * BYTES;
                for (int w = 0; w < DW_WORDS; w++) {
                    uint32_t v = 0;
                    for (int b = 0; b < 4; b++) v |= (uint32_t)mem.rd(a + 4 * w + b) << (8 * b);
                    d->m_rdata[l * DW_WORDS + w] = v;
                }
                if (r_beat[l] == rq[l].front().beats - 1) rl |= 1ULL << l;
            }
            if (!bq[l].empty() && cyc >= bq[l].front() && !gap()) bv |= 1ULL << l;
        }
        setb(d->m_arready, 0, NL, arr); setb(d->m_awready, 0, NL, awr); setb(d->m_wready, 0, NL, wrd);
        setb(d->m_rvalid, 0, NL, rv); setb(d->m_rlast, 0, NL, rl); setb(d->m_bvalid, 0, NL, bv);
        d->clk = 0; d->eval();
        if (sample) sample();
        bool ar_f[NL], r_f[NL], aw_f[NL], b_f[NL]; uint64_t ara[NL], awa[NL]; int arl[NL], awl[NL];
        for (int l = 0; l < NL; l++) {
            ar_f[l] = getb(d->m_arvalid, l, 1) && ((arr >> l) & 1);
            r_f[l]  = ((rv >> l) & 1) && getb(d->m_rready, l, 1);
            aw_f[l] = getb(d->m_awvalid, l, 1) && ((awr >> l) & 1);
            b_f[l]  = ((bv >> l) & 1) && getb(d->m_bready, l, 1);
            ara[l] = getb(d->m_araddr, 64 * l, 64); arl[l] = (int)getb(d->m_arlen, 8 * l, 8);
            awa[l] = getb(d->m_awaddr, 64 * l, 64); awl[l] = (int)getb(d->m_awlen, 8 * l, 8);
            if (getb(d->m_wvalid, l, 1) && ((wrd >> l) & 1)) {
                if (wq[l].empty()) { fprintf(stderr, "lane %d: W before AW\n", l); proto_ok = false; continue; }
                uint64_t a = wq[l].front().addr + (uint64_t)w_beat[l] * BYTES;
                uint64_t st = getb(d->m_wstrb, BYTES * l, BYTES);
                for (int w = 0; w < DW_WORDS; w++)
                    for (int b = 0; b < 4; b++)
                        if ((st >> (4 * w + b)) & 1) mem.wr(a + 4 * w + b, (d->m_wdata[l * DW_WORDS + w] >> (8 * b)) & 0xFF);
                bool last_exp = (w_beat[l] == wq[l].front().beats - 1);
                if ((bool)getb(d->m_wlast, l, 1) != last_exp) { fprintf(stderr, "lane %d: wlast wrong\n", l); proto_ok = false; }
                if (++w_beat[l] == wq[l].front().beats) { w_beat[l] = 0; wq[l].pop_front(); bq[l].push_back(cyc + 2 + (int64_t)(rnd() % 8)); }
            }
        }
        d->clk = 1; d->eval();
        cyc++;
        for (int l = 0; l < NL; l++) {
            if (ar_f[l]) {
                if (((ara[l] & 4095) + (uint64_t)(arl[l] + 1) * BYTES) > 4096 || ara[l] % BYTES) { fprintf(stderr, "lane %d: bad read burst\n", l); proto_ok = false; }
                rq[l].push_back({ara[l], arl[l] + 1, cyc + latency + (int64_t)(rnd() % (latency + 1))});
            }
            if (r_f[l] && ++r_beat[l] == rq[l].front().beats) { r_beat[l] = 0; rq[l].pop_front(); }
            if (aw_f[l]) {
                if (((awa[l] & 4095) + (uint64_t)(awl[l] + 1) * BYTES) > 4096 || awa[l] % BYTES) { fprintf(stderr, "lane %d: bad write burst\n", l); proto_ok = false; }
                wq[l].push_back({awa[l], awl[l] + 1});
            }
            if (b_f[l]) bq[l].pop_front();
            bool dn = getb(d->lane_done, l, 1);
            if (dn && !prev_done[l] && !(rq[l].empty() && r_beat[l] == 0 && wq[l].empty() && w_beat[l] == 0 && bq[l].empty())) {
                fprintf(stderr, "lane %d: done with bursts outstanding\n", l); undrained++;
            }
            prev_done[l] = dn;
        }
    };
    auto idle = [&](int n) { for (int i = 0; i < n; i++) tick(nullptr); };
    long long lite_ops = 0; bool lite_ok = true;
    auto lite_write = [&](uint32_t a, uint32_t v) {
        idle(host_lat); lite_ops++;
        d->s_awaddr = a; d->s_wdata = v; d->s_awvalid = 1; d->s_wvalid = 1; d->s_bready = 1;
        for (int n = 0; n < 1000; n++) {
            bool f_aw = false, f_b = false;
            tick([&] { f_aw = d->s_awvalid && d->s_awready && d->s_wvalid && d->s_wready; f_b = d->s_bvalid && d->s_bready; });
            if (f_aw) { d->s_awvalid = 0; d->s_wvalid = 0; }
            if (f_b) { d->s_bready = 0; return; }
        }
        fprintf(stderr, "AXI-Lite write 0x%x: no response\n", a); lite_ok = false;
    };
    auto lite_read = [&](uint32_t a) -> uint32_t {
        idle(host_lat); lite_ops++;
        d->s_araddr = a; d->s_arvalid = 1; d->s_rready = 1;
        for (int n = 0; n < 1000; n++) {
            bool f_ar = false, f_r = false; uint32_t v = 0;
            tick([&] { f_ar = d->s_arvalid && d->s_arready; f_r = d->s_rvalid && d->s_rready; v = d->s_rdata; });
            if (f_ar) d->s_arvalid = 0;
            if (f_r) { d->s_rready = 0; return v; }
        }
        fprintf(stderr, "AXI-Lite read 0x%x: no response\n", a); lite_ok = false; return 0;
    };

    for (int i = 0; i < 4; i++) tick(nullptr);
    d->rst = 0; tick(nullptr);

    // ---- the host's first checks
    bool id_ok = lite_read(R_ID) == 0x4A504547 && lite_read(R_VERSION) == 1 && lite_read(R_LANES) == NL && lite_read(R_DW) == DW;
    lite_write(R_SCRATCH, 0xC0FFEE11); id_ok = id_ok && lite_read(R_SCRATCH) == 0xC0FFEE11;
    uint32_t c0 = lite_read(R_CLOCK_LO); uint32_t c0h = lite_read(R_CLOCK_HI); uint32_t c1 = lite_read(R_CLOCK_LO);
    id_ok = id_ok && c0h == 0 && c1 > c0;
    if (!id_ok) fprintf(stderr, "identification / scratch / clock registers wrong\n");

    // ---- the batch
    auto verify = [&](Job& J) {
        int W = (int)J.w, H = (int)J.h;
        bool aborted = (J.status >> 4) & 1, ovf = (J.status >> 2) & 1, axi_err = (J.status >> 3) & 1;
        uint32_t err = (J.status >> 16) & 0x1FFF;
        uint64_t rec_room = J.out_max / 16;
        uint32_t nread = (uint32_t)std::min<uint64_t>(J.records, rec_room);
        std::vector<uint8_t> img((size_t)W * H * 3, 0), seen((size_t)W * H, 0);
        long long dup = 0, oob = 0, npx = 0; uint64_t hash = 0;
        for (uint32_t r = 0; r < nread && !aborted; r++) {
            uint64_t a = J.out_addr + (uint64_t)r * 16;
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
        bool full = J.records <= rec_room;
        bool hash_ok = !full || aborted || hash == J.hash;
        long long diffs = -1;
        if (J.golden != "-" && full && !aborted) {
            int gw, gh; std::vector<uint8_t> g;
            if (read_ppm(J.golden.c_str(), gw, gh, g) && gw == W && gh == H) { diffs = 0; for (size_t i = 0; i < g.size(); i++) if (g[i] != img[i]) diffs++; }
            else diffs = 1LL << 40;
        }
        bool exp_ok = J.expect == "ok", exp_np = J.expect.rfind("errnp:", 0) == 0;
        bool exp_err = J.expect.rfind("err:", 0) == 0 || exp_np, exp_abort = J.expect.rfind("abort:", 0) == 0;
        long mask = exp_err ? strtol(J.expect.c_str() + J.expect.find(':') + 1, nullptr, 16) : 0;
        bool ovf_exp = J.out_max < 0x08000000ULL;
        bool ok = J.done && J.run_tag == J.tag && !axi_err && !dup && !oob && J.t_done >= J.t_start + J.cycles;
        if (exp_abort) ok = ok && aborted && J.abort_sent;
        else {
            ok = ok && !aborted && hash_ok && (!full || (uint32_t)npx == J.pixels) && (ovf_exp ? (ovf && !full) : !ovf);
            if (exp_ok) ok = ok && err == 0 && (ovf_exp || (!missing && (J.golden == "-" || diffs == 0)));
            if (exp_err) ok = ok && (((long)err & mask) == mask) && !(exp_np && (J.pixels || J.records));
        }
        J.ok = ok;
        printf("lane %d tag 0x%x %s%s: %ux%u cycles=%u clocks=%llu in_wait=%u out_wait=%u pixels=%u records=%u err=0x%04x "
               "ovf=%d abort=%d dup=%lld missing=%lld oob=%lld hash=%s%s expect=%s %s\n",
               J.lane, J.run_tag, J.file.c_str(), J.pad ? " (+pad)" : "", J.w, J.h, J.cycles,
               (unsigned long long)(J.t_done - J.t_start), J.in_wait, J.out_wait, J.pixels, J.records, err, ovf, aborted,
               dup, missing, oob, hash_ok ? "match" : "MISMATCH",
               diffs < 0 ? "" : (diffs == 0 ? " golden=identical" : " golden=DIFFERS"), J.expect.c_str(), ok ? "PASS" : "FAIL");
        fflush(stdout);
        mem.drop(J.out_addr, std::max<uint64_t>(16, std::min<uint64_t>((uint64_t)J.records * 16, J.out_max)));
    };
    auto collect = [&](int l, Job& J) {
        auto rr = [&](int r) { return lite_read(lane_reg(l, r)); };
        J.status = rr(L_STATUS); J.run_tag = rr(L_RUN_TAG); J.cycles = rr(L_CYCLES); J.in_wait = rr(L_IN_WAIT);
        J.out_wait = rr(L_OUT_WAIT); J.pixels = rr(L_PIXELS); J.records = rr(L_RECORDS);
        uint32_t sz = rr(L_SIZE); J.w = sz & 0xFFFF; J.h = sz >> 16;
        J.hash = rr(L_HASH_LO); J.hash |= (uint64_t)rr(L_HASH_HI) << 32;
        J.t_start = rr(L_T0_LO); J.t_start |= (uint64_t)rr(L_T0_HI) << 32;
        J.t_done = rr(L_T1_LO); J.t_done |= (uint64_t)rr(L_T1_HI) << 32;
        J.done = (J.status >> 1) & 1;
        verify(J);
    };
    size_t biggest = std::max_element(jobs.begin(), jobs.end(), [](const Job& a, const Job& b) { return a.len < b.len; }) - jobs.begin();
    bool busy_start_ok = false, busy_start_tried = false;
    int busy_lane = -1;
    std::vector<int> lane_job(NL, -1), lane_count(NL, 0);
    std::vector<int> sched;                       // the order in which jobs started
    size_t next = 0;
    bool stuck = false;
    while ((next < order.size() || std::any_of(lane_job.begin(), lane_job.end(), [](int j) { return j >= 0; })) && lite_ok && !stuck) {
        uint64_t dm = lite_read(R_DONE_LO);
        if (NL > 32) dm |= (uint64_t)lite_read(R_DONE_HI) << 32;
        bool progress = false;
        for (int l = 0; l < NL; l++)
            if (lane_job[l] >= 0 && ((dm >> l) & 1)) { collect(l, jobs[lane_job[l]]); lane_job[l] = -1; progress = true; }
        for (int l = 0; l < NL; l++) {
            if (lane_job[l] < 0) continue;
            Job& J = jobs[lane_job[l]];
            bool exp_abort = J.expect.rfind("abort:", 0) == 0;
            int64_t limit = exp_abort ? atoll(J.expect.c_str() + 6) : (int64_t)400000000;
            if (!J.abort_sent && cyc - J.host_t0 >= limit) {
                lite_write(lane_reg(l, L_CTRL), 2); J.abort_sent = true; progress = true;
                if (!exp_abort) fprintf(stderr, "lane %d: %s did not finish: aborted\n", l, J.file.c_str());
            }
        }
        for (int l = 0; l < NL && next < order.size(); l++) {
            if (lane_job[l] >= 0) continue;
            int j = order[next++];
            Job& J = jobs[j];
            auto wr = [&](int r, uint32_t v) { lite_write(lane_reg(l, r), v); };
            wr(L_IN_LO, (uint32_t)J.in_addr); wr(L_IN_HI, (uint32_t)(J.in_addr >> 32)); wr(L_LEN, (uint32_t)J.len);
            wr(L_OUT_LO, (uint32_t)J.out_addr); wr(L_OUT_HI, (uint32_t)(J.out_addr >> 32)); wr(L_OUT_MAX, (uint32_t)J.out_max);
            wr(L_TAG, J.tag); wr(L_CTRL, 1);
            J.lane = l; J.host_t0 = cyc; lane_job[l] = j; lane_count[l]++; sched.push_back(j); progress = true;
            if ((size_t)j == biggest && !busy_start_tried) {
                // a second start while the lane runs the biggest file: ignored, counted, the job unaffected
                busy_start_tried = true; busy_lane = l;
                uint32_t a = lite_read(lane_reg(l, L_CTRL));
                wr(L_TAG, 0xBAD); wr(L_CTRL, 1);
                uint32_t b = lite_read(lane_reg(l, L_CTRL));
                busy_start_ok = (b >> 16) == (a >> 16) + 1 && (b & 0xFFFF) == (a & 0xFFFF);
                if (!busy_start_ok) fprintf(stderr, "lane %d: start while busy: CTRL 0x%08x -> 0x%08x\n", l, a, b);
            }
        }
        if (!progress) idle(64);
        if ((uint64_t)cyc > max_cycles) { fprintf(stderr, "batch did not finish in %llu clocks\n", (unsigned long long)max_cycles); stuck = true; }
    }
    // ---- the lanes' counters: every job accepted once; the one start written while busy ignored
    bool counters_ok = true;
    for (int l = 0; l < NL; l++) {
        uint32_t c = lite_read(lane_reg(l, L_CTRL));
        uint32_t ign_exp = (l == busy_lane) ? 1 : 0;
        if ((c & 0xFFFF) != (uint32_t)lane_count[l] || (c >> 16) != ign_exp) {
            fprintf(stderr, "lane %d: CTRL counters 0x%08x, expected %d accepted, %u ignored\n", l, c, lane_count[l], ign_exp); counters_ok = false;
        }
    }
    int passed = 0; uint64_t t0 = ~0ULL, t1 = 0, busy_sum = 0, longest = 0;
    for (auto& J : jobs) {
        if (J.ok) passed++;
        if (J.done) { t0 = std::min(t0, J.t_start); t1 = std::max(t1, J.t_done); busy_sum += J.t_done - J.t_start; longest = std::max(longest, J.t_done - J.t_start); }
    }
    uint64_t wall = t1 > t0 ? t1 - t0 : 0;
    uint64_t bound = std::max<uint64_t>(longest, (busy_sum + NL - 1) / NL);
    printf("schedule (%s):", policy.c_str());
    for (size_t k = 0; k < sched.size() && k < 400; k++) printf(" %d", sched[k]);
    printf("\nbatch: %zu jobs on %d lanes, wall %llu clocks (engine clock, first start to last done), lane busy %llu, "
           "utilisation %.3f, lower bound %llu (wall / bound %.3f); AXI-Lite accesses %lld, host latency %d\n",
           jobs.size(), NL, (unsigned long long)wall, (unsigned long long)busy_sum,
           wall ? (double)busy_sum / ((double)NL * wall) : 0.0, (unsigned long long)bound, bound ? (double)wall / bound : 0.0,
           lite_ops, host_lat);
    bool all = passed == (int)jobs.size() && id_ok && counters_ok && proto_ok && lite_ok && !stuck && !undrained
               && busy_start_tried && busy_start_ok;
    printf("checks: id %d, counters %d, start-while-busy %d, protocol %d, drained %d\n", id_ok, counters_ok,
           busy_start_tried && busy_start_ok, proto_ok, undrained == 0);
    printf("ENGINE JOBS %d/%zu passed (NL=%d, DW=%d, policy %s, stall %d%%, seed %u)%s\n", passed, jobs.size(), NL, DW,
           policy.c_str(), stall, seed, all ? "" : " - CHECKS FAILED");
    delete d;
    return all ? 0 : 1;
}
