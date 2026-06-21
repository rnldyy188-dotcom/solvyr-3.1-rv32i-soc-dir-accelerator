// ============================================================================
// tb_bench_debug.v  -  READ-ONLY diagnostic for the benchmark sw-path mismatch
//
// Identical SoC instantiation to tb_bench.v, but it does NOT change the design
// or check anything. It only PRINTS, for the first few software-loop
// iterations, every register-file write to the registers that matter:
//   x7  = t2  (loop index i)        x10 = a0 (img[i], then the product)
//   x11 = a1  (kern[i])             x19 = s3 (the running accumulator)
// plus the PC of the instruction doing the write (so we can tell a load from a
// multiply result from the accumulate). This pinpoints whether the loads, the
// multiply, or the accumulation is producing the wrong value.
//
// Run:
//   iverilog -g2012 -I rtl -o build_bdbg bench/tb_bench_debug.v <SOC sources>
//   vvp build_bdbg
// (Use the same source list run_sim.sh uses for `bench`; or:
//   ./run_sim.sh bench   then copy that iverilog line and swap the tb file.)
// ============================================================================
`timescale 1ns/1ps

module tb_bench_debug;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

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

    // Convenient hierarchical handles into the core's register-file write port.
    wire        rf_we    = u_soc.u_core.u_rf.we;
    wire [4:0]  rf_rd    = u_soc.u_core.u_rf.rd_addr;
    wire [31:0] rf_data  = u_soc.u_core.u_rf.rd_data;
    wire [31:0] wb_pc    = u_soc.u_core.wb_pc4 - 32'd4;   // PC of the WB instruction

    reg [31:0] prev_s3 = 0;
    integer    s3_writes = 0;

    initial begin
        repeat (4) @(posedge clk);
        rst = 0;
    end

    // Read-only trace of writes to t2 / a0 / a1 / s3.
    always @(posedge clk) begin
        if (!rst && rf_we && (rf_rd==5'd7 || rf_rd==5'd10 ||
                              rf_rd==5'd11 || rf_rd==5'd19)) begin
            case (rf_rd)
                5'd7 : $display("[pc=%08x] t2(i) <= %0d", wb_pc, rf_data);
                5'd10: $display("[pc=%08x] a0    <= %0d", wb_pc, rf_data);
                5'd11: $display("[pc=%08x] a1    <= %0d", wb_pc, rf_data);
                5'd19: begin
                    $display("[pc=%08x] s3    <= %0d   (product added = %0d)",
                             wb_pc, rf_data, rf_data - prev_s3);
                    prev_s3   = rf_data;
                    s3_writes = s3_writes + 1;
                    if (s3_writes >= 7) begin
                        $display("---- stopping after %0d s3 writes ----", s3_writes);
                        $finish;
                    end
                end
            endcase
        end
    end

    initial begin #2000000; $display("TIMEOUT (debug)"); $finish; end

endmodule
