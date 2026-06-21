// ============================================================================
// tb_irq.v  -  Timer-interrupt test (asynchronous trap entry)
//
// Loads tb/test_irq.hex: the program enables mtvec/mie.MTIE/mstatus.MIE, arms
// the timer (MTIMECMP=8, CTRL=EN|IE), and spins incrementing x1 until the timer
// interrupt handler sets x2 and clears the timer match. Verifies:
//   - the interrupt is actually taken (x2 == 1)
//   - the main loop ran before the interrupt (x1 > 0)
//   - mcause shows an interrupt (bit 31 set, code 7) -- checked via the CSR file
// ============================================================================
`timescale 1ns/1ps

module tb_irq;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    solvyr3_soc #(
        .IMEM_INIT("tb/test_irq.hex"),
        .IMEM_WORDS(1024), .DMEM_WORDS(1024),
        .TIMER_PRESCALE(1)
    ) u_soc (
        .clk(clk), .rst(rst),
        .gpio_led(), .gpio_sw(16'h0), .gpio_btn(5'h0),
        .uart_tx(), .uart_rx(1'b1), .boot_sel(1'b0),
        .dbg_pc(), .cpu_trap(), .bus_error(),
        .accel_busy(), .accel_done()
    );

    integer errors = 0;
    task expect_true(input [255:0] name, input cond);
        begin
            if (!cond) begin $display("FAIL %0s", name); errors=errors+1; end
            else         $display("PASS %0s", name);
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst = 0;
        repeat (120) @(posedge clk);

        $display("==== Timer interrupt check ====");
        $display("  x1 (spin count) = %0d", u_soc.u_core.u_rf.regs[1]);
        $display("  x2 (irq taken)  = %0d", u_soc.u_core.u_rf.regs[2]);
        $display("  mcause          = 0x%h", u_soc.u_core.u_csr.mcause);
        expect_true("interrupt taken (x2==1)", u_soc.u_core.u_rf.regs[2] === 32'd1);
        expect_true("spun before irq (x1>0)",  u_soc.u_core.u_rf.regs[1]  >  32'd0);
        expect_true("mcause = interrupt|7",    u_soc.u_core.u_csr.mcause === 32'h8000_0007);

        $display("===============================");
        if (errors == 0) $display("IRQ TEST PASSED");
        else             $display("IRQ TEST FAILED: %0d errors", errors);
        $finish;
    end

    initial begin #40000; $display("TIMEOUT"); $finish; end

endmodule
