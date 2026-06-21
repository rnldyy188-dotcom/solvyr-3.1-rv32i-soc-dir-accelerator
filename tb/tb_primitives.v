// ============================================================================
// tb_primitives.v  -  Self-checking unit tests for the combinational blocks
//
// Covers: alu, regfile, imm_gen, decoder, control_unit, load_store_unit,
// branch_unit, forwarding_unit, hazard_unit.  Prints PASS/FAIL per check and a
// final summary. Run with:  ./run_sim.sh prim
// ============================================================================
`timescale 1ns/1ps
`include "solvyr3_defs.vh"

module tb_primitives;

    integer errors = 0, checks = 0;
    task check32(input [255:0] name, input [31:0] got, input [31:0] exp);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                $display("FAIL [%0s] got=%h exp=%h", name, got, exp);
                errors = errors + 1;
            end else $display("PASS [%0s] = %h", name, got);
        end
    endtask
    task check1(input [255:0] name, input got, input exp);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                $display("FAIL [%0s] got=%b exp=%b", name, got, exp);
                errors = errors + 1;
            end else $display("PASS [%0s] = %b", name, got);
        end
    endtask

    // ---------------------------------------------------------------- ALU
    reg  [31:0] a, b; reg [3:0] op;
    wire [31:0] alu_y;
    alu u_alu (.a(a), .b(b), .alu_op(op), .result(alu_y));

    // ------------------------------------------------------------ imm_gen
    reg  [31:0] instr; reg [2:0] isel;
    wire [31:0] imm;
    imm_gen u_imm (.instr(instr), .imm_sel(isel), .imm(imm));

    // ------------------------------------------------------------ regfile
    reg clk = 0, rst = 0, we;
    reg  [4:0] rs1a, rs2a, rda; reg [31:0] rdd;
    wire [31:0] rs1d, rs2d;
    regfile u_rf (.clk(clk), .rs1_addr(rs1a), .rs2_addr(rs2a),
                  .rs1_data(rs1d), .rs2_data(rs2d),
                  .we(we), .rd_addr(rda), .rd_data(rdd));
    always #5 clk = ~clk;

    // ------------------------------------------------------------ decoder
    reg  [31:0] dinstr;
    wire [6:0]  d_op, d_f7; wire [4:0] d_rd, d_rs1, d_rs2; wire [2:0] d_f3;
    wire [3:0]  d_aluop;    wire [2:0] d_immsel;
    decoder u_dec (.instr(dinstr), .opcode(d_op), .rd(d_rd), .rs1(d_rs1),
                   .rs2(d_rs2), .funct3(d_f3), .funct7(d_f7),
                   .alu_op(d_aluop), .imm_sel(d_immsel));

    // -------------------------------------------------------- control_unit
    reg  [6:0] c_op, c_f7; reg [2:0] c_f3; reg [11:0] c_imm12;
    wire c_rw,c_asa,c_asb,c_mr,c_mw,c_mu,c_br,c_jm,c_cw,c_ec,c_eb,c_mret,c_ill;
    wire [1:0] c_msz, c_rsrc;
    control_unit u_ctrl (.opcode(c_op), .funct3(c_f3), .funct7(c_f7), .imm12(c_imm12),
        .reg_write(c_rw), .alu_src_a(c_asa), .alu_src_b(c_asb), .mem_read(c_mr),
        .mem_write(c_mw), .mem_size(c_msz), .mem_unsigned(c_mu), .result_src(c_rsrc),
        .branch(c_br), .jump(c_jm), .csr_write(c_cw), .is_ecall(c_ec),
        .is_ebreak(c_eb), .is_mret(c_mret), .illegal(c_ill));

    // ----------------------------------------------------- load_store_unit
    reg  [31:0] l_addr, l_sdata, l_rdata; reg [1:0] l_size; reg l_uns, l_rd, l_wr;
    wire [3:0]  l_be; wire [31:0] l_wdata, l_ld; wire l_mis;
    load_store_unit u_lsu (.addr(l_addr), .mem_size(l_size), .mem_unsigned(l_uns),
        .mem_read(l_rd), .mem_write(l_wr), .store_data(l_sdata),
        .byte_en(l_be), .bus_wdata(l_wdata), .bus_rdata(l_rdata),
        .load_data(l_ld), .misaligned(l_mis));

    // -------------------------------------------------------- branch_unit
    reg  [2:0] bf3; reg [31:0] boa, bob; reg ben; wire btk;
    branch_unit u_br (.branch(ben), .funct3(bf3), .op_a(boa), .op_b(bob), .take_branch(btk));

    // ----------------------------------------------------- forwarding_unit
    reg  [4:0] f_rs1, f_rs2, f_mrd, f_wrd; reg f_mw, f_ww;
    wire [1:0] f_a, f_b;
    forwarding_unit u_fwd (.ex_rs1(f_rs1), .ex_rs2(f_rs2),
        .mem_reg_write(f_mw), .mem_rd(f_mrd), .wb_reg_write(f_ww), .wb_rd(f_wrd),
        .fwd_a(f_a), .fwd_b(f_b));

    // -------------------------------------------------------- hazard_unit
    reg  h_mr; reg [4:0] h_exrd, h_rs1, h_rs2; reg h_tk, h_jmp;
    wire h_spc, h_sif, h_bub, h_fif, h_fie;
    hazard_unit u_haz (.ex_mem_read(h_mr), .ex_rd(h_exrd), .id_rs1(h_rs1),
        .id_rs2(h_rs2), .ex_take_branch(h_tk), .ex_jump(h_jmp),
        .stall_pc(h_spc), .stall_if_id(h_sif), .bubble_id_ex(h_bub),
        .flush_if_id(h_fif), .flush_id_ex(h_fie));

    initial begin
        // ===== ALU =====
        a=10;b=5;op=`ALU_ADD; #1 check32("ADD",alu_y,32'd15);
        a=10;b=5;op=`ALU_SUB; #1 check32("SUB",alu_y,32'd5);
        a=32'hF0F0F0F0;b=32'h0F0F0F0F;op=`ALU_OR; #1 check32("OR",alu_y,32'hFFFFFFFF);
        a=32'hFF00FF00;b=32'h0F0F0F0F;op=`ALU_AND;#1 check32("AND",alu_y,32'h0F000F00);
        a=1;b=4;op=`ALU_SLL; #1 check32("SLL",alu_y,32'd16);
        a=32'hFFFFFFF0;b=4;op=`ALU_SRL;#1 check32("SRL",alu_y,32'h0FFFFFFF);
        a=32'hFFFFFFF0;b=4;op=`ALU_SRA;#1 check32("SRA",alu_y,32'hFFFFFFFF);
        a=-5;b=3;op=`ALU_SLT; #1 check32("SLT",alu_y,32'd1);
        a=-5;b=3;op=`ALU_SLTU;#1 check32("SLTU",alu_y,32'd0);
        a=0;b=32'hABCD1234;op=`ALU_PASSB;#1 check32("PASSB",alu_y,32'hABCD1234);

        // ===== imm_gen =====
        instr=32'hFFF00093; isel=`IMM_I; #1 check32("IMM_I -1", imm, 32'hFFFFFFFF);
        instr=32'h12345037; isel=`IMM_U; #1 check32("IMM_U", imm, 32'h12345000);
        instr={7'b0000000,5'd0,5'd0,3'b010,5'b01000,`OP_STORE};
        isel=`IMM_S; #1 check32("IMM_S 8", imm, 32'd8);

        // ===== regfile =====
        rst=1; we=0; rs1a=0; rs2a=0; @(posedge clk); #1 rst=0;
        we=1; rda=5'd5; rdd=32'hDEADBEEF; @(posedge clk); #1 we=0;
        rs1a=5'd5; #1 check32("RF read x5", rs1d, 32'hDEADBEEF);
        we=1; rda=5'd0; rdd=32'hFFFFFFFF; @(posedge clk); #1 we=0;
        rs1a=5'd0; #1 check32("RF x0 zero", rs1d, 32'd0);
        rs1a=5'd7; we=1; rda=5'd7; rdd=32'h0000CAFE; #1 check32("RF bypass x7", rs1d, 32'h0000CAFE);
        @(posedge clk); we=0;

        // ===== decoder ===== (add x1,x2,x3 = 0x003100b3)
        dinstr=32'h003100b3; #1 check32("DEC add aluop", {28'd0,d_aluop}, {28'd0,`ALU_ADD});
        // sub x1,x2,x3 = 0x40310133 -> rd=2? just check aluop=SUB
        dinstr=32'h403100b3; #1 check32("DEC sub aluop", {28'd0,d_aluop}, {28'd0,`ALU_SUB});
        // addi -> I-type imm select
        dinstr=32'h00500093; #1 check32("DEC addi immsel", {29'd0,d_immsel}, {29'd0,`IMM_I});
        // jal -> J immsel
        dinstr=32'h008000EF; #1 check32("DEC jal immsel", {29'd0,d_immsel}, {29'd0,`IMM_J});

        // ===== control_unit =====
        c_op=`OP_LOAD; c_f3=3'b010; c_f7=0; c_imm12=0; #1
            check1("CU load mem_read", c_mr, 1'b1);
        #1 check1("CU load reg_write", c_rw, 1'b1);
        c_op=`OP_STORE; c_f3=3'b010; #1 check1("CU store mem_write", c_mw, 1'b1);
        #1 check1("CU store no reg_write", c_rw, 1'b0);
        c_op=`OP_BRANCH; c_f3=3'b000; #1 check1("CU branch", c_br, 1'b1);
        c_op=`OP_SYSTEM; c_f3=3'b000; c_imm12=12'h000; #1 check1("CU ecall", c_ec, 1'b1);
        c_op=`OP_SYSTEM; c_f3=3'b000; c_imm12=12'h302; #1 check1("CU mret", c_mret, 1'b1);
        c_op=`OP_SYSTEM; c_f3=3'b001; c_imm12=12'h305; #1 check1("CU csr csr_write", c_cw, 1'b1);
        c_op=7'b0000000; c_f3=0; #1 check1("CU illegal", c_ill, 1'b1);

        // ===== load_store_unit =====
        l_rd=1; l_wr=0; l_uns=0;
        l_addr=32'h100; l_size=`MEM_W; l_rdata=32'hDEADBEEF; #1
            check32("LSU LW", l_ld, 32'hDEADBEEF);
        l_addr=32'h101; l_size=`MEM_B; l_rdata=32'hDEADBEEF; #1
            check32("LSU LB s-ext", l_ld, 32'hFFFFFFBE);
        l_uns=1; #1 check32("LSU LBU z-ext", l_ld, 32'h000000BE);
        l_uns=0; l_addr=32'h102; l_size=`MEM_H; l_rdata=32'hDEADBEEF; #1
            check32("LSU LH s-ext", l_ld, 32'hFFFFDEAD);
        l_addr=32'h102; l_size=`MEM_W; #1 check1("LSU misalign W", l_mis, 1'b1);
        // store: SB at offset 1
        l_rd=0; l_wr=1; l_addr=32'h101; l_size=`MEM_B; l_sdata=32'h000000AB; #1
            check32("LSU SB wdata", l_wdata, 32'h0000AB00);
        #1 check32("LSU SB byte_en", {28'd0,l_be}, 32'h00000002);
        l_addr=32'h100; l_size=`MEM_W; l_sdata=32'h12345678; #1
            check32("LSU SW wdata", l_wdata, 32'h12345678);
        l_wr=0; l_rd=0;

        // ===== branch_unit =====
        ben=1; bf3=3'b000; boa=5; bob=5; #1 check1("BR BEQ taken", btk, 1'b1);
        bf3=3'b000; boa=5; bob=6; #1 check1("BR BEQ not", btk, 1'b0);
        bf3=3'b100; boa=-1; bob=1; #1 check1("BR BLT signed", btk, 1'b1);
        bf3=3'b110; boa=-1; bob=1; #1 check1("BR BLTU unsigned", btk, 1'b0);
        ben=0; bf3=3'b000; boa=5; bob=5; #1 check1("BR disabled", btk, 1'b0);

        // ===== forwarding_unit =====
        f_mw=1; f_mrd=5; f_ww=0; f_wrd=0; f_rs1=5; f_rs2=0; #1
            check32("FWD mem->A", {30'd0,f_a}, {30'd0,`FWD_MEM});
        f_mw=0; f_ww=1; f_wrd=6; f_rs2=6; #1
            check32("FWD wb->B", {30'd0,f_b}, {30'd0,`FWD_WB});
        f_mw=1; f_mrd=0; f_rs1=0; #1 check32("FWD x0 guard", {30'd0,f_a}, {30'd0,`FWD_NONE});

        // ===== hazard_unit =====
        h_mr=1; h_exrd=5; h_rs1=5; h_rs2=0; h_tk=0; h_jmp=0; #1
            check1("HAZ load-use stall", h_spc, 1'b1);
        #1 check1("HAZ load-use bubble", h_bub, 1'b1);
        h_mr=0; h_tk=1; #1 check1("HAZ branch flush", h_fif, 1'b1);
        #1 check1("HAZ branch flush idex", h_fie, 1'b1);

        // ===== summary =====
        $display("----------------------------------------");
        if (errors == 0) $display("ALL %0d CHECKS PASSED", checks);
        else             $display("%0d / %0d CHECKS FAILED", errors, checks);
        $finish;
    end
endmodule
