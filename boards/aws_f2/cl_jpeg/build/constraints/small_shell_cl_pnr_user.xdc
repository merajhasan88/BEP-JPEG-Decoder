# small_shell_cl_pnr_user.xdc - placement of the BEP-JPEG CL in the small shell (read by the HDK's build_level_1_cl.tcl).
# The shell's OCL and PCIS ports are on the middle die (SLR1), the DDR4 DIMM's pins on the top die (SLR2), as in AWS's
# examples (cl_mem_perf, cl_dram_hbm_dma: SH_DDR in SLR2). The register stage next to the shell (SH_SIDE: OCL and PCIS
# slices, the core's reset) stays in SLR1; the core (15 lanes, the multiplexer, the registers), its slice to the DDR4
# and the DDR4 controller with its statistics pipes go to SLR2, so the only die crossings are register to register.
create_pblock pblock_CL_SLR2
resize_pblock pblock_CL_SLR2 -add {CLOCKREGION_X0Y8:CLOCKREGION_X7Y11}
set_property parent pblock_CL [get_pblocks pblock_CL_SLR2]
add_cells_to_pblock pblock_CL_SLR2 [get_cells [list WRAPPER/CL/SH_DDR WRAPPER/CL/PIPE_DDR_STAT0 WRAPPER/CL/PIPE_DDR_STAT1 \
                                                    WRAPPER/CL/DDR_SLC WRAPPER/CL/CORE]]

create_pblock pblock_CL_SLR1
resize_pblock pblock_CL_SLR1 -add {CLOCKREGION_X0Y4:CLOCKREGION_X3Y7}
set_property parent pblock_CL [get_pblocks pblock_CL_SLR1]
add_cells_to_pblock pblock_CL_SLR1 [get_cells [list WRAPPER/CL/SH_SIDE]]
