# Verilator simulation of mem_lane (../mem_lane.sv) with an AXI4 memory model (tb_mem_lane.cpp).
#   make                      -> obj_lane/Vmem_lane (512-bit data) and obj_lane256/Vmem_lane (256-bit data)
#   obj_lane/Vmem_lane [--stall 30] [--seed N] jobs.txt     (job list format: tb_mem_lane.cpp)
#   obj_eng/Vengine [--policy order|size] [--stall 30] [--host-lat 100] jobs.txt   (the job engine: tb_engine.cpp)
RTL_DIR := ../../../rtl
RTL     := $(RTL_DIR)/jpeg_pkg.sv $(RTL_DIR)/jpeg_sdp_ram.sv $(RTL_DIR)/jpeg_blockram.sv \
           $(RTL_DIR)/jpeg_parser.sv $(RTL_DIR)/jpeg_bitreader.sv $(RTL_DIR)/jpeg_coefdec.sv \
           $(RTL_DIR)/jpeg_idct.sv $(RTL_DIR)/jpeg_ycc2rgb.sv $(RTL_DIR)/jpeg_pixgen.sv \
           $(RTL_DIR)/jpeg_raster.sv $(RTL_DIR)/jpeg_dec_small.sv \
           $(RTL_DIR)/jpeg_bitwin.sv $(RTL_DIR)/jpeg_huffdec.sv $(RTL_DIR)/jpeg_idct_fast.sv \
           $(RTL_DIR)/jpeg_mcuout.sv $(RTL_DIR)/jpeg_raster_fast.sv $(RTL_DIR)/jpeg_dec_fast.sv \
           $(RTL_DIR)/jpeg_huffdec_wide.sv $(RTL_DIR)/jpeg_idct1d.sv $(RTL_DIR)/jpeg_idct_wide.sv \
           $(RTL_DIR)/jpeg_mcuout_wide.sv $(RTL_DIR)/jpeg_dec_wide.sv $(RTL_DIR)/jpeg_decoder.sv
VFLAGS  := -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-WIDTH --top-module mem_lane \
           -O2 --x-assign fast --x-initial fast
all: obj_lane/Vmem_lane obj_lane256/Vmem_lane obj_eng/Vengine obj_eng3/Vengine
ENG := ../mem_lane.sv ../f2_regs.sv ../jpeg_f2_engine.sv
obj_lane/Vmem_lane: $(RTL) ../mem_lane.sv tb_mem_lane.cpp
	verilator $(VFLAGS) -GDW=512 -CFLAGS -DDW=512 -Mdir obj_lane -cc $(RTL) ../mem_lane.sv --exe tb_mem_lane.cpp -o Vmem_lane \
	  > obj_lane.log 2>&1 || (cat obj_lane.log; false)
	$(MAKE) -s -j2 -C obj_lane -f Vmem_lane.mk Vmem_lane
obj_lane256/Vmem_lane: $(RTL) ../mem_lane.sv tb_mem_lane.cpp
	verilator $(VFLAGS) -GDW=256 -CFLAGS -DDW=256 -Mdir obj_lane256 -cc $(RTL) ../mem_lane.sv --exe tb_mem_lane.cpp -o Vmem_lane \
	  > obj_lane256.log 2>&1 || (cat obj_lane256.log; false)
	$(MAKE) -s -j2 -C obj_lane256 -f Vmem_lane.mk Vmem_lane
# the job engine (../jpeg_f2_engine.sv) with tb_engine.cpp: 4 lanes of 512 bits, 3 lanes of 256 bits
obj_eng/Vengine: $(RTL) $(ENG) tb_engine.cpp
	verilator $(subst mem_lane,jpeg_f2_engine,$(VFLAGS)) -GNL=4 -GDW=512 -CFLAGS "-DNL=4 -DDW=512" -Mdir obj_eng -cc $(RTL) $(ENG) \
	  --exe tb_engine.cpp -o Vengine > obj_eng.log 2>&1 || (cat obj_eng.log; false)
	$(MAKE) -s -j2 -C obj_eng -f Vjpeg_f2_engine.mk Vengine
obj_eng3/Vengine: $(RTL) $(ENG) tb_engine.cpp
	verilator $(subst mem_lane,jpeg_f2_engine,$(VFLAGS)) -GNL=3 -GDW=256 -CFLAGS "-DNL=3 -DDW=256" -Mdir obj_eng3 -cc $(RTL) $(ENG) \
	  --exe tb_engine.cpp -o Vengine > obj_eng3.log 2>&1 || (cat obj_eng3.log; false)
	$(MAKE) -s -j2 -C obj_eng3 -f Vjpeg_f2_engine.mk Vengine
clean:
	rm -rf obj_lane obj_lane.log obj_lane256 obj_lane256.log obj_eng obj_eng.log obj_eng3 obj_eng3.log
