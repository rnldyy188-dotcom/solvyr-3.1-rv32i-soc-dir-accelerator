# ============================================================================
# Makefile  -  Build the Solvyr-3 demo with a riscv32 bare-metal toolchain
#
#   make            # build demo.elf / demo.bin / demo.hex / demo.lst
#   make clean
#
# Requires a RISC-V GCC (rv32i / ilp32). The prefix is auto-detected; override
# with e.g. `make CROSS=riscv64-unknown-elf-` (multilib gcc also works).
#
# demo.hex is the $readmemh image baked into the instruction BRAM by the FPGA
# build (vivado/build.tcl) -- i.e. the program the chip actually runs. It ships
# as a simple LED counter so synthesis works without a toolchain; `make` here
# overwrites it with the compiled C demo. (The LED-counter source is kept in
# sw/blink.hex by tools/rv32i.py; restore it with `cp blink.hex demo.hex`.)
# ============================================================================
# Auto-detect a RISC-V bare-metal GCC; fall back to a real name for clear errors.
CROSS  ?= $(shell for p in riscv64-unknown-elf- riscv32-unknown-elf- riscv-none-elf-; do command -v $${p}gcc >/dev/null 2>&1 && { printf '%s' $$p; break; }; done)
CROSS  := $(if $(CROSS),$(CROSS),riscv64-unknown-elf-)
CC      = $(CROSS)gcc
OBJCOPY = $(CROSS)objcopy
OBJDUMP = $(CROSS)objdump

ARCH    = -march=rv32izicsr -mabi=ilp32
CFLAGS  = $(ARCH) -ffreestanding -nostdlib -nostartfiles -O2 -Wall -Wextra \
          -fno-builtin -ffunction-sections -fdata-sections
LDFLAGS = $(ARCH) -nostdlib -nostartfiles -T solvyr3.ld -Wl,--gc-sections

OBJS = startup.o demo.o

all: demo.hex demo.lst

startup.o: startup.s
	$(CC) $(CFLAGS) -c $< -o $@

demo.o: demo.c solvyr3.h
	$(CC) $(CFLAGS) -c $< -o $@

demo.elf: $(OBJS) solvyr3.ld
	$(CC) $(LDFLAGS) $(OBJS) -o $@

demo.bin: demo.elf
	$(OBJCOPY) -O binary --only-section=.text --only-section=.rodata \
	    --only-section=.data $< $@

demo.hex: demo.bin
	python3 ../tools/bin2hex.py $< $@

demo.lst: demo.elf
	$(OBJDUMP) -d -S $< > $@

clean:
	rm -f $(OBJS) demo.elf demo.bin demo.lst

.PHONY: all clean
