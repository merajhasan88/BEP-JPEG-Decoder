# Makefile - AWS's XSIM testbench with the BEP-JPEG CL, on AWS's build image (after source hdk_setup.sh, with CL_DIR set):
#   make TEST=cl_jpeg_test DONT_GENERATE_FILE_LIST=1
# The HDK's flow does the rest (header, the shell model, AWS's DDR4 simulation model, compile, run).
ifndef HDK_COMMON_DIR
  $(error HDK_COMMON_DIR is not set: source the aws-fpga hdk_setup.sh first)
endif
include $(HDK_COMMON_DIR)/verif/tb/scripts/Makefile.header.inc
C_FILES = $(C_SDK_USR_UTILS_DIR)/sh_dpi_tasks.c $(C_COMMON_DIR)/src/fpga_pci_sv.c
C_INCLUDE_DIRS = $(C_SDK_USR_INC_DIR) $(C_SDK_USR_UTILS_DIR) $(C_COMMON_DIR)/include $(C_COMMON_DIR)/src $(C_INC_DIR) $(C_HEADER_INCLUDE_DIR)
REGRESSION_TEST_LIST = ${DEFAULT_REGRESSION_TEST_LIST_COLLECTION}
regression: run_regression log_regression_results print_regression_results
include $(HDK_COMMON_DIR)/verif/tb/scripts/Makefile.common.inc
