// cl_id_defines.vh - the PCIe IDs of the BEP-JPEG F2 image (read by the HDK's build script into the AFI manifest;
// keep the exact form `define NAME 32'hXXXX_XXXX: the script splits the value at the underscore).
// CL_SH_ID0: [31:16] device ID, [15:0] vendor ID. With Amazon's vendor ID 0x1D0F the device ID must be 0xF000-0xF0FF.
// CL_SH_ID1: [31:16] subsystem ID, [15:0] subsystem vendor ID (not zero).
`ifndef CL_ID_DEFINES
`define CL_ID_DEFINES
`define CL_SH_ID0 32'hF0A1_1D0F
`define CL_SH_ID1 32'h1D51_FEDC
`endif
