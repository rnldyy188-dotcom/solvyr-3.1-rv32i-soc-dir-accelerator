// ============================================================================
// branch_unit.v  -  Branch condition evaluation (EX stage)
//
// Compares the two (already-forwarded) operands and, combined with the branch
// control bit and funct3, decides whether a conditional branch is taken. Jumps
// are unconditional and handled separately in the core's next-PC logic.
//
// funct3 encodings (RV32I branches):
//   000 BEQ   001 BNE   100 BLT   101 BGE   110 BLTU  111 BGEU
//
// Pure combinational.
// ============================================================================

module branch_unit (
    input  wire        branch,    // control: this is a conditional branch
    input  wire [2:0]  funct3,
    input  wire [31:0] op_a,      // forwarded rs1
    input  wire [31:0] op_b,      // forwarded rs2
    output reg         take_branch
);

    wire eq  = (op_a == op_b);
    wire lt  = ($signed(op_a) < $signed(op_b)); // signed
    wire ltu = (op_a < op_b);                   // unsigned

    reg cond;
    always @(*) begin
        case (funct3)
            3'b000: cond =  eq;     // BEQ
            3'b001: cond = ~eq;     // BNE
            3'b100: cond =  lt;     // BLT
            3'b101: cond = ~lt;     // BGE
            3'b110: cond =  ltu;    // BLTU
            3'b111: cond = ~ltu;    // BGEU
            default:cond = 1'b0;
        endcase
        take_branch = branch && cond;
    end

endmodule
