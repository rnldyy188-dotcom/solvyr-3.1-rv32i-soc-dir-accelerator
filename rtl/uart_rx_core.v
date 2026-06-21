// ============================================================================
// uart_rx_core.v  -  Reusable 8-N-1 UART receiver (sync + sample FSM)
//
// The receive half of an 8-N-1 serial port, factored out so the system UART
// (uart.v) and the boot loader (prog_loader.v) share ONE implementation instead
// of each carrying its own copy of the same FSM. Each caller still instantiates
// its own copy of this module, so the two receive datapaths stay physically
// independent at run time (the loader owns the line during boot; the CPU's UART
// owns it afterwards) — only the source is shared.
//
// (Named *_core, not uart_rx, because both callers name their serial input pin
// `uart_rx`; a distinct module name avoids any net/instance name clash.)
//
// Behaviour:
//   - 2-flop synchronizes the asynchronous `rx` line into the clock domain.
//   - Detects the start edge, re-checks it at the half-bit point (false-start
//     reject), then samples the 8 data bits LSB-first at their bit centres.
//   - On a completed frame, presents the byte on `data` and pulses `strobe`
//     high for exactly one clock. The caller latches `data` (and applies any
//     valid/overrun policy) on that pulse.
//
// Bit period DIV = CLK_HZ / BAUD system clocks (clamped to >= 2 so a too-fast
// baud in simulation still has a sampling midpoint). The stop bit is not
// validated (framing-error detection is out of scope for this minimal core).
// ============================================================================

module uart_rx_core #(
    parameter integer CLK_HZ = 100_000_000,
    parameter integer BAUD   = 115_200
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       rx,            // asynchronous serial input pin
    output reg  [7:0] data,          // last received byte (valid when strobe=1)
    output reg        strobe         // 1-cycle pulse when a new byte is ready
);

    localparam integer DIV     = (CLK_HZ / BAUD) < 2 ? 2 : (CLK_HZ / BAUD);
    localparam integer HALFDIV = DIV / 2;

    // ---- 2-flop input synchronizer (idle line is high) -------------------
    reg rx_meta, rx_sync;
    always @(posedge clk) begin
        if (rst) begin rx_meta <= 1'b1; rx_sync <= 1'b1; end
        else     begin rx_meta <= rx;   rx_sync <= rx_meta; end
    end

    // ---- Receive FSM -----------------------------------------------------
    localparam [1:0] S_IDLE = 2'd0, S_START = 2'd1, S_DATA = 2'd2, S_STOP = 2'd3;
    reg [1:0]  state;
    reg [31:0] baud_cnt;
    reg [2:0]  bit_idx;
    reg [7:0]  shifter;

    always @(posedge clk) begin
        if (rst) begin
            state    <= S_IDLE;
            baud_cnt <= 32'd0;
            bit_idx  <= 3'd0;
            shifter  <= 8'd0;
            data     <= 8'd0;
            strobe   <= 1'b0;
        end else begin
            strobe <= 1'b0;                       // default: no new byte
            case (state)
                S_IDLE: begin
                    baud_cnt <= 32'd0;
                    if (!rx_sync) state <= S_START;          // falling start edge
                end
                S_START: begin
                    if (baud_cnt == HALFDIV-1) begin
                        baud_cnt <= 32'd0;
                        if (!rx_sync) begin                  // confirm true start
                            state   <= S_DATA;
                            bit_idx <= 3'd0;
                        end else begin
                            state <= S_IDLE;                 // glitch: false start
                        end
                    end else baud_cnt <= baud_cnt + 32'd1;
                end
                S_DATA: begin
                    if (baud_cnt == DIV-1) begin
                        baud_cnt <= 32'd0;
                        shifter  <= {rx_sync, shifter[7:1]}; // sample, LSB first
                        if (bit_idx == 3'd7) state   <= S_STOP;
                        else                 bit_idx <= bit_idx + 3'd1;
                    end else baud_cnt <= baud_cnt + 32'd1;
                end
                S_STOP: begin
                    if (baud_cnt == DIV-1) begin
                        baud_cnt <= 32'd0;
                        state    <= S_IDLE;
                        data     <= shifter;
                        strobe   <= 1'b1;                    // byte complete
                    end else baud_cnt <= baud_cnt + 32'd1;
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
