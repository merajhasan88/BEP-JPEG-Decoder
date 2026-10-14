# Timing probe of the 1-symbol/clock Huffman loop of the wide core (rtl/jpeg_huffdec_wide.sv):
#   vivado -mode batch -source probe.tcl
# (probe 1: change the file and top to hufloop_probe1; probe_fmax.tcl takes the file and top as arguments)
# The probe file is copied into ./src and checked against the commit checked out first, ./provenance.txt names it
# (../../../boards/acorn_cle215/provenance.tcl; BUILD_UNCOMMITTED=1 probes an uncommitted file, recorded as such).
source [file dirname [file normalize [info script]]]/../../../boards/acorn_cle215/provenance.tcl
prov_init [info script]
prov_snapshot . [list hufloop_probe2.sv]
prov_write . "hufloop_probe2 out of context, part xc7a200tfbg484-2, period 6.667 ns"
read_verilog -sv [prov_path hufloop_probe2.sv]
synth_design -top hufloop_probe2 -part xc7a200tfbg484-2 -mode out_of_context -flatten_hierarchy rebuilt
create_clock -period 6.667 -name clk [get_ports clk]
opt_design
place_design
phys_opt_design
route_design
report_timing_summary -max_paths 3 -file timing.rpt
report_utilization -file util.rpt
report_timing -max_paths 8 -nworst 1 -file paths.rpt
