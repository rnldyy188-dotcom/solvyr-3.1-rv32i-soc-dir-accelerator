// ============================================================================
// solvyr3_top.v  -  Board top level for the Artix-7 (e.g. Nexys A7 / Basys-class)
//
// Connects the Solvyr-3 SoC to the physical board: clock pin, reset push-button,
// LEDs, slide switches, push-buttons, USB-UART, and the multiplexed 7-segment
// display. Clocking and a clean synchronous reset come from clk_reset; the
// 7-segment display shows the live program counter for debug.
//
//   LED[15:12] = {accel_done, accel_busy, cpu_trap(sticky), heartbeat}
//   LED[11:0]  = GPIO LED register (software controlled)
//   7-seg      = current fetch PC (hex)
//
// Pin names match the constraints in constraints/solvyr3_artix7.xdc.
// ============================================================================
`include "solvyr3_defs.vh"

module solvyr3_top #(
    parameter         IMEM_INIT = "",          // program image (.hex) for BRAM
    parameter integer CLK_HZ    = 100_000_000,
    parameter integer BAUD      = 115_200,
    parameter         USE_LOADER = 0
) (
    input  wire        CLK100MHZ,              // board oscillator
    input  wire        CPU_RESETN,             // reset button (active low)

    output wire [15:0] LED,
    input  wire [15:0] SW,
    input  wire [4:0]  BTN,                    // {C,U,D,L,R}

    input  wire        UART_TXD_IN,            // host -> FPGA  (FPGA RX)
    output wire        UART_RXD_OUT,           // FPGA -> host  (FPGA TX)

    output wire [6:0]  SEG,                    // {g,f,e,d,c,b,a}, active low
    output wire        DP,                     // active low
    output wire [7:0]  AN                      // digit anodes, active low
);

    // ---- Clock + synchronous reset ---------------------------------------
    wire clk, rst;
    clk_reset #(.RST_ACTIVE_LOW(1)) u_clkrst (
        .clk_in(CLK100MHZ), .rst_btn(CPU_RESETN), .clk(clk), .rst(rst)
    );

    // ---- SoC --------------------------------------------------------------
    wire [15:0] gpio_led;
    wire [31:0] dbg_pc;
    wire        cpu_trap, bus_error, accel_busy, accel_done;

    solvyr3_soc #(
        .IMEM_INIT(IMEM_INIT), .IMEM_WORDS(1024), .DMEM_WORDS(1024),
        .SCRATCH_WORDS(1024), .CLK_HZ(CLK_HZ), .BAUD(BAUD),
        .NUM_LED(16), .NUM_SW(16), .NUM_BTN(5), .USE_LOADER(USE_LOADER)
    ) u_soc (
        .clk(clk), .rst(rst),
        .gpio_led(gpio_led), .gpio_sw(SW), .gpio_btn(BTN),
        .uart_tx(UART_RXD_OUT), .uart_rx(UART_TXD_IN),
        .boot_sel(SW[15]),
        .dbg_pc(dbg_pc), .cpu_trap(cpu_trap), .bus_error(bus_error),
        .accel_busy(accel_busy), .accel_done(accel_done)
    );

    // ---- Heartbeat (visual "CPU running / clock alive") -------------------
    reg [25:0] heartbeat;
    always @(posedge clk) begin
        if (rst) heartbeat <= 26'd0;
        else     heartbeat <= heartbeat + 26'd1;
    end

    // ---- LED mapping ------------------------------------------------------
    assign LED = { accel_done, accel_busy, cpu_trap, heartbeat[25],
                   gpio_led[11:0] };

    // ---- 7-segment debug display (shows the PC) ---------------------------
    seven_seg #(.REFRESH_BITS(17)) u_seg (
        .clk(clk), .rst(rst), .value(dbg_pc),
        .dp_in({7'b0, bus_error}),     // DP0 lights on a bus error
        .seg(SEG), .dp(DP), .an(AN)
    );

endmodule
