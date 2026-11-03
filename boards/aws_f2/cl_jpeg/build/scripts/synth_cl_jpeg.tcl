# synth_cl_jpeg.tcl - sourced by the HDK's build_all.tcl after encrypt.tcl: synthesis of the BEP-JPEG CL (out of
# context, the HDK's header and footer around it). The DDR4 controller is AWS's pre-built IP (cl_ddr4, the 64 GB
# DIMM without user auto-precharge: sh_ddr's default, no define needed).
source ${HDK_SHELL_DIR}/build/scripts/synth_cl_header.tcl

print "Reading the BEP-JPEG sources (package first)"
foreach f $cl_src_order {
  if {[string match "*.sv" $f]} { read_verilog -sv $f }
}

print "Reading the CL's IP: the DDR4 controller"
read_ip [list ${HDK_IP_SRC_DIR}/cl_ddr4/cl_ddr4.xci]

print "Reading user constraints"
read_xdc [list ${constraints_dir}/cl_synth_user.xdc ${constraints_dir}/cl_timing_user.xdc]
set_property PROCESSING_ORDER LATE [get_files cl_synth_user.xdc]
set_property PROCESSING_ORDER LATE [get_files cl_timing_user.xdc]

print "Starting synthesis of ${CL}"
update_compile_order -fileset sources_1
synth_design -mode out_of_context -top ${CL} -verilog_define XSDB_SLV_DIS -part ${DEVICE_TYPE} -keep_equivalent_registers

source ${HDK_SHELL_DIR}/build/scripts/synth_cl_footer.tcl
