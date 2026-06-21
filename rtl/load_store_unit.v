// ============================================================================
// load_store_unit.v  -  Data-memory access shaping (MEM stage)
//
// Sits between the pipeline and the memory-mapped data bus. Responsibilities:
//   - Generate byte-enables for stores (SB/SH/SW) and align store data to the
//     correct byte lanes.
//   - Extract and sign/zero-extend load data (LB/LBU/LH/LHU/LW) from the word
//     returned by memory.
//   - Flag misaligned accesses (halfword not on a 2-byte boundary, word not on
//     a 4-byte boundary) for the trap unit.
//
// Memory is word-addressed internally via mem_addr (byte address); the low two
// bits select the byte lane. This module is combinational shaping logic; the
// one-cycle BRAM latency / stall is handled by the core's MEM-stage control,
// per the locked design decision.
//
// Pure combinational.
// ============================================================================
`include "solvyr3_defs.vh"

module load_store_unit (
    input  wire [31:0] addr,        // effective byte address (from ALU)
    input  wire [1:0]  mem_size,    // MEM_B / MEM_H / MEM_W
    input  wire        mem_unsigned,// 1 = zero-extend (LBU/LHU)
    input  wire        mem_read,
    input  wire        mem_write,

    input  wire [31:0] store_data,  // rs2 value to store

    // --- to/from the data bus ---
    output reg  [3:0]  byte_en,     // per-byte write/read strobe
    output reg  [31:0] bus_wdata,   // lane-aligned store data
    input  wire [31:0] bus_rdata,   // raw word read from memory

    // --- load result back to pipeline ---
    output reg  [31:0] load_data,

    // --- exception flags ---
    output wire        misaligned
);

    wire [1:0] off = addr[1:0];     // byte offset within the word

    // ---- Alignment check --------------------------------------------------
    // Byte access: always aligned. Halfword: off[0] must be 0. Word: off==0.
    reg align_ok;
    always @(*) begin
        case (mem_size)
            `MEM_B : align_ok = 1'b1;
            `MEM_H : align_ok = (off[0] == 1'b0);
            `MEM_W : align_ok = (off    == 2'b00);
            default: align_ok = 1'b0;
        endcase
    end
    assign misaligned = (mem_read || mem_write) && !align_ok;

    // ---- Store: byte-enable + lane alignment ------------------------------
    always @(*) begin
        byte_en   = 4'b0000;
        bus_wdata = 32'd0;
        if (mem_write && align_ok) begin
            case (mem_size)
                `MEM_B: begin
                    byte_en           = 4'b0001 << off;
                    bus_wdata         = store_data[7:0]  << (8*off);
                end
                `MEM_H: begin
                    byte_en           = 4'b0011 << off;          // off is 0 or 2
                    bus_wdata         = store_data[15:0] << (8*off);
                end
                `MEM_W: begin
                    byte_en           = 4'b1111;
                    bus_wdata         = store_data;
                end
                default: ;
            endcase
        end
    end

    // ---- Load: lane extract + sign/zero extension -------------------------
    reg [7:0]  b_lane;
    reg [15:0] h_lane;
    always @(*) begin
        // select byte / halfword lane based on offset
        case (off)
            2'b00: b_lane = bus_rdata[7:0];
            2'b01: b_lane = bus_rdata[15:8];
            2'b10: b_lane = bus_rdata[23:16];
            2'b11: b_lane = bus_rdata[31:24];
        endcase
        h_lane = off[1] ? bus_rdata[31:16] : bus_rdata[15:0]; // off 0 or 2

        case (mem_size)
            `MEM_B : load_data = mem_unsigned ? {24'd0, b_lane}
                                              : {{24{b_lane[7]}},  b_lane};
            `MEM_H : load_data = mem_unsigned ? {16'd0, h_lane}
                                              : {{16{h_lane[15]}}, h_lane};
            `MEM_W : load_data = bus_rdata;
            default: load_data = bus_rdata;
        endcase
    end

endmodule
