// cl_jpeg_defines.vh - the CL's name (used by AWS's testbench to instantiate it) and the source commit.
// JPEG_F2_COMMIT: the first 8 hex digits of the commit the image is built from; written by ../build_on_aws.sh into
// the build's copy (0 here: not stamped). The host reads it at OCL 0x030 (f2_regs.sv, COMMIT).
`ifndef CL_JPEG_DEFINES
`define CL_JPEG_DEFINES
`define CL_NAME cl_jpeg
`ifndef JPEG_F2_COMMIT
`define JPEG_F2_COMMIT 32'h00000000
`endif
`endif
