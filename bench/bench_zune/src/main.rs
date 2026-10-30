// bench_zune - single-thread decode benchmark of zune-jpeg (Rust; SIMD chosen at run time), JPEG
// already in memory, RGB output.  Same method and output line as bench_c.c:
//   bench_zune file.jpg [mode, ignored] [min_seconds]
use std::time::Instant;
use zune_jpeg::JpegDecoder;

fn rapl() -> i64 {
    std::fs::read_to_string("/sys/class/powercap/intel-rapl:0/energy_uj")
        .ok()
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(-1)
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        eprintln!("usage: bench_zune file.jpg [mode] [min_seconds]");
        std::process::exit(2);
    }
    let data = std::fs::read(&args[1]).expect("cannot read the file");
    let min_s: f64 = if args.len() > 3 { args[3].parse().unwrap_or(1.0) } else { 1.0 };
    let (mut w, mut h) = (0usize, 0usize);
    let mut decode = || {
        let mut d = JpegDecoder::new(&data);
        let px = d.decode().expect("decode failed");
        let info = d.info().expect("no image info");
        w = info.width as usize;
        h = info.height as usize;
        std::hint::black_box(px);
    };
    decode(); // warm up, learn the size
    let t0 = Instant::now();
    let mut calib = 0;
    while t0.elapsed().as_secs_f64() < 0.05 {
        decode();
        calib += 1;
    }
    let per_batch = calib * 2 + 1; // ~0.1 s batches
    let mut per: Vec<f64> = Vec::new();
    let e0 = rapl();
    let tstart = Instant::now();
    let mut total = 0;
    while per.len() < 64 && (tstart.elapsed().as_secs_f64() < min_s || per.len() < 5) {
        let a = Instant::now();
        for _ in 0..per_batch {
            decode();
        }
        per.push(a.elapsed().as_secs_f64() / per_batch as f64);
        total += per_batch;
    }
    let e1 = rapl();
    let elapsed = tstart.elapsed().as_secs_f64();
    let seq = per.clone(); // every batch in the order measured, for the spread
    per.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let med = per[per.len() / 2];
    let uj = if e0 >= 0 && e1 >= e0 { (e1 - e0) as f64 / total as f64 } else { -1.0 };
    println!("{}x{} ms={:.4} mpx_s={:.2} decodes={} elapsed={:.2} uJ_per_decode={:.1}",
             w, h, med * 1e3, (w * h) as f64 / med / 1e6, total, elapsed, uj);
    let list: Vec<String> = seq.iter().map(|v| format!("{:.4}", v * 1e3)).collect();
    println!("per_batch={} batches_ms={}", per_batch, list.join(","));
}
