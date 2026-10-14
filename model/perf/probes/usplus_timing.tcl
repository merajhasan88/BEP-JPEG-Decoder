# Timing check of the wide decoder lanes of the batched harness (boards/acorn_cle215/bench_lane.sv) on an
# UltraScale+ FPGA, out of context: an estimate of the decoders' clock on AWS F2's xcvu47p-fsvh2892-2-e,
# which the free Vivado licence does not cover, from a Kintex UltraScale+ part of the same speed grade
# that it does. Synthesis, placement and routing with the high-effort directives of
# boards/acorn_cle215/build_batch.tcl (VIVADO_EFFORT=high), no bitstream.
#   vivado -mode batch -source usplus_timing.tcl -tclargs <lanes> <period_ns> <out_dir> [stage]
# stage: synth, place, route or all (default), as build_batch.tcl (separate processes need less memory).
# One lane: the batched harness as on the board (usplus_batch_top.sv, uart_batch_core.sv). More lanes:
# usplus_lanes_top.sv, the lanes without the harness's UART core, whose synthesis alone grew past 9 GB
# with 15 lanes; the stage lane comes first, synthesizing one lane on its own, and its netlist
# (lane.edf) fills every lane of the top, which is synthesized with the lanes as black boxes
# (usplus_lane_stub.sv), so that synthesis needs about what one decoder needs.
# Environment: VIVADO_PART (default xcku5p-ffvb676-2-e), VIVADO_THREADS. The route stage writes the
# reports and summary.txt: the worst setup path overall, inside a decoder (start and end in u_dut) and
# outside the decoders (the harness), each with its slack and, when it fails, Fmax = 1 / (period - slack).
# The stages that read sources (lane, synth) copy them into <out_dir>/src and check them against the commit checked
# out first (../../../boards/acorn_cle215/provenance.tcl; BUILD_UNCOMMITTED=1 probes uncommitted files, recorded as
# such): provenance_lane.txt and provenance.txt; the synth stage stops if lane.edf comes from another commit, and
# summary.txt's first line names the commit.
if {[info exists ::env(VIVADO_THREADS)]} { set_param general.maxThreads $::env(VIVADO_THREADS) }
set n [lindex $argv 0]; set period [lindex $argv 1]; set out [lindex $argv 2]
set stage [lindex $argv 3]; if {$stage eq ""} { set stage all }
set part xcku5p-ffvb676-2-e
if {[info exists ::env(VIVADO_PART)]} { set part $::env(VIVADO_PART) }
set here  [file dirname [file normalize [info script]]]
set root  [file normalize $here/../../..]
set rtl   $root/rtl
set acorn $root/boards/acorn_cle215
source $acorn/provenance.tcl
prov_init [info script]
file mkdir $out

# the decoder's sources in compile order (rtl/files.f) and the other files given, copied into $out/src and checked
# against the commit (provenance.tcl); returns the copies
proc snapshot_decoder {rtl out files} {
  prov_snapshot $out [list $rtl/files.f]
  set dec {}
  foreach f [prov_list [prov_path $rtl/files.f]] { lappend dec $rtl/$f }
  return [prov_snapshot $out [concat $dec $files]]
}

if {$stage eq "lane"} {
  set src [snapshot_decoder $rtl $out [list $acorn/bench_lane.sv]]
  prov_write $out "bench_lane FAST=2 out of context, part $part, period $period ns" provenance_lane.txt
  read_verilog -sv $src
  set fh [open $out/lane_clock.xdc w]
  puts $fh "create_clock -period $period -name clk \[get_ports clk\]"
  puts $fh "create_clock -period $period -name dclk \[get_ports dclk\]"
  close $fh
  read_xdc $out/lane_clock.xdc
  synth_design -top bench_lane -part $part -mode out_of_context -generic FAST=2
  report_utilization -file $out/utilization_lane.rpt
  write_edif -force $out/lane.edf
  return
}
if {$stage eq "synth" || $stage eq "all"} {
  set fh [open $out/clock.xdc w]
  puts $fh "create_clock -period $period -name clk \[get_ports clk_in\]"
  close $fh
  read_xdc $out/clock.xdc
  if {$n > 1} {
    # N lanes without the UART core (usplus_lanes_top.sv), filled from lane.edf (made from the same commit)
    set src [prov_snapshot $out [list $here/usplus_lane_stub.sv $here/usplus_lanes_top.sv]]
    prov_write $out "usplus_lanes_top N=$n out of context, part $part, period $period ns, lanes from lane.edf"
    if {![file exists $out/lane.edf] || [prov_id $out provenance_lane.txt] ne [prov_id $out] ||
        [file mtime $out/lane.edf] < [file mtime $out/provenance_lane.txt]} {
      error "provenance: lane.edf ([prov_id $out provenance_lane.txt]) is not from this commit ([prov_id $out]): run the lane stage again"
    }
    read_verilog -sv $src
    synth_design -top usplus_lanes_top -part $part -mode out_of_context -generic N=$n
  } else {
    # one lane in the batched harness (usplus_batch_top.sv)
    set src [snapshot_decoder $rtl $out [list $acorn/bench_lane.sv $acorn/uart_batch_core.sv $here/usplus_batch_top.sv]]
    prov_write $out "usplus_batch_top N=$n out of context, part $part, period $period ns"
    read_verilog -sv $src
    set clk_hz [expr {int(round(1000.0 / $period)) * 1000000}]
    synth_design -top usplus_batch_top -part $part -mode out_of_context \
      -generic N=$n -generic FAST=2 -generic CLK_HZ=$clk_hz
  }
  if {$n > 1} {
    foreach c [get_cells -hier -filter {IS_BLACKBOX}] { update_design -cells $c -from_file $out/lane.edf }
    if {[llength [get_cells -hier -filter {IS_BLACKBOX}]]} { error "lanes left as black boxes" }
  }
  report_utilization -file $out/utilization_synth.rpt
  if {$stage eq "synth"} { write_checkpoint -force $out/post_synth.dcp; return }
}
if {$stage eq "place" || $stage eq "all"} {
  if {$stage eq "place"} { prov_stage $out $out/post_synth.dcp; open_checkpoint $out/post_synth.dcp }
  opt_design
  place_design -directive ExtraTimingOpt
  phys_opt_design -directive AggressiveExplore
  report_timing_summary -max_paths 10 -file $out/timing_place.rpt
  if {$stage eq "place"} { write_checkpoint -force $out/post_place.dcp; return }
}
if {$stage eq "route" || $stage eq "all"} {
  if {$stage eq "route"} { prov_stage $out $out/post_place.dcp; open_checkpoint $out/post_place.dcp }
  route_design -directive AggressiveExplore
  phys_opt_design -directive AggressiveExplore
  write_checkpoint -force $out/post_route.dcp
  report_timing_summary -max_paths 10 -file $out/timing.rpt
  report_timing -max_paths 1000 -nworst 1 -unique_pins -slack_lesser_than 0 -file $out/failing.rpt
  report_clock_utilization -file $out/clock_utilization.rpt
  report_utilization -file $out/utilization.rpt
  report_utilization -hierarchical -hierarchical_depth 4 -file $out/utilization_hier.rpt
  report_design_analysis -congestion -file $out/congestion.rpt

  # the worst setup path overall, inside a decoder and outside the decoders
  set paths [get_timing_paths -setup -max_paths 20000 -nworst 1]
  set dec ""; set har ""
  foreach p $paths {
    set in [expr {[string match "*/u_dut/*" [get_property STARTPOINT_PIN $p]] &&
                  [string match "*/u_dut/*" [get_property ENDPOINT_PIN $p]]}]
    if {$in && $dec eq ""} { set dec $p }
    if {!$in && $har eq ""} { set har $p }
    if {$dec ne "" && $har ne ""} break
  }
  set fh [open $out/summary.txt w]
  puts $fh [prov_id $out]
  puts $fh "part $part lanes $n period_ns $period"
  foreach {name p} [list overall [lindex $paths 0] decoder $dec harness $har] {
    if {$p eq ""} { puts $fh "$name none"; continue }
    set s [get_property SLACK $p]
    set f [expr {$s < 0 ? [format %.1f [expr {1000.0 / ($period - $s)}]] : "met"}]
    puts $fh "$name slack_ns $s fmax_mhz $f levels [get_property LOGIC_LEVELS $p]\
      from [get_property STARTPOINT_PIN $p] to [get_property ENDPOINT_PIN $p]"
    report_timing -of_objects $p -file $out/worst_$name.rpt
  }
  puts $fh "hold_slack_ns [get_property SLACK [get_timing_paths -hold -max_paths 1 -nworst 1]]"
  close $fh
  set fh [open $out/summary.txt]; puts "USPLUS_SUMMARY\n[read $fh]"; close $fh
}
