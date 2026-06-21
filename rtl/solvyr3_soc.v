// ============================================================================
// solvyr3_soc.v  -  Solvyr-3 SoC: core + memories + interconnect + peripherals
//
// Integrates the RV32I core (with machine-mode traps) onto the custom memory-
// mapped bus, with the full peripheral set and the DIR accelerator:
//
//   CPU.imem ---------------------------------> Instruction BRAM (port A, fetch)
//   CPU.dmem -> mm_interconnect -> slave 0 ----> Instruction BRAM (port B, data)
//                                  slave 1 ----> Data BRAM
//                                  slave 2 ----> GPIO            (LEDs/sw/btn)
//                                  slave 3 ----> Timer           (irq_timer)
//                                  slave 4 ----> UART            (tx/rx)
//                                  slave 5 ----> DIR accel regs
//                                  slave 6 ----> DIR accel scratchpad
//
// Interrupts (timer, accelerator-done) feed the core's trap unit. An optional
// UART boot loader (USE_LOADER=1) can write the program image into instruction
// BRAM via port B and hold the CPU in reset until the load completes.
//
// This is the simulation/synthesis integration target; solvyr3_top.v wraps it
// with clocking, reset synchronization, the 7-segment display, and board pins.
// ============================================================================
`include "solvyr3_defs.vh"

module solvyr3_soc #(
    parameter         IMEM_INIT      = "",      // hex image for instruction BRAM
    parameter         DMEM_INIT      = "",
    parameter integer IMEM_WORDS     = 1024,    // 4 KB
    parameter integer DMEM_WORDS     = 1024,    // 4 KB
    parameter integer SCRATCH_WORDS  = 1024,    // 4 KB accelerator scratchpad
    parameter integer CLK_HZ         = 100_000_000,
    parameter integer BAUD           = 115_200,
    parameter integer TIMER_PRESCALE = 1,
    parameter integer NUM_LED        = 16,
    parameter integer NUM_SW         = 16,
    parameter integer NUM_BTN        = 5,
    parameter         USE_LOADER     = 0
) (
    input  wire                clk,
    input  wire                rst,

    // ---- Board I/O ----
    output wire [NUM_LED-1:0]  gpio_led,
    input  wire [NUM_SW-1:0]   gpio_sw,
    input  wire [NUM_BTN-1:0]  gpio_btn,
    output wire                uart_tx,
    input  wire                uart_rx,
    input  wire                boot_sel,        // (USE_LOADER) 1 = UART boot

    // ---- Status / debug ----
    output wire [31:0]         dbg_pc,
    output wire                cpu_trap,        // sticky: a trap has been taken
    output wire                bus_error,       // sticky: an errored access
    output wire                accel_busy,
    output wire                accel_done
);

    // ======================================================================
    //  Reset gating for optional boot loader
    // ======================================================================
    wire load_done;
    wire core_rst = rst | ~load_done;           // CPU held in reset while loading

    // ======================================================================
    //  Core
    // ======================================================================
    wire [31:0] imem_addr, imem_rdata;
    wire        imem_en;                 // fetch enable (held low to stall the IF buffer)
    wire        c_req, c_we;
    wire [31:0] c_addr, c_wdata;
    wire [3:0]  c_byte_en;
    wire [31:0] c_rdata;
    wire        c_ready, c_error;
    wire        irq_timer, irq_accel;
    wire        dbg_trap;

    solvyr3_core u_core (
        .clk(clk), .rst(core_rst),
        .imem_addr(imem_addr), .imem_en(imem_en), .imem_rdata(imem_rdata),
        .dmem_req(c_req), .dmem_we(c_we), .dmem_addr(c_addr),
        .dmem_wdata(c_wdata), .dmem_byte_en(c_byte_en),
        .dmem_rdata(c_rdata), .dmem_ready(c_ready), .dmem_error(c_error),
        .irq_timer(irq_timer), .irq_accel(irq_accel),
        .dbg_pc(dbg_pc), .dbg_trap(dbg_trap), .bus_error(bus_error)
    );

    // Sticky "trap seen" flag for a status LED.
    reg trap_seen;
    always @(posedge clk) begin
        if (rst)           trap_seen <= 1'b0;
        else if (dbg_trap) trap_seen <= 1'b1;
    end
    assign cpu_trap = trap_seen;

    // ======================================================================
    //  Interconnect
    // ======================================================================
    wire        bus_we;
    wire [31:0] bus_addr, bus_wdata;
    wire [3:0]  bus_byte_en;
    wire [6:0]  slv_req, slv_ready;
    wire [223:0] slv_rdata;

    mm_interconnect u_xbar (
        .clk(clk), .rst(rst),
        .mem_valid(c_req), .mem_we(c_we), .mem_addr(c_addr),
        .mem_wdata(c_wdata), .mem_byte_en(c_byte_en),
        .mem_rdata(c_rdata), .mem_ready(c_ready), .mem_error(c_error),
        .bus_we(bus_we), .bus_addr(bus_addr), .bus_wdata(bus_wdata),
        .bus_byte_en(bus_byte_en),
        .slv_req(slv_req), .slv_ready(slv_ready), .slv_rdata(slv_rdata)
    );

    // Per-slave response wires.
    wire [31:0] rd_imem, rd_dmem, rd_gpio, rd_timer, rd_uart, rd_areg, rd_ascr;
    wire        ry_imem, ry_dmem, ry_gpio, ry_timer, ry_uart, ry_areg, ry_ascr;

    assign slv_rdata = {rd_ascr, rd_areg, rd_uart, rd_timer, rd_gpio, rd_dmem, rd_imem};
    assign slv_ready = {ry_ascr, ry_areg, ry_uart, ry_timer, ry_gpio, ry_dmem, ry_imem};

    // ======================================================================
    //  Instruction BRAM  (port A = fetch, port B = data bus / loader)
    // ======================================================================
    // Port B is driven by the loader during boot, otherwise by interconnect s0.
    wire        ld_req, ld_we;
    wire [31:0] ld_addr, ld_wdata;
    wire [3:0]  ld_byte_en;
    wire        ld_active = (USE_LOADER != 0) && ~load_done;

    wire        imb_req     = ld_active ? ld_req     : slv_req[0];
    wire        imb_we      = ld_active ? ld_we      : bus_we;
    wire [31:0] imb_addr    = ld_active ? ld_addr    : bus_addr;
    wire [31:0] imb_wdata   = ld_active ? ld_wdata   : bus_wdata;
    wire [3:0]  imb_byte_en = ld_active ? ld_byte_en : bus_byte_en;

    imem_bram #(
        .DEPTH_WORDS(IMEM_WORDS), .ADDR_BITS(10), .INIT_FILE(IMEM_INIT)
    ) u_imem (
        .clk(clk),
        .a_en(imem_en), .a_addr(imem_addr), .a_instr(imem_rdata),
        .b_req(imb_req), .b_we(imb_we), .b_addr(imb_addr),
        .b_wdata(imb_wdata), .b_byte_en(imb_byte_en),
        .b_rdata(rd_imem), .b_ready(ry_imem)
    );

    // ======================================================================
    //  Data BRAM (slave 1)
    // ======================================================================
    dmem_bram #(
        .DEPTH_WORDS(DMEM_WORDS), .ADDR_BITS(10), .INIT_FILE(DMEM_INIT)
    ) u_dmem (
        .clk(clk), .rst(rst),
        .req(slv_req[1]), .we(bus_we), .addr(bus_addr),
        .wdata(bus_wdata), .byte_en(bus_byte_en),
        .rdata(rd_dmem), .ready(ry_dmem)
    );

    // ======================================================================
    //  GPIO (slave 2)
    // ======================================================================
    gpio #(.NUM_LED(NUM_LED), .NUM_SW(NUM_SW), .NUM_BTN(NUM_BTN)) u_gpio (
        .clk(clk), .rst(rst),
        .req(slv_req[2]), .we(bus_we), .addr(bus_addr),
        .wdata(bus_wdata), .byte_en(bus_byte_en),
        .rdata(rd_gpio), .ready(ry_gpio),
        .led(gpio_led), .sw(gpio_sw), .btn(gpio_btn)
    );

    // ======================================================================
    //  Timer (slave 3)
    // ======================================================================
    timer #(.PRESCALE(TIMER_PRESCALE)) u_timer (
        .clk(clk), .rst(rst),
        .req(slv_req[3]), .we(bus_we), .addr(bus_addr),
        .wdata(bus_wdata), .byte_en(bus_byte_en),
        .rdata(rd_timer), .ready(ry_timer),
        .irq_timer(irq_timer)
    );

    // ======================================================================
    //  UART (slave 4)
    // ======================================================================
    uart #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_uart (
        .clk(clk), .rst(rst),
        .req(slv_req[4]), .we(bus_we), .addr(bus_addr),
        .wdata(bus_wdata), .byte_en(bus_byte_en),
        .rdata(rd_uart), .ready(ry_uart),
        .uart_tx(uart_tx), .uart_rx(uart_rx)
    );

    // ======================================================================
    //  DIR accelerator (slave 5 = regs, slave 6 = scratchpad)
    // ======================================================================
    dir_accel #(
        .SCRATCH_WORDS(SCRATCH_WORDS), .SCR_ABITS(10), .MAXK(7)
    ) u_accel (
        .clk(clk), .rst(rst),
        .rreq(slv_req[5]), .rwe(bus_we), .raddr(bus_addr),
        .rwdata(bus_wdata), .rbyte_en(bus_byte_en),
        .rrdata(rd_areg), .rready(ry_areg),
        .sreq(slv_req[6]), .swe(bus_we), .saddr(bus_addr),
        .swdata(bus_wdata), .sbyte_en(bus_byte_en),
        .srdata(rd_ascr), .sready(ry_ascr),
        .irq_accel(irq_accel), .acc_busy(accel_busy), .acc_done(accel_done)
    );

    // ======================================================================
    //  Optional UART boot loader
    // ======================================================================
    generate
        if (USE_LOADER != 0) begin : g_loader
            prog_loader #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .IMEM_WORDS(IMEM_WORDS)) u_loader (
                .clk(clk), .rst(rst), .enable(boot_sel), .uart_rx(uart_rx),
                .imem_req(ld_req), .imem_we(ld_we), .imem_addr(ld_addr),
                .imem_wdata(ld_wdata), .imem_byte_en(ld_byte_en),
                .load_done(load_done)
            );
        end else begin : g_noloader
            assign ld_req = 1'b0;  assign ld_we = 1'b0;
            assign ld_addr = 32'd0; assign ld_wdata = 32'd0; assign ld_byte_en = 4'd0;
            assign load_done = 1'b1;        // no loader: run immediately
        end
    endgenerate

endmodule
