// ============================================================================
// tb_timer.v  -  Timer peripheral self-check (compare match + interrupt)
//
// Drives the timer's bus port directly: programs MTIMECMP and enables the
// counter + interrupt, waits for the compare match, checks that irq_timer
// asserts and STATUS.MATCH sets, then clears MATCH (write-1-to-clear) and
// confirms the interrupt deasserts.
// ============================================================================
`timescale 1ns/1ps

module tb_timer;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg         req, we; reg [31:0] addr, wdata; reg [3:0] byte_en;
    wire [31:0] rdata;   wire ready, irq_timer;

    timer #(.PRESCALE(1)) dut (
        .clk(clk), .rst(rst),
        .req(req), .we(we), .addr(addr), .wdata(wdata), .byte_en(byte_en),
        .rdata(rdata), .ready(ready), .irq_timer(irq_timer)
    );

    localparam MTIME=32'h00, MTIMECMP=32'h04, CTRL=32'h08, STATUS=32'h0C;

    task wr(input [31:0] a, input [31:0] d);
        begin @(negedge clk); req=1; we=1; addr=a; wdata=d; byte_en=4'hF;
              @(negedge clk); req=0; we=0; end
    endtask
    task rd(input [31:0] a, output [31:0] d);
        begin @(negedge clk); req=1; we=0; addr=a;
              @(negedge clk); req=0; d=rdata; end
    endtask

    integer errors = 0, i;
    reg [31:0] st;

    initial begin
        req=0; we=0; addr=0; wdata=0; byte_en=0;
        repeat (4) @(posedge clk); rst=0; @(negedge clk);

        wr(MTIMECMP, 32'd5);          // compare value
        wr(CTRL,     32'b011);        // EN | IE

        // Wait for the match / interrupt.
        st = 0;
        for (i=0; i<100 && !irq_timer; i=i+1) @(posedge clk);

        $display("==== Timer check ====");
        if (irq_timer) $display("PASS irq_timer asserted after %0d cycles", i);
        else begin $display("FAIL irq_timer never asserted"); errors=errors+1; end

        rd(STATUS, st);
        if (st[0]) $display("PASS STATUS.MATCH set");
        else begin $display("FAIL STATUS.MATCH not set"); errors=errors+1; end

        // Clear the match (W1C) and confirm the interrupt drops.
        wr(STATUS, 32'h1);
        @(posedge clk);
        if (!irq_timer) $display("PASS irq_timer cleared after W1C");
        else begin $display("FAIL irq_timer still asserted"); errors=errors+1; end

        $display("=====================");
        if (errors==0) $display("TIMER TEST PASSED");
        else           $display("TIMER TEST FAILED: %0d errors", errors);
        $finish;
    end

    initial begin #50000; $display("TIMEOUT"); $finish; end

endmodule
