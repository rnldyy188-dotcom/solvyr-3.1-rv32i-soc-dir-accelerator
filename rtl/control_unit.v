// ============================================================================
// control_unit.v  -  Hardwired control for the Solvyr-3 RV32I core
//
// Maps opcode (+ funct3 for mem size / branch / SYSTEM, + instr[20] and
// funct7 for the privileged SYSTEM ops) to the datapath control lines.
// Hardwired (not microcoded) per spec. Pure combinational.
//
// ALUSrcA : 0 = rs1,   1 = PC          (AUIPC, JAL target calc)
// ALUSrcB : 0 = rs2,   1 = immediate
// ResultSrc: RES_ALU / RES_MEM / RES_PC4 / RES_CSR
//
// CSR / ecall / ebreak / mret lines are produced here and consumed by the
// trap unit added later. Until then they are simply unused (harmless).
// ============================================================================
`include "solvyr3_defs.vh"

module control_unit (
    input  wire [6:0]  opcode,
    input  wire [2:0]  funct3,
    input  wire [6:0]  funct7,
    input  wire [11:0] imm12,        // instr[31:20] - the SYSTEM function code

    output reg         reg_write,
    output reg         alu_src_a,    // 0=rs1, 1=PC
    output reg         alu_src_b,    // 0=rs2, 1=imm
    output reg         mem_read,
    output reg         mem_write,
    output reg  [1:0]  mem_size,     // MEM_B/H/W
    output reg         mem_unsigned, // 1 = zero-extend load (LBU/LHU)
    output reg  [1:0]  result_src,   // RES_*
    output reg         branch,       // is a conditional branch
    output reg         jump,         // is JAL/JALR (unconditional)
    output reg         csr_write,
    output reg         is_ecall,
    output reg         is_ebreak,
    output reg         is_mret,
    output reg         illegal       // opcode/function not recognized
);

    // SYSTEM privileged function codes live in imm12 (instr[31:20]):
    //   ECALL = 0x000, EBREAK = 0x001, MRET = 0x302
    localparam [11:0] SYS_ECALL  = 12'h000;
    localparam [11:0] SYS_EBREAK = 12'h001;
    localparam [11:0] SYS_MRET   = 12'h302;

    always @(*) begin
        // ---- Safe defaults (NOP that writes nothing) ----
        reg_write    = 1'b0;
        alu_src_a    = 1'b0;
        alu_src_b    = 1'b0;
        mem_read     = 1'b0;
        mem_write    = 1'b0;
        mem_size     = `MEM_W;
        mem_unsigned = 1'b0;
        result_src   = `RES_ALU;
        branch       = 1'b0;
        jump         = 1'b0;
        csr_write    = 1'b0;
        is_ecall     = 1'b0;
        is_ebreak    = 1'b0;
        is_mret      = 1'b0;
        illegal      = 1'b0;

        case (opcode)
            `OP_OP: begin                       // R-type ALU
                reg_write  = 1'b1;
                result_src = `RES_ALU;
            end

            `OP_OPIMM: begin                    // I-type ALU
                reg_write  = 1'b1;
                alu_src_b  = 1'b1;
                result_src = `RES_ALU;
            end

            `OP_LOAD: begin                     // LB/LH/LW/LBU/LHU
                reg_write    = 1'b1;
                alu_src_b    = 1'b1;
                mem_read     = 1'b1;
                result_src   = `RES_MEM;
                mem_size     = funct3[1:0];
                mem_unsigned = funct3[2];
            end

            `OP_STORE: begin                    // SB/SH/SW
                alu_src_b = 1'b1;
                mem_write = 1'b1;
                mem_size  = funct3[1:0];
            end

            `OP_BRANCH: begin                   // BEQ/BNE/BLT/BGE/BLTU/BGEU
                branch    = 1'b1;
            end

            `OP_JAL: begin                      // JAL
                reg_write  = 1'b1;
                jump       = 1'b1;
                result_src = `RES_PC4;
            end

            `OP_JALR: begin                     // JALR
                reg_write  = 1'b1;
                jump       = 1'b1;
                alu_src_b  = 1'b1;
                result_src = `RES_PC4;
            end

            `OP_LUI: begin                      // LUI (PASSB passes imm)
                reg_write  = 1'b1;
                alu_src_b  = 1'b1;
                result_src = `RES_ALU;
            end

            `OP_AUIPC: begin                    // AUIPC = PC + imm
                reg_write  = 1'b1;
                alu_src_a  = 1'b1;
                alu_src_b  = 1'b1;
                result_src = `RES_ALU;
            end

            `OP_SYSTEM: begin
                case (funct3)
                    3'b000: begin               // privileged: ECALL/EBREAK/MRET
                        case (imm12)
                            SYS_ECALL : is_ecall  = 1'b1;
                            SYS_EBREAK: is_ebreak = 1'b1;
                            SYS_MRET  : is_mret   = 1'b1;
                            default   : illegal   = 1'b1;
                        endcase
                    end
                    // CSR group: CSRRW/CSRRS/CSRRC and their immediate forms
                    3'b001, 3'b010, 3'b011,
                    3'b101, 3'b110, 3'b111: begin
                        reg_write  = 1'b1;
                        csr_write  = 1'b1;
                        result_src = `RES_CSR;
                    end
                    default: illegal = 1'b1;
                endcase
            end

            default: illegal = 1'b1;
        endcase
    end

endmodule
