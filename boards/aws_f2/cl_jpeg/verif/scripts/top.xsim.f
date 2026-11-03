# top.xsim.f - AWS's XSIM testbench with the BEP-JPEG CL. Our sources live outside $CL_DIR/design (the decoder in
# rtl/, the F2 harness in boards/aws_f2/), so this list is written by hand; it has no AUTO-GENERATE block, which
# leaves the HDK's generate_sim_file_list.py nothing to replace (run make with DONT_GENERATE_FILE_LIST=1 anyway).

-define CL_NAME=cl_jpeg
-define DISABLE_VJTAG_DEBUG

-include $CL_DIR/verif/tests
-f ${HDK_COMMON_DIR}/verif/tb/filelists/tb.${SIMULATOR}.f
${TEST_NAME}

-include $CL_DIR/design
${CL_DIR}/../../../rtl/jpeg_pkg.sv
${CL_DIR}/../../../rtl/jpeg_sdp_ram.sv
${CL_DIR}/../../../rtl/jpeg_blockram.sv
${CL_DIR}/../../../rtl/jpeg_parser.sv
${CL_DIR}/../../../rtl/jpeg_bitreader.sv
${CL_DIR}/../../../rtl/jpeg_coefdec.sv
${CL_DIR}/../../../rtl/jpeg_idct.sv
${CL_DIR}/../../../rtl/jpeg_ycc2rgb.sv
${CL_DIR}/../../../rtl/jpeg_pixgen.sv
${CL_DIR}/../../../rtl/jpeg_raster.sv
${CL_DIR}/../../../rtl/jpeg_dec_small.sv
${CL_DIR}/../../../rtl/jpeg_bitwin.sv
${CL_DIR}/../../../rtl/jpeg_huffdec.sv
${CL_DIR}/../../../rtl/jpeg_idct_fast.sv
${CL_DIR}/../../../rtl/jpeg_mcuout.sv
${CL_DIR}/../../../rtl/jpeg_huffdec_wide.sv
${CL_DIR}/../../../rtl/jpeg_idct1d.sv
${CL_DIR}/../../../rtl/jpeg_idct_wide.sv
${CL_DIR}/../../../rtl/jpeg_mcuout_wide.sv
${CL_DIR}/../../../rtl/jpeg_raster_fast.sv
${CL_DIR}/../../../rtl/jpeg_dec_fast.sv
${CL_DIR}/../../../rtl/jpeg_dec_wide.sv
${CL_DIR}/../../../rtl/jpeg_decoder.sv
${CL_DIR}/../f2_slices.sv
${CL_DIR}/../f2_pcis.sv
${CL_DIR}/../f2_axi_mux.sv
${CL_DIR}/../f2_regs.sv
${CL_DIR}/../mem_lane.sv
${CL_DIR}/../f2_core.sv
${CL_DIR}/design/cl_jpeg.sv
