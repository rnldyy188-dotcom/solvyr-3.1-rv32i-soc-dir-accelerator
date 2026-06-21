// ============================================================================
// pipeline_regs.v  -  The four pipeline registers for Solvyr-3
//
//   reg_if_id, reg_id_ex, reg_ex_mem, reg_mem_wb
//
// Each register:
//   - Latches its inputs on the rising clock edge.
//   - Honors `stall` (hold current value) and `flush` (load a bubble: a NOP
//     with all control disabled and valid=0). flush takes priority over stall.
//   - Carries a `valid` bit so squashed/bubble instructions write nothing.
//
// Control signals are passed as a packed bus to keep the port lists sane; the
// core packs/unpacks with the field layout documented in solvyr3_core.v.
//
// Exception/CSR metadata is carried alongside the datapath so traps can be
// resolved precisely at a single point in the MEM stage:
//   - has_exc / exc_cause / tval : a synchronous exception detected upstream
//   - is_mret                    : this instruction is an MRET
//   - csr_addr / csr_wsrc        : operands for a CSR read/modify/write
// On flush/reset these collapse to "no exception, not an MRET" so a squashed
// instruction can never trigger a trap.
//
// A "bubble" is simply valid=0 with all write-enable controls forced low,
// behaviourally identical to addi x0,x0,0 (NOP).
// ============================================================================
`include "solvyr3_defs.vh"

// ---------------------------------------------------------------------------
// IF/ID : carries the fetched instruction and its PC.
// ---------------------------------------------------------------------------
module reg_if_id (
    input  wire        clk,
    input  wire        rst,
    input  wire        stall,
    input  wire        flush,

    input  wire [31:0] pc_in,
    input  wire [31:0] pc4_in,
    input  wire [31:0] instr_in,
    input  wire        valid_in,

    output reg  [31:0] pc_out,
    output reg  [31:0] pc4_out,
    output reg  [31:0] instr_out,
    output reg         valid_out
);
    always @(posedge clk) begin
        if (rst) begin
            pc_out    <= 32'd0;
            pc4_out   <= 32'd0;
            instr_out <= `NOP_INSTR;
            valid_out <= 1'b0;
        end else if (flush) begin
            // Flush = turn this slot into a bubble. Only `instr` (-> NOP, so the
            // decoder yields rs1=rs2=0 and raises no spurious load-use) and
            // `valid` need to clear; pc/pc4 are don't-care while valid=0, so they
            // are intentionally LEFT UNCHANGED. That keeps the high-fanout flush
            // net off 64 reset pins (pc + pc4), shortening the branch-redirect ->
            // IF/ID-flush timing path. (flush still takes priority over stall.)
            instr_out <= `NOP_INSTR;
            valid_out <= 1'b0;
        end else if (!stall) begin
            pc_out    <= pc_in;
            pc4_out   <= pc4_in;
            instr_out <= instr_in;
            valid_out <= valid_in;
        end
        // else: hold (stall)
    end
endmodule


// ---------------------------------------------------------------------------
// ID/EX : decoded operands, immediate, control bundle, register addresses,
//         and exception/CSR metadata.
// ---------------------------------------------------------------------------
module reg_id_ex #(
    parameter CTRLW = 13
) (
    input  wire             clk,
    input  wire             rst,
    input  wire             stall,
    input  wire             flush,

    input  wire [31:0]      pc_in,
    input  wire [31:0]      pc4_in,
    input  wire [31:0]      rs1_data_in,
    input  wire [31:0]      rs2_data_in,
    input  wire [31:0]      imm_in,
    input  wire [4:0]       rs1_in,
    input  wire [4:0]       rs2_in,
    input  wire [4:0]       rd_in,
    input  wire [2:0]       funct3_in,
    input  wire [3:0]       alu_op_in,
    input  wire [CTRLW-1:0] ctrl_in,
    input  wire             valid_in,
    // exception / CSR metadata
    input  wire             has_exc_in,
    input  wire [3:0]       exc_cause_in,
    input  wire [31:0]      tval_in,
    input  wire             is_mret_in,
    input  wire [11:0]      csr_addr_in,

    output reg  [31:0]      pc_out,
    output reg  [31:0]      pc4_out,
    output reg  [31:0]      rs1_data_out,
    output reg  [31:0]      rs2_data_out,
    output reg  [31:0]      imm_out,
    output reg  [4:0]       rs1_out,
    output reg  [4:0]       rs2_out,
    output reg  [4:0]       rd_out,
    output reg  [2:0]       funct3_out,
    output reg  [3:0]       alu_op_out,
    output reg  [CTRLW-1:0] ctrl_out,
    output reg              valid_out,
    output reg              has_exc_out,
    output reg  [3:0]       exc_cause_out,
    output reg  [31:0]      tval_out,
    output reg              is_mret_out,
    output reg  [11:0]      csr_addr_out
);
    always @(posedge clk) begin
        if (rst) begin
            pc_out        <= 32'd0;
            pc4_out       <= 32'd0;
            rs1_data_out  <= 32'd0;
            rs2_data_out  <= 32'd0;
            imm_out       <= 32'd0;
            rs1_out       <= 5'd0;
            rs2_out       <= 5'd0;
            rd_out        <= 5'd0;
            funct3_out    <= 3'd0;
            alu_op_out    <= `ALU_ADD;
            ctrl_out      <= {CTRLW{1'b0}};
            valid_out     <= 1'b0;
            has_exc_out   <= 1'b0;
            exc_cause_out <= 4'd0;
            tval_out      <= 32'd0;
            is_mret_out   <= 1'b0;
            csr_addr_out  <= 12'd0;
        end else if (flush) begin
            // Bubble: clearing valid + the control word makes the instruction
            // architecturally inert (no register write, no memory access, and
            // crucially no branch/jump -> no spurious redirect); clearing the two
            // trap triggers (has_exc, is_mret) guarantees no spurious trap/MRET.
            // Every remaining field (pc, pc4, rs*_data, imm, rs/rd, funct3,
            // alu_op, exc_cause, tval, csr_addr) is don't-care while valid=0 (its
            // consumers are all gated by valid/ctrl), so it is LEFT UNCHANGED --
            // keeping the high-fanout flush net off ~260 reset pins and
            // shortening the branch-redirect -> ID/EX timing path. (flush still
            // takes priority over stall.)
            ctrl_out    <= {CTRLW{1'b0}};
            valid_out   <= 1'b0;
            has_exc_out <= 1'b0;
            is_mret_out <= 1'b0;
        end else if (!stall) begin
            pc_out        <= pc_in;
            pc4_out       <= pc4_in;
            rs1_data_out  <= rs1_data_in;
            rs2_data_out  <= rs2_data_in;
            imm_out       <= imm_in;
            rs1_out       <= rs1_in;
            rs2_out       <= rs2_in;
            rd_out        <= rd_in;
            funct3_out    <= funct3_in;
            alu_op_out    <= alu_op_in;
            ctrl_out      <= ctrl_in;
            valid_out     <= valid_in;
            has_exc_out   <= has_exc_in;
            exc_cause_out <= exc_cause_in;
            tval_out      <= tval_in;
            is_mret_out   <= is_mret_in;
            csr_addr_out  <= csr_addr_in;
        end
    end
endmodule


// ---------------------------------------------------------------------------
// EX/MEM : ALU result, store data, control bundle, rd, and the exception/CSR
//          metadata needed to resolve a trap at the MEM commit point.
// ---------------------------------------------------------------------------
module reg_ex_mem #(
    parameter CTRLW = 13
) (
    input  wire             clk,
    input  wire             rst,
    input  wire             stall,
    input  wire             flush,

    input  wire [31:0]      alu_result_in,
    input  wire [31:0]      store_data_in,
    input  wire [31:0]      pc4_in,
    input  wire [4:0]       rd_in,
    input  wire [2:0]       funct3_in,
    input  wire [CTRLW-1:0] ctrl_in,
    input  wire             valid_in,
    // exception / CSR metadata
    input  wire             has_exc_in,
    input  wire [3:0]       exc_cause_in,
    input  wire [31:0]      tval_in,
    input  wire             is_mret_in,
    input  wire [11:0]      csr_addr_in,
    input  wire [31:0]      csr_wsrc_in,

    output reg  [31:0]      alu_result_out,
    output reg  [31:0]      store_data_out,
    output reg  [31:0]      pc4_out,
    output reg  [4:0]       rd_out,
    output reg  [2:0]       funct3_out,
    output reg  [CTRLW-1:0] ctrl_out,
    output reg              valid_out,
    output reg              has_exc_out,
    output reg  [3:0]       exc_cause_out,
    output reg  [31:0]      tval_out,
    output reg              is_mret_out,
    output reg  [11:0]      csr_addr_out,
    output reg  [31:0]      csr_wsrc_out
);
    always @(posedge clk) begin
        if (rst || flush) begin
            alu_result_out <= 32'd0;
            store_data_out <= 32'd0;
            pc4_out        <= 32'd0;
            rd_out         <= 5'd0;
            funct3_out     <= 3'd0;
            ctrl_out       <= {CTRLW{1'b0}};
            valid_out      <= 1'b0;
            has_exc_out    <= 1'b0;
            exc_cause_out  <= 4'd0;
            tval_out       <= 32'd0;
            is_mret_out    <= 1'b0;
            csr_addr_out   <= 12'd0;
            csr_wsrc_out   <= 32'd0;
        end else if (!stall) begin
            alu_result_out <= alu_result_in;
            store_data_out <= store_data_in;
            pc4_out        <= pc4_in;
            rd_out         <= rd_in;
            funct3_out     <= funct3_in;
            ctrl_out       <= ctrl_in;
            valid_out      <= valid_in;
            has_exc_out    <= has_exc_in;
            exc_cause_out  <= exc_cause_in;
            tval_out       <= tval_in;
            is_mret_out    <= is_mret_in;
            csr_addr_out   <= csr_addr_in;
            csr_wsrc_out   <= csr_wsrc_in;
        end
        // else hold (stall)
    end
endmodule


// ---------------------------------------------------------------------------
// MEM/WB : final writeback value sources and rd. A `flush` input lets the core
// squash the writeback of an instruction that traps in MEM (so it commits no
// architectural state before re-executing after MRET).
//
// Like the other three pipeline registers, it ALSO honors `stall`: a memory
// stall must freeze the WHOLE pipeline coherently. If MEM/WB kept advancing
// while the stages above were frozen, the instruction in WB would drain and
// retire mid-stall, removing it as a forwarding source — and a younger
// instruction frozen in EX would then fall back to its stale latched operand
// and compute a wrong result. (flush takes priority over stall.)
// ---------------------------------------------------------------------------
module reg_mem_wb #(
    parameter CTRLW = 13
) (
    input  wire             clk,
    input  wire             rst,
    input  wire             stall,
    input  wire             flush,

    input  wire [31:0]      alu_result_in,
    input  wire [31:0]      load_data_in,
    input  wire [31:0]      pc4_in,
    input  wire [31:0]      csr_data_in,
    input  wire [4:0]       rd_in,
    input  wire [CTRLW-1:0] ctrl_in,
    input  wire             valid_in,

    output reg  [31:0]      alu_result_out,
    output reg  [31:0]      load_data_out,
    output reg  [31:0]      pc4_out,
    output reg  [31:0]      csr_data_out,
    output reg  [4:0]       rd_out,
    output reg  [CTRLW-1:0] ctrl_out,
    output reg              valid_out
);
    always @(posedge clk) begin
        if (rst || flush) begin
            alu_result_out <= 32'd0;
            load_data_out  <= 32'd0;
            pc4_out        <= 32'd0;
            csr_data_out   <= 32'd0;
            rd_out         <= 5'd0;
            ctrl_out       <= {CTRLW{1'b0}};
            valid_out      <= 1'b0;
        end else if (!stall) begin
            alu_result_out <= alu_result_in;
            load_data_out  <= load_data_in;
            pc4_out        <= pc4_in;
            csr_data_out   <= csr_data_in;
            rd_out         <= rd_in;
            ctrl_out       <= ctrl_in;
            valid_out      <= valid_in;
        end
        // else: hold (stall) — keep this instruction in WB so it remains a valid
        // forwarding source while a memory stall freezes the stages above.
    end
endmodule
