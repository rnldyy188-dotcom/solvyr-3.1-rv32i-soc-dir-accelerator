// ============================================================================
// tb_gpio.v  -  GPIO integration test (CPU -> interconnect -> GPIO -> back)
//
// Runs tb/test_gpio.hex through the full SoC. The program writes 0xAB to the
// LED register, reads it back into x12, and reads the switch inputs into x13.
// The testbench drives the switches to 0x1234 and checks:
//   - the GPIO LED register / led output == 0xAB
//   - x12 (LED readback) == 0xAB
//   - x13 (switch readback) == 0x1234   (after 2-flop synchronization)
// ============================================================================
`timescale 1ns/1ps

module tb_gpio;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    wire [15:0] led;

    solvyr3_soc #(
        .IMEM_INIT("tb/test_gpio.hex"),
        .IMEM_WORDS(1024), .DMEM_WORDS(1024)
    ) u_soc (
        .clk(clk), .rst(rst),
        .gpio_led(led), .gpio_sw(16'h1234), .gpio_btn(5'h0),
        .uart_tx(), .uart_rx(1'b1), .boot_sel(1'b0),
        .dbg_pc(), .cpu_trap(), .bus_error(),
        .accel_busy(), .accel_done()
    );

    integer errors = 0;
    task chk(input [255:0] name, input [31:0] got, input [31:0] exp);
        begin
            if (got !== exp) begin
                $display("FAIL %0s = 0x%h, expected 0x%h", name, got, exp);
                errors = errors + 1;
            end else $display("PASS %0s = 0x%h", name, got);
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst = 0;
        repeat (40) @(posedge clk);

        $display("==== GPIO check ====");
        chk("led output",  {16'd0, led},                 32'h0000_00AB);
        chk("led_reg",     u_soc.u_gpio.led_reg,         32'h0000_00AB);
        chk("x12 readback", u_soc.u_core.u_rf.regs[12],  32'h0000_00AB);
        chk("x13 switches", u_soc.u_core.u_rf.regs[13],  32'h0000_1234);

        $display("====================");
        if (errors == 0) $display("GPIO TEST PASSED");
        else             $display("GPIO TEST FAILED: %0d errors", errors);
        $finish;
    end

    initial begin #20000; $display("TIMEOUT"); $finish; end

endmodule
