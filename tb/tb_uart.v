// ============================================================================
// tb_uart.v  -  UART loopback self-check
//
// Wires uart_tx back to uart_rx and exercises the full transmit + receive path
// at a small baud divisor (DIV = CLK_HZ/BAUD = 8) for fast simulation:
//   - write a byte to TXDATA
//   - wait for the frame to shift out and be received (poll STATUS.RX_VALID)
//   - read RXDATA and confirm it matches the byte sent
//   - confirm RX_VALID clears after the read
// ============================================================================
`timescale 1ns/1ps

module tb_uart;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg         req, we; reg [31:0] addr, wdata; reg [3:0] byte_en;
    wire [31:0] rdata;   wire ready;
    wire        loop;                       // tx -> rx loopback

    uart #(.CLK_HZ(1_000_000), .BAUD(125_000)) dut (   // DIV = 8
        .clk(clk), .rst(rst),
        .req(req), .we(we), .addr(addr), .wdata(wdata), .byte_en(byte_en),
        .rdata(rdata), .ready(ready),
        .uart_tx(loop), .uart_rx(loop)
    );

    localparam TXD=32'h00, RXD=32'h04, STAT=32'h08;

    task wr(input [31:0] a, input [31:0] d);
        begin @(negedge clk); req=1; we=1; addr=a; wdata=d; byte_en=4'hF;
              @(negedge clk); req=0; we=0; end
    endtask
    task rd(input [31:0] a, output [31:0] d);
        begin @(negedge clk); req=1; we=0; addr=a;
              @(negedge clk); req=0; d=rdata; end
    endtask

    integer errors = 0, i;
    reg [31:0] st, got;
    localparam [7:0] TESTBYTE = 8'h5A;

    initial begin
        req=0; we=0; addr=0; wdata=0; byte_en=0;
        repeat (4) @(posedge clk); rst=0; @(negedge clk);

        wr(TXD, TESTBYTE);                    // transmit

        // Wait until a byte is received (loopback) or timeout.
        st = 0;
        for (i=0; i<2000 && !st[2]; i=i+1) rd(STAT, st);

        $display("==== UART loopback check ====");
        if (st[2]) $display("PASS RX_VALID set");
        else begin $display("FAIL no byte received"); errors=errors+1; end

        rd(RXD, got);
        if (got[7:0] === TESTBYTE) $display("PASS received 0x%02h", got[7:0]);
        else begin $display("FAIL received 0x%02h, expected 0x%02h", got[7:0], TESTBYTE);
                   errors=errors+1; end

        rd(STAT, st);
        if (!st[2]) $display("PASS RX_VALID cleared after read");
        else begin $display("FAIL RX_VALID still set"); errors=errors+1; end

        $display("=============================");
        if (errors==0) $display("UART TEST PASSED");
        else           $display("UART TEST FAILED: %0d errors", errors);
        $finish;
    end

    initial begin #500000; $display("TIMEOUT"); $finish; end

endmodule
