// ============================================================================
// dpram_be.v  -  True dual-port RAM with per-byte write enables (Artix-7 BRAM)
//
// Two independent read/write ports sharing one memory array, inferring a Xilinx
// true-dual-port block RAM. Each port is word-addressed (byte address in, low
// two bits ignored), 1-cycle synchronous read latency, with per-byte write
// enables. Used as the DIR accelerator scratchpad:
//   Port A -> CPU (memory-mapped via the interconnect at 0x6000)
//   Port B -> accelerator compute datapath (pixels / coeffs / results)
//
// Simultaneous access to different words is fine. Simultaneous same-word
// read/write across ports is a don't-care (read-during-write is unspecified);
// the accelerator's software contract avoids CPU/accelerator scratchpad races
// by only touching the scratchpad while the accelerator is not busy.
// ============================================================================

module dpram_be #(
    parameter integer DEPTH_WORDS = 1024,
    parameter integer ADDR_BITS   = 10
) (
    input  wire        clk,

    // ---- Port A ----
    input  wire        a_en,
    input  wire        a_we,
    input  wire [31:0] a_addr,
    input  wire [31:0] a_wdata,
    input  wire [3:0]  a_byte_en,
    output reg  [31:0] a_rdata,

    // ---- Port B ----
    input  wire        b_en,
    input  wire        b_we,
    input  wire [31:0] b_addr,
    input  wire [31:0] b_wdata,
    input  wire [3:0]  b_byte_en,
    output reg  [31:0] b_rdata
);

    (* ram_style = "block" *) reg [31:0] mem [0:DEPTH_WORDS-1];

    integer i;
    initial begin
        for (i = 0; i < DEPTH_WORDS; i = i + 1)
            mem[i] = 32'd0;
    end

    wire [ADDR_BITS-1:0] a_idx = a_addr[ADDR_BITS+1:2];
    wire [ADDR_BITS-1:0] b_idx = b_addr[ADDR_BITS+1:2];

    // ---- Port A ----
    always @(posedge clk) begin
        if (a_en && a_we) begin
            if (a_byte_en[0]) mem[a_idx][7:0]   <= a_wdata[7:0];
            if (a_byte_en[1]) mem[a_idx][15:8]  <= a_wdata[15:8];
            if (a_byte_en[2]) mem[a_idx][23:16] <= a_wdata[23:16];
            if (a_byte_en[3]) mem[a_idx][31:24] <= a_wdata[31:24];
        end
        a_rdata <= mem[a_idx];
    end

    // ---- Port B ----
    always @(posedge clk) begin
        if (b_en && b_we) begin
            if (b_byte_en[0]) mem[b_idx][7:0]   <= b_wdata[7:0];
            if (b_byte_en[1]) mem[b_idx][15:8]  <= b_wdata[15:8];
            if (b_byte_en[2]) mem[b_idx][23:16] <= b_wdata[23:16];
            if (b_byte_en[3]) mem[b_idx][31:24] <= b_wdata[31:24];
        end
        b_rdata <= mem[b_idx];
    end

endmodule
