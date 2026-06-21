// ============================================================================
// alu.v  -  32-bit ALU for the Solvyr-3 RV32I core
//
// Pure combinational. Handles arithmetic, logic, shifts, comparisons, and a
// pass-through for LUI. Branch decisions are made in the dedicated branch unit,
// so no condition flags are produced here.
// ============================================================================
`include "solvyr3_defs.vh"

module alu (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [3:0]  alu_op,
    output reg  [31:0] result
);

    // Shift amount is the low 5 bits of operand B (RV32I: shifts use rs2[4:0]
    // or shamt[4:0]); higher bits are ignored by the ISA.
    wire [4:0] shamt = b[4:0];

    // Signed views for SLT / arithmetic shift.
    wire signed [31:0] a_s = a;
    wire signed [31:0] b_s = b;

    always @(*) begin
        case (alu_op)
            `ALU_ADD  : result = a + b;
            `ALU_SUB  : result = a - b;
            `ALU_AND  : result = a & b;
            `ALU_OR   : result = a | b;
            `ALU_XOR  : result = a ^ b;
            `ALU_SLL  : result = a << shamt;
            `ALU_SRL  : result = a >> shamt;
            `ALU_SRA  : result = a_s >>> shamt;            // arithmetic: sign-extends
            `ALU_SLT  : result = (a_s < b_s) ? 32'd1 : 32'd0;
            `ALU_SLTU : result = (a   < b  ) ? 32'd1 : 32'd0;
            `ALU_PASSB: result = b;                         // LUI: pass immediate
            default   : result = 32'd0;
        endcase
    end

endmodule
