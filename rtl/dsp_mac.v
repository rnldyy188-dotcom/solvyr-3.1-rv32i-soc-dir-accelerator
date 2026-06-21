// ============================================================================
// dsp_mac.v  -  Signed multiply-accumulate primitive (maps to a DSP48E1)
//
// This is the inner arithmetic primitive of the DIR accelerator: a single
// signed 16x16 multiply with a 48-bit accumulator. Coded in the canonical
// "P <= P + A*B" pattern that Vivado infers onto one Artix-7 DSP48E1 slice
// (the use_dsp attribute nudges the tool to the hard block rather than LUTs).
//
//   en=1, clear=1 : acc <= a*b              (start a new dot product)
//   en=1, clear=0 : acc <= acc + a*b        (accumulate the next term)
//   en=0, clear=1 : acc <= 0                 (reset accumulator)
//   en=0, clear=0 : hold
//
// Single accumulation stage (P register only): the result is valid the cycle
// after `en`. For higher Fmax the A/B input and M (multiply) registers of the
// DSP48E1 can be pipelined in; the accelerator FSM would then add matching
// drain cycles. A 2D convolution output pixel is just a dot product of the
// flattened window with the flattened kernel, so the accelerator drives this
// MAC one tap per cycle and reads `acc` once the window is exhausted.
// ============================================================================

module dsp_mac (
    input  wire               clk,
    input  wire               rst,
    input  wire               clear,        // start fresh accumulation
    input  wire               en,           // accumulate this cycle
    input  wire signed [15:0] a,            // operand A (e.g. pixel)
    input  wire signed [15:0] b,            // operand B (e.g. kernel coeff)
    output reg  signed [47:0] acc           // accumulated result
);

    (* use_dsp = "yes" *) wire signed [31:0] product = a * b;

    always @(posedge clk) begin
        if (rst)              acc <= 48'sd0;
        else if (clear && en) acc <= product;        // first term of a new sum
        else if (clear)       acc <= 48'sd0;
        else if (en)          acc <= acc + product;  // accumulate next term
    end

endmodule
