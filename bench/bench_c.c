/* bench_c.c - single-thread decode benchmark of C JPEG decoders, JPEG already in memory.
 *   BACKEND_LIBJPEG : libjpeg API (link with libjpeg-turbo or with libjpeg 9e)
 *   BACKEND_STB     : stb_image
 * usage: bench_xxx file.jpg [mode] [min_seconds]
 *   mode (libjpeg): fancy (default: islow + fancy upsampling), nosmooth, ifast
 * Prints: median ms per decode over batches, Mpixel/s, and package energy per decode (RAPL)
 * when /sys/class/powercap/intel-rapl:0/energy_uj is readable; then a second line with every
 * batch's ms per decode in the order measured (the spread; one warm-up decode and a 0.05 s
 * calibration come first, batches of ~0.1 s, at least min_seconds and 5 batches, at most 64).  */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#ifdef BACKEND_LIBJPEG
#include <jpeglib.h>
#endif
#ifdef BACKEND_STB
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_JPEG
#include "stb_image.h"          /* -I<folder of stb_image.h> (bench/tools.py downloads it) */
#endif

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec * 1e-9; }
static long long rapl(void) {
    FILE *f = fopen("/sys/class/powercap/intel-rapl:0/energy_uj", "r"); long long v = -1;
    if (f) { if (fscanf(f, "%lld", &v) != 1) v = -1; fclose(f); }
    return v;
}
static unsigned char *buf; static long len; static int W, H; static unsigned char *out;
static const char *mode = "fancy";

static void decode_once(void) {
#ifdef BACKEND_LIBJPEG
    struct jpeg_decompress_struct c; struct jpeg_error_mgr e;
    c.err = jpeg_std_error(&e); jpeg_create_decompress(&c);
    jpeg_mem_src(&c, buf, len); jpeg_read_header(&c, TRUE);
    c.out_color_space = (c.num_components == 1) ? JCS_GRAYSCALE : JCS_RGB;
    c.dct_method = strcmp(mode, "ifast") ? JDCT_ISLOW : JDCT_IFAST;
    c.do_fancy_upsampling = strcmp(mode, "nosmooth") ? TRUE : FALSE;
    jpeg_start_decompress(&c);
    W = c.output_width; H = c.output_height;
    int stride = W * c.output_components;
    if (!out) out = malloc((size_t)stride * H);
    while (c.output_scanline < c.output_height) { JSAMPROW r = out + (size_t)c.output_scanline * stride; jpeg_read_scanlines(&c, &r, 1); }
    jpeg_finish_decompress(&c); jpeg_destroy_decompress(&c);
#endif
#ifdef BACKEND_STB
    int n; unsigned char *p = stbi_load_from_memory(buf, (int)len, &W, &H, &n, 3);
    stbi_image_free(p);
#endif
}

static int cmpd(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return x < y ? -1 : x > y; }
int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s file.jpg [fancy|nosmooth|ifast] [min_seconds]\n", argv[0]); return 2; }
    if (argc > 2) mode = argv[2];
    double min_s = argc > 3 ? atof(argv[3]) : 1.0;
    FILE *f = fopen(argv[1], "rb"); fseek(f, 0, SEEK_END); len = ftell(f); fseek(f, 0, SEEK_SET);
    buf = malloc(len); if (fread(buf, 1, len, f) != (size_t)len) return 1; fclose(f);
    decode_once();                                                   /* warm up, learn size */
    double t0 = now(); int calib = 0; while (now() - t0 < 0.05) { decode_once(); calib++; }
    int per_batch = calib * 2 + 1;                                   /* ~0.1 s batches */
    enum { NB = 64 }; double per[NB]; int nb = 0; long long e0 = rapl(); double tstart = now(); long total = 0;
    while (nb < NB && (now() - tstart < min_s || nb < 5)) {
        double a = now(); for (int i = 0; i < per_batch; i++) decode_once(); double b = now();
        per[nb++] = (b - a) / per_batch; total += per_batch;
    }
    long long e1 = rapl(); double elapsed = now() - tstart;
    double seq[NB]; memcpy(seq, per, sizeof(double) * nb);           /* measured order, for the spread */
    qsort(per, nb, sizeof(double), cmpd);
    double med = per[nb / 2];
    double uj = (e0 >= 0 && e1 >= e0) ? (double)(e1 - e0) / total : -1;
    printf("%dx%d ms=%.4f mpx_s=%.2f decodes=%ld elapsed=%.2f uJ_per_decode=%.1f\n", W, H, med * 1e3, W * (double)H / med / 1e6, total, elapsed, uj);
    printf("per_batch=%d batches_ms=", per_batch);
    for (int i = 0; i < nb; i++) printf(i ? ",%.4f" : "%.4f", seq[i] * 1e3);
    printf("\n");
    return 0;
}
