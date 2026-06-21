// ============================================================================
// uart.v  -  8-N-1 UART (TX + RX) with baud generator (memory-mapped)
//
// Base 0x0000_4000. Word registers (addr[7:2] selects):
//   0x00  TXDATA  (W)  write a byte to transmit (accepted when TX_READY=1)
//   0x04  RXDATA  (R)  read the received byte; reading clears RX_VALID
//   0x08  STATUS  (R)  [0]TX_BUSY [1]TX_READY [2]RX_VALID [3]RX_OVERRUN
//   0x0C  CTRL    (W)  [0] write 1 to clear RX_OVERRUN
//
// Frame: 1 start bit (0), 8 data bits LSB-first, 1 stop bit (1). The bit period
// is DIV = CLK_HZ/BAUD system clocks. RX 2-flop-synchronizes the line, detects
// the start edge, samples each bit at its center, and flags overrun if a new
// byte arrives before the previous one is read.
//
// TX path: a 1-deep HOLDING REGISTER decouples the bus write from the bit
// shifter. A CPU write lands in the holding register (when empty) and is moved
// into the shifter on the next idle cycle; the holding register then frees up so
// the next byte can be queued while the current one transmits. TX_READY reflects
// "holding register empty" and TX_BUSY reflects "shifter active OR byte queued".
// This makes the software handshake reliable: after a write, TX_BUSY is held
// continuously until the frame completes, so a poll-before-write driver never
// races the write->busy edge. (The previous single-register TX silently dropped
// any write that arrived before TX_BUSY had propagated high, which is why the
// firmware needed a per-character guard delay -- no longer required.)
//
// This is the program-load / debug-print / test-result path. Custom-bus slave
// with the standard 1-cycle valid/ready handshake.
// ============================================================================
`include "solvyr3_defs.vh"

module uart #(
    parameter integer CLK_HZ = 100_000_000,
    parameter integer BAUD   = 115_200
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

    // ---- Serial pins ----
    output wire        uart_tx,
    input  wire        uart_rx
);

    localparam integer DIV = (CLK_HZ / BAUD) < 2 ? 2 : (CLK_HZ / BAUD);  // bit period
    localparam [5:0] REG_TX = 6'd0, REG_RX = 6'd1, REG_STATUS = 6'd2, REG_CTRL = 6'd3;

    wire [5:0] widx = addr[7:2];
    wire       wr   = req && we;

    // Bus strobes that affect the TX/RX state.
    wire tx_load  = wr && (widx == REG_TX);
    wire rx_read  = req && !we && (widx == REG_RX);
    wire ovr_clr  = wr && (widx == REG_CTRL) && wdata[0];

    // ======================================================================
    //  Transmitter  (1-deep holding register + bit shifter)
    // ======================================================================
    reg [9:0]  tx_frame;     // {stop, data[7:0], start}
    reg [3:0]  tx_bitcnt;    // bits remaining (0..10)
    reg [31:0] tx_baud;
    reg        tx_active;    // bit shifter busy
    reg        tx_line;
    reg [7:0]  tx_hold;      // holding register: next byte to send
    reg        tx_hold_full; // holding register occupied

    always @(posedge clk) begin
        if (rst) begin
            tx_frame     <= 10'h3FF;
            tx_bitcnt    <= 4'd0;
            tx_baud      <= 32'd0;
            tx_active    <= 1'b0;
            tx_line      <= 1'b1;     // idle line is high
            tx_hold      <= 8'd0;
            tx_hold_full <= 1'b0;
        end else begin
            // Bus write -> holding register (accepted only when it is empty; the
            // driver polls TX_READY first). One write fills one slot; a second
            // write while full is ignored, exactly as TX_READY advertises.
            if (tx_load && !tx_hold_full) begin
                tx_hold      <= wdata[7:0];
                tx_hold_full <= 1'b1;
            end

            if (!tx_active) begin
                tx_line <= 1'b1;                 // idle high between frames
                if (tx_hold_full) begin          // launch the queued byte
                    tx_frame     <= {1'b1, tx_hold, 1'b0}; // stop|data|start
                    tx_bitcnt    <= 4'd10;
                    tx_baud      <= 32'd0;
                    tx_active    <= 1'b1;
                    tx_hold_full <= 1'b0;         // slot freed -> TX_READY again
                end
            end else begin
                tx_line <= tx_frame[0];          // shift out LSB first
                if (tx_baud == DIV-1) begin
                    tx_baud   <= 32'd0;
                    tx_frame  <= {1'b1, tx_frame[9:1]};
                    tx_bitcnt <= tx_bitcnt - 4'd1;
                    if (tx_bitcnt == 4'd1)
                        tx_active <= 1'b0;        // last bit done
                end else begin
                    tx_baud <= tx_baud + 32'd1;
                end
            end
        end
    end

    assign uart_tx = tx_line;
    // "Busy" = something still in flight (queued byte or active shifter). Held
    // high continuously from the accepting write until the frame completes.
    wire tx_busy  = tx_active | tx_hold_full;
    wire tx_ready = !tx_hold_full;   // holding register can accept a byte

    // ======================================================================
    //  Receiver  (shared uart_rx_core + valid/overrun latching)
    // ======================================================================
    wire [7:0] rx_byte;
    wire       rx_strobe;

    uart_rx_core #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_rx (
        .clk(clk), .rst(rst), .rx(uart_rx),
        .data(rx_byte), .strobe(rx_strobe)
    );

    // Latch the received byte and track RX_VALID / RX_OVERRUN. A bus read of
    // RXDATA clears valid; a byte arriving before the previous one is read sets
    // overrun. The strobe's `rx_valid <= 1` is written after the read-clear, so
    // a byte completing in the same cycle as a read still registers as valid —
    // matching the original inline FSM exactly.
    reg [7:0] rx_data;
    reg       rx_valid;
    reg       rx_overrun;
    always @(posedge clk) begin
        if (rst) begin
            rx_data    <= 8'd0;
            rx_valid   <= 1'b0;
            rx_overrun <= 1'b0;
        end else begin
            if (rx_read) rx_valid   <= 1'b0;          // read clears valid
            if (ovr_clr) rx_overrun <= 1'b0;          // CTRL.W1C clears overrun
            if (rx_strobe) begin
                rx_data <= rx_byte;
                if (rx_valid && !rx_read) rx_overrun <= 1'b1; // prev not consumed
                rx_valid <= 1'b1;
            end
        end
    end

    // ======================================================================
    //  Read path
    // ======================================================================
    wire [31:0] status = {28'd0, rx_overrun, rx_valid, tx_ready, tx_busy};
    always @(posedge clk) begin
        if (rst) begin
            rdata <= 32'd0;
            ready <= 1'b0;
        end else begin
            ready <= req;
            case (widx)
                REG_RX    : rdata <= {24'd0, rx_data};
                REG_STATUS: rdata <= status;
                default   : rdata <= 32'd0;
            endcase
        end
    end

endmodule
