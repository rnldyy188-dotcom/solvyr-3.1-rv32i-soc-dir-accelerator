// ============================================================================
// tb_csr.v  -  Machine-mode trap / CSR test (ECALL + MRET round trip)
//
// Loads tb/test_csr.hex and verifies the synchronous-trap path:
//   - mtvec is programmed (csrrw)
//   - ECALL traps to the handler (mcause = 11, mepc = ecall PC)
//   - handler reads mcause/mepc (csrrs), bumps mepc past the ecall (csrrw)
//   - MRET returns and execution resumes
//
// Golden values from tools/rv32i.py:
//   x1=1 (pre-trap), x3=mcause=11, x4=mepc=0x0C, x8=42 (handler), x2=7 (post-MRET)
// ============================================================================
`timescale 1ns/1ps

module tb_csr;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    solvyr3_soc #(
        .IMEM_INIT("tb/test_csr.hex"),
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
                $display("FAIL %0s = 0x%h, expected 0x%h", name, got, exp);
                errors = errors + 1;
            end else
                $display("PASS %0s = 0x%h", name, got);
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst = 0;
        repeat (60) @(posedge clk);

        $display("==== CSR / trap check ====");
        chk("x1 pre-trap",  u_soc.u_core.u_rf.regs[1], 32'd1);
        chk("x3 mcause",    u_soc.u_core.u_rf.regs[3], 32'd11);
        chk("x4 mepc",      u_soc.u_core.u_rf.regs[4], 32'h0000_000C);
        chk("x8 handler",   u_soc.u_core.u_rf.regs[8], 32'd42);
        chk("x2 post-mret", u_soc.u_core.u_rf.regs[2], 32'd7);

        $display("==========================");
        if (errors == 0) $display("CSR TEST PASSED");
        else             $display("CSR TEST FAILED: %0d errors", errors);
        $finish;
    end

    initial begin #20000; $display("TIMEOUT"); $finish; end

endmodule
