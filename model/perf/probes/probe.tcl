# Timing probe of the 1-symbol/clock Huffman loop of the wide core (rtl/jpeg_huffdec_wide.sv):
#   vivado -mode batch -source probe.tcl [-tclargs <out_dir>]      (default out_dir: probe2_out)
# (probe 1: change the file and top to hufloop_probe1; probe_fmax.tcl takes the file and top as arguments)
# The probe file is copied into <out_dir>/src and checked against the commit checked out first, <out_dir>/
# provenance.txt names it (../../../boards/acorn_cle215/provenance.tcl; BUILD_UNCOMMITTED=1 probes an uncommitted file,
# recorded as such); the reports go to <out_dir> too.
set here [file dirname [file normalize [info script]]]
set out probe2_out; if {[llength $argv]} { set out [lindex $argv 0] }
source $here/../../../boards/acorn_cle215/provenance.tcl
prov_init [info script]
file mkdir $out
prov_snapshot $out [list $here/hufloop_probe2.sv]
prov_write $out "hufloop_probe2 out of context, part xc7a200tfbg484-2, period 6.667 ns"
read_verilog -sv [prov_path $here/hufloop_probe2.sv]
synth_design -top hufloop_probe2 -part xc7a200tfbg484-2 -mode out_of_context -flatten_hierarchy rebuilt
create_clock -period 6.667 -name clk [get_ports clk]
opt_design
place_design
phys_opt_design
route_design
report_timing_summary -max_paths 3 -file $out/timing.rpt
report_utilization -file $out/util.rpt
report_timing -max_paths 8 -nworst 1 -file $out/paths.rpt
