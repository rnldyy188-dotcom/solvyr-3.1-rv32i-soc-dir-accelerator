// ============================================================================
// regfile.v  -  32 x 32-bit register file for Solvyr-3
//
//   - x0 is hardwired to zero (writes to x0 are ignored).
//   - 2 read ports, 1 write port.
//   - Synchronous write on the rising clock edge.
//   - WRITE-FIRST INTERNAL BYPASS: if a read port addresses the same register
//     being written this cycle, the read returns the *new* value. This emulates
//     the classic "write in first half / read in second half" behaviour and
//     removes the need for a separate WB->ID forwarding path.
//
// IMPLEMENTATION NOTE (efficiency):
//   The array has no synchronous reset. A reset that clears all 32 words forces
//   a flip-flop implementation (~1024 FFs) because distributed/Block RAM cannot
//   be cleared in one cycle. RISC-V does not require GPRs to reset (only x0 is
//   always 0, handled by the read mux), so we instead power-up to 0 via an
//   `initial` block. On Artix-7 this lets the 2R/1W array infer as LUT-based
//   distributed RAM, saving the flip-flops and the reset fan-out, and gives
//   defined values in simulation.
// ============================================================================

module regfile (
    input  wire        clk,

    input  wire [4:0]  rs1_addr,
    input  wire [4:0]  rs2_addr,
    output wire [31:0] rs1_data,
    output wire [31:0] rs2_data,

    input  wire        we,         // write enable (from WB stage)
    input  wire [4:0]  rd_addr,
    input  wire [31:0] rd_data
);

    reg [31:0] regs [0:31];

    integer i;
    initial begin
        for (i = 0; i < 32; i = i + 1) regs[i] = 32'd0;
    end

    // A write is real only when enabled and not targeting x0.
    wire write_en = we && (rd_addr != 5'd0);

    // ---- Synchronous write (no reset -> distributed RAM) ------------------
    always @(posedge clk) begin
        if (write_en) regs[rd_addr] <= rd_data;
    end

    // ---- Read with write-first bypass ------------------------------------
    // x0 always reads 0. Otherwise, if this read matches the in-flight write,
    // return the fresh write data; else return the stored value.
    assign rs1_data = (rs1_addr == 5'd0)                  ? 32'd0   :
                      (write_en && (rs1_addr == rd_addr)) ? rd_data :
                                                            regs[rs1_addr];

    assign rs2_data = (rs2_addr == 5'd0)                  ? 32'd0   :
                      (write_en && (rs2_addr == rd_addr)) ? rd_data :
                                                            regs[rs2_addr];

endmodule
