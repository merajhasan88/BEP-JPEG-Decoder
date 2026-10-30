#!/usr/bin/env python3
"""Single-thread decode benchmark of Python-facing decoders, JPEG already in memory.
usage: bench_py.py pillow|opencv|model file.jpg [min_seconds]
Pillow: Image.open(BytesIO).load() (libjpeg-turbo, fancy upsampling, output RGB/L)
OpenCV: cv2.imdecode(IMREAD_COLOR) with cv2.setNumThreads(1)
model : model/jpeg_golden.py (pure-Python bit-exact reference, for scale only)"""
import sys, io, time, os
which, path = sys.argv[1], sys.argv[2]
min_s = float(sys.argv[3]) if len(sys.argv) > 3 else 1.0
data = open(path, "rb").read()
def rapl():
    try: return int(open("/sys/class/powercap/intel-rapl:0/energy_uj").read())
    except Exception: return -1
if which == "pillow":
    from PIL import Image
    def dec():
        im = Image.open(io.BytesIO(data)); im.load(); return im.size
elif which == "opencv":
    import numpy as np, cv2
    cv2.setNumThreads(1); arr = np.frombuffer(data, np.uint8)
    def dec():
        a = cv2.imdecode(arr, cv2.IMREAD_COLOR); return (a.shape[1], a.shape[0])
elif which == "model":
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "model"))
    import jpeg_golden as G
    def dec():
        G.Decoder(data, upsample="fancy", cc="turbo").run(); return None
W, H = dec() or (0, 0)
t0 = time.perf_counter(); n = 0
while time.perf_counter() - t0 < 0.05 or n == 0: dec(); n += 1
per_batch = max(1, n * 2); per = []; total = 0; e0 = rapl(); ts = time.perf_counter()
while len(per) < 64 and (time.perf_counter() - ts < min_s or len(per) < 5):
    a = time.perf_counter()
    for _ in range(per_batch): dec()
    per.append((time.perf_counter() - a) / per_batch); total += per_batch
e1 = rapl(); seq = list(per); per.sort(); med = per[len(per) // 2]
uj = (e1 - e0) / total if e0 >= 0 and e1 >= e0 else -1
if not W:
    from PIL import Image; W, H = Image.open(io.BytesIO(data)).size
print(f"{W}x{H} ms={med*1e3:.4f} mpx_s={W*H/med/1e6:.2f} decodes={total} elapsed={time.perf_counter()-ts:.2f} uJ_per_decode={uj:.1f}")
print(f"per_batch={per_batch} batches_ms=" + ",".join(f"{v*1e3:.4f}" for v in seq))   # every batch, measured order
