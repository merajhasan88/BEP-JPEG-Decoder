// jpeg_checker_bind.sv - puts jpeg_checker (jpeg_checker.sv) into every jpeg_decoder of a simulation build
// whose top is not tb_jpeg.sv: the Verilator C++ harnesses (tb/Makefile) and the F2 harness (boards/aws_f2/sim).
bind jpeg_decoder jpeg_checker #(.NPIX(NPIX)) u_jpeg_checker (.*);
