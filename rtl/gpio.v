// ============================================================================
// gpio.v  -  General-purpose I/O peripheral (memory-mapped)
//
// Base 0x0000_2000. Word registers (addr[7:2] selects):
//   0x00  LED_OUT  (R/W)  drives board LEDs
//   0x04  SW_IN    (R)    synchronized slide-switch inputs
//   0x08  BTN_IN   (R)    synchronized push-button inputs
//
// Switch and button inputs cross from the asynchronous board domain into the
// system clock domain through 2-flop synchronizers to avoid metastability.
// Custom-bus slave: 1-cycle valid/ready handshake matching the BRAMs.
// ============================================================================
`include "solvyr3_defs.vh"

module gpio #(
    parameter integer NUM_LED = 16,
    parameter integer NUM_SW  = 16,
    parameter integer NUM_BTN = 5
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

    // ---- Board I/O ----
    output wire [NUM_LED-1:0] led,
    input  wire [NUM_SW-1:0]  sw,
    input  wire [NUM_BTN-1:0] btn
);

    localparam [5:0] REG_LED = 6'h00 >> 2,   // word index 0
                     REG_SW  = 6'h04 >> 2,   // word index 1
                     REG_BTN = 6'h08 >> 2;   // word index 2

    wire [5:0] widx = addr[7:2];

    // ---- Input synchronizers (2-flop) ------------------------------------
    reg [NUM_SW-1:0]  sw_meta,  sw_sync;
    reg [NUM_BTN-1:0] btn_meta, btn_sync;
    always @(posedge clk) begin
        if (rst) begin
            sw_meta  <= {NUM_SW{1'b0}};  sw_sync  <= {NUM_SW{1'b0}};
            btn_meta <= {NUM_BTN{1'b0}}; btn_sync <= {NUM_BTN{1'b0}};
        end else begin
            sw_meta  <= sw;   sw_sync  <= sw_meta;
            btn_meta <= btn;  btn_sync <= btn_meta;
        end
    end

    // ---- LED output register --------------------------------------------
    reg [31:0] led_reg;
    always @(posedge clk) begin
        if (rst)
            led_reg <= 32'd0;
        else if (req && we && (widx == REG_LED)) begin
            if (byte_en[0]) led_reg[7:0]   <= wdata[7:0];
            if (byte_en[1]) led_reg[15:8]  <= wdata[15:8];
            if (byte_en[2]) led_reg[23:16] <= wdata[23:16];
            if (byte_en[3]) led_reg[31:24] <= wdata[31:24];
        end
    end
    assign led = led_reg[NUM_LED-1:0];

    // ---- Read path (registered, 1-cycle latency) ------------------------
    always @(posedge clk) begin
        if (rst) begin
            rdata <= 32'd0;
            ready <= 1'b0;
        end else begin
            ready <= req;
            case (widx)
                REG_LED: rdata <= led_reg;
                REG_SW : rdata <= {{(32-NUM_SW){1'b0}},  sw_sync};
                REG_BTN: rdata <= {{(32-NUM_BTN){1'b0}}, btn_sync};
                default: rdata <= 32'd0;
            endcase
        end
    end

endmodule
