// ============================================================================
// mm_interconnect.v  -  Custom memory-mapped bus interconnect (single master)
//
// Decodes the data-side address from the CPU and routes the transaction to one
// of seven slaves, per the Solvyr-3 memory map. This is a deliberately simple
// custom bus (NOT AXI): one master (the CPU data port), single outstanding
// transaction, 1-cycle slave latency.
//
// Bus signals (master side):
//   mem_valid   - request strobe (single-cycle pulse from the core)
//   mem_we      - write enable
//   mem_addr    - byte address
//   mem_wdata   - write data
//   mem_byte_en - per-byte write strobe
//   mem_rdata   - read data        (valid the cycle mem_ready is high)
//   mem_ready   - response valid   (1 cycle after mem_valid)
//   mem_error   - access error     (unmapped address)
//
// Address decode (bits [15:12]; bits [31:16] must be zero):
//   0x0xxx IMEM(dataport) 0x1xxx DMEM 0x2xxx GPIO 0x3xxx TIMER
//   0x4xxx UART           0x5xxx ACC-REGS         0x6xxx ACC-SCRATCH
//
// The CPU holds the address stable across the request and response cycles, so
// the response mux can decode combinationally from the live address. Unmapped
// accesses get a registered error+ready response so the core never deadlocks.
//
// Write data / address / byte-enables are broadcast to every slave; only the
// selected slave receives an asserted request (slv_req one-hot).
// ============================================================================
`include "solvyr3_defs.vh"

module mm_interconnect (
    input  wire        clk,
    input  wire        rst,

    // ---- Master port (CPU data bus) ----
    input  wire        mem_valid,
    input  wire        mem_we,
    input  wire [31:0] mem_addr,
    input  wire [31:0] mem_wdata,
    input  wire [3:0]  mem_byte_en,
    output wire [31:0] mem_rdata,
    output wire        mem_ready,
    output wire        mem_error,

    // ---- Broadcast to all slaves ----
    output wire        bus_we,
    output wire [31:0] bus_addr,
    output wire [31:0] bus_wdata,
    output wire [3:0]  bus_byte_en,

    // ---- Per-slave request strobes (one-hot) ----
    output wire [6:0]  slv_req,

    // ---- Per-slave responses ----
    input  wire [6:0]  slv_ready,
    input  wire [223:0] slv_rdata     // 7 x 32, slave i at [i*32 +: 32]
);

    // ---- Decode ----------------------------------------------------------
    // Seven slaves sit on the bus (see the memory map above); the slave index
    // is the address field `sel`. One named constant drives the "in range"
    // check and the request-fan-out loop below.
    localparam integer NUM_SLAVES = 7;
    wire [3:0] sel    = mem_addr[15:12];
    wire       mapped = (mem_addr[31:16] == 16'd0) && (sel < NUM_SLAVES);
    wire [2:0] sidx   = sel[2:0];        // 0..6 when mapped

    // ---- Broadcast signals -----------------------------------------------
    assign bus_we      = mem_we;
    assign bus_addr    = mem_addr;
    assign bus_wdata   = mem_wdata;
    assign bus_byte_en = mem_byte_en;

    // ---- One-hot request to the selected slave ---------------------------
    genvar i;
    generate
        for (i = 0; i < NUM_SLAVES; i = i + 1) begin : gen_req
            assign slv_req[i] = mem_valid && mapped && (sel == i);
        end
    endgenerate

    // ---- Response mux (combinational; address held stable by the CPU) ----
    wire        sel_ready = mapped ? slv_ready[sidx]            : 1'b0;
    wire [31:0] sel_rdata = mapped ? slv_rdata[sidx*32 +: 32]   : 32'd0;

    // Unmapped access: respond with error+ready one cycle later so the CPU's
    // single-wait-state handshake completes instead of hanging.
    reg unmapped_q;
    always @(posedge clk) begin
        if (rst) unmapped_q <= 1'b0;
        else     unmapped_q <= mem_valid && !mapped;
    end

    assign mem_ready = sel_ready | unmapped_q;
    assign mem_rdata = sel_rdata;
    assign mem_error = unmapped_q;

endmodule
