#!/usr/bin/env python3
"""Check model/jpeg_golden.py against the decoders ML stacks actually use.

For every JPEG given, the model is run in each output mode and compared with:
  rgb   (fancy + turbo colour)  vs  Pillow Image.convert('RGB'), OpenCV imread, turbo `djpeg -dct int`
  ycbcr (fancy)                 vs  Pillow draft('YCbCr')   (libjpeg output space JCS_YCbCr)
  y                             vs  Pillow draft('L'), turbo `djpeg -grayscale`   (JCS_GRAYSCALE = component 0)
  rgb   (box + turbo colour)    vs  turbo `djpeg -dct int -nosmooth`
  rgb   (box + libjpeg9 colour) is the default profile, checked against djpeg 9e elsewhere (tb/golden).
The fancy upsampler is also cross-checked against a literal transcription of turbo's C loops.
An RGB-coded image (libjpeg 9e's colour-space rule) is compared in RGB only: the decoder, and so the model,
gives no YCbCr or grey output of it.
usage: compare_refs.py file.jpg [...]      exit status 0 = everything identical"""
import sys, os, re, subprocess, io
import numpy as np
from PIL import Image
import cv2
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "model"))
import jpeg_golden as G

def pnm_to_array(b):
    m = re.match(rb'(P[56])\s+(\d+)\s+(\d+)\s+255\s', b)
    w, h = int(m.group(2)), int(m.group(3)); a = np.frombuffer(b[m.end():], np.uint8)
    return a.reshape(h, w, 3) if m.group(1) == b'P6' else a.reshape(h, w)

def model(data, **kw):
    return pnm_to_array(G.Decoder(data, crosscheck=True, **kw).run())

def rgb3(a): return np.repeat(a[:, :, None], 3, axis=2) if a.ndim == 2 else a

def djpeg(path, *opts):
    return pnm_to_array(subprocess.run(["djpeg", "-dct", "int", *opts, "-pnm", path], check=True, capture_output=True).stdout)

def cmp(a, b):
    a = np.asarray(a).astype(int); b = np.asarray(b).astype(int)
    if a.shape != b.shape: return "SHAPE %s vs %s" % (a.shape, b.shape)
    d = np.abs(a - b)
    return "ok" if d.max() == 0 else "DIFF %d px, max %d" % ((d.reshape(d.shape[0], d.shape[1], -1).max(axis=2) > 0).sum(), d.max())

def sof_type(data):
    """n of the first SOFn marker (0 = baseline), skipping segments by their length"""
    i = 2
    while i + 4 <= len(data) and data[i] == 0xFF:
        m = data[i + 1]
        if 0xC0 <= m <= 0xCF and m not in (0xC4, 0xC8, 0xCC): return m - 0xC0
        i += 2 + int.from_bytes(data[i + 2:i + 4], "big")
    return None

cols = ["rgb~Pillow", "rgb~OpenCV", "rgb~djpeg", "ycc~Pillow", "y~Pillow", "y~djpeg", "box~djpeg-nosmooth"]
print("%-34s " % "image" + " ".join("%-18s" % c for c in cols))
bad = 0
for path in sys.argv[1:]:
    data = open(path, 'rb').read()
    if sof_type(data) != 0:
        print("%-34s skipped (SOF%s, not a baseline file: the decoder rejects it)" % (os.path.basename(path), sof_type(data))); continue
    try:
        m_rgb = rgb3(model(data, upsample='fancy', cc='turbo', out='rgb'))
        try:
            m_ycc = model(data, upsample='fancy', cc='turbo', out='ycbcr')
            m_y   = model(data, upsample='fancy', cc='turbo', out='y')
            rgb_coded = False
        except ValueError:                        # an RGB-coded image: RGB output only
            m_ycc = m_y = None; rgb_coded = True
        m_box = rgb3(model(data, upsample='box', cc='turbo', out='rgb'))
    except AssertionError as e:
        print("%-34s MODEL CROSSCHECK FAILED: %s" % (os.path.basename(path), e)); bad += 1; continue
    im = Image.open(path); is_gray = im.mode == 'L'
    r = []
    r.append(cmp(m_rgb, np.asarray(Image.open(path).convert('RGB'))))
    r.append(cmp(m_rgb, cv2.imread(path, cv2.IMREAD_COLOR)[:, :, ::-1]))
    r.append(cmp(m_rgb, rgb3(djpeg(path))))
    if rgb_coded:
        r += ["n/a (RGB-coded)"] * 3
    else:
        if is_gray:
            r.append("n/a (grey)")
        else:
            iy = Image.open(path); iy.draft('YCbCr', None); r.append(cmp(m_ycc, np.asarray(iy)) if iy.mode == 'YCbCr' else "draft failed")
        il = Image.open(path); il.draft('L', None); r.append(cmp(m_y, np.asarray(il)))
        r.append(cmp(m_y, djpeg(path, "-grayscale")))
    r.append(cmp(m_box, rgb3(djpeg(path, "-nosmooth"))))
    bad += sum(1 for x in r if not (x == "ok" or x.startswith("n/a")))
    print("%-34s " % os.path.basename(path) + " ".join("%-18s" % x for x in r))
print("ALL IDENTICAL" if bad == 0 else "%d MISMATCHES" % bad)
sys.exit(1 if bad else 0)
