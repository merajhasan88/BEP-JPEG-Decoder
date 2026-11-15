# local_check.tcl - the free checks of the F2 image on this machine before AWS builds it (the free Vivado licence does not
# cover F2's xcvu47p, so a Kintex UltraScale+ of the same speed grade stands in, as in model/perf/probes/usplus_timing.tcl):
#   elab   the real top level (design/cl_jpeg.sv with the HDK's cl_ports.vh; AWS's sh_ddr as a black box, ../sim/sh_ddr_bb.sv)
#          elaborated by Vivado: every cell that build/constraints/small_shell_cl_pnr_user.xdc places must exist
#   lane   one lane (../mem_lane.sv: the wide decoder with its memory ports) synthesized on its own -> lane.edf
#   synth  the core (../f2_core.sv, NL lanes, the multiplexer, the registers, the slices) with the lanes as black boxes
#          (../sim/mem_lane_stub.sv), each filled from lane.edf
#   place, route   at the period given (F2's clk_main_a0: 4.0 ns), high-effort directives; summary.txt: the worst setup
#          path overall, inside a lane and outside the lanes, and the worst hold path
#   vivado -mode batch -source local_check.tcl -tclargs <stage> <out_dir> [lanes] [period_ns]
# Environment: HDK_DIR (an aws-fpga v2.3.5 checkout, for cl_ports.vh), VIVADO_PART (default xcku5p-ffvb676-2-e),
# VIVADO_THREADS. Sources are copied and checked against the commit checked out (../../acorn_cle215/provenance.tcl).
if {[info exists ::env(VIVADO_THREADS)]} { set_param general.maxThreads $::env(VIVADO_THREADS) }
set stage  [lindex $argv 0]; set out [lindex $argv 1]
set n      [lindex $argv 2]; if {$n eq ""} { set n 15 }
set period [lindex $argv 3]; if {$period eq ""} { set period 4.0 }
set part xcku5p-ffvb676-2-e
if {[info exists ::env(VIVADO_PART)]} { set part $::env(VIVADO_PART) }
set here [file dirname [file normalize [info script]]]
set f2   [file normalize $here/..]
set root [file normalize $here/../../..]
set rtl  $root/rtl
source $root/boards/acorn_cle215/provenance.tcl
prov_init [info script]
file mkdir $out

proc snapshot_decoder {rtl out files} {
  prov_snapshot $out [list $rtl/files.f]
  set dec {}
  foreach f [prov_list [prov_path $rtl/files.f]] { lappend dec $rtl/$f }
  return [prov_snapshot $out [concat $dec $files]]
}
set glue [list $f2/f2_slices.sv $f2/f2_pcis.sv $f2/f2_axi_mux.sv $f2/f2_regs.sv]

if {$stage eq "elab"} {
  if {![info exists ::env(HDK_DIR)]} { error "set HDK_DIR to an aws-fpga v2.3.5 checkout" }
  set ports $::env(HDK_DIR)/hdk/common/shell_stable/design/interfaces/cl_ports.vh
  prov_snapshot $out [list $ports] -external
  prov_snapshot $out [list $here/design/cl_id_defines.vh $here/design/cl_jpeg_defines.vh]
  set src [snapshot_decoder $rtl $out [concat $glue [list $f2/mem_lane.sv $f2/f2_core.sv $f2/sim/sh_ddr_bb.sv $here/design/cl_jpeg.sv]]]
  prov_write $out "cl_jpeg elaboration (NL=$n), part $part, sh_ddr as a black box" provenance_elab.txt
  read_verilog -sv $src
  synth_design -rtl -top cl_jpeg -part $part -mode out_of_context -generic NL=$n \
    -include_dirs [list [file dirname [prov_path $ports]] [file dirname [prov_path $here/design/cl_jpeg.sv]]]
  set fh [open $out/elab.txt w]
  puts $fh [prov_id $out provenance_elab.txt]
  set missing 0
  foreach c {SH_SIDE CORE DDR_SLC SH_DDR PIPE_DDR_STAT0 PIPE_DDR_STAT1} {
    set got [get_cells -quiet $c]
    puts $fh "cell $c: [expr {$got ne {} ? {present} : {MISSING}}]"
    if {$got eq ""} { incr missing }
  }
  set lanes [llength [get_cells -quiet -hier -filter {REF_NAME == mem_lane || ORIG_REF_NAME == mem_lane}]]
  puts $fh "lanes (mem_lane cells): $lanes"
  close $fh
  set fh [open $out/elab.txt]; puts "LOCAL_CHECK_ELAB\n[read $fh]"; close $fh
  if {$missing} { error "cells named in small_shell_cl_pnr_user.xdc are missing" }
  return
}
if {$stage eq "lane"} {
  # the lane's data width: 512 (the DDR4, image 1) or 256 (an HBM port, split 3); environment LANE_DW
  set ldw 512; if {[info exists ::env(LANE_DW)]} { set ldw $::env(LANE_DW) }
  set src [snapshot_decoder $rtl $out [list $f2/mem_lane.sv]]
  prov_write $out "mem_lane AW=64 DW=$ldw BURST=16 WOUT=8 out of context, part $part, period $period ns" provenance_lane.txt
  read_verilog -sv $src
  set fh [open $out/lane_clock.xdc w]
  puts $fh "create_clock -period $period -name clk \[get_ports clk\]"
  close $fh
  read_xdc $out/lane_clock.xdc
  synth_design -top mem_lane -part $part -mode out_of_context -generic AW=64 -generic DW=$ldw -generic BURST=16 -generic WOUT=8
  report_utilization -file $out/utilization_lane.rpt
  write_edif -force $out/lane.edf
  return
}
if {$stage eq "synth"} {
  set src [snapshot_decoder $rtl $out [concat $glue [list $f2/sim/mem_lane_stub.sv $f2/f2_core.sv]]]
  prov_write $out "f2_core NL=$n out of context, part $part, period $period ns, lanes from lane.edf"
  if {![file exists $out/lane.edf] || [prov_id $out provenance_lane.txt] ne [prov_id $out] ||
      [file mtime $out/lane.edf] < [file mtime $out/provenance_lane.txt]} {
    error "provenance: lane.edf ([prov_id $out provenance_lane.txt]) is not from this commit ([prov_id $out]): run the lane stage again"
  }
  set fh [open $out/clock.xdc w]
  puts $fh "create_clock -period $period -name clk \[get_ports clk\]"
  close $fh
  read_xdc $out/clock.xdc
  read_verilog -sv $src
  synth_design -top f2_core -part $part -mode out_of_context -generic NL=$n
  foreach c [get_cells -hier -filter {IS_BLACKBOX}] { update_design -cells $c -from_file $out/lane.edf }
  if {[llength [get_cells -hier -filter {IS_BLACKBOX}]]} { error "lanes left as black boxes" }
  report_utilization -file $out/utilization_synth.rpt
  write_checkpoint -force $out/post_synth.dcp
  return
}
if {$stage eq "place"} {
  prov_stage $out $out/post_synth.dcp; open_checkpoint $out/post_synth.dcp
  opt_design
  place_design -directive ExtraTimingOpt
  phys_opt_design -directive AggressiveExplore
  report_timing_summary -max_paths 10 -file $out/timing_place.rpt
  write_checkpoint -force $out/post_place.dcp
  return
}
if {$stage eq "route"} {
  prov_stage $out $out/post_place.dcp; open_checkpoint $out/post_place.dcp
  route_design -directive AggressiveExplore
  phys_opt_design -directive AggressiveExplore
  write_checkpoint -force $out/post_route.dcp
  report_timing_summary -max_paths 10 -file $out/timing.rpt
  report_timing -max_paths 1000 -nworst 1 -unique_pins -slack_lesser_than 0 -file $out/failing.rpt
  report_utilization -file $out/utilization.rpt
  report_utilization -hierarchical -hierarchical_depth 3 -file $out/utilization_hier.rpt
  set paths [get_timing_paths -setup -max_paths 20000 -nworst 1]
  set lane ""; set glue_p ""
  foreach p $paths {
    set in [expr {[string match "*/u_lane/*" [get_property STARTPOINT_PIN $p]] &&
                  [string match "*/u_lane/*" [get_property ENDPOINT_PIN $p]]}]
    if {$in && $lane eq ""} { set lane $p }
    if {!$in && $glue_p eq ""} { set glue_p $p }
    if {$lane ne "" && $glue_p ne ""} break
  }
  set fh [open $out/summary.txt w]
  puts $fh [prov_id $out]
  puts $fh "part $part lanes $n period_ns $period"
  foreach {name p} [list overall [lindex $paths 0] lane $lane glue $glue_p] {
    if {$p eq ""} { puts $fh "$name none"; continue }
    set s [get_property SLACK $p]
    set f [expr {$s < 0 ? [format %.1f [expr {1000.0 / ($period - $s)}]] : "met"}]
    puts $fh "$name slack_ns $s fmax_mhz $f levels [get_property LOGIC_LEVELS $p]\
      from [get_property STARTPOINT_PIN $p] to [get_property ENDPOINT_PIN $p]"
    report_timing -of_objects $p -file $out/worst_$name.rpt
  }
  puts $fh "hold_slack_ns [get_property SLACK [get_timing_paths -hold -max_paths 1 -nworst 1]]"
  close $fh
  set fh [open $out/summary.txt]; puts "LOCAL_CHECK_SUMMARY\n[read $fh]"; close $fh
  return
}
error "stage must be elab, lane, synth, place or route"
