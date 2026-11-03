# synth_cl_jpeg.tcl - sourced by the HDK's build_all.tcl after encrypt.tcl: synthesis of the BEP-JPEG CL (out of
# context, the HDK's header and footer around it). The DDR4 controller is AWS's pre-built IP (cl_ddr4, the 64 GB
# DIMM without user auto-precharge: sh_ddr's default, no define needed).
# AWS's sh_ddr (encrypted) also instantiates two AXI clock converters, cl_axi_clock_converter and
# cl_axi_clock_converter_light (and lib_pipe, which the HDK's header reads): AWS's simulation of this CL elaborates
# exactly these under cl_jpeg, and AWS's DDR4 examples (cl_dram_hbm_dma, cl_mem_perf) read both. Without them the
# first build on AWS (2026-11-03, 3eb58efb) stopped in elaboration: "[Synth 8-5809] Error generated from encrypted
# envelope" at two lines of sh_ddr.sv.
source ${HDK_SHELL_DIR}/build/scripts/synth_cl_header.tcl

print "Reading the BEP-JPEG sources (package first)"
foreach f $cl_src_order {
  if {[string match "*.sv" $f]} { read_verilog -sv $f }
}

print "Reading the CL's IP: the DDR4 controller and the clock converters inside sh_ddr"
read_ip [list ${HDK_IP_SRC_DIR}/cl_ddr4/cl_ddr4.xci \
              ${HDK_IP_SRC_DIR}/cl_axi_clock_converter/cl_axi_clock_converter.xci \
              ${HDK_IP_SRC_DIR}/cl_axi_clock_converter_light/cl_axi_clock_converter_light.xci]

print "Reading user constraints"
read_xdc [list ${constraints_dir}/cl_synth_user.xdc ${constraints_dir}/cl_timing_user.xdc]
set_property PROCESSING_ORDER LATE [get_files cl_synth_user.xdc]
set_property PROCESSING_ORDER LATE [get_files cl_timing_user.xdc]

print "Starting synthesis of ${CL}"
update_compile_order -fileset sources_1
synth_design -mode out_of_context -top ${CL} -verilog_define XSDB_SLV_DIS -part ${DEVICE_TYPE} -keep_equivalent_registers

source ${HDK_SHELL_DIR}/build/scripts/synth_cl_footer.tcl
