// ============================================================================
// tb_system.v  -  Full-pipeline system test for Solvyr-3 (through the SoC)
//
// Loads tb/test_prog.hex into instruction memory, runs the core through the
// full SoC (interconnect + Data BRAM), and checks the architectural register
// file and a stored Data-BRAM word. Exercises:
//   - ADDI / ADD / SUB with EX-stage forwarding
//   - LUI to form the Data-BRAM base (0x1000)
//   - SW / LW through the interconnect to Data BRAM (memory stall path)
//   - load-use hazard (lw x6 then add x7,x6,x1)
//   - taken branch with flush (the skipped addi must NOT execute)
//
// Golden values come from tools/rv32i.py (reference ISA simulator).
//
// Run:  ./run_sim.sh system     (or see run_sim.sh for the raw iverilog line)
// ============================================================================
`timescale 1ns/1ps

module tb_system;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;            // 100 MHz

    solvyr3_soc #(
        .IMEM_INIT("tb/test_prog.hex"),
        .IMEM_WORDS(1024), .DMEM_WORDS(1024)
    ) u_soc (
        .clk(clk), .rst(rst),
        .gpio_led(), .gpio_sw(16'h0), .gpio_btn(5'h0),
        .uart_tx(), .uart_rx(1'b1), .boot_sel(1'b0),
        .dbg_pc(), .cpu_trap(), .bus_error(),
        .accel_busy(), .accel_done()
    );

    integer errors = 0;
    task chk(input [255:0] name, input [31:0] got, input [31:0] exp);
        begin
            if (got !== exp) begin
                $display("FAIL %0s = %0d (0x%h), expected %0d (0x%h)",
                         name, got, got, exp, exp);
                errors = errors + 1;
            end else
                $display("PASS %0s = %0d", name, got);
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst = 0;

        repeat (80) @(posedge clk);   // run to completion (ends in self-branch)

        $display("==== Register check ====");
        chk("x1", u_soc.u_core.u_rf.regs[1], 32'd5);
        chk("x2", u_soc.u_core.u_rf.regs[2], 32'd10);
        chk("x3", u_soc.u_core.u_rf.regs[3], 32'd15);
        chk("x4", u_soc.u_core.u_rf.regs[4], 32'd10);
        chk("x5", u_soc.u_core.u_rf.regs[5], 32'h0000_1000);
        chk("x6", u_soc.u_core.u_rf.regs[6], 32'd15);   // loaded value
        chk("x7", u_soc.u_core.u_rf.regs[7], 32'd20);   // load-use result
        chk("x8", u_soc.u_core.u_rf.regs[8], 32'd42);   // branch target
        chk("dmem[1]", u_soc.u_dmem.mem[1], 32'd15);    // stored value

        $display("========================");
        if (errors == 0) $display("SYSTEM TEST PASSED");
        else             $display("SYSTEM TEST FAILED: %0d errors", errors);
        $finish;
    end

    initial begin
        #20000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
