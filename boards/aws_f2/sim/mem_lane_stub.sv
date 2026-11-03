// mem_lane_stub.sv - mem_lane (../mem_lane.sv) as a black box, for the bottom-up synthesis in ../cl_jpeg/local_check.tcl:
// the core is synthesized with these empty lanes, then each is filled with the netlist of one lane synthesized on its
// own. The ports must match mem_lane.sv.
(* black_box *)
module mem_lane #(
  parameter int AW    = 64,
  parameter int DW    = 512,          // AXI data width in bits: 256 or 512
  parameter int BURST = 16,           // beats per burst, at most (16 keeps AXI3 slaves happy)
  parameter int WOUT  = 8             // write bursts in flight, at most
) (
  input  logic          clk,
  input  logic          rst,
  // job (sampled at an accepted start)
  input  logic          start,        // pulse: begin a job (ignored while busy)
  input  logic          job_abort,        // pulse: end the running job (see the header)
  input  logic [AW-1:0] in_addr,
  input  logic [31:0]   in_len,       // bytes of the file
  input  logic [AW-1:0] out_addr,
  input  logic [31:0]   out_max,      // bytes of room for records (a multiple of DW/8)
  output logic          busy,
  output logic          done,         // the job is over, results valid until the next start
  output logic [12:0]   res_err,      // the decoder's error bits at frame_done
  output logic          res_ovf,      // records beyond out_max were dropped
  output logic          res_axi_err,  // an AXI response other than OKAY
  output logic          res_abort,    // the job was aborted
  output logic [31:0]   res_cycles,   // clocks from start to frame_done
  output logic [31:0]   res_in_wait,  // of them: the decoder asked for input and had none
  output logic [31:0]   res_out_wait, // of them: an output beat waited for the writer
  output logic [31:0]   res_pixels,
  output logic [31:0]   res_records,
  output logic [63:0]   res_hash,
  output logic [15:0]   res_w,
  output logic [15:0]   res_h,
  // AXI4 read master
  output logic          arvalid,
  input  logic          arready,
  output logic [AW-1:0] araddr,
  output logic [7:0]    arlen,
  output logic [2:0]    arsize,
  output logic [1:0]    arburst,
  input  logic          rvalid,
  output logic          rready,
  input  logic [DW-1:0] rdata,
  input  logic          rlast,
  input  logic [1:0]    rresp,
  // AXI4 write master
  output logic          awvalid,
  input  logic          awready,
  output logic [AW-1:0] awaddr,
  output logic [7:0]    awlen,
  output logic [2:0]    awsize,
  output logic [1:0]    awburst,
  output logic          wvalid,
  input  logic          wready,
  output logic [DW-1:0] wdata,
  output logic [DW/8-1:0] wstrb,
  output logic          wlast,
  input  logic          bvalid,
  output logic          bready,
  input  logic [1:0]    bresp
);
endmodule
