// ============================================================================
// imm_gen.v  -  Immediate generator for Solvyr-3 RV32I
//
// Extracts and sign-extends the immediate field from a 32-bit instruction
// according to the selected format. All outputs are 32-bit. Branch (B) and
// jump (J) immediates already include the implicit low zero bit and are
// expressed as byte offsets (LSB = 0), matching how the next-PC adder uses
// them (PC + imm).
//
// Pure combinational.
// ============================================================================
`include "solvyr3_defs.vh"

module imm_gen (
    input  wire [31:0] instr,
    input  wire [2:0]  imm_sel,
    output reg  [31:0] imm
);

    wire        sign = instr[31];   // immediate sign bit for all formats

    always @(*) begin
        case (imm_sel)
            // I-type: instr[31:20]
            `IMM_I: imm = {{20{sign}}, instr[31:20]};

            // S-type: instr[31:25] | instr[11:7]
            `IMM_S: imm = {{20{sign}}, instr[31:25], instr[11:7]};

            // B-type: instr[31] | instr[7] | instr[30:25] | instr[11:8] | 0
            `IMM_B: imm = {{19{sign}}, instr[31], instr[7],
                            instr[30:25], instr[11:8], 1'b0};

            // U-type: instr[31:12] << 12
            `IMM_U: imm = {instr[31:12], 12'b0};

            // J-type: instr[31] | instr[19:12] | instr[20] | instr[30:21] | 0
            `IMM_J: imm = {{11{sign}}, instr[31], instr[19:12],
                            instr[20], instr[30:21], 1'b0};

            default: imm = 32'd0;
        endcase
    end

endmodule
