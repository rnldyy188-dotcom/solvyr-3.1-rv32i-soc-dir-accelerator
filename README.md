# Solvyr-3 — RV32I Pipelined RISC-V Mini-SoC with DIR Accelerator on Artix-7

Solvyr-3 is a synthesizable 32-bit RISC-V mini-SoC written in Verilog, built as a
portfolio-level RTL project spanning digital IC design, computer architecture,
FPGA implementation, and hardware-accelerator design. It pairs a 5-stage in-order
RV32I core (with machine-mode traps) and a custom memory-mapped SoC fabric with a
workload-specific **DIR accelerator**: externally a 2D windowed image/depth
filter, internally a DSP48E1-based streaming multiply-accumulate (dot-product)
engine. The target is an AMD/Xilinx **Artix-7** board (Vivado flow).

```
                         Artix-7 FPGA Fabric
  ┌───────────────────────────────────────────────────────────────────────┐
  │  clk_reset (BUFG / opt. MMCM, sync reset)                              │
  │                                                                        │
  │   ┌───────────────┐  fetch   ┌──────────────┐                          │
  │   │ Solvyr-3 Core │─────────▶│ Instr BRAM   │ (true dual-port)         │
  │   │ IF ID EX MEM  │◀── instr │ portA fetch  │◀── portB (data/loader)   │
  │   │ WB + CSR/trap │          └──────────────┘            ▲             │
  │   └──────┬────────┘                                      │             │
  │   data   │  custom bus (valid/ready/we/addr/wdata/rdata/byte_en/error) │
  │          ▼                                               │             │
  │   ┌───────────────────────── mm_interconnect ───────────┴───────────┐ │
  │   │  s0 IMEM   s1 DMEM   s2 GPIO   s3 Timer   s4 UART   s5 ACC-regs  │ │
  │   │                                                     s6 ACC-scratch│ │
  │   └───┬─────────┬─────────┬─────────┬─────────┬──────────────┬──────┘ │
  │       ▼         ▼         ▼         ▼         ▼              ▼         │
  │   Data BRAM   GPIO      Timer     UART     DIR Accelerator (FSM +      │
  │             LED/SW/BTN  (irq)   TX/RX/dbg  DSP48E1 MAC + scratchpad)   │
  │                           │                     │  irq                 │
  │                           └──────── interrupts ─┴──▶ CSR / trap unit   │
  │   Board I/O: LEDs · switches · buttons · UART · 7-seg (LVCMOS33)       │
  └───────────────────────────────────────────────────────────────────────┘
```

## What's in the box

| Area | Modules |
|---|---|
| **Core datapath** | `alu` · `regfile` · `imm_gen` · `decoder` · `control_unit` · `load_store_unit` · `branch_unit` |
| **Hazards** | `forwarding_unit` · `hazard_unit` · `pipeline_regs` (IF/ID, ID/EX, EX/MEM, MEM/WB) |
| **Traps** | `csr_file` (mstatus/mtvec/mepc/mcause/mtval/mie/mip + ECALL/EBREAK/MRET + exceptions/interrupts) |
| **Memory** | `imem_bram` (dual-port) · `dmem_bram` · `dpram_be` (accelerator scratchpad) |
| **Fabric** | `mm_interconnect` (custom bus, address decode) |
| **Peripherals** | `gpio` · `timer` · `uart` · `uart_rx_core` (8-N-1 receiver, shared with the boot loader) |
| **Accelerator** | `dir_accel` · `dsp_mac` (DSP48E1) |
| **Platform** | `clk_reset` · `seven_seg` · `prog_loader` (optional UART boot) |
| **Integration** | `solvyr3_core` · `solvyr3_soc` · `solvyr3_top` |

## CPU core

RV32I base integer ISA — 32-bit instructions, datapath, and byte-addressed
address space. Single-issue, in-order, scalar 5-stage pipeline:

```
IF  → ID  → EX  → MEM → WB
PC    decode  ALU/   load/   register
fetch regrd   branch store   writeback
      immgen  fwdmux  trap
      control         commit
```

Key microarchitecture choices:

- **Write-first register file** returns fresh write data on a same-cycle read,
  eliminating the WB→ID forwarding case. It has no reset clear, so it infers as
  LUT-based distributed RAM (saving ~1K flip-flops) and powers up to zero.
- **Forwarding** from EX/MEM and MEM/WB into the EX operand muxes, x0-guarded.
  The EX/MEM forward is *result-source aware*: JAL/JALR forward PC+4 and CSR
  reads forward the CSR value, not the raw ALU output.
- **Load-use hazard** detected in ID: stall PC + IF/ID, inject one ID/EX bubble.
- **Branch/jump resolved in EX**, static not-taken; taken control transfers flush
  the two younger instructions. Misaligned targets raise a precise exception.
- **Memory wait state on loads only.** A load holds the front end one cycle for
  the BRAM data; stores return nothing and complete in a single cycle, so they
  never stall. The data-bus request is a single-cycle pulse either way, so
  side-effecting peripherals fire exactly once.
- **Precise machine-mode traps** committed at a single point in MEM (details below).

RV32I coverage: all R/I ALU ops, LB/LH/LW/LBU/LHU, SB/SH/SW, BEQ/BNE/BLT/BGE/
BLTU/BGEU, JAL/JALR, LUI/AUIPC, ECALL/EBREAK/MRET, and the Zicsr CSR instructions.

## Traps, CSRs, and interrupts

`csr_file.v` implements the machine-mode CSRs (`mstatus`, `mtvec`, `mepc`,
`mcause`, `mtval`, `mie`, `mip`, `mscratch`, `misa`, cycle/instret counters) and
sequences every trap and MRET at the **MEM commit point** for precise, in-order
behaviour:

1. exception metadata (cause + tval) is generated where it is first known —
   illegal / ECALL / EBREAK in ID, instruction-address-misaligned in EX,
   load/store-address-misaligned in MEM — and carried down the pipeline;
2. at MEM the trapping instruction is squashed (no writeback, no memory write);
3. `mepc`/`mcause`/`mtval` are captured, `mstatus.MIE→MPIE`, and the PC is
   redirected to `mtvec`; all four pipeline registers flush;
4. **MRET** restores `MIE` and returns to `mepc`.

Supported exceptions: illegal instruction, instruction/load/store address
misaligned, ECALL, EBREAK. Interrupts: machine **timer** (`mie.MTIE`) and the
**DIR accelerator** done line (`mie.MEIE`, external), taken at a clean
instruction boundary with the global enable `mstatus.MIE`.

## Memory map

Decoded on address bits `[15:12]` (bits `[31:16]` must be zero, else a bus error):

| Range | Slave | Notes |
|---|---|---|
| `0x0000_0000–0x0FFF` | Instruction BRAM | dual-port: fetch + data/loader |
| `0x0000_1000–0x1FFF` | Data BRAM | byte-enabled, B/H/W access |
| `0x0000_2000–0x20FF` | GPIO | LED out, switch/button in |
| `0x0000_3000–0x30FF` | Timer | mtime/mtimecmp + interrupt |
| `0x0000_4000–0x40FF` | UART / Debug | 8-N-1 TX/RX |
| `0x0000_5000–0x50FF` | DIR accelerator registers | control/status/config |
| `0x0000_6000–0x6FFF` | DIR accelerator scratchpad | true dual-port |

The custom bus (`mem_valid/ready/we/addr/wdata/rdata/byte_en/error`) is a simple
single-master, single-outstanding protocol — deliberately *not* AXI.

## Peripherals

**GPIO** (`0x2000`): `LED_OUT` (0x00), `SW_IN` (0x04), `BTN_IN` (0x08); switch and
button inputs pass through 2-flop synchronizers.

**Timer** (`0x3000`): `MTIME` (0x00), `MTIMECMP` (0x04), `CTRL` (0x08:
EN/IE/ARLD), `STATUS` (0x0C: MATCH, write-1-to-clear). Raises `irq_timer` on
compare match; auto-reload gives periodic interrupts.

**UART** (`0x4000`): `TXDATA` (0x00), `RXDATA` (0x04), `STATUS` (0x08:
TX_BUSY/TX_READY/RX_VALID/RX_OVERRUN). 8-N-1 with a `CLK_HZ/BAUD` baud generator;
the program-load / debug-print / test-result path. The receive FSM is the
reusable `uart_rx_core` module, instantiated here and again in `prog_loader` so
there is a single receiver implementation (no duplicated logic).

## DIR accelerator

A memory-mapped DIR accelerator built around **DSP48E1-based MAC/convolution/
filtering hardware**. Externally it computes a *valid 2D convolution* of an
image/depth tile with a K×K kernel; internally each output pixel is the dot
product of the flattened window and kernel, accumulated in a signed 16×16 →
48-bit `dsp_mac` (DSP48E1). Blocks: register file, controller FSM, DSP MAC
datapath, accumulator, true-dual-port scratchpad (CPU + compute ports),
output/result registers, and interrupt logic.

The controller is **pipelined to one tap per cycle**: each cycle presents the
next scratchpad address while MACing the operand fetched the previous cycle,
hiding the BRAM read latency. (Both the coefficient load and the MAC stream are
pipelined.) This roughly halves the compute time versus an address-then-data
sequence — directly improving the benchmark speedup.

Registers (`0x5000`): `ACC_CONTROL` (0x00: START/IRQEN/SIGNED), `ACC_STATUS`
(0x04: BUSY/DONE/ERROR), `ACC_INPUT_BASE` (0x08), `ACC_OUTPUT_BASE` (0x0C),
`ACC_CONFIG` (0x10: width/height), `ACC_KERNEL_CONFIG` (0x14: K / shift /
coeff_base), `ACC_RESULT` (0x18), `ACC_INT_ACK` (0x1C).

Flow: the CPU loads the input tile and kernel into the scratchpad, programs the
registers, sets START, then polls DONE or takes the accelerator interrupt and
reads the output tile. Data format is one signed-16 sample per 32-bit word.

## Clocking and reset

`clk_reset.v` derives the single system clock from the board oscillator (direct
BUFG by default, optional MMCME2_BASE behind `SOLVYR3_USE_MMCM`) and produces a
clean **synchronous, active-high** reset via async-assert / sync-deassert plus a
stretch counter. On reset the PC is 0x0, the pipeline is invalidated, and CSR /
peripheral / accelerator state is cleared.

## Efficiency notes (PPA)

Deliberate optimizations for performance, power, and area:

- **Register file as distributed RAM.** No synchronous reset clear, so the 2R/1W
  array infers LUTRAM instead of ~1024 flip-flops, also removing the reset
  fan-out. x0=0 is enforced by the read mux; power-up state is 0 via `initial`.
- **Stores don't stall.** The memory wait state exists only to capture returned
  load data; stores complete in a single cycle, cutting one cycle per store
  (≈10–15 % of instructions) from CPI.
- **Pipelined accelerator (1 cycle/tap).** Streaming the scratchpad reads hides
  the BRAM latency and roughly halves the DIR accelerator's compute time vs. an
  address-then-data loop — the largest single efficiency win and the one that
  most improves the documented speedup.
- **Single DSP48E1 MAC + true-dual-port scratchpad** keep the accelerator's area
  small; the MAC is the only multiplier in the whole SoC (the RV32I core has no
  hardware multiplier, which is exactly why software MACs are slow — see `bench/`).
- **Lean dead-code removal**: unused ALU condition flags and redundant control
  were dropped during a polish pass.

## Repository layout

```
rtl/          all synthesizable Verilog (core, fabric, peripherals, accelerator)
tb/           self-checking testbenches + generated *.hex programs
bench/        performance benchmark: software RV32I vs DIR accelerator (+ host ref)
tools/        rv32i.py (assembler + ISA reference), accel_model.py, gen_bench.py, lint.py, bin2hex.py
sw/           C/asm demo: demo.c, startup.s, solvyr3.ld, solvyr3.h, Makefile, demo.hex (+ blink.hex backup)
constraints/  solvyr3_artix7.xdc (Nexys A7-class pinout, LVCMOS33, timing)
vivado/       build.tcl (synth→impl→bitstream→reports), sim.tcl (xsim)
run_sim.sh    Icarus Verilog build/run for every testbench
```


## Simulation

Requires Icarus Verilog (`iverilog` + `vvp`). Test programs are generated by the
Python assembler.

```bash
python3 tools/rv32i.py     # (re)generate tb/*.hex and sw/blink.hex (test programs)
./run_sim.sh prim          # ALU/regfile/imm/decoder/control/lsu/branch/fwd/hazard
./run_sim.sh system        # full pipeline: forwarding, load-use, branch, memory
./run_sim.sh csr           # ECALL + MRET round trip
./run_sim.sh irq           # timer interrupt entry
./run_sim.sh gpio          # CPU → interconnect → GPIO
./run_sim.sh timer         # timer compare-match + interrupt
./run_sim.sh uart          # UART loopback
./run_sim.sh accel         # DIR accelerator 2D convolution
./run_sim.sh bench         # performance: software RV32I vs accelerator (cycles)
./run_sim.sh all
```

Expected system-test result: `x1=5 x2=10 x3=15 x4=10 x5=0x1000 x6=15 x7=20 x8=42`,
`dmem[1]=15`. Expected accelerator output (5×5 ramp ⊛ 3×3 "X" kernel):
`[30 35 40 / 55 60 65 / 80 85 90]`.

## Performance

`bench/` measures the DIR accelerator against the same workload in software on
the plain RV32I core (no hardware multiplier) — the controlled software-vs-
hardware comparison, both timed with `rdcycle` on the same clock. `./run_sim.sh
bench` prints software cycles, accelerator cycles, and the speedup; `bench/bench.c`
runs the full C 2D-convolution version and `bench/host_ref.c` gives a desktop-CPU
reference. See `bench/README.md` for the methodology and a results table.

## FPGA build (Vivado)

```bash
vivado -mode batch -source vivado/build.tcl                       # Nexys A7-100T
vivado -mode batch -source vivado/build.tcl -tclargs <part> <hex> # other board
```

The flow reads all RTL + the XDC, runs synthesis and implementation, writes
`vivado/out/solvyr3.bit`, and emits utilization (LUT/FF/BRAM/DSP48E1) and timing
reports. The instruction BRAM is initialized from `sw/demo.hex` via `$readmemh`. By
default that image is a simple LED counter, so on the board the LEDs count and the
7-segment display shows the live program counter. Build the C demo (`sw/demo.c`,
needs a RISC-V toolchain) and rebuild to get the full behaviour — a UART banner, the
accelerator result printed over serial, and a timer-interrupt LED animation.

## Software demo

`sw/` builds a bare-metal demo with a RISC-V toolchain (`make` in `sw/`,
`CROSS=riscv32-unknown-elf-`). It prints a banner over UART, runs the accelerator
and prints the output tile, enables a periodic timer interrupt that animates the
LEDs, and mirrors the switches. A toolchain-free `demo.hex` (LED counter) is
checked in so synthesis works immediately.

## Verification status

The RTL was developed alongside a Python **golden reference** (`tools/rv32i.py`,
an RV32I assembler + ISA simulator) and a **cycle-accurate accelerator model**
(`tools/accel_model.py`); both reproduce the testbench expected values exactly
(register results, trap/MRET behaviour, and the convolution output tile). All
sources pass the structural lint (`tools/lint.py`). The self-checking Verilog
testbenches encode those golden values — run `./run_sim.sh all` under Icarus (or
`vivado/sim.tcl` under xsim) to confirm cycle-level behaviour, then check timing
in Vivado before relying on synthesis numbers.

## Verification plan

- **Unit:** ALU, register file, immediate generator, control unit, load/store
  unit, hazard unit, forwarding unit, CSR file, interconnect, DIR accelerator.
- **System:** RV32I arithmetic, branch/jump, load/store, hazard/forwarding,
  exception/trap, timer interrupt, and DIR accelerator programs.
- **FPGA:** LED/switch GPIO demo, UART debug output, accelerator busy/done on
  LEDs, Vivado timing closure, and a resource report (LUTs, FFs, BRAM, DSP48E1).
```
