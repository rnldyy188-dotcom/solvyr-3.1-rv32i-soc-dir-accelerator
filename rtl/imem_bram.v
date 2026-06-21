// ============================================================================
// imem_bram.v  -  Instruction memory (Artix-7 Block RAM, true dual-port)
//
// Port A : CPU fetch port. Read-only, word-addressed, 1-cycle read latency:
//          the instruction for the address presented on a given cycle appears
//          on `a_instr` the NEXT cycle. The fetch stage accounts for this. A
//          read-enable `a_en` lets the core freeze `a_instr` during a pipeline
//          stall so the buffered fetch is held rather than overwritten.
//
// Port B : Data-bus port (custom memory-mapped bus). Read/write with per-byte
//          enables and a 1-cycle valid/ready handshake, identical in shape to
//          dmem_bram. This backs the data-side image of instruction memory at
//          0x0000_0000-0x0FFF in the system memory map and lets a UART boot
//          loader (or self-modifying loader code) write the program image.
//
// Initialized from a hex file via $readmemh if INIT_FILE is non-empty. The
// $readmemh sits in an initial block, which is the one initial-block use that
// is synthesizable for FPGA BRAM initialization (Vivado supports it). Both
// ports share the same memory array, inferring a Xilinx true-dual-port BRAM.
//
// Port A address range is checked against the memory depth; out-of-range
// fetches return a NOP so a runaway PC cannot inject garbage into the pipeline.
// ============================================================================
`include "solvyr3_defs.vh"

module imem_bram #(
    parameter integer DEPTH_WORDS = 1024,           // 4 KB = 1024 words
    parameter integer ADDR_BITS   = 10,             // log2(DEPTH_WORDS)
    parameter         INIT_FILE   = ""
) (
    input  wire        clk,

    // ---- Port A : fetch (read-only) ----
    input  wire        a_en,         // fetch enable: 0 holds a_instr (stall the IF buffer)
    input  wire [31:0] a_addr,       // byte address from PC
    output reg  [31:0] a_instr,

    // ---- Port B : data bus (read/write, custom-bus handshake) ----
    input  wire        b_req,        // access requested this cycle
    input  wire        b_we,         // write enable
    input  wire [31:0] b_addr,       // byte address
    input  wire [31:0] b_wdata,
    input  wire [3:0]  b_byte_en,
    output reg  [31:0] b_rdata,
    output reg         b_ready       // data valid / write accepted (next cycle)
);

    (* ram_style = "block" *) reg [31:0] mem [0:DEPTH_WORDS-1];

    integer i;
    initial begin
        // Default-fill with NOP so uninitialized space is inert.
        for (i = 0; i < DEPTH_WORDS; i = i + 1)
            mem[i] = `NOP_INSTR;
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, mem);
    end

    // ---- Port A : synchronous read, NOP on out-of-range ------------------
    // a_en gates the read so the fetched word is held (not overwritten) while
    // the front end is stalled. Without it, a stall that freezes the PC one
    // address past a just-fetched instruction would drop that instruction,
    // because this output register would reload from the frozen PC. (This is a
    // standard clock-enable on a synchronous-read BRAM; it costs no extra logic.)
    wire [ADDR_BITS-1:0] a_index   = a_addr[ADDR_BITS+1:2];
    wire                 a_inrange = (a_addr[31:ADDR_BITS+2] == 0);
    always @(posedge clk) begin
        if (a_en)
            a_instr <= a_inrange ? mem[a_index] : `NOP_INSTR;
    end

    // ---- Port B : read/write with per-byte enables -----------------------
    wire [ADDR_BITS-1:0] b_index = b_addr[ADDR_BITS+1:2];
    always @(posedge clk) begin
        b_ready <= b_req;                      // 1-cycle latency handshake
        if (b_req && b_we) begin
            if (b_byte_en[0]) mem[b_index][7:0]   <= b_wdata[7:0];
            if (b_byte_en[1]) mem[b_index][15:8]  <= b_wdata[15:8];
            if (b_byte_en[2]) mem[b_index][23:16] <= b_wdata[23:16];
            if (b_byte_en[3]) mem[b_index][31:24] <= b_wdata[31:24];
        end
        b_rdata <= mem[b_index];
    end

endmodule
