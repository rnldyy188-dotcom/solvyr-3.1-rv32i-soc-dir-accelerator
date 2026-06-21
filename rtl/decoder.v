// ============================================================================
// decoder.v  -  Field extraction + ALU op / immediate-type derivation
//
// Splits a 32-bit instruction into its register addresses and funct fields,
// and derives the ALU operation and immediate format. The high-level control
// signals (RegWrite, MemRead, branch, etc.) come from control_unit; this
// module focuses on the "what arithmetic / which immediate" decode so the two
// concerns stay separate and individually testable.
//
// Pure combinational.
// ============================================================================
`include "solvyr3_defs.vh"

module decoder (
    input  wire [31:0] instr,

    output wire [6:0]  opcode,
    output wire [4:0]  rd,
    output wire [4:0]  rs1,
    output wire [4:0]  rs2,
    output wire [2:0]  funct3,
    output wire [6:0]  funct7,

    output reg  [3:0]  alu_op,
    output reg  [2:0]  imm_sel
);

    assign opcode = instr[6:0];
    assign rd     = instr[11:7];
    assign funct3 = instr[14:12];
    assign rs1    = instr[19:15];
    assign rs2    = instr[24:20];
    assign funct7 = instr[31:25];

    // funct7 bit 5 distinguishes ADD/SUB and SRL/SRA, and SRAI in I-type.
    wire alt = instr[30];

    // ---- ALU operation decode --------------------------------------------
    always @(*) begin
        case (opcode)
            // R-type: full funct3 + funct7[5] decode
            `OP_OP: begin
                case (funct3)
                    3'b000: alu_op = alt ? `ALU_SUB : `ALU_ADD;
                    3'b001: alu_op = `ALU_SLL;
                    3'b010: alu_op = `ALU_SLT;
                    3'b011: alu_op = `ALU_SLTU;
                    3'b100: alu_op = `ALU_XOR;
                    3'b101: alu_op = alt ? `ALU_SRA : `ALU_SRL;
                    3'b110: alu_op = `ALU_OR;
                    3'b111: alu_op = `ALU_AND;
                    default:alu_op = `ALU_ADD;
                endcase
            end

            // I-type ALU: same as R-type except ADDI has no SUB, and only
            // the shift-immediate forms use funct7[5] (SRAI).
            `OP_OPIMM: begin
                case (funct3)
                    3'b000: alu_op = `ALU_ADD;            // ADDI
                    3'b001: alu_op = `ALU_SLL;            // SLLI
                    3'b010: alu_op = `ALU_SLT;            // SLTI
                    3'b011: alu_op = `ALU_SLTU;           // SLTIU
                    3'b100: alu_op = `ALU_XOR;            // XORI
                    3'b101: alu_op = alt ? `ALU_SRA : `ALU_SRL; // SRAI/SRLI
                    3'b110: alu_op = `ALU_OR;             // ORI
                    3'b111: alu_op = `ALU_AND;            // ANDI
                    default:alu_op = `ALU_ADD;
                endcase
            end

            // Loads / stores: ALU computes the effective address (base + imm).
            `OP_LOAD, `OP_STORE: alu_op = `ALU_ADD;

            // AUIPC: PC + (imm<<12)  -> ADD (operand A = PC, B = imm)
            `OP_AUIPC:           alu_op = `ALU_ADD;

            // LUI: result is just the immediate -> pass operand B.
            `OP_LUI:             alu_op = `ALU_PASSB;

            // JAL/JALR: ALU computes the link target base for address calc;
            // PC+4 link value is selected via ResultSrc in control_unit.
            `OP_JAL, `OP_JALR:   alu_op = `ALU_ADD;

            // Branches: subtraction feeds the branch comparator's flags,
            // but the dedicated branch_unit does the real comparison.
            `OP_BRANCH:          alu_op = `ALU_SUB;

            default:             alu_op = `ALU_ADD;
        endcase
    end

    // ---- Immediate-type decode -------------------------------------------
    always @(*) begin
        case (opcode)
            `OP_OPIMM, `OP_LOAD, `OP_JALR: imm_sel = `IMM_I;
            `OP_STORE:                      imm_sel = `IMM_S;
            `OP_BRANCH:                     imm_sel = `IMM_B;
            `OP_LUI, `OP_AUIPC:             imm_sel = `IMM_U;
            `OP_JAL:                        imm_sel = `IMM_J;
            default:                        imm_sel = `IMM_I;
        endcase
    end

endmodule
