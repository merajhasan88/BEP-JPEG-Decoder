# Fmax of a timing probe: out-of-context synthesis, place and route at a tight clock, then
# Fmax = 1 / (period - WNS).
#   vivado -mode batch -source probe_fmax.tcl -tclargs <file.sv> <top> <period_ns> <out_dir>
# The probe file is copied into <out_dir>/src and checked against the commit checked out first
# (../../../boards/acorn_cle215/provenance.tcl; BUILD_UNCOMMITTED=1 probes an uncommitted file, recorded as such).
set f [lindex $argv 0]; set top [lindex $argv 1]; set period [lindex $argv 2]; set out [lindex $argv 3]
source [file dirname [file normalize [info script]]]/../../../boards/acorn_cle215/provenance.tcl
prov_init [info script]
file mkdir $out
prov_snapshot $out [list $f]
prov_write $out "$top out of context, part xc7a200tfbg484-2, period $period ns"
read_verilog -sv [prov_path $f]
synth_design -top $top -part xc7a200tfbg484-2 -mode out_of_context -flatten_hierarchy rebuilt
create_clock -period $period -name clk [get_ports clk]
opt_design
place_design
phys_opt_design
route_design
report_timing_summary -max_paths 3 -file $out/timing.rpt
report_utilization -file $out/util.rpt
report_timing -max_paths 4 -nworst 1 -file $out/paths.rpt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set fmax [expr {1000.0 / ($period - $wns)}]
puts "PROBE $top period=$period wns=$wns fmax_mhz=[format %.1f $fmax] [prov_id $out]"
