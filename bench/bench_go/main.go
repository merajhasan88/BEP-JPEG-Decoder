// bench_go - single-thread decode benchmark of Go's standard image/jpeg, JPEG already in memory.
// image/jpeg returns YCbCr; the output is converted to RGBA with image/draw (its YCbCr fast path),
// since the other decoders deliver RGB.  Same method and output line as bench_c.c:
//   bench_go file.jpg [mode, ignored] [min_seconds]
//   -> "<W>x<H> ms=<median per decode> mpx_s= decodes= elapsed= uJ_per_decode=<RAPL package energy>"
package main

import (
	"bytes"
	"fmt"
	"image"
	"image/draw"
	"image/jpeg"
	"os"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"time"
)

func rapl() int64 {
	b, err := os.ReadFile("/sys/class/powercap/intel-rapl:0/energy_uj")
	if err != nil {
		return -1
	}
	v, err := strconv.ParseInt(strings.TrimSpace(string(b)), 10, 64)
	if err != nil {
		return -1
	}
	return v
}

func main() {
	runtime.GOMAXPROCS(1)
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: bench_go file.jpg [mode] [min_seconds]")
		os.Exit(2)
	}
	data, err := os.ReadFile(os.Args[1])
	if err != nil {
		panic(err)
	}
	minS := 1.0
	if len(os.Args) > 3 {
		minS, _ = strconv.ParseFloat(os.Args[3], 64)
	}
	var w, h int
	decode := func() {
		img, err := jpeg.Decode(bytes.NewReader(data))
		if err != nil {
			panic(err)
		}
		b := img.Bounds()
		w, h = b.Dx(), b.Dy()
		dst := image.NewRGBA(b)
		draw.Draw(dst, b, img, b.Min, draw.Src)
	}
	decode() // warm up, learn the size
	t0 := time.Now()
	calib := 0
	for time.Since(t0).Seconds() < 0.05 {
		decode()
		calib++
	}
	perBatch := calib*2 + 1 // ~0.1 s batches
	var per []float64
	e0 := rapl()
	tstart := time.Now()
	total := 0
	for len(per) < 64 && (time.Since(tstart).Seconds() < minS || len(per) < 5) {
		a := time.Now()
		for i := 0; i < perBatch; i++ {
			decode()
		}
		per = append(per, time.Since(a).Seconds()/float64(perBatch))
		total += perBatch
	}
	e1 := rapl()
	elapsed := time.Since(tstart).Seconds()
	seq := append([]float64(nil), per...) // every batch in the order measured, for the spread
	sort.Float64s(per)
	med := per[len(per)/2]
	uj := -1.0
	if e0 >= 0 && e1 >= e0 {
		uj = float64(e1-e0) / float64(total)
	}
	fmt.Printf("%dx%d ms=%.4f mpx_s=%.2f decodes=%d elapsed=%.2f uJ_per_decode=%.1f\n",
		w, h, med*1e3, float64(w)*float64(h)/med/1e6, total, elapsed, uj)
	fmt.Printf("per_batch=%d batches_ms=", perBatch)
	for i, v := range seq {
		if i > 0 {
			fmt.Print(",")
		}
		fmt.Printf("%.4f", v*1e3)
	}
	fmt.Println()
}
