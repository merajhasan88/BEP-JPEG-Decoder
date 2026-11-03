// tb_cl.cpp - Verilator testbench of the whole F2 custom logic: ../cl_jpeg/design/cl_jpeg.sv, the real top level
// with the HDK's cl_ports.vh, simulated unchanged. It plays the instance (the host program) and AWS's shell on
// every port; the DDR4 is a model (ddr_step, called every clock by the sim-only sh_ddr of sh_ddr_sim.sv).
//   Shell side, as the F2 shell behaves (aws-fpga HDK v2.3.5, AWS_Shell_Interface_Specification.md):
//   - PCIS (BAR4): the host's writes come as write-combined pieces of any length and alignment (unaligned
//     AxADDR, partial byte strobes, 1-8 beats, never across 4 KB), up to 32 transactions in flight per
//     direction, shell IDs varying, W data sometimes before its AW, random gaps on every valid and ready;
//     every transaction must complete within 2,000 clocks of its AxVALID (8 us at 250 MHz: the shell's
//     timeout); B and R must return each transaction's own ID.
//   - OCL (BAR0): one access at a time, --host-lat clocks apart (a PCIe round trip), AW and W skewed at random.
//   - Before the DDR4 is ready (--ddr-ready clocks after reset) STATUS reads 0, a BAR4 write and read are
//     answered with SLVERR (reads: zeros) and counted in MEM_ERR, and the memory stays untouched.
//   DDR4 model: random ready gaps, read latency, answers reordered across IDs and read beats interleaved
//   between IDs (both allowed by AXI), checks of every burst (64-byte beats, INCR, aligned, inside 4 KB,
//   IDs of the multiplexer's masters only, wlast on the right beat).
//   The host's job flow is tb_engine.cpp's: every file written into DDR4 over PCIS first, jobs by register,
//   DONE polled, results read; each job's hash compared with the golden image's (the F2 host's own check)
//   and its records read back (the backing memory for all of them, PCIS for the first 2 KB) and placed by
//   x and y. --hash-only: the jobs get no output area (the throughput mode: records dropped, hash only).
//   Vcl [--policy order|size] [--preload] [--hash-only] [--stall P] [--ddr-stall P] [--ddr-lat N] [--ddr-ready N]
//       [--no-reorder] [--no-interleave] [--host-lat N] [--seed N] [--max-cycles N] JOBFILE
// JOBFILE: as tb_engine.cpp ("file golden expect pad [out_max]").
#include "Vcl_jpeg.h"
#include "Vcl_jpeg__Dpi.h"
#include "verilated.h"
#include <algorithm>
#include <array>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <deque>
#include <functional>
#include <map>
#include <numeric>
#include <string>
#include <unordered_map>
#include <vector>

#ifndef NL
#define NL 15
#endif
#ifndef COMMIT_EXP
#define COMMIT_EXP 0u
#endif
static const int NM = NL + 1;
static const int PCIS_TIMEOUT = 2000;           // 8 us at 250 MHz

struct Mem {
    std::unordered_map<uint64_t, std::vector<uint8_t>> pages;
    uint8_t* at(uint64_t a) { auto& p = pages[a >> 12]; if (p.empty()) p.assign(4096, 0); return &p[a & 4095]; }
    uint8_t rd(uint64_t a) { auto it = pages.find(a >> 12); return it == pages.end() ? 0 : it->second[a & 4095]; }
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

static unsigned rng = 1;
static int rnd() { rng = rng * 1103515245u + 12345u; return (rng >> 16) & 0x7fff; }
static int64_t cyc = 0;
static long long tb_errors = 0;
static void fail(const char* what) {
    if (tb_errors < 40) fprintf(stderr, "[%lld] %s\n", (long long)cyc, what);
    tb_errors++;
}

// ====================================================================== the DDR4 model (behind sh_ddr_sim.sv)
static Mem ddr;
static struct { int stall = 0, lat = 30, ready_at = 3000; bool reorder = true, interleave = true; } dc;
struct DdrModel {
    bool awready = 0, wready = 0, bvalid = 0, arready = 0, rvalid = 0, rlast = 0, stat_ack = 0, ready = 0;
    uint16_t bid = 0, rid = 0; uint8_t bresp = 0, rresp = 0; uint32_t rdata[16] = {0}; uint32_t stat_rdata = 0;
    int64_t t = 0;
    struct AWe { uint16_t id; uint64_t addr; int beats; };
    struct We { uint32_t d[16]; uint64_t strb; bool last; };
    struct Rb { uint64_t addr; int beats; int done; int64_t at; };
    std::deque<AWe> awq; std::deque<We> wq; int wbeat = 0;
    std::map<int, std::deque<int64_t>> bpend;
    std::map<int, std::deque<Rb>> rpend;
    int ar_total = 0, b_cur = -1, r_cur = -1;
    std::deque<int> stat_q;
    long long aw_n = 0, ar_n = 0, w_beats = 0, r_beats = 0, interleaved = 0, reordered = 0;
    bool gap() { return dc.stall && rnd() % 100 < dc.stall; }
    void reset() {
        awready = wready = bvalid = arready = rvalid = rlast = stat_ack = ready = 0; bid = rid = 0; bresp = rresp = 0;
        awq.clear(); wq.clear(); wbeat = 0; bpend.clear(); rpend.clear(); ar_total = 0; b_cur = r_cur = -1; stat_q.clear();
    }
    void check_burst(const char* ch, uint16_t id, uint64_t a, int beats, int size, int burst) {
        char m[200];
        if (size != 6 || burst != 1) { snprintf(m, sizeof m, "DDR %s: size %d burst %d", ch, size, burst); fail(m); }
        if (a & 63) { snprintf(m, sizeof m, "DDR %s: address 0x%llx not 64-byte aligned", ch, (unsigned long long)a); fail(m); }
        if ((a & 4095) + (uint64_t)beats * 64 > 4096) { snprintf(m, sizeof m, "DDR %s: 0x%llx + %d beats crosses 4 KB", ch, (unsigned long long)a, beats); fail(m); }
        if (id >= NM) { snprintf(m, sizeof m, "DDR %s: ID %u is no master's", ch, id); fail(m); }
        if (a >> 36) { snprintf(m, sizeof m, "DDR %s: address 0x%llx beyond 64 GiB", ch, (unsigned long long)a); fail(m); }
    }
    void step(bool rst, bool awvalid_i, uint16_t awid, uint64_t awaddr, int awlen, int awsize, int awburst,
              bool wvalid_i, const uint32_t* wdata, uint64_t wstrb, bool wlast_i, bool bready_i,
              bool arvalid_i, uint16_t arid, uint64_t araddr, int arlen, int arsize, int arburst, bool rready_i,
              bool stat_wr, bool stat_rd) {
        t++;
        if (rst) { reset(); return; }
        // ---- the handshakes of the clock that just ended
        if (awvalid_i && awready) { aw_n++; check_burst("AW", awid, awaddr, awlen + 1, awsize, awburst); awq.push_back({awid, awaddr, awlen + 1}); }
        if (wvalid_i && wready) { We w; memcpy(w.d, wdata, 64); w.strb = wstrb; w.last = wlast_i; wq.push_back(w); }
        if (bvalid && bready_i) { bpend[b_cur].pop_front(); b_cur = -1; bvalid = 0; }
        if (arvalid_i && arready) {
            ar_n++; check_burst("AR", arid, araddr, arlen + 1, arsize, arburst);
            rpend[arid].push_back({araddr, arlen + 1, 0, t + dc.lat + rnd() % (dc.lat + 1)}); ar_total++;
        }
        if (rvalid && rready_i) {
            Rb& b = rpend[r_cur].front(); b.done++; r_beats++;
            if (b.done == b.beats) { rpend[r_cur].pop_front(); ar_total--; }
            rvalid = 0;
        }
        // ---- the write engine: a beat per clock, once its address is in
        if (!awq.empty() && !wq.empty()) {
            AWe& a = awq.front(); We& w = wq.front();
            uint64_t base = a.addr + (uint64_t)wbeat * 64;
            for (int i = 0; i < 64; i++) if ((w.strb >> i) & 1) ddr.wr(base + i, (w.d[i >> 2] >> (8 * (i & 3))) & 0xFF);
            if (w.last != (wbeat == a.beats - 1)) fail("DDR W: wlast on the wrong beat");
            wq.pop_front(); w_beats++;
            if (++wbeat == a.beats) { bpend[a.id].push_back(t + 2 + rnd() % 6); awq.pop_front(); wbeat = 0; }
        }
        // ---- the next clock's outputs
        awready = !gap() && awq.size() < 8;
        wready = !gap() && wq.size() < 32;
        arready = !gap() && ar_total < 32;
        if (!bvalid) {
            std::vector<int> c;
            for (auto& kv : bpend) if (!kv.second.empty() && kv.second.front() <= t) c.push_back(kv.first);
            if (!c.empty() && !gap()) {
                int pick = c[0];
                if (dc.reorder) { pick = c[rnd() % c.size()]; if (pick != c[0]) reordered++; }
                else for (int id : c) if (bpend[id].front() < bpend[pick].front()) pick = id;
                b_cur = pick; bvalid = 1; bid = (uint16_t)pick; bresp = 0;
            }
        }
        if (!rvalid) {
            std::vector<int> c;
            for (auto& kv : rpend) if (!kv.second.empty() && kv.second.front().at <= t) c.push_back(kv.first);
            if (!c.empty() && !gap()) {
                int pick = -1;
                bool mid = r_cur >= 0 && !rpend[r_cur].empty() && rpend[r_cur].front().done > 0;
                if (mid && !(dc.interleave && rnd() % 4 == 0)) pick = r_cur;
                else if (dc.reorder) pick = c[rnd() % c.size()];
                else { pick = c[0]; for (int id : c) if (rpend[id].front().at < rpend[pick].front().at) pick = id; }
                if (mid && pick != r_cur) interleaved++;
                Rb& b = rpend[pick].front();
                uint64_t a = b.addr + (uint64_t)b.done * 64;
                for (int w = 0; w < 16; w++) {
                    uint32_t v = 0;
                    for (int k = 0; k < 4; k++) v |= (uint32_t)ddr.rd(a + 4 * w + k) << (8 * k);
                    rdata[w] = v;
                }
                r_cur = pick; rvalid = 1; rid = (uint16_t)pick; rresp = 0; rlast = (b.done == b.beats - 1);
            }
        }
        // the statistics bus: every strobe is acknowledged a few clocks later
        stat_ack = 0;
        for (auto& s : stat_q) s--;
        if (!stat_q.empty() && stat_q.front() <= 0) { stat_q.pop_front(); stat_ack = 1; stat_rdata = 0x5A5A0000u | (uint32_t)(t & 0xFFFF); }
        if (stat_wr || stat_rd) stat_q.push_back(3);
        ready = (t >= dc.ready_at);
    }
} dm;

static uint32_t vec32(const svBitVecVal* v) { return v[0]; }
extern "C" void ddr_step(svBit rst, svBit awvalid, const svBitVecVal* awid, unsigned long long awaddr, const svBitVecVal* awlen,
                         const svBitVecVal* awsize, const svBitVecVal* awburst, svBit wvalid, const svBitVecVal* wdata,
                         const svBitVecVal* wstrb, svBit wlast, svBit bready, svBit arvalid, const svBitVecVal* arid,
                         unsigned long long araddr, const svBitVecVal* arlen, const svBitVecVal* arsize, const svBitVecVal* arburst,
                         svBit rready, svBit stat_wr, svBit stat_rd, const svBitVecVal* stat_addr,
                         svBit* o_awready, svBit* o_wready, svBit* o_bvalid, svBitVecVal* o_bid, svBitVecVal* o_bresp,
                         svBit* o_arready, svBit* o_rvalid, svBitVecVal* o_rid, svBitVecVal* o_rdata, svBitVecVal* o_rresp,
                         svBit* o_rlast, svBit* o_stat_ack, svBitVecVal* o_stat_rdata, svBit* o_ready) {
    (void)stat_addr;
    uint64_t strb = (uint64_t)wstrb[0] | ((uint64_t)wstrb[1] << 32);
    dm.step(rst, awvalid, (uint16_t)vec32(awid), awaddr, vec32(awlen) & 0xFF, vec32(awsize) & 7, vec32(awburst) & 3,
            wvalid, wdata, strb, wlast, bready, arvalid, (uint16_t)vec32(arid), araddr, vec32(arlen) & 0xFF,
            vec32(arsize) & 7, vec32(arburst) & 3, rready, stat_wr, stat_rd);
    *o_awready = dm.awready; *o_wready = dm.wready; *o_bvalid = dm.bvalid; o_bid[0] = dm.bid; o_bresp[0] = dm.bresp;
    *o_arready = dm.arready; *o_rvalid = dm.rvalid; o_rid[0] = dm.rid; for (int i = 0; i < 16; i++) o_rdata[i] = dm.rdata[i];
    o_rresp[0] = dm.rresp; *o_rlast = dm.rlast; *o_stat_ack = dm.stat_ack; o_stat_rdata[0] = dm.stat_rdata; *o_ready = dm.ready;
}

// ====================================================================== registers (f2_regs.sv)
enum { R_ID = 0x000, R_VERSION = 0x004, R_LANES = 0x008, R_DW = 0x00C, R_CLOCK_LO = 0x010, R_CLOCK_HI = 0x014,
       R_DONE_LO = 0x018, R_DONE_HI = 0x01C, R_BUSY_LO = 0x020, R_SCRATCH = 0x028, R_STATUS = 0x02C, R_COMMIT = 0x030,
       R_MEM_ERR = 0x034 };
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

// ====================================================================== PCIS transactions of the host
struct PTx {
    bool write = false, expect_err = false; uint16_t id = 0x20; uint64_t addr = 0; int beats = 0;
    std::vector<std::array<uint32_t, 16>> data; std::vector<uint64_t> strb;     // writes
    std::vector<std::array<uint32_t, 16>> got; int rgot = 0;                    // reads
    int wsent = 0; int64_t t0 = -1, t1 = -1; bool done = false; uint8_t resp = 0;
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    int stall = 0, host_lat = 100; unsigned seed = 1; uint64_t max_cycles = 4000000000ULL;
    std::string policy = "order"; const char* jobfile = nullptr; bool preload = false, hash_only = false;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--stall") && i + 1 < argc) stall = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--ddr-stall") && i + 1 < argc) dc.stall = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--ddr-lat") && i + 1 < argc) dc.lat = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--ddr-ready") && i + 1 < argc) dc.ready_at = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--no-reorder")) dc.reorder = false;
        else if (!strcmp(argv[i], "--no-interleave")) dc.interleave = false;
        else if (!strcmp(argv[i], "--seed") && i + 1 < argc) seed = (unsigned)atoi(argv[++i]);
        else if (!strcmp(argv[i], "--host-lat") && i + 1 < argc) host_lat = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--max-cycles") && i + 1 < argc) max_cycles = strtoull(argv[++i], nullptr, 10);
        else if (!strcmp(argv[i], "--policy") && i + 1 < argc) policy = argv[++i];
        else if (!strcmp(argv[i], "--preload")) preload = true;
        else if (!strcmp(argv[i], "--hash-only")) hash_only = true;
        else if (argv[i][0] != '-' && argv[i][0] != '+') jobfile = argv[i];
    }
    if (!jobfile || (policy != "order" && policy != "size")) {
        fprintf(stderr, "usage: %s [--policy order|size] [--preload] [--hash-only] [--stall P] [--ddr-stall P] [--ddr-lat N] "
                        "[--ddr-ready N] [--no-reorder] [--no-interleave] [--host-lat N] [--seed N] [--max-cycles N] JOBFILE\n", argv[0]);
        return 2;
    }
    rng = seed * 2654435761u + 12345u;
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
            else if (hash_only) j.out_max = 0;
            jobs.push_back(j);
        }
        fclose(f);
    }
    auto gap = [&]() { return stall && rnd() % 100 < stall; };

    Vcl_jpeg* d = new Vcl_jpeg;
    // ---- the shell's constant inputs
    d->clk_main_a0 = 0; d->rst_main_n = 0; d->clk_hbm_ref = 0; d->sh_cl_flr_assert = 0;
    d->sh_cl_ctl0 = 0; d->sh_cl_ctl1 = 0; d->sh_cl_ctl2 = 0; d->sh_cl_status_vdip = 0; d->sh_cl_pwr_state = 0;
    d->sh_cl_pcim_awready = 0; d->sh_cl_pcim_wready = 0; d->sh_cl_pcim_bvalid = 0; d->sh_cl_pcim_arready = 0;
    d->sh_cl_pcim_rvalid = 0; d->cfg_max_payload = 1; d->cfg_max_read_req = 2;
    d->sh_cl_ddr_stat_addr = 0; d->sh_cl_ddr_stat_wdata = 0; d->sh_cl_ddr_stat_wr = 0; d->sh_cl_ddr_stat_rd = 0;
    d->sh_cl_ddr_stat_user = 0; d->sh_cl_apppf_irq_ack = 0;
    d->sh_cl_dma_pcis_awvalid = 0; d->sh_cl_dma_pcis_wvalid = 0; d->sh_cl_dma_pcis_bready = 0;
    d->sh_cl_dma_pcis_arvalid = 0; d->sh_cl_dma_pcis_rready = 0;
    d->sh_cl_dma_pcis_awsize = 6; d->sh_cl_dma_pcis_awburst = 1; d->sh_cl_dma_pcis_arsize = 6; d->sh_cl_dma_pcis_arburst = 1;
    d->ocl_cl_awvalid = 0; d->ocl_cl_wvalid = 0; d->ocl_cl_bready = 0; d->ocl_cl_arvalid = 0; d->ocl_cl_rready = 0;
    d->ocl_cl_wstrb = 0xF; d->ocl_cl_awuser = 0; d->ocl_cl_aruser = 0;
    d->sda_cl_awvalid = 0; d->sda_cl_wvalid = 0; d->sda_cl_bready = 0; d->sda_cl_arvalid = 0; d->sda_cl_rready = 0;
    d->hbm_apb_preset_n_1 = 1; d->hbm_apb_preset_n_0 = 1; d->PCIE_EP_PERSTN = 1;

    // ---- PCIS: the host's transactions, in flight
    std::deque<PTx*> q_aw, q_w, q_b, q_ar, q_r;       // AW to issue; W beats to send; B awaited; AR to issue; R awaited
    int wr_out = 0, rd_out = 0;                        // issued (AxVALID shown) and not complete
    bool aw_on = false, w_on = false, ar_on = false;   // a valid is up and must stay until its ready
    int64_t pcis_max_lat = 0; long long pcis_txn = 0, pcis_beats_w = 0, pcis_beats_r = 0;
    bool flr_seen_done = false;
    std::function<void()> no_sample;
    auto tick = [&](const std::function<void()>& sample) {
        // the shell's PCIS outputs for this clock
        if (!aw_on && !q_aw.empty() && wr_out < 32 && !gap()) {
            PTx* x = q_aw.front(); aw_on = true; if (x->t0 < 0) x->t0 = cyc; wr_out++;
            d->sh_cl_dma_pcis_awid = x->id; d->sh_cl_dma_pcis_awaddr = x->addr; d->sh_cl_dma_pcis_awlen = (uint8_t)(x->beats - 1);
        }
        d->sh_cl_dma_pcis_awvalid = aw_on;
        if (!w_on && !q_w.empty() && !gap()) {
            PTx* x = q_w.front(); w_on = true;
            for (int i = 0; i < 16; i++) d->sh_cl_dma_pcis_wdata[i] = x->data[x->wsent][i];
            d->sh_cl_dma_pcis_wstrb = x->strb[x->wsent]; d->sh_cl_dma_pcis_wlast = (x->wsent == x->beats - 1);
            d->sh_cl_dma_pcis_wid = x->id;
        }
        d->sh_cl_dma_pcis_wvalid = w_on;
        if (!ar_on && !q_ar.empty() && rd_out < 32 && !gap()) {
            PTx* x = q_ar.front(); ar_on = true; if (x->t0 < 0) x->t0 = cyc; rd_out++;
            d->sh_cl_dma_pcis_arid = x->id; d->sh_cl_dma_pcis_araddr = x->addr; d->sh_cl_dma_pcis_arlen = (uint8_t)(x->beats - 1);
        }
        d->sh_cl_dma_pcis_arvalid = ar_on;
        d->sh_cl_dma_pcis_bready = !gap();
        d->sh_cl_dma_pcis_rready = !gap();
        d->sh_cl_glcount0 = (uint64_t)cyc; d->sh_cl_glcount1 = (uint64_t)cyc;
        d->clk_main_a0 = 0; d->eval();
        if (sample) sample();
        bool f_aw = aw_on && d->cl_sh_dma_pcis_awready, f_w = w_on && d->cl_sh_dma_pcis_wready;
        bool f_ar = ar_on && d->cl_sh_dma_pcis_arready;
        bool f_b = d->cl_sh_dma_pcis_bvalid && d->sh_cl_dma_pcis_bready, f_r = d->cl_sh_dma_pcis_rvalid && d->sh_cl_dma_pcis_rready;
        uint16_t bid = d->cl_sh_dma_pcis_bid, rid = d->cl_sh_dma_pcis_rid; uint8_t bresp = d->cl_sh_dma_pcis_bresp;
        uint8_t rresp = d->cl_sh_dma_pcis_rresp; bool rlast = d->cl_sh_dma_pcis_rlast;
        std::array<uint32_t, 16> rd; for (int i = 0; i < 16; i++) rd[i] = d->cl_sh_dma_pcis_rdata[i];
        if (d->cl_sh_flr_done) flr_seen_done = true;
        d->clk_main_a0 = 1; d->eval();
        cyc++;
        char m[240];
        if (f_aw) { q_aw.pop_front(); aw_on = false; }
        if (f_w) {
            PTx* x = q_w.front(); w_on = false; pcis_beats_w++;
            if (++x->wsent == x->beats) q_w.pop_front();
        }
        if (f_ar) { PTx* x = q_ar.front(); q_ar.pop_front(); ar_on = false; q_r.push_back(x); }
        if (f_b) {
            if (q_b.empty()) fail("PCIS: a B without a write");
            else {
                PTx* x = q_b.front(); q_b.pop_front(); wr_out--; pcis_txn++;
                x->t1 = cyc; x->done = true; x->resp = bresp; pcis_max_lat = std::max<int64_t>(pcis_max_lat, x->t1 - x->t0);
                if (bid != x->id) { snprintf(m, sizeof m, "PCIS: B ID 0x%x, expected 0x%x", bid, x->id); fail(m); }
                if (bresp != (x->expect_err ? 2 : 0)) { snprintf(m, sizeof m, "PCIS: BRESP %d at 0x%llx", bresp, (unsigned long long)x->addr); fail(m); }
                if (x->t1 - x->t0 > PCIS_TIMEOUT) { snprintf(m, sizeof m, "PCIS: write took %lld clocks (> 8 us)", (long long)(x->t1 - x->t0)); fail(m); }
            }
        }
        if (f_r) {
            if (q_r.empty()) fail("PCIS: an R without a read");
            else {
                PTx* x = q_r.front(); pcis_beats_r++;
                if (rid != x->id) { snprintf(m, sizeof m, "PCIS: R ID 0x%x, expected 0x%x", rid, x->id); fail(m); }
                if (rresp != (x->expect_err ? 2 : 0)) { snprintf(m, sizeof m, "PCIS: RRESP %d at 0x%llx", rresp, (unsigned long long)x->addr); fail(m); }
                if (rlast != (x->rgot == x->beats - 1)) fail("PCIS: rlast on the wrong beat");
                x->got.push_back(rd);
                if (++x->rgot == x->beats) {
                    q_r.pop_front(); rd_out--; pcis_txn++; x->t1 = cyc; x->done = true;
                    pcis_max_lat = std::max<int64_t>(pcis_max_lat, x->t1 - x->t0);
                    if (x->t1 - x->t0 > PCIS_TIMEOUT) { snprintf(m, sizeof m, "PCIS: read took %lld clocks (> 8 us)", (long long)(x->t1 - x->t0)); fail(m); }
                }
            }
        }
    };
    auto idle = [&](int n) { for (int i = 0; i < n; i++) tick(no_sample); };
    auto pcis_ids = [&]() -> uint16_t { static const uint16_t ids[] = {0x20, 0x20, 0x20, 0x00, 0x01, 0x21, 0x3F}; return ids[rnd() % 7]; };
    // a write of len bytes at any address: write-combined pieces of 1-512 bytes, never across 4 KB
    std::vector<PTx*> all_tx;
    auto pcis_write = [&](uint64_t addr, const uint8_t* src, uint64_t len, bool expect_err = false) {
        uint64_t o = 0;
        while (o < len) {
            uint64_t a = addr + o;
            uint64_t n = std::min<uint64_t>(len - o, 1 + rnd() % 512);
            n = std::min<uint64_t>(n, 4096 - (a & 4095));
            PTx* x = new PTx; x->write = true; x->expect_err = expect_err; x->id = pcis_ids(); x->addr = a;
            x->beats = (int)(((a & 63) + n + 63) / 64);
            x->data.assign(x->beats, {}); x->strb.assign(x->beats, 0);
            for (auto& b : x->data) b.fill(0);
            for (uint64_t k = 0; k < n; k++) {
                uint64_t off = (a & 63) + k; int bt = (int)(off / 64), by = (int)(off % 64);
                x->data[bt][by >> 2] |= (uint32_t)src[o + k] << (8 * (by & 3));
                x->strb[bt] |= 1ULL << by;
            }
            q_aw.push_back(x); q_w.push_back(x); q_b.push_back(x); all_tx.push_back(x);
            o += n;
        }
    };
    auto pcis_drain = [&](int64_t limit) {
        int64_t t0 = cyc;
        while ((!q_aw.empty() || !q_w.empty() || !q_b.empty() || !q_ar.empty() || !q_r.empty()) && cyc - t0 < limit) tick(no_sample);
        if (!q_aw.empty() || !q_w.empty() || !q_b.empty() || !q_ar.empty() || !q_r.empty()) fail("PCIS: transactions never completed");
        for (auto* x : all_tx) delete x;
        all_tx.clear();
    };
    // a read of len bytes at any address (pieces of 1-512 bytes); the bytes come back in out
    auto pcis_read = [&](uint64_t addr, uint64_t len, std::vector<uint8_t>& out, bool expect_err = false) {
        std::vector<std::pair<PTx*, uint64_t>> parts;       // transaction, its first byte's offset in out
        uint64_t o = 0;
        while (o < len) {
            uint64_t a = addr + o;
            uint64_t n = std::min<uint64_t>(len - o, 1 + rnd() % 512);
            n = std::min<uint64_t>(n, 4096 - (a & 4095));
            PTx* x = new PTx; x->expect_err = expect_err; x->id = pcis_ids(); x->addr = a; x->beats = (int)(((a & 63) + n + 63) / 64);
            q_ar.push_back(x); all_tx.push_back(x); parts.push_back({x, o});
            o += n;
        }
        int64_t t0 = cyc;
        while (std::any_of(parts.begin(), parts.end(), [](auto& p) { return !p.first->done; }) && cyc - t0 < 2000000) tick(no_sample);
        out.assign(len, 0);
        for (size_t k = 0; k < parts.size(); k++) {
            PTx* x = parts[k].first; uint64_t start = parts[k].second;
            uint64_t end = (k + 1 < parts.size()) ? parts[k + 1].second : len;
            for (uint64_t i = start; i < end; i++) {
                uint64_t off = (x->addr & 63) + (i - start); int bt = (int)(off / 64), by = (int)(off % 64);
                if (bt < (int)x->got.size()) out[i] = (x->got[bt][by >> 2] >> (8 * (by & 3))) & 0xFF;
            }
        }
        pcis_drain(10000);
    };

    // ---- OCL: one access at a time, AW and W skewed at random
    long long lite_ops = 0;
    auto lite_write = [&](uint32_t a, uint32_t v) {
        idle(host_lat); lite_ops++;
        int skew = rnd() % 3;                         // 0: together, 1: AW first, 2: W first
        d->ocl_cl_awaddr = a; d->ocl_cl_wdata = v; d->ocl_cl_bready = 1;
        d->ocl_cl_awvalid = (skew != 2); d->ocl_cl_wvalid = (skew != 1);
        bool aw_done = false, w_done = false;
        for (int n = 0; n < PCIS_TIMEOUT; n++) {
            bool f_aw = false, f_w = false, f_b = false; uint8_t br = 0;
            tick([&] { f_aw = d->ocl_cl_awvalid && d->cl_ocl_awready; f_w = d->ocl_cl_wvalid && d->cl_ocl_wready;
                       f_b = d->cl_ocl_bvalid && d->ocl_cl_bready; br = d->cl_ocl_bresp; });
            if (f_aw) { d->ocl_cl_awvalid = 0; aw_done = true; }
            if (f_w) { d->ocl_cl_wvalid = 0; w_done = true; }
            if (n == 3) { if (!aw_done && !f_aw) d->ocl_cl_awvalid = 1; if (!w_done && !f_w) d->ocl_cl_wvalid = 1; }
            if (f_b) { d->ocl_cl_bready = 0; if (br) fail("OCL: BRESP not OKAY"); if (!aw_done || !w_done) fail("OCL: B before AW and W"); return; }
        }
        char m[100]; snprintf(m, sizeof m, "OCL write 0x%x: no response in 8 us", a); fail(m);
    };
    auto lite_read = [&](uint32_t a) -> uint32_t {
        idle(host_lat); lite_ops++;
        d->ocl_cl_araddr = a; d->ocl_cl_arvalid = 1; d->ocl_cl_rready = 1;
        for (int n = 0; n < PCIS_TIMEOUT; n++) {
            bool f_ar = false, f_r = false; uint32_t v = 0; uint8_t rr = 0;
            tick([&] { f_ar = d->ocl_cl_arvalid && d->cl_ocl_arready; f_r = d->cl_ocl_rvalid && d->ocl_cl_rready; v = d->cl_ocl_rdata; rr = d->cl_ocl_rresp; });
            if (f_ar) d->ocl_cl_arvalid = 0;
            if (f_r) { d->ocl_cl_rready = 0; if (rr) fail("OCL: RRESP not OKAY"); return v; }
        }
        char m[100]; snprintf(m, sizeof m, "OCL read 0x%x: no response in 8 us", a); fail(m); return 0;
    };

    // ======================================================================= reset, then the memory before it is ready
    idle(32); d->rst_main_n = 1; idle(16);
    bool early_ok = true;
    if (dc.ready_at > 600) {
        if (lite_read(R_STATUS) & 1) { fail("STATUS says ready before the DDR4 is"); early_ok = false; }
        std::vector<uint8_t> junk(100, 0xA5), back;
        pcis_write(0x7000, junk.data(), junk.size(), true);
        pcis_drain(10000);
        pcis_read(0x7000, 130, back, true);
        for (auto v : back) if (v) { fail("PCIS read before ready: data not zero"); early_ok = false; break; }
        for (uint64_t a = 0x7000; a < 0x7000 + 100; a++) if (ddr.rd(a)) { fail("PCIS write before ready reached the memory"); early_ok = false; break; }
        uint32_t me = lite_read(R_MEM_ERR);
        if (me == 0) { fail("MEM_ERR did not count the early accesses"); early_ok = false; }
        int64_t t0 = cyc;
        while (!(lite_read(R_STATUS) & 1) && cyc - t0 < 10LL * dc.ready_at + 100000) idle(64);
        if (!(lite_read(R_STATUS) & 1)) { fail("STATUS never says ready"); early_ok = false; }
        printf("before the DDR4 was ready: BAR4 answered with SLVERR, %u accesses counted, memory untouched: %s\n", me, early_ok ? "ok" : "FAIL");
    } else {
        while (!(lite_read(R_STATUS) & 1) && cyc < 1000000) idle(64);
    }
    // ---- identification
    bool id_ok = lite_read(R_ID) == 0x4A504547 && lite_read(R_VERSION) == 2 && lite_read(R_LANES) == NL && lite_read(R_DW) == 512
                 && lite_read(R_COMMIT) == (uint32_t)COMMIT_EXP;
    lite_write(R_SCRATCH, 0xC0FFEE11); id_ok = id_ok && lite_read(R_SCRATCH) == 0xC0FFEE11;
    uint32_t c0 = lite_read(R_CLOCK_LO); uint32_t c0h = lite_read(R_CLOCK_HI); uint32_t c1 = lite_read(R_CLOCK_LO);
    id_ok = id_ok && c0h == 0 && c1 > c0;
    id_ok = id_ok && lite_read(0x0FFFC) == 0 && lite_read(0x100 + 0x80 * NL) == 0;       // nothing behind the map
    if (!id_ok) fail("identification / scratch / clock / commit registers wrong");
    if ((d->cl_sh_status_vled & 3) != 3) fail("vLED: DDR4 ready and memory on not shown");

    // ---- BAR4 at any alignment: write-combined pieces, read back in pieces of other sizes
    bool bar4_ok = true;
    {
        std::vector<uint8_t> ref(70000);
        for (auto& v : ref) v = (uint8_t)rnd();
        const uint64_t base = 0xF00000000ULL + 13;                // near the top of the 64 GiB, unaligned
        for (int pass = 0; pass < 2; pass++) {
            pcis_write(base, ref.data(), ref.size());
            pcis_drain(4000000);
            std::vector<uint8_t> back;
            pcis_read(base - 5, ref.size() + 9, back);
            for (size_t i = 0; i < ref.size() && bar4_ok; i++)
                if (back[i + 5] != ref[i] || ddr.rd(base + i) != ref[i]) { fail("BAR4 data wrong"); bar4_ok = false; }
            for (int i = 0; i < 5; i++) if (back[i] != ddr.rd(base - 5 + i)) { fail("BAR4 bytes before the write changed"); bar4_ok = false; }
            for (auto& v : ref) v = (uint8_t)(v * 7 + 1);
        }
        ddr.drop(base - 64, ref.size() + 128);
    }
    printf("BAR4 at any alignment (70 KB, pieces of 1-512 bytes, shell IDs varied): %s\n", bar4_ok ? "ok" : "FAIL");

    // ======================================================================= the files into DDR4 over PCIS
    const uint64_t IN_BASE = 0x000100000ULL, OUT_BASE = 0x400000000ULL, OUT_REGION = 0x10000000ULL;
    uint64_t in_next = IN_BASE;
    bool load_ok = true;
    for (size_t j = 0; j < jobs.size(); j++) {
        std::vector<uint8_t> dd;
        if (!slurp(jobs[j].file.c_str(), dd)) { fprintf(stderr, "cannot read %s\n", jobs[j].file.c_str()); return 2; }
        Job& J = jobs[j];
        dd.resize(dd.size() + (size_t)J.pad, 0);
        J.len = dd.size(); J.in_addr = in_next; J.tag = 0x1000 + (uint32_t)j;
        pcis_write(J.in_addr, dd.data(), dd.size());
        if (q_aw.size() > 4096) pcis_drain(40000000);
        in_next = (in_next + J.len + 4096 + 4095) & ~4095ULL;
    }
    pcis_drain(400000000);
    for (size_t j = 0; j < jobs.size() && load_ok; j++) {
        std::vector<uint8_t> dd; slurp(jobs[j].file.c_str(), dd); dd.resize(dd.size() + (size_t)jobs[j].pad, 0);
        for (size_t i = 0; i < dd.size(); i++) if (ddr.rd(jobs[j].in_addr + i) != dd[i]) { fail("a file did not arrive intact in DDR4"); load_ok = false; break; }
    }
    int64_t load_clocks = cyc;
    printf("files into DDR4 over BAR4: %zu files, %s, %lld write beats, %lld clocks so far\n", jobs.size(), load_ok ? "intact" : "CORRUPT",
           pcis_beats_w, (long long)load_clocks);
    fflush(stdout);
    std::vector<int> order(jobs.size());
    std::iota(order.begin(), order.end(), 0);
    if (policy == "size") std::stable_sort(order.begin(), order.end(), [&](int a, int b) { return jobs[a].len > jobs[b].len; });

    // ======================================================================= the batch (tb_engine.cpp's host)
    std::unordered_map<std::string, uint64_t> golden_hash;
    auto ghash = [&](const std::string& g, int& W, int& H, std::vector<uint8_t>& img) -> bool {
        if (!read_ppm(g.c_str(), W, H, img)) return false;
        auto it = golden_hash.find(g); if (it != golden_hash.end()) return true;
        uint64_t h = 0;
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
            size_t p = 3 * ((size_t)y * W + x);
            h += mix(((uint64_t)y << 48) | ((uint64_t)x << 32) | ((uint64_t)img[p] << 16) | ((uint64_t)img[p + 1] << 8) | img[p + 2]);
        }
        golden_hash[g] = h; return true;
    };
    long long pcis_rb_bytes = 0; bool pcis_rb_ok = true;
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
            int x = ddr.rd(a) | (ddr.rd(a + 1) << 8), y = ddr.rd(a + 2) | (ddr.rd(a + 3) << 8);
            for (int i = 0; i < 4 && x + i < W; i++) {
                if (y >= H) { oob++; continue; }
                size_t p = (size_t)y * W + x + i;
                if (seen[p]) dup++;
                seen[p] = 1; npx++;
                uint8_t R = ddr.rd(a + 4 + 3 * i), G = ddr.rd(a + 5 + 3 * i), B = ddr.rd(a + 6 + 3 * i);
                img[3 * p] = R; img[3 * p + 1] = G; img[3 * p + 2] = B;
                hash += mix(((uint64_t)y << 48) | ((uint64_t)(x + i) << 32) | ((uint64_t)R << 16) | ((uint64_t)G << 8) | B);
            }
        }
        // the first 2 KB of the records again, over BAR4 (the host's own path)
        uint64_t rb = std::min<uint64_t>((uint64_t)nread * 16, 2048);
        if (rb && !aborted) {
            std::vector<uint8_t> back; pcis_read(J.out_addr, rb, back); pcis_rb_bytes += (long long)rb;
            for (uint64_t i = 0; i < rb; i++) if (back[i] != ddr.rd(J.out_addr + i)) { fail("BAR4 readback of the records differs"); pcis_rb_ok = false; break; }
        }
        long long missing = 0; for (size_t p = 0; p < seen.size(); p++) if (!seen[p]) missing++;
        bool full = J.records <= rec_room;
        bool hash_ok = !full || aborted || hash == J.hash;
        long long diffs = -1; bool ghash_ok = true;
        bool exp_ok = J.expect == "ok", exp_np = J.expect.rfind("errnp:", 0) == 0;
        bool exp_err = J.expect.rfind("err:", 0) == 0 || exp_np, exp_abort = J.expect.rfind("abort:", 0) == 0;
        if (J.golden != "-" && exp_ok && !aborted) {
            int gw, gh; std::vector<uint8_t> g;
            if (ghash(J.golden, gw, gh, g) && gw == W && gh == H) {
                ghash_ok = (golden_hash[J.golden] == J.hash);       // the F2 host's check: no records needed
                if (full) { diffs = 0; for (size_t i = 0; i < g.size(); i++) if (g[i] != img[i]) diffs++; }
            } else { diffs = 1LL << 40; ghash_ok = false; }
        }
        long mask = exp_err ? strtol(J.expect.c_str() + J.expect.find(':') + 1, nullptr, 16) : 0;
        bool ovf_exp = J.out_max < 0x08000000ULL && (uint64_t)J.records * 16 > J.out_max;
        bool ok = J.done && J.run_tag == J.tag && !axi_err && !dup && !oob && J.t_done >= J.t_start + J.cycles;
        if (exp_abort) ok = ok && aborted && J.abort_sent;
        else {
            ok = ok && !aborted && hash_ok && ghash_ok && (!full || (uint32_t)npx == J.pixels) && (ovf_exp ? (ovf && !full) : !ovf);
            if (exp_ok) ok = ok && err == 0 && (!full || (!missing && (J.golden == "-" || diffs == 0)));
            if (exp_err) ok = ok && (((long)err & mask) == mask) && !(exp_np && (J.pixels || J.records));
        }
        J.ok = ok;
        printf("lane %d tag 0x%x %s%s: %ux%u cycles=%u clocks=%llu in_wait=%u out_wait=%u pixels=%u records=%u err=0x%04x "
               "ovf=%d abort=%d dup=%lld missing=%lld oob=%lld hash=%s golden_hash=%s%s expect=%s %s\n",
               J.lane, J.run_tag, J.file.c_str(), J.pad ? " (+pad)" : "", J.w, J.h, J.cycles,
               (unsigned long long)(J.t_done - J.t_start), J.in_wait, J.out_wait, J.pixels, J.records, err, ovf, aborted,
               dup, missing, oob, hash_ok ? (full ? "match" : "n/a") : "MISMATCH",
               (J.golden != "-" && exp_ok && !aborted) ? (ghash_ok ? "match" : "MISMATCH") : "n/a",
               diffs < 0 ? "" : (diffs == 0 ? " golden=identical" : " golden=DIFFERS"), J.expect.c_str(), ok ? "PASS" : "FAIL");
        fflush(stdout);
        if (J.out_max) ddr.drop(J.out_addr, std::max<uint64_t>(16, std::min<uint64_t>((uint64_t)J.records * 16, J.out_max)));
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
    std::vector<int> lane_job(NL, -1), lane_next(NL, -1), lane_count(NL, 0), lane_slot(NL, 0);
    std::vector<int> sched;
    size_t next = 0;
    bool stuck = false;
    auto write_job = [&](int l, int j) {
        Job& J = jobs[j];
        J.out_addr = OUT_BASE + (uint64_t)(2 * l + (lane_slot[l]++ & 1)) * OUT_REGION;     // two areas per lane, in turn
        auto wr = [&](int r, uint32_t v) { lite_write(lane_reg(l, r), v); };
        wr(L_IN_LO, (uint32_t)J.in_addr); wr(L_IN_HI, (uint32_t)(J.in_addr >> 32)); wr(L_LEN, (uint32_t)J.len);
        wr(L_OUT_LO, (uint32_t)J.out_addr); wr(L_OUT_HI, (uint32_t)(J.out_addr >> 32)); wr(L_OUT_MAX, (uint32_t)J.out_max);
        wr(L_TAG, J.tag);
    };
    auto start_job = [&](int l, int j) {
        lite_write(lane_reg(l, L_CTRL), 1);
        Job& J = jobs[j];
        J.lane = l; J.host_t0 = cyc; lane_job[l] = j; lane_count[l]++; sched.push_back(j);
        if (preload && next < order.size()) { int k = order[next++]; write_job(l, k); lane_next[l] = k; }
        if ((size_t)j == biggest && !busy_start_tried) {
            busy_start_tried = true; busy_lane = l;
            uint32_t a = lite_read(lane_reg(l, L_CTRL));
            if (!preload) lite_write(lane_reg(l, L_TAG), 0xBAD);
            lite_write(lane_reg(l, L_CTRL), 1);
            uint32_t b = lite_read(lane_reg(l, L_CTRL));
            busy_start_ok = (b >> 16) == (a >> 16) + 1 && (b & 0xFFFF) == (a & 0xFFFF);
            if (!busy_start_ok) fprintf(stderr, "lane %d: start while busy: CTRL 0x%08x -> 0x%08x\n", l, a, b);
        }
    };
    auto pending = [&]() { return next < order.size() || std::any_of(lane_job.begin(), lane_job.end(), [](int j) { return j >= 0; })
                                  || std::any_of(lane_next.begin(), lane_next.end(), [](int j) { return j >= 0; }); };
    int64_t batch_t0 = cyc;
    while (pending() && !stuck && tb_errors < 1000) {
        uint64_t dm_ = lite_read(R_DONE_LO);
        if (NL > 32) dm_ |= (uint64_t)lite_read(R_DONE_HI) << 32;
        bool progress = false;
        for (int l = 0; l < NL; l++)
            if (lane_job[l] >= 0 && ((dm_ >> l) & 1)) { collect(l, jobs[lane_job[l]]); lane_job[l] = -1; progress = true; }
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
        for (int l = 0; l < NL; l++) {
            if (lane_job[l] >= 0) continue;
            if (lane_next[l] >= 0) { int j = lane_next[l]; lane_next[l] = -1; start_job(l, j); progress = true; }
            else if (next < order.size()) { int j = order[next++]; write_job(l, j); start_job(l, j); progress = true; }
        }
        if (!progress) idle(64);
        if ((uint64_t)cyc > max_cycles) { fprintf(stderr, "batch did not finish in %llu clocks\n", (unsigned long long)max_cycles); stuck = true; }
    }
    // ---- counters, the function-level reset, the memory model's own findings
    bool counters_ok = true;
    for (int l = 0; l < NL; l++) {
        uint32_t c = lite_read(lane_reg(l, L_CTRL));
        uint32_t ign_exp = (l == busy_lane) ? 1 : 0;
        if ((c & 0xFFFF) != (uint32_t)lane_count[l] || (c >> 16) != ign_exp) {
            fprintf(stderr, "lane %d: CTRL counters 0x%08x, expected %d accepted, %u ignored\n", l, c, lane_count[l], ign_exp); counters_ok = false;
        }
    }
    if (lite_read(R_BUSY_LO) != 0) { fail("BUSY not clear after the batch"); counters_ok = false; }
    d->sh_cl_flr_assert = 1; idle(8); d->sh_cl_flr_assert = 0; idle(4);
    if (!flr_seen_done) fail("FLR: cl_sh_flr_done never came");
    if (lite_read(R_SCRATCH) != 0xC0FFEE11) fail("the registers lost state at an FLR (they should not)");
    d->sh_cl_ddr_stat_wr = 1; d->sh_cl_ddr_stat_addr = 0x12; idle(1); d->sh_cl_ddr_stat_wr = 0;
    bool stat_ack = false; for (int i = 0; i < 40 && !stat_ack; i++) tick([&] { stat_ack = stat_ack || d->cl_sh_ddr_stat_ack; });
    if (!stat_ack) fail("DDR statistics bus: no acknowledgement through the pipes");
    pcis_drain(100000);

    int passed = 0; uint64_t t0 = ~0ULL, t1 = 0, busy_sum = 0, longest = 0;
    for (auto& J : jobs) {
        if (J.ok) passed++;
        if (J.done) { t0 = std::min(t0, J.t_start); t1 = std::max(t1, J.t_done); busy_sum += J.t_done - J.t_start; longest = std::max(longest, J.t_done - J.t_start); }
    }
    uint64_t wall = t1 > t0 ? t1 - t0 : 0;
    uint64_t bound = std::max<uint64_t>(longest, (busy_sum + NL - 1) / NL);
    printf("batch: %zu jobs on %d lanes%s, wall %llu clocks (engine clock, first start to last done), lane busy %llu, "
           "utilisation %.3f, lower bound %llu (wall / bound %.3f); OCL accesses %lld, host latency %d; %lld clocks in all\n",
           jobs.size(), NL, hash_only ? " (hash only)" : "", (unsigned long long)wall, (unsigned long long)busy_sum,
           wall ? (double)busy_sum / ((double)NL * wall) : 0.0, (unsigned long long)bound, bound ? (double)wall / bound : 0.0,
           lite_ops, host_lat, (long long)(cyc - batch_t0));
    printf("checks: start while busy %s, lane counters %s, BAR4 readback of records %s (%lld bytes), PCIS %lld transactions, "
           "slowest %lld clocks (limit %d), DDR4 model: %lld AW / %lld AR / %lld W beats / %lld R beats, %lld B and R answers "
           "reordered across IDs, %lld read bursts interleaved\n",
           busy_start_tried ? (busy_start_ok ? "ok" : "FAIL") : "n/a", counters_ok ? "ok" : "FAIL", pcis_rb_ok ? "ok" : "FAIL",
           pcis_rb_bytes, pcis_txn, (long long)pcis_max_lat, PCIS_TIMEOUT, dm.aw_n, dm.ar_n, dm.w_beats, dm.r_beats, dm.reordered,
           dm.interleaved);
    bool all = passed == (int)jobs.size() && id_ok && early_ok && bar4_ok && load_ok && counters_ok && pcis_rb_ok && !stuck
               && tb_errors == 0 && (!busy_start_tried || busy_start_ok);
    printf("CL JOBS %d/%zu passed, %lld errors, all checks %s\n", passed, jobs.size(), tb_errors, all ? "passed" : "FAILED");
    d->final();
    delete d;
    return all ? 0 : 1;
}
