# ============================================================================
# Makefile  -  Build the Solvyr-3 performance benchmark
#
#   make            # build bench_c.hex (the C benchmark) + host_ref (your PC)
#   make bench_c.hex# just the RISC-V program image
#   make host_ref   # just the host reference
#   make run-host   # build + run the host reference
#   make load PORT=COM3   # build bench_c.hex, then load it over UART (see below)
#   make clean
#
# IMPORTANT — two different program files, on purpose:
#   bench.hex    : the checked-in 49-tap microbenchmark (from tools/gen_bench.py).
#                  Used by the SIMULATION (bench/tb_bench.v). Needs no toolchain.
#   bench_c.hex  : the full C 2D-convolution benchmark, built here. This is the
#                  one to bake into the FPGA bitstream to run on the REAL BOARD
#                  (it prints the result over UART). Building it does NOT touch
#                  bench.hex, so simulation keeps working.
#
# The toolchain prefix is auto-detected (rv64 multilib, rv32, or rv-none).
# Override explicitly if needed:  make CROSS=riscv64-unknown-elf-
# ============================================================================
# Auto-detect a RISC-V bare-metal GCC; fall back to a real name for clear errors.
CROSS  ?= $(shell for p in riscv64-unknown-elf- riscv32-unknown-elf- riscv-none-elf-; do command -v $${p}gcc >/dev/null 2>&1 && { printf '%s' $$p; break; }; done)
CROSS  := $(if $(CROSS),$(CROSS),riscv64-unknown-elf-)
CC      = $(CROSS)gcc
OBJCOPY = $(CROSS)objcopy
OBJDUMP = $(CROSS)objdump
HOSTCC ?= cc

# Host UART loader knobs (used only by `make load`).
#   PORT   : serial port, e.g. COM3 (Windows) or /dev/ttyUSB1  (no default)
#   PYTHON : use PYTHON=python if `python3` is not on your PATH
# (Comments are on their own lines: a trailing inline comment would make PORT
#  default to whitespace instead of empty, defeating the "PORT not set" check.)
PORT   ?=
PYTHON ?= python3

SW      = ../sw
ARCH    = -march=rv32izicsr -mabi=ilp32
# EXTRA_CFLAGS lets you flip the workload profile, e.g.
#   make EXTRA_CFLAGS=-DBENCH_40X=0   # reproduce the verified 11.4x (16x16 ⊛ 3x3)
CFLAGS  = $(ARCH) -ffreestanding -nostdlib -nostartfiles -O2 -Wall -Wextra \
          -fno-builtin -ffunction-sections -fdata-sections -I$(SW) $(EXTRA_CFLAGS)
LDFLAGS = $(ARCH) -nostdlib -nostartfiles -T $(SW)/solvyr3.ld -Wl,--gc-sections

all: bench_c.hex host_ref

startup.o: $(SW)/startup.s
	$(CC) $(CFLAGS) -c $< -o $@

bench.o: bench.c $(SW)/solvyr3.h
	$(CC) $(CFLAGS) -c $< -o $@

bench_c.elf: startup.o bench.o $(SW)/solvyr3.ld
	$(CC) $(LDFLAGS) startup.o bench.o -o $@

bench_c.bin: bench_c.elf
	$(OBJCOPY) -O binary --only-section=.text --only-section=.rodata \
	    --only-section=.data $< $@

bench_c.hex: bench_c.bin
	python3 ../tools/bin2hex.py $< $@

bench_c.lst: bench_c.elf
	$(OBJDUMP) -d -S $< > $@

host_ref: host_ref.c
	$(HOSTCC) -O2 -Wall host_ref.c -o host_ref

run-host: host_ref
	./host_ref

# ---- Fast UART program load (no FPGA rebuild) ------------------------------
# Builds bench_c.hex, then streams it to the on-chip loader via tools/uart_load.py.
# Prerequisites (one-time):  build a loader bitstream  (../build_fpga.sh bench --loader)
#                            program the FPGA with solvyr3_loader.bit
# Each load:  set SW15 = ON, press CPU_RESETN (loader waits), then run this.
# IMPORTANT: CLOSE TeraTerm / any serial monitor first -- the script needs the
# COM port, and only one program can hold it at a time.
#   make load PORT=COM3                 (Windows)
#   make load PORT=/dev/ttyUSB1         (Linux/macOS)
load: bench_c.hex
	@if [ -z "$(PORT)" ]; then \
	  echo "ERROR: set PORT, e.g.  make load PORT=COM3  (or PORT=/dev/ttyUSB1)"; \
	  exit 1; \
	fi
	@echo ">>> Close TeraTerm / any serial monitor first -- the loader needs $(PORT)."
	$(PYTHON) ../tools/uart_load.py "$(PORT)" bench_c.hex --monitor

clean:
	rm -f *.o bench_c.elf bench_c.bin bench_c.lst host_ref

.PHONY: all clean run-host load
