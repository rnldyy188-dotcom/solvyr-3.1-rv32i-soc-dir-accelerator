// ============================================================================
// hazard_unit.v  -  Stall / bubble / flush control for the pipeline
//
// Two jobs:
//
// 1. LOAD-USE HAZARD (data hazard that forwarding cannot fix):
//    When the instruction in EX is a load (mem_read) and the instruction in ID
//    reads the load's destination register, the loaded data is not available
//    in time to forward. We stall one cycle:
//       - freeze PC          (stall_pc)
//       - freeze IF/ID       (stall_if_id)
//       - inject a bubble into ID/EX (bubble_id_ex), turning the dependent
//         instruction in ID into a NOP for one cycle.
//
// 2. CONTROL HAZARD (taken branch / jump resolved in EX):
//    Static not-taken prediction. When EX resolves a taken branch or a jump,
//    the two instructions already fetched behind it (in IF and ID) are wrong
//    and must be squashed:
//       - flush_if_id  (kill the instruction in IF/ID)
//       - flush_id_ex  (kill the instruction in ID/EX)
//    PC is redirected to the target by the next-PC mux (driven elsewhere).
//
// Priority: a flush dominates a stall. If we are flushing because of a taken
// branch, any load-use stall in the squashed instructions is irrelevant.
//
// Pure combinational.
// ============================================================================

module hazard_unit (
    // --- load-use detection ---
    input  wire        ex_mem_read,   // instruction in EX is a load
    input  wire [4:0]  ex_rd,         // its destination register
    input  wire [4:0]  id_rs1,        // source regs of instruction in ID
    input  wire [4:0]  id_rs2,

    // --- control hazard ---
    input  wire        ex_take_branch, // EX resolved a taken branch
    input  wire        ex_jump,        // EX has an unconditional jump

    output wire        stall_pc,
    output wire        stall_if_id,
    output wire        bubble_id_ex,
    output wire        flush_if_id,
    output wire        flush_id_ex
);

    // Redirect = taken branch or any jump resolved in EX. This drives both
    // flush outputs, which fan out to the IF/ID and ID/EX register reset/control
    // pins -- the v1.1 setup-critical net. Cap fanout so the tool replicates the
    // driver (logically identical; no cycle/result change).
    (* max_fanout = 12 *)
    wire redirect = ex_take_branch || ex_jump;

    // Load-use: EX is a load writing a non-zero reg that ID consumes.
    wire load_use = ex_mem_read && (ex_rd != 5'd0) &&
                    ((ex_rd == id_rs1) || (ex_rd == id_rs2));

    // do_stall = load_use. (No `&& !redirect`: a load-use and a redirect are
    // mutually exclusive — load_use requires the EX instruction to be a load,
    // while redirect requires it to be a taken branch/jump, and one instruction
    // cannot be both. The old `!redirect` term was therefore always redundant,
    // and it pulled the EX branch resolution (forwarding -> branch compare ->
    // ex_redirect) into the stall path -> front_stall -> the instruction-memory
    // fetch enable, creating a long combinational path to the IMEM BRAM. Using
    // load_use directly keeps the stall (and the fetch enable) off that chain.)
    wire do_stall = load_use;

    assign stall_pc     = do_stall;
    assign stall_if_id  = do_stall;
    assign bubble_id_ex = do_stall;

    // On redirect, kill the two younger instructions (IF/ID and ID/EX).
    assign flush_if_id  = redirect;
    assign flush_id_ex  = redirect;

endmodule
