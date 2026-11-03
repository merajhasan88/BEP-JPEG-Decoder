# cl_timing_user.xdc - timing constraints of the BEP-JPEG CL. Everything runs on clk_main_a0 (250 MHz, defined by the
# HDK's generated_cl_clocks_aws.xdc); the CL has no other clock and no asynchronous path of its own.
set clk_main_a0 [get_clocks -of_objects [get_ports clk_main_a0]]
