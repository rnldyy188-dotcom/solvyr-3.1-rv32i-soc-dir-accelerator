// ============================================================================
// clk_reset.v  -  Clocking and reset generation for the Artix-7 board
//
// Produces the single system clock and a clean SYNCHRONOUS, active-high reset
// for the whole SoC from the board clock pin and the reset push-button.
//
// Clock:
//   - Default: the board clock is used directly (a BUFG is inferred by Vivado
//     on a top-level clock net, so no primitive is needed here).
//   - Optional: define SOLVYR3_USE_MMCM to instantiate an MMCME2_BASE and run
//     the SoC from a derived frequency. The primitive is guarded so simulation
//     (and non-Xilinx tools) compile the pass-through path.
//
// Reset:
//   - The asynchronous button is asserted asynchronously but DEASSERTED
//     synchronously (async-assert / sync-deassert) through a 2-flop chain and
//     then stretched, giving every flop in the design a clean synchronous
//     release. RST_ACTIVE_LOW selects the button polarity.
// ============================================================================

module clk_reset #(
    parameter RST_ACTIVE_LOW = 1,        // 1: button low = reset (Digilent CPU_RESETN)
    parameter integer STRETCH_BITS = 4   // hold reset 2^STRETCH_BITS cycles after release
) (
    input  wire clk_in,                  // board oscillator pin
    input  wire rst_btn,                 // reset push-button pin
    output wire clk,                     // system clock
    output wire rst                      // synchronous, active-high reset
);

    // ---- System clock ----------------------------------------------------
`ifdef SOLVYR3_USE_MMCM
    // Derived clock via MMCM (Vivado / unisim only). Edit CLKFBOUT_MULT_F /
    // CLKOUT0_DIVIDE_F / CLKIN1_PERIOD for the desired output frequency.
    wire clk_fb, clk_mmcm, locked;
    MMCME2_BASE #(
        .CLKIN1_PERIOD   (10.0),         // 100 MHz input
        .CLKFBOUT_MULT_F (10.0),         // VCO = 1000 MHz
        .CLKOUT0_DIVIDE_F(10.0),         // 100 MHz output
        .DIVCLK_DIVIDE   (1)
    ) u_mmcm (
        .CLKIN1(clk_in), .CLKFBIN(clk_fb), .CLKFBOUT(clk_fb),
        .CLKOUT0(clk_mmcm), .LOCKED(locked),
        .RST(1'b0), .PWRDWN(1'b0),
        .CLKOUT1(), .CLKOUT2(), .CLKOUT3(), .CLKOUT4(), .CLKOUT5(),
        .CLKOUT6(), .CLKOUT0B(), .CLKOUT1B(), .CLKOUT2B(), .CLKOUT3B(),
        .CLKFBOUTB()
    );
    assign clk = clk_mmcm;
    wire   clk_ok = locked;
`else
    assign clk = clk_in;                 // direct board clock (BUFG inferred)
    wire   clk_ok = 1'b1;
`endif

    // ---- Reset synchronizer + stretch ------------------------------------
    wire rst_req = RST_ACTIVE_LOW ? ~rst_btn : rst_btn;      // active-high request
    wire async_rst = rst_req | ~clk_ok;                      // also hold until clk ok

    reg meta, sync;
    always @(posedge clk or posedge async_rst) begin
        if (async_rst) begin meta <= 1'b1; sync <= 1'b1; end
        else           begin meta <= 1'b0; sync <= meta;  end
    end

    // Stretch: keep reset high for a counter span after `sync` deasserts.
    reg [STRETCH_BITS-1:0] cnt;
    reg rst_r;
    always @(posedge clk) begin
        if (sync) begin
            cnt   <= {STRETCH_BITS{1'b0}};
            rst_r <= 1'b1;
        end else if (cnt != {STRETCH_BITS{1'b1}}) begin
            cnt   <= cnt + 1'b1;
            rst_r <= 1'b1;
        end else begin
            rst_r <= 1'b0;
        end
    end

    assign rst = rst_r;

endmodule
