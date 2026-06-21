// ============================================================================
// timer.v  -  Machine timer peripheral (memory-mapped) with interrupt
//
// Base 0x0000_3000. Word registers (addr[7:2] selects):
//   0x00  MTIME     (R/W)  free-running up-counter (counts while CTRL.EN=1)
//   0x04  MTIMECMP  (R/W)  compare value
//   0x08  CTRL      (R/W)  [0]EN enable count  [1]IE irq enable  [2]ARLD reload
//   0x0C  STATUS    (R/Wc) [0]MATCH match flag (write 1 to clear)
//
// When MTIME reaches MTIMECMP the MATCH flag sets. irq_timer = MATCH & IE.
// With CTRL.ARLD set, MTIME resets to 0 on match (periodic interrupts); the
// handler clears MATCH (W1C) to deassert the request. A small prescaler scales
// the tick rate so practical real-time delays fit in 32 bits.
//
// Custom-bus slave: 1-cycle valid/ready handshake.
// ============================================================================
`include "solvyr3_defs.vh"

module timer #(
    parameter integer PRESCALE = 1      // clocks per timer tick (>=1)
) (
    input  wire        clk,
    input  wire        rst,

    // ---- Custom-bus slave port ----
    input  wire        req,
    input  wire        we,
    input  wire [31:0] addr,
    input  wire [31:0] wdata,
    input  wire [3:0]  byte_en,
    output reg  [31:0] rdata,
    output reg         ready,

    // ---- Interrupt ----
    output wire        irq_timer
);

    localparam [5:0] REG_MTIME = 6'd0, REG_CMP = 6'd1,
                     REG_CTRL  = 6'd2, REG_STATUS = 6'd3;

    wire [5:0] widx = addr[7:2];
    wire       wr   = req && we;

    reg [31:0] mtime;
    reg [31:0] mtimecmp;
    reg        en, ie, arld;     // CTRL bits
    reg        match;            // STATUS.MATCH
    reg [31:0] presc_cnt;

    wire tick = (PRESCALE <= 1) ? 1'b1 : (presc_cnt == (PRESCALE-1));
    wire match_event = en && tick && (mtime == mtimecmp);

    // ---- Prescaler -------------------------------------------------------
    always @(posedge clk) begin
        if (rst)            presc_cnt <= 32'd0;
        else if (!en)       presc_cnt <= 32'd0;
        else if (tick)      presc_cnt <= 32'd0;
        else                presc_cnt <= presc_cnt + 32'd1;
    end

    // ---- Counter + compare + control state -------------------------------
    always @(posedge clk) begin
        if (rst) begin
            mtime    <= 32'd0;
            mtimecmp <= 32'hFFFF_FFFF;
            en       <= 1'b0;
            ie       <= 1'b0;
            arld     <= 1'b0;
            match    <= 1'b0;
        end else begin
            // Count.
            if (en && tick) begin
                if (match_event && arld) mtime <= 32'd0;
                else                     mtime <= mtime + 32'd1;
            end
            // Match flag (sticky until cleared).
            if (match_event) match <= 1'b1;

            // Register writes (byte-enables ignored for control regs: 32-bit).
            if (wr) begin
                case (widx)
                    REG_MTIME : mtime    <= wdata;
                    REG_CMP   : mtimecmp <= wdata;
                    REG_CTRL  : begin en <= wdata[0]; ie <= wdata[1]; arld <= wdata[2]; end
                    REG_STATUS: if (wdata[0]) match <= 1'b0;   // W1C
                    default   : ;
                endcase
            end
        end
    end

    assign irq_timer = match & ie;

    // ---- Read path -------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            rdata <= 32'd0;
            ready <= 1'b0;
        end else begin
            ready <= req;
            case (widx)
                REG_MTIME : rdata <= mtime;
                REG_CMP   : rdata <= mtimecmp;
                REG_CTRL  : rdata <= {29'd0, arld, ie, en};
                REG_STATUS: rdata <= {31'd0, match};
                default   : rdata <= 32'd0;
            endcase
        end
    end

endmodule
