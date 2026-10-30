# Vivado non-project build of acorn_top for one decoder:
#   vivado -mode batch -source build.tcl -tclargs <DUT 0|1|2|3> <CLKOUT_DIV> <out_dir>
# DUTs 0 and 3 (this library, FAST=1 / FAST=2) need ../../rtl; DUT 1 and 2 need the other decoders' sources in
# ../../bench/others/third_party (bench/others/fetch.sh).  Part: XC7A200T-2 (the Acorn CLE-215+ is -3; -2
# timing is the safe side for either grade). Every file the build reads is first copied into <out_dir>/src and
# checked against the commit checked out (provenance.tcl; the other decoders' sources, which are not in the
# repository, are copied with their sha256 recorded): a file that is not the commit's stops the build unless
# BUILD_UNCOMMITTED=1; <out_dir>/provenance.txt records the commit and the bitstream's USERID is its first 8 hex digits.
if {[info exists ::env(VIVADO_THREADS)]} { set_param general.maxThreads $::env(VIVADO_THREADS) }
set dut [lindex $argv 0]; set div [lindex $argv 1]; set out [file normalize [lindex $argv 2]]
set here [file dirname [file normalize [info script]]]
set rtl  [file normalize $here/../../rtl]
set tp   [file normalize $here/../../bench/others/third_party]
source $here/provenance.tcl
prov_init [info script]
file mkdir $out
# every file this build reads, copied into $out/src and checked against the commit; the build reads the copies
set srcs [list $rtl/jpeg_sdp_ram.sv]
set ext {}
if {$dut == 0 || $dut == 3} {
  # the decoder's sources in compile order (rtl/files.f)
  prov_snapshot $out [list $rtl/files.f]
  foreach f [prov_list [prov_path $rtl/files.f]] { if {$f ne "jpeg_sdp_ram.sv"} { lappend srcs $rtl/$f } }
} elseif {$dut == 1} {
  set ext [glob $tp/core_jpeg/src_v/*.v]
} else {
  set ext [glob $tp/legacy_jpeg_decoder/core/*.v]
}
set top [list $here/uart_bench_core.sv $here/acorn_top.sv]
prov_snapshot $out [concat $srcs $top [list $here/acorn.xdc]]
if {[llength $ext]} { prov_snapshot $out $ext -external }
prov_write $out "acorn_top DUT=$dut CLKOUT_DIV=$div, part xc7a200tfbg484-2, effort [expr {[info exists ::env(VIVADO_EFFORT)] && $::env(VIVADO_EFFORT) eq "high" ? "high" : "default"}]"
foreach f $srcs { read_verilog -sv [prov_path $f] }
if {[llength $ext]} { read_verilog [prov_paths $ext] }
read_verilog -sv [prov_paths $top]
read_xdc [prov_path $here/acorn.xdc]
synth_design -top acorn_top -part xc7a200tfbg484-2 -generic DUT=$dut -generic CLKOUT_DIV=$div
opt_design
# VIVADO_EFFORT=high: stronger placement / routing / physical optimisation (used for DUT 3, the wide
# core, whose one-symbol-per-clock Huffman loop is routing-bound); default: Vivado's default flow
if {[info exists ::env(VIVADO_EFFORT)] && $::env(VIVADO_EFFORT) eq "high"} {
  place_design -directive ExtraTimingOpt
  phys_opt_design -directive AggressiveExplore
  route_design -directive AggressiveExplore
  phys_opt_design -directive AggressiveExplore
} else {
  place_design
  phys_opt_design
  route_design
}
report_timing_summary -max_paths 10 -file $out/timing.rpt
report_timing -max_paths 1000 -nworst 1 -unique_pins -slack_lesser_than 0 -file $out/failing.rpt
write_checkpoint -force $out/post_route.dcp
report_utilization -file $out/utilization.rpt
report_utilization -hierarchical -hierarchical_depth 3 -file $out/utilization_hier.rpt
prov_stamp $out
write_bitstream -force $out/acorn_dut${dut}_div${div}.bit
prov_bit $out $out/acorn_dut${dut}_div${div}.bit
