# Verilator builds of the RTL decoder + C++ testbench.
#   make              -> all configurations (obj_mcu, obj_rbox, obj_rfancy, obj_ep2c5)
#   make test         -> regression: every configuration x output format x corpus image, with and
#                        without random stalls, against model/jpeg_golden.py (run_tests.py), then
#                        several images streamed back to back without reset (run_stream_tests.py),
#                        malformed files (run_malformed_tests.py) and files cut at 230 points, each
#                        followed by a valid image (run_trunc_tests.py)
#   The corpus is tb/corpus (generated from test_images/adapter.jpg by ../scripts/make_corpus.py).
#   make lint
#   make decode       -> decode ../test_images/*.jpg with the C++ harness into ../out/
#   make TRACE=1      -> VCD tracing (run the binary with --trace out.vcd)
# Configurations (jpeg_decoder parameters):
#   mcu    : defaults - MCU-order output, sample replication, libjpeg 9 colour  (= djpeg 9e -nosmooth)
#   rbox   : RASTER_OUT=1                                                         (same pixels, raster order)
#   rfancy : RASTER_OUT=1 FANCY_UPSAMPLE=1 CC_TURBO=1                             (= Pillow / OpenCV / turbo djpeg)
#   ep2c5  : rfancy with ROWBUF_BYTES=9216, the largest row buffer that fits the EP2C5 build
#   noyrgb : ep2c5 without the colour converter (RGB_OUT=0): FMT_RGB delivers YCbCr
#   fmcu   : FAST=1 (pipelined core), MCU-order output                            (= mcu, ~10x faster)
#   frbox  : FAST=1 RASTER_OUT=1                                                  (= rbox)
#   frfancy: FAST=1 RASTER_OUT=1 FANCY_UPSAMPLE=1 CC_TURBO=1                      (= rfancy)
#   frfancy64k (not in the regression): frfancy with a 64 KB row buffer, for ../bench
#   rfancy64k (not in the regression): rfancy with a 64 KB row buffer, used by ../bench for large photos
RTL_DIR  := ../rtl
RTL      := $(RTL_DIR)/jpeg_pkg.sv $(RTL_DIR)/jpeg_sdp_ram.sv $(RTL_DIR)/jpeg_blockram.sv \
            $(RTL_DIR)/jpeg_parser.sv $(RTL_DIR)/jpeg_bitreader.sv $(RTL_DIR)/jpeg_coefdec.sv \
            $(RTL_DIR)/jpeg_idct.sv $(RTL_DIR)/jpeg_ycc2rgb.sv $(RTL_DIR)/jpeg_pixgen.sv \
            $(RTL_DIR)/jpeg_raster.sv $(RTL_DIR)/jpeg_dec_small.sv \
            $(RTL_DIR)/jpeg_bitwin.sv $(RTL_DIR)/jpeg_huffdec.sv $(RTL_DIR)/jpeg_idct_fast.sv \
            $(RTL_DIR)/jpeg_mcuout.sv $(RTL_DIR)/jpeg_raster_fast.sv $(RTL_DIR)/jpeg_dec_fast.sv \
            $(RTL_DIR)/jpeg_huffdec_wide.sv $(RTL_DIR)/jpeg_idct1d.sv $(RTL_DIR)/jpeg_idct_wide.sv \
            $(RTL_DIR)/jpeg_mcuout_wide.sv $(RTL_DIR)/jpeg_dec_wide.sv $(RTL_DIR)/jpeg_decoder.sv
TRACE    ?= 0
VFLAGS   := -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM --top-module jpeg_decoder -O2 --x-assign fast --x-initial fast
ifeq ($(TRACE),1)
VFLAGS   += --trace
endif
CFG_mcu    :=
CFG_rbox   := -GRASTER_OUT=1
CFG_rfancy := -GRASTER_OUT=1 -GFANCY_UPSAMPLE=1 -GCC_TURBO=1
CFG_ep2c5  := -GRASTER_OUT=1 -GFANCY_UPSAMPLE=1 -GCC_TURBO=1 -GROWBUF_BYTES=9216
CFG_noyrgb := -GRASTER_OUT=1 -GFANCY_UPSAMPLE=1 -GCC_TURBO=1 -GROWBUF_BYTES=9216 -GRGB_OUT=0
CFG_rfancy64k := -GRASTER_OUT=1 -GFANCY_UPSAMPLE=1 -GCC_TURBO=1 -GROWBUF_BYTES=65536
CFG_fmcu   := -GFAST=1
CFG_frbox  := -GFAST=1 -GRASTER_OUT=1
CFG_frfancy := -GFAST=1 -GRASTER_OUT=1 -GFANCY_UPSAMPLE=1 -GCC_TURBO=1
CFG_frfancy64k := -GFAST=1 -GRASTER_OUT=1 -GFANCY_UPSAMPLE=1 -GCC_TURBO=1 -GROWBUF_BYTES=65536
CFG_wmcu   := -GFAST=2 -CFLAGS -DNPIX=4
DEF_wmcu   := -DNPIX=4
CONFIGS    := mcu rbox rfancy ep2c5 noyrgb fmcu frbox frfancy wmcu
BINS       := $(foreach c,$(CONFIGS),obj_$(c)/Vjpeg_decoder)
MULTI      := $(foreach c,$(CONFIGS),obj_$(c)/Vmulti)
VROOT      := $(shell verilator --getenv VERILATOR_ROOT)

all: $(BINS)

obj_%/Vjpeg_decoder: $(RTL) tb_jpeg.cpp
	verilator $(VFLAGS) $(CFG_$*) -Mdir obj_$* -cc $(RTL) --exe tb_jpeg.cpp -o Vjpeg_decoder > obj_$*.log 2>&1 || (cat obj_$*.log; false)
	$(MAKE) -s -j2 -C obj_$* -f Vjpeg_decoder.mk Vjpeg_decoder

# raster + fancy upsampling with a row buffer of N bytes (scripts/decode.py --profile pillow sizes N
# for the widest image): obj_frfancy_rbN (FAST=1), obj_rfancy_rbN (compact core)
obj_frfancy_rb%/Vjpeg_decoder: $(RTL) tb_jpeg.cpp
	verilator $(VFLAGS) $(CFG_frfancy) -GROWBUF_BYTES=$* -Mdir obj_frfancy_rb$* -cc $(RTL) --exe tb_jpeg.cpp -o Vjpeg_decoder > obj_frfancy_rb$*.log 2>&1 || (cat obj_frfancy_rb$*.log; false)
	$(MAKE) -s -j2 -C obj_frfancy_rb$* -f Vjpeg_decoder.mk Vjpeg_decoder
obj_rfancy_rb%/Vjpeg_decoder: $(RTL) tb_jpeg.cpp
	verilator $(VFLAGS) $(CFG_rfancy) -GROWBUF_BYTES=$* -Mdir obj_rfancy_rb$* -cc $(RTL) --exe tb_jpeg.cpp -o Vjpeg_decoder > obj_rfancy_rb$*.log 2>&1 || (cat obj_rfancy_rb$*.log; false)
	$(MAKE) -s -j2 -C obj_rfancy_rb$* -f Vjpeg_decoder.mk Vjpeg_decoder

# decode every JPEG in ../test_images with the C++ harness (FAST=1, MCU order: the pixels of
# libjpeg 9e `djpeg -dct int -nosmooth`), no Python needed:  make decode  -> ../out/<name>.ppm
decode: obj_fmcu/Vjpeg_decoder
	@mkdir -p ../out
	@for f in ../test_images/*.jpg ../test_images/*.jpeg ../test_images/*.JPG; do \
	  [ -f "$$f" ] || continue; b=$$(basename "$$f"); \
	  printf "%-30s " "$$b"; ./obj_fmcu/Vjpeg_decoder "$$f" "../out/$${b%.*}.ppm" --quiet 2>&1 | grep -o "cycles=.*" || echo "failed"; \
	done; echo "outputs in ../out"

# multi-image harness, linked against the model compiled for Vjpeg_decoder
obj_%/Vmulti: obj_%/Vjpeg_decoder tb_multi.cpp
	$(CXX) -O1 -std=c++17 $(DEF_$*) -Iobj_$* -I$(VROOT)/include -I$(VROOT)/include/vltstd tb_multi.cpp \
	  obj_$*/Vjpeg_decoder__ALL.a obj_$*/verilated.o -o $@ -lpthread

multi: $(MULTI)

.PHONY: all multi lint test clean decode
lint:
	$(foreach c,$(CONFIGS),echo "== $(c)"; verilator --lint-only -Wall -Wno-DECLFILENAME $(CFG_$(c)) --top-module jpeg_decoder $(RTL);)

test: $(BINS) $(MULTI)
	python3 run_tests.py
	python3 run_stream_tests.py
	python3 run_malformed_tests.py
	python3 run_trunc_tests.py

clean:
	rm -rf obj_* out build *.log
