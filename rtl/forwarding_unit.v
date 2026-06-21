// ============================================================================
// forwarding_unit.v  -  Operand bypass selection for the EX stage
//
// For each ALU source register (rs1, rs2 as seen in EX) decides whether to use
//   - the value from ID/EX           (FWD_NONE)
//   - the EX/MEM-stage result        (FWD_MEM)   highest priority
//   - the MEM/WB-stage result        (FWD_WB)
//
// EX/MEM takes priority over MEM/WB because it is the more recent producer.
//
// x0 guard: never forward when the producing instruction's destination is x0,
// because a write to x0 is architecturally discarded. Forwarding it would
// inject a stale/garbage value where the ISA guarantees zero.
//
// Pure combinational.
// ============================================================================
`include "solvyr3_defs.vh"

module forwarding_unit (
    input  wire [4:0] ex_rs1,        // rs1 used by the instruction in EX
    input  wire [4:0] ex_rs2,        // rs2 used by the instruction in EX

    input  wire       mem_reg_write, // EX/MEM stage will write a register
    input  wire [4:0] mem_rd,        // EX/MEM destination

    input  wire       wb_reg_write,  // MEM/WB stage will write a register
    input  wire [4:0] wb_rd,         // MEM/WB destination

    output reg  [1:0] fwd_a,         // select for ALU operand A (rs1)
    output reg  [1:0] fwd_b          // select for ALU operand B (rs2)
);

    // A producer is valid for forwarding only if it writes a register and that
    // register is non-zero (x0 guard).
    wire mem_valid_fwd = mem_reg_write && (mem_rd != 5'd0);
    wire wb_valid_fwd  = wb_reg_write  && (wb_rd  != 5'd0);

    always @(*) begin
        // ---- operand A (rs1) ----
        if (mem_valid_fwd && (mem_rd == ex_rs1))
            fwd_a = `FWD_MEM;
        else if (wb_valid_fwd && (wb_rd == ex_rs1))
            fwd_a = `FWD_WB;
        else
            fwd_a = `FWD_NONE;

        // ---- operand B (rs2) ----
        if (mem_valid_fwd && (mem_rd == ex_rs2))
            fwd_b = `FWD_MEM;
        else if (wb_valid_fwd && (wb_rd == ex_rs2))
            fwd_b = `FWD_WB;
        else
            fwd_b = `FWD_NONE;
    end

endmodule
