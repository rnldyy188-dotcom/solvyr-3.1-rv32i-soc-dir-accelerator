// ============================================================================
// tb_bench.v  -  Cycle-accurate performance comparison on the RTL
//
// Runs bench/bench_c.hex on the full Solvyr-3 SoC -- the SAME image baked into
// the FPGA bitstream -- so the simulation reports the SAME software/accelerator
// cycle counts the board prints over UART. The program computes a valid 2D
// convolution in software (on the base RV32I core, no hardware multiplier) and
// on the DIR accelerator, then publishes the results to a Data BRAM mailbox.
//
// The mailbox is written BEFORE the program's (slow) UART printout, so this
// testbench finishes the instant compute completes -- it does NOT wait for or
// decode serial output, and it does NOT depend on the UART guard delay.
//
//   mailbox @ DMEM 0x1A00 : word 640 = sw_cycles
//                           word 641 = hw_cycles
//                           word 642 = match (1 if sw tile == hw tile)
//   (keep RESULT_W in sync with MAILBOX in bench/bench.c)
//
// Build:  ./run_sim.sh bench   (rebuilds bench_c.hex if a riscv toolchain is
//         present, then runs this testbench under Icarus Verilog).
// ============================================================================
`timescale 1ns/1ps

module tb_bench;

    localparam integer RESULT_W = 640;   // DMEM word of the mailbox (0x1A00)

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;             // 100 MHz

    solvyr3_soc #(
        .IMEM_INIT("bench/bench_c.hex"),
        .IMEM_WORDS(1024), .DMEM_WORDS(1024), .SCRATCH_WORDS(1024)
    ) u_soc (
        .clk(clk), .rst(rst),
        .gpio_led(), .gpio_sw(16'h0), .gpio_btn(5'h0),
        .uart_tx(), .uart_rx(1'b1), .boot_sel(1'b0),
        .dbg_pc(), .cpu_trap(), .bus_error(),
        .accel_busy(), .accel_done()
    );

    // Data-BRAM result mailbox (mirrors bench.c).
    wire [31:0] sw_cycles = u_soc.u_dmem.mem[RESULT_W + 0];
    wire [31:0] hw_cycles = u_soc.u_dmem.mem[RESULT_W + 1];
    wire [31:0] match     = u_soc.u_dmem.mem[RESULT_W + 2];

    // Workload dimensions, read straight from the accelerator config the firmware
    // programmed -- always correct, whatever bench.c was compiled with.
    wire [15:0] img_w = u_soc.u_accel.img_w;
    wire [15:0] img_h = u_soc.u_accel.img_h;
    wire [3:0]  kdim  = u_soc.u_accel.kdim;

    integer i;
    real speedup;

    initial begin
        repeat (4) @(posedge clk);
        rst = 0;

        // Run until the program publishes the match flag (or a generous cap).
        for (i = 0; i < 2000000 && match !== 32'd1; i = i + 1) @(posedge clk);

        $display("============================================================");
        $display(" Solvyr-3 performance: software RV32I vs DIR accelerator");
        $display("============================================================");
        if (kdim != 0)
            $display(" workload      : %0dx%0d input, %0dx%0d kernel -> %0dx%0d output",
                     img_w, img_h, kdim, kdim, img_w-kdim+1, img_h-kdim+1);
        $display(" software cycles (RV32I, shift-add multiply) : %0d", sw_cycles);
        $display(" accelerator cycles (DSP48E1 MAC)            : %0d", hw_cycles);
        if (hw_cycles != 0) begin
            speedup = sw_cycles * 1.0 / hw_cycles;
            $display(" end-to-end speedup (sw / hw)                : %0.1fx", speedup);
        end
        $display(" results match : %0d", match);
        $display("============================================================");

        if (match === 32'd1)
            $display("BENCH PASSED (sw tile == hw tile; cycles above match the board)");
        else
            $display("BENCH FAILED (match flag not set -- did you rebuild bench_c.hex?)");
        $finish;
    end

    // Safety net: the program reaches the mailbox in well under 1M cycles even
    // for the 7x7 workload; this only fires if something is wired wrong.
    initial begin #30000000; $display("TIMEOUT (mailbox never written)"); $finish; end

endmodule
