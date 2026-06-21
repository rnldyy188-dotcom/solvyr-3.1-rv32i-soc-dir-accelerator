// ============================================================================
// solvyr3_defs.vh  -  Shared definitions for the Solvyr-3 RV32I core
// Include with `include "solvyr3_defs.vh"
// ============================================================================
`ifndef SOLVYR3_DEFS_VH
`define SOLVYR3_DEFS_VH

// ---- Reset vector --------------------------------------------------------
`define RESET_PC          32'h0000_0000

// ---- A canonical NOP (addi x0, x0, 0) ------------------------------------
`define NOP_INSTR         32'h0000_0013

// ---- RV32I opcodes (instr[6:0]) ------------------------------------------
`define OP_LUI            7'b0110111
`define OP_AUIPC          7'b0010111
`define OP_JAL            7'b1101111
`define OP_JALR           7'b1100111
`define OP_BRANCH         7'b1100011
`define OP_LOAD           7'b0000011
`define OP_STORE          7'b0100011
`define OP_OPIMM          7'b0010011   // I-type ALU (ADDI, etc.)
`define OP_OP             7'b0110011   // R-type ALU
`define OP_SYSTEM         7'b1110011   // ECALL/EBREAK/MRET/CSR

// ---- ALU operations ------------------------------------------------------
// 4-bit ALU op encoding. Width chosen to leave room for growth.
`define ALU_ADD           4'b0000
`define ALU_SUB           4'b0001
`define ALU_AND           4'b0010
`define ALU_OR            4'b0011
`define ALU_XOR           4'b0100
`define ALU_SLL           4'b0101
`define ALU_SRL           4'b0110
`define ALU_SRA           4'b0111
`define ALU_SLT           4'b1000   // signed set-less-than
`define ALU_SLTU          4'b1001   // unsigned set-less-than
`define ALU_PASSB         4'b1010   // pass operand B (for LUI)

// ---- Immediate type select ----------------------------------------------
`define IMM_I             3'b000
`define IMM_S             3'b001
`define IMM_B             3'b010
`define IMM_U             3'b011
`define IMM_J             3'b100

// ---- Writeback result source --------------------------------------------
`define RES_ALU           2'b00   // ALU result
`define RES_MEM           2'b01   // load data
`define RES_PC4           2'b10   // PC+4 (for JAL/JALR link)
`define RES_CSR           2'b11   // CSR read data

// ---- Memory access size (matches funct3 low bits) ------------------------
`define MEM_B             2'b00   // byte
`define MEM_H             2'b01   // halfword
`define MEM_W             2'b10   // word

// ---- Forwarding select (per ALU operand) ---------------------------------
`define FWD_NONE          2'b00   // use value from ID/EX register
`define FWD_MEM           2'b01   // forward from EX/MEM stage
`define FWD_WB            2'b10   // forward from MEM/WB stage

// ============================================================================
//  CSR / trap support
// ============================================================================
// ---- Machine-mode CSR addresses (instr[31:20]) ---------------------------
`define CSR_MSTATUS       12'h300
`define CSR_MISA          12'h301
`define CSR_MIE           12'h304
`define CSR_MTVEC         12'h305
`define CSR_MSCRATCH      12'h340
`define CSR_MEPC          12'h341
`define CSR_MCAUSE        12'h342
`define CSR_MTVAL         12'h343
`define CSR_MIP           12'h344
`define CSR_MVENDORID     12'hF11
`define CSR_MARCHID       12'hF12
`define CSR_MIMPID        12'hF13
`define CSR_MHARTID       12'hF14
`define CSR_CYCLE         12'hC00
`define CSR_CYCLEH        12'hC80
`define CSR_INSTRET       12'hC02
`define CSR_INSTRETH      12'hC82

// ---- mstatus bit positions (machine mode subset) -------------------------
`define MSTATUS_MIE       3       // global machine interrupt enable
`define MSTATUS_MPIE      7       // previous MIE (saved on trap)
// MPP is hardwired to 2'b11 (M-mode) since only M-mode is implemented.

// ---- mie / mip bit positions (standard) ----------------------------------
`define IRQ_MTI           7       // machine timer interrupt
`define IRQ_MEI           11      // machine external interrupt (DIR accel)

// ---- CSR ALU op (funct3 of SYSTEM CSR instructions) ----------------------
`define CSRRW             3'b001
`define CSRRS             3'b010
`define CSRRC             3'b011
`define CSRRWI            3'b101
`define CSRRSI            3'b110
`define CSRRCI            3'b111

// ---- mcause codes --------------------------------------------------------
// Synchronous exceptions (mcause[31]=0):
`define EXC_INSTR_MISALIGN 4'd0
`define EXC_ILLEGAL        4'd2
`define EXC_BREAKPOINT     4'd3
`define EXC_LOAD_MISALIGN  4'd4
`define EXC_STORE_MISALIGN 4'd6
`define EXC_ECALL_M        4'd11
// Asynchronous interrupts (mcause[31]=1) reuse IRQ_MTI / IRQ_MEI codes.

// ============================================================================
//  System memory map (byte addresses; low 16 bits decoded)
// ============================================================================
//   0x0000_0000 - 0x0000_0FFF : Instruction BRAM (data-side / loader port)
//   0x0000_1000 - 0x0000_1FFF : Data BRAM
//   0x0000_2000 - 0x0000_20FF : GPIO
//   0x0000_3000 - 0x0000_30FF : Timer
//   0x0000_4000 - 0x0000_40FF : UART / Debug
//   0x0000_5000 - 0x0000_50FF : DIR Accelerator registers
//   0x0000_6000 - 0x0000_6FFF : DIR Accelerator scratchpad
// Address decode uses bits [15:12]; bits [31:16] must be zero (else bus error).
`define SEL_IMEM          4'h0
`define SEL_DMEM          4'h1
`define SEL_GPIO          4'h2
`define SEL_TIMER         4'h3
`define SEL_UART          4'h4
`define SEL_ACC_REGS      4'h5
`define SEL_ACC_SCRATCH   4'h6

`define MMAP_IMEM_BASE    32'h0000_0000
`define MMAP_DMEM_BASE    32'h0000_1000
`define MMAP_GPIO_BASE    32'h0000_2000
`define MMAP_TIMER_BASE   32'h0000_3000
`define MMAP_UART_BASE    32'h0000_4000
`define MMAP_ACC_BASE     32'h0000_5000
`define MMAP_SCRATCH_BASE 32'h0000_6000

// ============================================================================
//  DIR accelerator register file (word offsets from MMAP_ACC_BASE)
// ============================================================================
`define ACC_CONTROL       8'h00   // [0]start [1]irq_en [2]signed ...
`define ACC_STATUS        8'h04   // [0]busy  [1]done   [2]error
`define ACC_INPUT_BASE    8'h08   // input  tile word offset within scratchpad
`define ACC_OUTPUT_BASE   8'h0C   // output tile word offset within scratchpad
`define ACC_CONFIG        8'h10   // [15:0]img_w  [31:16]img_h
`define ACC_KERNEL_CONFIG 8'h14   // [3:0]kdim [11:8]shift [27:16]coeff_base
`define ACC_RESULT        8'h18   // last output sample (read-only)
`define ACC_INT_ACK       8'h1C   // write 1 to clear done/irq

// ACC_CONTROL bits
`define ACC_CTRL_START    0
`define ACC_CTRL_IRQEN    1
`define ACC_CTRL_SIGNED   2       // treat pixels/coeffs as signed

// ACC_STATUS bits
`define ACC_STAT_BUSY     0
`define ACC_STAT_DONE     1
`define ACC_STAT_ERROR    2

`endif
