# Vivado non-project build of acorn_batch_top (N decoder lanes, all decoding at the same time):
#   vivado -mode batch -source build_batch.tcl -tclargs <lanes> <FAST 1|2> <CLKOUT_DIV> <out_dir> [stage]
# stage: synth (synthesis -> post_synth.dcp), place (post_synth.dcp -> opt, place, phys_opt ->
# post_place.dcp), route (post_place.dcp -> route, phys_opt, reports, bitstream) or all (default, one
# process). Run as separate processes, the stages need less memory than one process: a 15-lane build
# in one process grew to 9.7 GB resident by the end of placement. Environment: VIVADO_THREADS,
# VIVADO_EFFORT=high (as build.tcl), VIVADO_PART (default xc7a200tfbg484-2; the Acorn CLE-215+ itself
# is a -3), BUILD_UNCOMMITTED=1 (provenance.tcl). The synthesis stage first copies every file the build reads into
# <out_dir>/src and checks it against the commit checked out (provenance.tcl): a file that is not the commit's stops
# the build; <out_dir>/provenance.txt records the commit and the bitstream's USERID is its first 8 hex digits.
if {[info exists ::env(VIVADO_THREADS)]} { set_param general.maxThreads $::env(VIVADO_THREADS) }
set n [lindex $argv 0]; set fast [lindex $argv 1]; set div [lindex $argv 2]; set out [file normalize [lindex $argv 3]]
set stage [lindex $argv 4]; if {$stage eq ""} { set stage all }
set part xc7a200tfbg484-2
if {[info exists ::env(VIVADO_PART)]} { set part $::env(VIVADO_PART) }
set high [expr {[info exists ::env(VIVADO_EFFORT)] && $::env(VIVADO_EFFORT) eq "high"}]
set here [file dirname [file normalize [info script]]]
set rtl  [file normalize $here/../../rtl]
set bit  $out/acorn_batch_n${n}_f${fast}_div${div}.bit
source $here/provenance.tcl
prov_init [info script]
file mkdir $out

if {$stage eq "synth" || $stage eq "all"} {
  # every file this build reads, copied into $out/src and checked against the commit before anything else; the build
  # reads the copies (provenance.tcl)
  prov_snapshot $out [list $rtl/files.f]
  set dec {}
  foreach f [prov_list [prov_path $rtl/files.f]] { lappend dec $rtl/$f }
  set top [list $here/bench_lane.sv $here/uart_batch_core.sv $here/acorn_batch_top.sv]
  prov_snapshot $out [concat $dec $top [list $here/acorn.xdc]]
  prov_write $out "acorn_batch_top N=$n FAST=$fast CLKOUT_DIV=$div, part $part, effort [expr {$high ? "high" : "default"}]"
  # the decoder's sources in compile order (rtl/files.f), the harness
  foreach f $dec { read_verilog -sv [prov_path $f] }
  read_verilog -sv [prov_paths $top]
  read_xdc [prov_path $here/acorn.xdc]
  synth_design -top acorn_batch_top -part $part -generic N=$n -generic FAST=$fast -generic CLKOUT_DIV=$div
  report_utilization -file $out/utilization_synth.rpt
  if {$stage eq "synth"} { write_checkpoint -force $out/post_synth.dcp; return }
}
if {$stage eq "place" || $stage eq "all"} {
  if {$stage eq "place"} { prov_stage $out $out/post_synth.dcp; open_checkpoint $out/post_synth.dcp }
  opt_design
  if {$high} {
    place_design -directive ExtraTimingOpt
    phys_opt_design -directive AggressiveExplore
  } else {
    place_design
    phys_opt_design
  }
  report_timing_summary -max_paths 10 -file $out/timing_place.rpt
  if {$stage eq "place"} { write_checkpoint -force $out/post_place.dcp; return }
}
if {$stage eq "route" || $stage eq "all"} {
  if {$stage eq "route"} { prov_stage $out $out/post_place.dcp; open_checkpoint $out/post_place.dcp }
  if {$high} {
    route_design -directive AggressiveExplore
    phys_opt_design -directive AggressiveExplore
  } else {
    route_design
  }
  report_timing_summary -max_paths 10 -file $out/timing.rpt
  report_timing -max_paths 1000 -nworst 1 -unique_pins -slack_lesser_than 0 -file $out/failing.rpt
  report_clock_utilization -file $out/clock_utilization.rpt
  write_checkpoint -force $out/post_route.dcp
  report_utilization -file $out/utilization.rpt
  report_utilization -hierarchical -hierarchical_depth 3 -file $out/utilization_hier.rpt
  prov_stamp $out
  write_bitstream -force $bit
  prov_bit $out $bit
}
