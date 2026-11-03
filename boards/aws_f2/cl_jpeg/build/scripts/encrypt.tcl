# encrypt.tcl - sourced by the HDK's build_all.tcl: copies every source of the CL into src_post_encryption
# (and encrypts them there with AWS's key unless the build runs with --no-encrypt). Our own file list, read from
# the repository: the CL's design/ folder, the F2 harness (boards/aws_f2) and the decoder (rtl/, in rtl/files.f
# order). The HDK's own files (cl_ports.vh, sh_ddr) are read by the HDK's synth_cl_header.tcl.
set repo_dir [file normalize ${CL_DIR}/../../..]
if {[llength [glob -nocomplain -dir $src_post_enc_dir *]] != 0} {
  eval file delete -force [glob $src_post_enc_dir/*]
}
set cl_src {}
set fl [open ${repo_dir}/rtl/files.f r]
foreach line [split [read $fl] "\n"] {
  set line [string trim $line]
  if {$line eq "" || [string match "//*" $line]} { continue }
  lappend cl_src ${repo_dir}/rtl/$line
}
close $fl
foreach f {f2_slices.sv f2_pcis.sv f2_axi_mux.sv f2_regs.sv mem_lane.sv f2_core.sv} {
  lappend cl_src ${repo_dir}/boards/aws_f2/$f
}
foreach f [lsort [glob ${CL_DIR}/design/*.sv ${CL_DIR}/design/*.vh]] { lappend cl_src $f }
foreach f $cl_src {
  if {![file exists $f]} { error "encrypt.tcl: missing source $f" }
  file copy -force $f $src_post_enc_dir
}
exec chmod +w {*}[glob ${src_post_enc_dir}/*]
# the read order for synth_cl_jpeg.tcl (the package first)
set cl_src_order {}
foreach f $cl_src { lappend cl_src_order ${src_post_enc_dir}/[file tail $f] }
if {$ENCRYPT} {
  print "Encryption enabled. Encrypting HDL files."
  encrypt -k ${HDK_SHELL_DIR}/build/scripts/vivado_keyfile.txt -lang verilog -quiet [glob -nocomplain -- ${src_post_enc_dir}/*.{v,sv,vh,inc}]
} else {
  print "Encryption disabled."
}
