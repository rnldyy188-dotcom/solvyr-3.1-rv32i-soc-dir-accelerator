// ============================================================================
// dmem_bram.v  -  Data memory (Artix-7 Block RAM)
//
// Word-addressed with per-byte write enables (for SB/SH/SW). Synchronous:
// a read issued this cycle returns data next cycle (1-cycle latency), matching
// imem. The MEM-stage stall in the core covers this latency.
//
// Simple valid/ready handshake: ready is asserted the cycle after a request
// (valid). This models true BRAM timing and exercises the stall path.
// ============================================================================

module dmem_bram #(
    parameter integer DEPTH_WORDS = 1024,
    parameter integer ADDR_BITS   = 10,
    parameter         INIT_FILE   = ""
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        req,         // access requested this cycle
    input  wire        we,          // write enable
    input  wire [31:0] addr,        // byte address
    input  wire [31:0] wdata,
    input  wire [3:0]  byte_en,
    output reg  [31:0] rdata,
    output reg         ready        // data valid / write accepted (next cycle)
);

    (* ram_style = "block" *) reg [31:0] mem [0:DEPTH_WORDS-1];

    integer i;
    initial begin
        for (i = 0; i < DEPTH_WORDS; i = i + 1)
            mem[i] = 32'd0;
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, mem);
    end

    wire [ADDR_BITS-1:0] word_index = addr[ADDR_BITS+1:2];

    always @(posedge clk) begin
        if (rst) begin
            ready <= 1'b0;
            rdata <= 32'd0;
        end else begin
            ready <= req;            // 1-cycle latency handshake
            if (req && we) begin
                if (byte_en[0]) mem[word_index][7:0]   <= wdata[7:0];
                if (byte_en[1]) mem[word_index][15:8]  <= wdata[15:8];
                if (byte_en[2]) mem[word_index][23:16] <= wdata[23:16];
                if (byte_en[3]) mem[word_index][31:24] <= wdata[31:24];
            end
            rdata <= mem[word_index];
        end
    end

endmodule
