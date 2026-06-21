// ============================================================================
// solvyr3_core.v  -  RV32I 5-stage in-order pipeline + machine-mode traps
//
// Stages: IF -> ID -> EX -> MEM -> WB
// Hazards: write-first regfile (no WB->ID fwd), EX/MEM & MEM/WB -> EX
//          forwarding, load-use stall, branch/jump flush (resolved in EX).
//
// Traps  : a SINGLE commit point in the MEM stage resolves all synchronous
//          exceptions, MRET, and asynchronous interrupts. Exception metadata
//          (cause/tval) is generated where it is first known and carried down
//          the pipeline:
//            ID  : illegal instruction, ECALL, EBREAK, (is_mret, csr_addr)
//            EX  : instruction-address-misaligned (taken branch/jump target)
//            MEM : load/store-address-misaligned (effective address)
//          At MEM the trapping instruction is squashed (no writeback, no
//          memory side effect), mepc/mcause/mtval are captured, and the PC is
//          redirected to mtvec. MRET redirects to mepc. Interrupts (timer,
//          DIR accelerator) are taken at a clean MEM boundary. This yields
//          precise, in-order traps.
//
// ---- Control bundle layout (CTRLW = 13 bits) -------------------------------
//   [0]     reg_write
//   [1]     alu_src_a   (0=rs1, 1=PC)
//   [2]     alu_src_b   (0=rs2, 1=imm)
//   [3]     mem_read
//   [4]     mem_write
//   [6:5]   mem_size
//   [7]     mem_unsigned
//   [9:8]   result_src
//   [10]    branch
//   [11]    jump
//   [12]    csr_write   (a CSR read/modify/write instruction)
// Decoder also carries alu_op (4b) and funct3 (3b) alongside the bundle.
// ============================================================================
`include "solvyr3_defs.vh"

module solvyr3_core #(
    parameter CTRLW = 13
) (
    input  wire        clk,
    input  wire        rst,

    // ---- Instruction memory port (Harvard) ----
    output wire [31:0] imem_addr,
    output wire        imem_en,       // fetch enable: 0 holds the fetched word during a stall
    input  wire [31:0] imem_rdata,

    // ---- Data memory / MMIO port (custom bus master) ----
    output wire        dmem_req,
    output wire        dmem_we,
    output wire [31:0] dmem_addr,
    output wire [31:0] dmem_wdata,
    output wire [3:0]  dmem_byte_en,
    input  wire [31:0] dmem_rdata,
    input  wire        dmem_ready,
    input  wire        dmem_error,    // bus error (unmapped/faulted access)

    // ---- Interrupt request lines (level-sensitive) ----
    input  wire        irq_timer,     // machine timer interrupt
    input  wire        irq_accel,     // DIR accelerator "done" interrupt

    // ---- Debug / status (for board LEDs, optional) ----
    output wire [31:0] dbg_pc,        // current fetch PC
    output wire        dbg_trap,      // pulses high the cycle a trap is taken
    output wire        bus_error      // sticky: an errored data access occurred
);

    // ======================================================================
    //  Control bundle pack/unpack helpers
    // ======================================================================
    function [CTRLW-1:0] pack_ctrl;
        input        rw, asa, asb, mr, mw, mu, br, jm, cw;
        input [1:0]  msz, rsrc;
        begin
            pack_ctrl = {cw, jm, br, rsrc, mu, msz, mw, mr, asb, asa, rw};
        end
    endfunction

    // Field indices into the packed bundle. Plain localparams (not `define
    // macros) keep these names module-local: they neither leak into the global
    // preprocessor namespace nor trip simple structural linters. Read a 1-bit
    // field as ctrl[CTRL_xxx]; read a 2-bit field as ctrl[CTRL_xxx_HI:CTRL_xxx_LO].
    localparam integer CTRL_RW      = 0;    // reg_write
    localparam integer CTRL_ASA     = 1;    // alu_src_a (0=rs1, 1=PC)
    localparam integer CTRL_ASB     = 2;    // alu_src_b (0=rs2, 1=imm)
    localparam integer CTRL_MR      = 3;    // mem_read
    localparam integer CTRL_MW      = 4;    // mem_write
    localparam integer CTRL_MSZ_LO  = 5;    // mem_size   = ctrl[6:5]
    localparam integer CTRL_MSZ_HI  = 6;
    localparam integer CTRL_MU      = 7;    // mem_unsigned
    localparam integer CTRL_RSRC_LO = 8;    // result_src = ctrl[9:8]
    localparam integer CTRL_RSRC_HI = 9;
    localparam integer CTRL_BR      = 10;   // branch
    localparam integer CTRL_JM      = 11;   // jump
    localparam integer CTRL_CW      = 12;   // csr_write

    // ======================================================================
    //  IF — Instruction Fetch
    // ======================================================================
    reg  [31:0] pc;
    wire [31:0] pc4 = pc + 32'd4;

    wire        stall_pc, stall_if_id, bubble_id_ex, flush_if_id, flush_id_ex;

    // ---- Memory-access stall (BRAM 1-cycle latency) ----------------------
    wire        dmem_access;          // a load/store is live in MEM this cycle
    reg         waiting;
    wire        mem_stall = dmem_access && !(waiting && dmem_ready);

    always @(posedge clk) begin
        if (rst)
            waiting <= 1'b0;
        else if (dmem_access && !waiting)
            waiting <= 1'b1;          // entering the wait cycle
        else if (waiting && dmem_ready)
            waiting <= 1'b0;          // access acknowledged, release
    end

    // ---- Next-PC selection -----------------------------------------------
    // Priority: trap/MRET redirect (MEM) > branch/jump redirect (EX) > PC+4.
    wire [31:0] branch_target;        // computed in EX
    wire        take_branch;          // from branch unit (EX)
    wire        ex_jump;              // jump control in EX
    // ex_redirect drives the next-PC mux AND (via the merged-equivalent hazard
    // `redirect`) the IF/ID + ID/EX flush, so it fans out to the instruction-
    // register set/reset pins -- the v1.1 setup-critical net. Capping its fanout
    // lets synth/phys_opt replicate the (cheap) OR so each copy drives fewer,
    // closer loads, shortening that route-dominated path. Pure replication =>
    // logically identical, no cycle/result change.
    (* max_fanout = 12 *)
    wire        ex_redirect = take_branch || ex_jump;

    wire        csr_redirect;         // trap or MRET taken at MEM
    wire [31:0] csr_target;           // mtvec (trap) or mepc (MRET)

    wire [31:0] next_pc = csr_redirect ? csr_target   :
                          ex_redirect  ? branch_target : pc4;

    // Front-end freeze: hold on a load-use stall or memory stall, UNLESS a
    // trap/MRET redirect is in flight (the redirect must win and advance PC).
    wire        front_stall = (stall_pc || mem_stall) && !csr_redirect;

    always @(posedge clk) begin
        if (rst)               pc <= `RESET_PC;
        else if (!front_stall) pc <= next_pc;
    end

    assign imem_addr = pc;
    // Advance the fetch only when the front end is not stalled, so the imem
    // output register and the IF buffer (pc_if / pc4_if / if_valid) hold as ONE
    // coherent stage. Without this the just-fetched instruction would be dropped
    // when a stall freezes the PC one address past it (the dropped-branch bug).
    assign imem_en   = !front_stall;

    // imem has 1-cycle read latency; delay PC/instr by one cycle to line up at
    // IF/ID. The reset-primed fetch is discarded as one bubble (if_valid=0).
    reg [31:0] pc_if;
    reg [31:0] pc4_if;
    reg        if_valid;
    always @(posedge clk) begin
        if (rst) begin
            pc_if    <= `RESET_PC;
            pc4_if   <= `RESET_PC + 32'd4;
            if_valid <= 1'b0;          // first fetch is a primed duplicate
        end else if ((ex_redirect && !mem_stall) || csr_redirect) begin
            // A taken branch/jump (EX) or trap/MRET (MEM) makes the fetch now in
            // flight wrong-path. Invalidate it so it enters IF/ID as a bubble,
            // instead of leaking one wrong-path instruction past the flush.
            // Gated by !mem_stall: while a load stalls the pipeline the redirect
            // is deferred (the branch/jump is held in EX), so the front end stays
            // frozen and the redirect is applied once the stall clears.
            if_valid <= 1'b0;
        end else if (!front_stall) begin
            pc_if    <= pc;
            pc4_if   <= pc4;
            if_valid <= 1'b1;
        end
    end

    // ======================================================================
    //  IF/ID register
    // ======================================================================
    // The branch/jump flushes are gated by `& ~mem_stall`: when a load is
    // stalling the pipeline, a redirect resolved in EX must be DEFERRED, not
    // applied. Otherwise the redirecting instruction (held in EX by the stall)
    // would be flushed away while the frozen PC ignores the redirect target,
    // dropping the branch/jump entirely. Holding the flush until the stall
    // clears lets the instruction redirect (and write its link, for JAL/JALR)
    // normally. csr_redirect (trap/MRET) still wins immediately, as before.
    wire [31:0] id_pc, id_pc4, id_instr;
    wire        id_valid;

    reg_if_id u_if_id (
        .clk(clk), .rst(rst),
        .stall(stall_if_id | mem_stall), .flush((flush_if_id & ~mem_stall) | csr_redirect),
        .pc_in(pc_if), .pc4_in(pc4_if), .instr_in(imem_rdata), .valid_in(if_valid),
        .pc_out(id_pc), .pc4_out(id_pc4), .instr_out(id_instr), .valid_out(id_valid)
    );

    // ======================================================================
    //  ID — Decode / Register read / Immediate / Control / Exception detect
    // ======================================================================
    wire [6:0]  opcode, funct7;
    wire [4:0]  id_rd, id_rs1, id_rs2;
    wire [2:0]  funct3;
    wire [3:0]  id_alu_op;
    wire [2:0]  imm_sel;

    decoder u_dec (
        .instr(id_instr),
        .opcode(opcode), .rd(id_rd), .rs1(id_rs1), .rs2(id_rs2),
        .funct3(funct3), .funct7(funct7),
        .alu_op(id_alu_op), .imm_sel(imm_sel)
    );

    wire c_rw, c_asa, c_asb, c_mr, c_mw, c_mu, c_br, c_jm, c_cw;
    wire [1:0] c_msz, c_rsrc;
    wire c_ecall, c_ebreak, c_mret, c_illegal;

    control_unit u_ctrl (
        .opcode(opcode), .funct3(funct3), .funct7(funct7),
        .imm12(id_instr[31:20]),
        .reg_write(c_rw), .alu_src_a(c_asa), .alu_src_b(c_asb),
        .mem_read(c_mr), .mem_write(c_mw), .mem_size(c_msz),
        .mem_unsigned(c_mu), .result_src(c_rsrc),
        .branch(c_br), .jump(c_jm), .csr_write(c_cw),
        .is_ecall(c_ecall), .is_ebreak(c_ebreak), .is_mret(c_mret),
        .illegal(c_illegal)
    );

    wire [31:0] id_imm;
    imm_gen u_imm (.instr(id_instr), .imm_sel(imm_sel), .imm(id_imm));

    // Register file. Writeback (WB stage) drives the write port.
    wire        wb_reg_write;
    wire [4:0]  wb_rd;
    wire [31:0] wb_data;
    wire [31:0] id_rs1_data, id_rs2_data;

    regfile u_rf (
        .clk(clk),
        .rs1_addr(id_rs1), .rs2_addr(id_rs2),
        .rs1_data(id_rs1_data), .rs2_data(id_rs2_data),
        .we(wb_reg_write), .rd_addr(wb_rd), .rd_data(wb_data)
    );

    // Pack the control bundle; gate writes off when the instruction is invalid
    // (bubble) so squashed instructions never commit.
    wire id_active = id_valid;
    wire [CTRLW-1:0] id_ctrl = pack_ctrl(
        c_rw & id_active, c_asa, c_asb, c_mr & id_active, c_mw & id_active,
        c_mu, c_br & id_active, c_jm & id_active, c_cw & id_active,
        c_msz, c_rsrc
    );

    // ---- ID-stage exception metadata -------------------------------------
    // Illegal / ECALL / EBREAK are mutually exclusive by opcode. tval for an
    // illegal instruction is the instruction word; 0 otherwise.
    wire        id_has_exc = (c_illegal | c_ecall | c_ebreak) & id_active;
    wire [3:0]  id_exc_cause = c_illegal ? `EXC_ILLEGAL    :
                               c_ecall   ? `EXC_ECALL_M    :
                               c_ebreak  ? `EXC_BREAKPOINT : 4'd0;
    wire [31:0] id_tval     = c_illegal ? id_instr : 32'd0;
    wire        id_is_mret  = c_mret & id_active;
    wire [11:0] id_csr_addr = id_instr[31:20];

    // ======================================================================
    //  ID/EX register
    // ======================================================================
    wire [31:0] ex_pc, ex_pc4, ex_rs1_data, ex_rs2_data, ex_imm;
    wire [4:0]  ex_rs1, ex_rs2, ex_rd;
    wire [2:0]  ex_funct3;
    wire [3:0]  ex_alu_op;
    wire [CTRLW-1:0] ex_ctrl;
    wire        ex_valid;
    wire        ex_has_exc;
    wire [3:0]  ex_exc_cause;
    wire [31:0] ex_tval;
    wire        ex_is_mret;
    wire [11:0] ex_csr_addr;

    reg_id_ex #(.CTRLW(CTRLW)) u_id_ex (
        .clk(clk), .rst(rst), .stall(mem_stall),
        .flush((flush_id_ex & ~mem_stall) | bubble_id_ex | csr_redirect),
        .pc_in(id_pc), .pc4_in(id_pc4),
        .rs1_data_in(id_rs1_data), .rs2_data_in(id_rs2_data), .imm_in(id_imm),
        .rs1_in(id_rs1), .rs2_in(id_rs2), .rd_in(id_rd),
        .funct3_in(funct3), .alu_op_in(id_alu_op), .ctrl_in(id_ctrl),
        .valid_in(id_active),
        .has_exc_in(id_has_exc), .exc_cause_in(id_exc_cause), .tval_in(id_tval),
        .is_mret_in(id_is_mret), .csr_addr_in(id_csr_addr),
        .pc_out(ex_pc), .pc4_out(ex_pc4),
        .rs1_data_out(ex_rs1_data), .rs2_data_out(ex_rs2_data), .imm_out(ex_imm),
        .rs1_out(ex_rs1), .rs2_out(ex_rs2), .rd_out(ex_rd),
        .funct3_out(ex_funct3), .alu_op_out(ex_alu_op), .ctrl_out(ex_ctrl),
        .valid_out(ex_valid),
        .has_exc_out(ex_has_exc), .exc_cause_out(ex_exc_cause), .tval_out(ex_tval),
        .is_mret_out(ex_is_mret), .csr_addr_out(ex_csr_addr)
    );

    assign ex_jump = ex_ctrl[CTRL_JM];

    // ======================================================================
    //  EX — Forwarding, operand mux, ALU, branch, instr-misalign detect
    // ======================================================================
    wire        mem_reg_write;
    wire [4:0]  mem_rd;
    wire [31:0] mem_alu_result;
    wire [31:0] mem_fwd_value;        // result-source-aware EX/MEM forward value

    wire [1:0]  fwd_a, fwd_b;
    forwarding_unit u_fwd (
        .ex_rs1(ex_rs1), .ex_rs2(ex_rs2),
        .mem_reg_write(mem_reg_write), .mem_rd(mem_rd),
        .wb_reg_write(wb_reg_write),  .wb_rd(wb_rd),
        .fwd_a(fwd_a), .fwd_b(fwd_b)
    );

    // EX/MEM forward uses the ACTUAL writeback source, not just the ALU result:
    // JAL/JALR forward PC+4, CSR reads forward the CSR value. (Loads are never
    // an EX/MEM forward source — the load-use stall guarantees it.)
    reg [31:0] fwd_rs1, fwd_rs2;
    always @(*) begin
        case (fwd_a)
            `FWD_MEM: fwd_rs1 = mem_fwd_value;
            `FWD_WB : fwd_rs1 = wb_data;
            default : fwd_rs1 = ex_rs1_data;
        endcase
        case (fwd_b)
            `FWD_MEM: fwd_rs2 = mem_fwd_value;
            `FWD_WB : fwd_rs2 = wb_data;
            default : fwd_rs2 = ex_rs2_data;
        endcase
    end

    wire [31:0] alu_a = ex_ctrl[CTRL_ASA] ? ex_pc  : fwd_rs1;
    wire [31:0] alu_b = ex_ctrl[CTRL_ASB] ? ex_imm : fwd_rs2;

    wire [31:0] alu_result;
    alu u_alu (.a(alu_a), .b(alu_b), .alu_op(ex_alu_op), .result(alu_result));

    branch_unit u_br (
        .branch(ex_ctrl[CTRL_BR]), .funct3(ex_funct3),
        .op_a(fwd_rs1), .op_b(fwd_rs2), .take_branch(take_branch)
    );

    // Branch/jump target.
    wire [31:0] pc_imm    = ex_pc + ex_imm;
    wire [31:0] jalr_tgt  = (fwd_rs1 + ex_imm) & ~32'd1;
    wire        is_jalr   = ex_jump && ex_ctrl[CTRL_ASB]; // JALR uses imm src
    assign branch_target  = is_jalr ? jalr_tgt : pc_imm;

    wire [31:0] ex_store_data = fwd_rs2;     // store data (forwarded)

    // CSR operand: rs1 value (register form) or zero-extended uimm (imm form).
    wire [31:0] ex_csr_wsrc = ex_funct3[2] ? {27'd0, ex_rs1} : fwd_rs1;

    // Instruction-address-misaligned: a taken branch/jump to a target whose
    // low two bits are nonzero (IALIGN=32, no compressed instructions).
    wire        ex_tgt_misalign = ex_redirect && (branch_target[1:0] != 2'b00)
                                  && ex_valid;
    wire        ex_has_exc_f   = ex_has_exc | ex_tgt_misalign;
    wire [3:0]  ex_exc_cause_f = ex_has_exc ? ex_exc_cause : `EXC_INSTR_MISALIGN;
    wire [31:0] ex_tval_f      = ex_has_exc ? ex_tval : branch_target;

    // ======================================================================
    //  EX/MEM register
    // ======================================================================
    wire [31:0] mem_store_data, mem_pc4;
    wire [2:0]  mem_funct3;
    wire [CTRLW-1:0] mem_ctrl;
    wire        mem_valid;
    wire        mem_has_exc_c;        // carried exception (from ID/EX upstream)
    wire [3:0]  mem_exc_cause_c;
    wire [31:0] mem_tval_c;
    wire        mem_is_mret;
    wire [11:0] mem_csr_addr;
    wire [31:0] mem_csr_wsrc;

    reg_ex_mem #(.CTRLW(CTRLW)) u_ex_mem (
        .clk(clk), .rst(rst), .stall(mem_stall), .flush(csr_redirect),
        .alu_result_in(alu_result), .store_data_in(ex_store_data),
        .pc4_in(ex_pc4), .rd_in(ex_rd), .funct3_in(ex_funct3),
        .ctrl_in(ex_ctrl), .valid_in(ex_valid),
        .has_exc_in(ex_has_exc_f), .exc_cause_in(ex_exc_cause_f),
        .tval_in(ex_tval_f), .is_mret_in(ex_is_mret), .csr_addr_in(ex_csr_addr),
        .csr_wsrc_in(ex_csr_wsrc),
        .alu_result_out(mem_alu_result), .store_data_out(mem_store_data),
        .pc4_out(mem_pc4), .rd_out(mem_rd), .funct3_out(mem_funct3),
        .ctrl_out(mem_ctrl), .valid_out(mem_valid),
        .has_exc_out(mem_has_exc_c), .exc_cause_out(mem_exc_cause_c),
        .tval_out(mem_tval_c), .is_mret_out(mem_is_mret),
        .csr_addr_out(mem_csr_addr), .csr_wsrc_out(mem_csr_wsrc)
    );

    assign mem_reg_write = mem_ctrl[CTRL_RW] & mem_valid;

    // ======================================================================
    //  MEM — Load/Store unit, trap commit point, CSR file
    // ======================================================================
    wire        mem_read_c  = mem_ctrl[CTRL_MR];
    wire        mem_write_c = mem_ctrl[CTRL_MW];
    wire        mem_is_load  = mem_read_c  & mem_valid;
    wire        mem_is_store = mem_write_c & mem_valid;
    wire        mem_is_ls    = mem_is_load | mem_is_store;   // for misalign detect

    wire [3:0]  lsu_byte_en;
    wire [31:0] lsu_wdata, lsu_load_data;
    wire        lsu_misaligned;

    load_store_unit u_lsu (
        .addr(mem_alu_result), .mem_size(mem_ctrl[CTRL_MSZ_HI:CTRL_MSZ_LO]),
        .mem_unsigned(mem_ctrl[CTRL_MU]),
        .mem_read(mem_read_c), .mem_write(mem_write_c),
        .store_data(mem_store_data),
        .byte_en(lsu_byte_en), .bus_wdata(lsu_wdata),
        .bus_rdata(dmem_rdata), .load_data(lsu_load_data),
        .misaligned(lsu_misaligned)
    );

    // ---- Final exception resolution at MEM -------------------------------
    wire        mem_ls_misalign = lsu_misaligned & mem_is_ls;
    wire        mem_has_exc   = mem_has_exc_c | mem_ls_misalign;
    wire [3:0]  mem_exc_cause = mem_has_exc_c ? mem_exc_cause_c :
                                (mem_read_c ? `EXC_LOAD_MISALIGN
                                            : `EXC_STORE_MISALIGN);
    wire [31:0] mem_tval      = mem_has_exc_c ? mem_tval_c : mem_alu_result;
    wire [31:0] mem_pc        = mem_pc4 - 32'd4;     // PC of the MEM instruction

    // ---- Interrupt / trap / MRET arbitration -----------------------------
    wire        irq_pending;
    wire [3:0]  irq_code;
    // Take an interrupt only at a clean boundary: a valid instruction in MEM,
    // not mid memory-access stall (~waiting), and not already trapping on a
    // synchronous exception.
    wire        take_irq  = irq_pending & mem_valid & ~waiting & ~mem_has_exc;
    wire        trap_take = (mem_valid & mem_has_exc) | take_irq;
    wire        mret_take = mem_is_mret & mem_valid & ~mem_has_exc & ~take_irq;

    assign csr_redirect = trap_take | mret_take;

    // Only LOADS use the memory wait state: a load needs the BRAM data that
    // returns one cycle later, so the front end holds for that cycle. Stores
    // return no data and complete in a single MEM cycle, so they never stall.
    // (A trapping access is squashed.)
    assign dmem_access  = mem_is_load & ~trap_take;

    // Trap inputs to the CSR file.
    wire        trap_is_irq  = take_irq;                 // 1 only when no sync exc
    wire [3:0]  trap_cause   = (mem_valid & mem_has_exc) ? mem_exc_cause : irq_code;
    wire [31:0] trap_tval    = (mem_valid & mem_has_exc) ? mem_tval : 32'd0;

    // CSR read/modify/write commits only if the instruction is not trapping.
    wire        csr_en = mem_ctrl[CTRL_CW] & mem_valid & ~trap_take & ~mret_take;
    wire [31:0] csr_rdata;
    wire [31:0] mtvec, mepc;

    csr_file u_csr (
        .clk(clk), .rst(rst),
        .csr_en(csr_en), .csr_addr(mem_csr_addr), .csr_op(mem_funct3),
        .csr_wsrc(mem_csr_wsrc), .csr_rdata(csr_rdata),
        .trap_valid(trap_take), .trap_is_irq(trap_is_irq),
        .trap_cause(trap_cause), .trap_epc(mem_pc), .trap_tval(trap_tval),
        .mret_valid(mret_take),
        .instr_retire(wb_valid),
        .irq_timer(irq_timer), .irq_accel(irq_accel),
        .mtvec_o(mtvec), .mepc_o(mepc),
        .irq_pending(irq_pending), .irq_code_o(irq_code)
    );

    assign csr_target = trap_take ? mtvec : mepc;       // trap->mtvec, mret->mepc

    // Result-source-aware EX/MEM forward value (see forwarding mux in EX).
    assign mem_fwd_value = (mem_ctrl[CTRL_RSRC_HI:CTRL_RSRC_LO] == `RES_PC4) ? mem_pc4   :
                           (mem_ctrl[CTRL_RSRC_HI:CTRL_RSRC_LO] == `RES_CSR) ? csr_rdata :
                                                             mem_alu_result;

    // ---- Data bus drive (single-cycle request pulse) ---------------------
    // A load issues one request pulse on its first MEM cycle, then rides out the
    // BRAM latency while `waiting`. A store is naturally one cycle in MEM, so it
    // is its own single-cycle pulse. Either way the bus sees exactly one
    // request, so side-effecting peripherals (UART TX, RX pop, W1C) fire once.
    wire        load_pulse  = dmem_access & ~waiting;
    wire        store_pulse = mem_is_store & ~trap_take;
    assign dmem_req     = load_pulse | store_pulse;
    assign dmem_we      = store_pulse;
    assign dmem_addr    = mem_alu_result;
    assign dmem_wdata   = lsu_wdata;
    assign dmem_byte_en = lsu_byte_en;

    // Sticky bus-error flag (observed when a response returns error).
    reg bus_error_r;
    always @(posedge clk) begin
        if (rst)                          bus_error_r <= 1'b0;
        else if (dmem_ready & dmem_error) bus_error_r <= 1'b1;
    end
    assign bus_error = bus_error_r;

    // ======================================================================
    //  MEM/WB register  (flushed when the MEM instruction traps)
    // ======================================================================
    wire [31:0] wb_alu_result, wb_load_data, wb_pc4, wb_csr_data;
    wire [CTRLW-1:0] wb_ctrl;
    wire        wb_valid;

    reg_mem_wb #(.CTRLW(CTRLW)) u_mem_wb (
        .clk(clk), .rst(rst), .stall(mem_stall), .flush(trap_take),
        .alu_result_in(mem_alu_result), .load_data_in(lsu_load_data),
        .pc4_in(mem_pc4), .csr_data_in(csr_rdata),
        .rd_in(mem_rd), .ctrl_in(mem_ctrl), .valid_in(mem_valid),
        .alu_result_out(wb_alu_result), .load_data_out(wb_load_data),
        .pc4_out(wb_pc4), .csr_data_out(wb_csr_data),
        .rd_out(wb_rd), .ctrl_out(wb_ctrl), .valid_out(wb_valid)
    );

    // ======================================================================
    //  WB — Writeback mux
    // ======================================================================
    reg [31:0] wb_mux;
    always @(*) begin
        case (wb_ctrl[CTRL_RSRC_HI:CTRL_RSRC_LO])
            `RES_ALU: wb_mux = wb_alu_result;
            `RES_MEM: wb_mux = wb_load_data;
            `RES_PC4: wb_mux = wb_pc4;
            `RES_CSR: wb_mux = wb_csr_data;
            default : wb_mux = wb_alu_result;
        endcase
    end
    assign wb_data       = wb_mux;
    assign wb_reg_write  = wb_ctrl[CTRL_RW] & wb_valid;

    // ======================================================================
    //  Hazard unit
    // ======================================================================
    hazard_unit u_haz (
        .ex_mem_read(ex_ctrl[CTRL_MR] & ex_valid), .ex_rd(ex_rd),
        .id_rs1(id_rs1), .id_rs2(id_rs2),
        .ex_take_branch(take_branch), .ex_jump(ex_jump),
        .stall_pc(stall_pc), .stall_if_id(stall_if_id),
        .bubble_id_ex(bubble_id_ex),
        .flush_if_id(flush_if_id), .flush_id_ex(flush_id_ex)
    );

    // ======================================================================
    //  Debug taps
    // ======================================================================
    assign dbg_pc   = pc;
    assign dbg_trap = trap_take;

endmodule
