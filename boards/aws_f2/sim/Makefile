# Verilator simulation of mem_lane (../mem_lane.sv) with an AXI4 memory model (tb_mem_lane.cpp).
#   make                      -> obj_lane/Vmem_lane
#   obj_lane/Vmem_lane file.jpg --golden ref.ppm [--stall 30] [--seed N]
RTL_DIR := ../../../rtl
RTL     := $(RTL_DIR)/jpeg_pkg.sv $(RTL_DIR)/jpeg_sdp_ram.sv $(RTL_DIR)/jpeg_blockram.sv \
           $(RTL_DIR)/jpeg_parser.sv $(RTL_DIR)/jpeg_bitreader.sv $(RTL_DIR)/jpeg_coefdec.sv \
           $(RTL_DIR)/jpeg_idct.sv $(RTL_DIR)/jpeg_ycc2rgb.sv $(RTL_DIR)/jpeg_pixgen.sv \
           $(RTL_DIR)/jpeg_raster.sv $(RTL_DIR)/jpeg_dec_small.sv \
           $(RTL_DIR)/jpeg_bitwin.sv $(RTL_DIR)/jpeg_huffdec.sv $(RTL_DIR)/jpeg_idct_fast.sv \
           $(RTL_DIR)/jpeg_mcuout.sv $(RTL_DIR)/jpeg_raster_fast.sv $(RTL_DIR)/jpeg_dec_fast.sv \
           $(RTL_DIR)/jpeg_huffdec_wide.sv $(RTL_DIR)/jpeg_idct1d.sv $(RTL_DIR)/jpeg_idct_wide.sv \
           $(RTL_DIR)/jpeg_mcuout_wide.sv $(RTL_DIR)/jpeg_dec_wide.sv $(RTL_DIR)/jpeg_decoder.sv
obj_lane/Vmem_lane: $(RTL) ../mem_lane.sv tb_mem_lane.cpp
	verilator -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-WIDTH --top-module mem_lane \
	  -O2 --x-assign fast --x-initial fast -Mdir obj_lane -cc $(RTL) ../mem_lane.sv --exe tb_mem_lane.cpp -o Vmem_lane \
	  > obj_lane.log 2>&1 || (cat obj_lane.log; false)
	$(MAKE) -s -j2 -C obj_lane -f Vmem_lane.mk Vmem_lane
clean:
	rm -rf obj_lane obj_lane.log
