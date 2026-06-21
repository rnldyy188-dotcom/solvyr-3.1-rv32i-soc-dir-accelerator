// ============================================================================
// tb_dir_accel.v  -  DIR accelerator 2D-convolution self-check
//
// Drives the accelerator's two bus slave ports directly (no CPU), performing
// the full software flow: load a 5x5 input tile and a 3x3 kernel into the
// scratchpad, program the registers, START, wait for DONE, then read back the
// 3x3 output tile and compare against the golden 2D convolution computed by
// tools/rv32i.py:
//
//   input  = ramp 0..24 (row-major 5x5)
//   kernel = [1 0 1 / 0 1 0 / 1 0 1]  ("X"), shift = 0
//   output = [30 35 40 / 55 60 65 / 80 85 90]
//
// Also checks BUSY during the run and the ACC_RESULT register (last sample).
// ============================================================================
`timescale 1ns/1ps
`include "solvyr3_defs.vh"

module tb_dir_accel;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    // ---- accelerator bus ports ----
    reg         rreq, rwe;  reg [31:0] raddr, rwdata; reg [3:0] rbyte_en;
    wire [31:0] rrdata;     wire rready;
    reg         sreq, swe;  reg [31:0] saddr, swdata; reg [3:0] sbyte_en;
    wire [31:0] srdata;     wire sready;
    wire        irq_accel, acc_busy, acc_done;

    dir_accel #(.SCRATCH_WORDS(1024), .SCR_ABITS(10), .MAXK(7)) dut (
        .clk(clk), .rst(rst),
        .rreq(rreq), .rwe(rwe), .raddr(raddr), .rwdata(rwdata), .rbyte_en(rbyte_en),
        .rrdata(rrdata), .rready(rready),
        .sreq(sreq), .swe(swe), .saddr(saddr), .swdata(swdata), .sbyte_en(sbyte_en),
        .srdata(srdata), .sready(sready),
        .irq_accel(irq_accel), .acc_busy(acc_busy), .acc_done(acc_done)
    );

    // ---- bus helper tasks (single-cycle req pulse, 1-cycle read latency) ----
    task reg_wr(input [31:0] a, input [31:0] d);
        begin @(negedge clk); rreq=1; rwe=1; raddr=a; rwdata=d; rbyte_en=4'hF;
              @(negedge clk); rreq=0; rwe=0; end
    endtask
    task reg_rd(input [31:0] a, output [31:0] d);
        begin @(negedge clk); rreq=1; rwe=0; raddr=a;
              @(negedge clk); rreq=0; d=rrdata; end
    endtask
    task scr_wr(input [31:0] wordoff, input [31:0] d);
        begin @(negedge clk); sreq=1; swe=1; saddr=wordoff<<2; swdata=d; sbyte_en=4'hF;
              @(negedge clk); sreq=0; swe=0; end
    endtask
    task scr_rd(input [31:0] wordoff, output [31:0] d);
        begin @(negedge clk); sreq=1; swe=0; saddr=wordoff<<2;
              @(negedge clk); sreq=0; d=srdata; end
    endtask

    // golden output
    reg [31:0] golden [0:8];
    integer i, errors, busy_seen;
    reg [31:0] rd, status;

    localparam IN_BASE = 0, CO_BASE = 64, OUT_BASE = 128;

    initial begin
        golden[0]=30; golden[1]=35; golden[2]=40;
        golden[3]=55; golden[4]=60; golden[5]=65;
        golden[6]=80; golden[7]=85; golden[8]=90;

        rreq=0; rwe=0; raddr=0; rwdata=0; rbyte_en=0;
        sreq=0; swe=0; saddr=0; swdata=0; sbyte_en=0;
        errors=0; busy_seen=0;

        repeat (4) @(posedge clk); rst = 0; @(negedge clk);

        // input ramp 0..24
        for (i=0; i<25; i=i+1) scr_wr(IN_BASE+i, i);
        // 3x3 "X" kernel
        scr_wr(CO_BASE+0,1); scr_wr(CO_BASE+1,0); scr_wr(CO_BASE+2,1);
        scr_wr(CO_BASE+3,0); scr_wr(CO_BASE+4,1); scr_wr(CO_BASE+5,0);
        scr_wr(CO_BASE+6,1); scr_wr(CO_BASE+7,0); scr_wr(CO_BASE+8,1);

        // program registers
        reg_wr(`ACC_INPUT_BASE,    IN_BASE);
        reg_wr(`ACC_OUTPUT_BASE,   OUT_BASE);
        reg_wr(`ACC_CONFIG,       (32'd5 << 16) | 32'd5);       // img_h=5, img_w=5
        reg_wr(`ACC_KERNEL_CONFIG,(CO_BASE << 16) | (0 << 8) | 3); // coeff_base, shift, kdim
        reg_wr(`ACC_CONTROL,       32'h1);                       // START

        // wait for DONE (poll STATUS), watch BUSY
        status = 0;
        for (i=0; i<2000 && !status[`ACC_STAT_DONE]; i=i+1) begin
            reg_rd(`ACC_STATUS, status);
            if (status[`ACC_STAT_BUSY]) busy_seen = 1;
        end

        $display("==== DIR accelerator check ====");
        if (!status[`ACC_STAT_DONE]) begin
            $display("FAIL accelerator never asserted DONE"); errors=errors+1;
        end else $display("PASS DONE asserted");
        if (!busy_seen) begin $display("FAIL BUSY never observed"); errors=errors+1; end
        else $display("PASS BUSY observed during run");

        // read back output tile
        for (i=0; i<9; i=i+1) begin
            scr_rd(OUT_BASE+i, rd);
            if (rd !== golden[i]) begin
                $display("FAIL out[%0d] = %0d, expected %0d", i, rd, golden[i]);
                errors=errors+1;
            end else
                $display("PASS out[%0d] = %0d", i, rd);
        end

        // ACC_RESULT = last sample written (out[8] = 90)
        reg_rd(`ACC_RESULT, rd);
        if (rd !== golden[8]) begin
            $display("FAIL ACC_RESULT = %0d, expected %0d", rd, golden[8]); errors=errors+1;
        end else $display("PASS ACC_RESULT = %0d", rd);

        $display("===============================");
        if (errors==0) $display("DIR ACCEL TEST PASSED");
        else           $display("DIR ACCEL TEST FAILED: %0d errors", errors);
        $finish;
    end

    initial begin #200000; $display("TIMEOUT"); $finish; end

endmodule
