// ============================================================================
// csr_file.v  -  Machine-mode CSR file + trap/interrupt sequencer
//
// Implements the RV32 machine-mode control/status registers and the trap
// commit logic for the Solvyr-3 core. Only M-mode is implemented (MPP is
// hardwired to 2'b11), which is all a bare-metal embedded SoC needs.
//
// The core resolves every trap and every MRET at a single point in the MEM
// stage (see solvyr3_core.v). This module is told, for the instruction
// currently committing in MEM, whether it:
//   - executes a CSR read/modify/write   (csr_en)
//   - takes a trap (exception or irq)     (trap_valid)
//   - is an MRET                          (mret_valid)
// Those three are mutually exclusive (a trapped instruction is squashed, so
// the core deasserts csr_en/mret_valid when trap_valid is set).
//
// CSR read returns the OLD value (architectural CSRRW/S/C semantics); the new
// value is written the same cycle. mtvec is direct mode (all traps vector to
// mtvec). mepc/mtvec are kept 4-byte aligned (IALIGN=32, no compressed ISA).
//
// Synthesizable: one sequential always block for state, one combinational
// always block for the read mux. No latches, no initial-for-logic.
// ============================================================================
`include "solvyr3_defs.vh"

module csr_file (
    input  wire        clk,
    input  wire        rst,

    // ---- CSR instruction access (commits in MEM) ----
    input  wire        csr_en,      // a CSR instruction is committing
    input  wire [11:0] csr_addr,    // instr[31:20]
    input  wire [2:0]  csr_op,      // funct3: CSRRW/S/C and immediate variants
    input  wire [31:0] csr_wsrc,    // rs1 value (reg form) or zero-ext uimm
    output reg  [31:0] csr_rdata,   // OLD CSR value -> writeback mux

    // ---- trap commit (from MEM-stage trap logic) ----
    input  wire        trap_valid,  // take a trap this cycle
    input  wire        trap_is_irq, // 1 = interrupt, 0 = synchronous exception
    input  wire [3:0]  trap_cause,  // cause code (sync exc code or irq code)
    input  wire [31:0] trap_epc,    // PC of trapping/interrupted instruction
    input  wire [31:0] trap_tval,   // faulting address / instruction / 0

    // ---- MRET commit ----
    input  wire        mret_valid,

    // ---- retirement counter strobe ----
    input  wire        instr_retire,// an instruction commits in WB this cycle

    // ---- interrupt source lines (level-sensitive) ----
    input  wire        irq_timer,   // machine timer interrupt pending
    input  wire        irq_accel,   // DIR accelerator "done" interrupt pending

    // ---- outputs to the core ----
    output wire [31:0] mtvec_o,     // trap vector base (redirect target on trap)
    output wire [31:0] mepc_o,      // return address (redirect target on MRET)
    output wire        irq_pending, // enabled+pending interrupt with MIE set
    output wire [3:0]  irq_code_o   // cause code of the interrupt to take
);

    // ======================================================================
    //  Architectural state
    // ======================================================================
    reg        mstatus_mie;         // mstatus[3]  : global interrupt enable
    reg        mstatus_mpie;        // mstatus[7]  : previous MIE
    reg        mie_mtie;            // mie[7]      : timer interrupt enable
    reg        mie_meie;            // mie[11]     : external interrupt enable
    reg [31:0] mtvec;               // trap vector base (direct mode)
    reg [31:0] mepc;                // exception program counter
    reg [31:0] mcause;              // trap cause ({irq, 27'b0, code})
    reg [31:0] mtval;               // trap value
    reg [31:0] mscratch;            // scratch register for the trap handler
    reg [63:0] cycle_ctr;           // mcycle / cycle
    reg [63:0] instret_ctr;         // minstret / instret

    // ---- mip is purely a view of the live interrupt source lines ----------
    wire [31:0] mip_view = (irq_timer ? (32'd1 << `IRQ_MTI) : 32'd0) |
                           (irq_accel ? (32'd1 << `IRQ_MEI) : 32'd0);
    wire [31:0] mie_view = (mie_mtie  ? (32'd1 << `IRQ_MTI) : 32'd0) |
                           (mie_meie  ? (32'd1 << `IRQ_MEI) : 32'd0);
    // mstatus: MPP hardwired to 2'b11 (machine mode).
    wire [31:0] mstatus_view = (32'd3            << 11) |   // MPP = M-mode
                               (mstatus_mpie ? (32'd1 << `MSTATUS_MPIE) : 32'd0) |
                               (mstatus_mie  ? (32'd1 << `MSTATUS_MIE ) : 32'd0);
    // misa: MXL=1 (RV32), extension I only.
    localparam [31:0] MISA_VAL = (32'd1 << 30) | (32'd1 << 8);

    // ======================================================================
    //  Read mux (combinational): returns the current value of csr_addr
    // ======================================================================
    always @(*) begin
        case (csr_addr)
            `CSR_MSTATUS : csr_rdata = mstatus_view;
            `CSR_MISA    : csr_rdata = MISA_VAL;
            `CSR_MIE     : csr_rdata = mie_view;
            `CSR_MTVEC   : csr_rdata = mtvec;
            `CSR_MSCRATCH: csr_rdata = mscratch;
            `CSR_MEPC    : csr_rdata = mepc;
            `CSR_MCAUSE  : csr_rdata = mcause;
            `CSR_MTVAL   : csr_rdata = mtval;
            `CSR_MIP     : csr_rdata = mip_view;
            `CSR_CYCLE   : csr_rdata = cycle_ctr[31:0];
            `CSR_CYCLEH  : csr_rdata = cycle_ctr[63:32];
            `CSR_INSTRET : csr_rdata = instret_ctr[31:0];
            `CSR_INSTRETH: csr_rdata = instret_ctr[63:32];
            `CSR_MVENDORID,
            `CSR_MARCHID,
            `CSR_MIMPID,
            `CSR_MHARTID : csr_rdata = 32'd0;     // single hart 0, no IDs
            default      : csr_rdata = 32'd0;
        endcase
    end

    // ======================================================================
    //  Write-value computation for a CSR instruction
    // ======================================================================
    // newval is the value to store; csr_rdata is the old value (read above).
    reg [31:0] newval;
    always @(*) begin
        case (csr_op)
            `CSRRW, `CSRRWI: newval = csr_wsrc;                 // write
            `CSRRS, `CSRRSI: newval = csr_rdata |  csr_wsrc;    // set bits
            `CSRRC, `CSRRCI: newval = csr_rdata & ~csr_wsrc;    // clear bits
            default        : newval = csr_rdata;
        endcase
    end

    // A set/clear with a zero source performs no write (no side effects), per
    // the ISA. CSRRW always writes (even rd=x0 / source 0).
    wire is_set_clear = (csr_op == `CSRRS) || (csr_op == `CSRRC) ||
                        (csr_op == `CSRRSI)|| (csr_op == `CSRRCI);
    wire do_csr_write = csr_en && !(is_set_clear && (csr_wsrc == 32'd0));

    // ======================================================================
    //  State update (one sequential block, trap > mret > csr-write priority)
    // ======================================================================
    always @(posedge clk) begin
        if (rst) begin
            mstatus_mie  <= 1'b0;
            mstatus_mpie <= 1'b0;
            mie_mtie     <= 1'b0;
            mie_meie     <= 1'b0;
            mtvec        <= 32'd0;
            mepc         <= 32'd0;
            mcause       <= 32'd0;
            mtval        <= 32'd0;
            mscratch     <= 32'd0;
            cycle_ctr    <= 64'd0;
            instret_ctr  <= 64'd0;
        end else begin
            // Free-running counters.
            cycle_ctr   <= cycle_ctr + 64'd1;
            if (instr_retire)
                instret_ctr <= instret_ctr + 64'd1;

            if (trap_valid) begin
                // Enter trap: save context, disable interrupts, set cause/tval.
                mepc         <= {trap_epc[31:2], 2'b00};
                mcause       <= {trap_is_irq, 27'd0, trap_cause};
                mtval        <= trap_is_irq ? 32'd0 : trap_tval;
                mstatus_mpie <= mstatus_mie;
                mstatus_mie  <= 1'b0;
            end else if (mret_valid) begin
                // Return from trap: restore interrupt-enable stack.
                mstatus_mie  <= mstatus_mpie;
                mstatus_mpie <= 1'b1;
            end else if (do_csr_write) begin
                case (csr_addr)
                    `CSR_MSTATUS : begin
                        mstatus_mie  <= newval[`MSTATUS_MIE];
                        mstatus_mpie <= newval[`MSTATUS_MPIE];
                    end
                    `CSR_MIE     : begin
                        mie_mtie <= newval[`IRQ_MTI];
                        mie_meie <= newval[`IRQ_MEI];
                    end
                    `CSR_MTVEC   : mtvec    <= {newval[31:2], 2'b00};
                    `CSR_MEPC    : mepc     <= {newval[31:2], 2'b00};
                    `CSR_MCAUSE  : mcause   <= newval;
                    `CSR_MTVAL   : mtval    <= newval;
                    `CSR_MSCRATCH: mscratch <= newval;
                    default      : ;  // read-only / unimplemented: ignore
                endcase
            end
        end
    end

    // ======================================================================
    //  Outputs
    // ======================================================================
    assign mtvec_o     = mtvec;
    assign mepc_o      = mepc;

    // An interrupt is takeable when globally enabled, locally enabled, pending.
    wire timer_take = mstatus_mie && mie_mtie && irq_timer;
    wire accel_take = mstatus_mie && mie_meie && irq_accel;
    assign irq_pending = timer_take || accel_take;
    // Cause codes come straight from the standard mip/mie bit positions, so the
    // magic 7/11 stay tied to their single definition in solvyr3_defs.vh.
    // Timer (MTI) is prioritised over the accelerator's external interrupt (MEI).
    localparam [3:0] CAUSE_MTI = `IRQ_MTI;   // 7
    localparam [3:0] CAUSE_MEI = `IRQ_MEI;   // 11
    assign irq_code_o  = timer_take ? CAUSE_MTI : CAUSE_MEI;

endmodule
