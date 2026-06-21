# ============================================================================
# Solvyr-3 top-level convenience targets.
#
# The real build logic lives in the sub-Makefiles (sw/, bench/) and the scripts
# (build_fpga.sh, run_sim.sh). These are just shortcuts; the OFFICIAL flows are
# unchanged (official bitstream is still `./build_fpga.sh bench` -> solvyr3.bit).
# ============================================================================
# PORT: serial port for `make load`, e.g. COM3 or /dev/ttyUSB1 (no default).
# PYTHON: use PYTHON=python if `python3` is not on your PATH.
# (Keep these comments on their own lines -- a trailing inline comment would
#  leave whitespace in the value and break the empty-PORT check below.)
PORT   ?=
PYTHON ?= python3

.PHONY: help load loader-bit sim

help:
	@echo "Solvyr-3 convenience targets:"
	@echo "  make load PORT=COM3   build bench_c.hex and reload it over UART."
	@echo "                        Requires the loader bitstream + SW15=ON + CPU_RESETN,"
	@echo "                        and TeraTerm CLOSED (the script needs the COM port)."
	@echo "  make loader-bit       one-time: build solvyr3_loader.bit (USE_LOADER=1)."
	@echo "  make sim              run the simulation benchmark (./run_sim.sh bench)."
	@echo ""
	@echo "  Official build is unchanged:  ./build_fpga.sh bench  ->  solvyr3.bit"
	@echo "  Details: docs/UART_LOADER.md"

# Forward to bench/ (which builds bench_c.hex first, then calls tools/uart_load.py).
load:
	@$(MAKE) -C bench load PORT="$(PORT)" PYTHON="$(PYTHON)"

# One-time: build the loader-enabled bitstream (separate from official solvyr3.bit).
loader-bit:
	./build_fpga.sh bench --loader

sim:
	./run_sim.sh bench
