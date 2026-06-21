// ============================================================================
// seven_seg.v  -  Time-multiplexed 8-digit hex display driver (debug output)
//
// Drives a Digilent-style multiplexed 7-segment display (8 digits, common
// anode, active-low segments and anodes). Shows a 32-bit value as 8 hex digits.
// A refresh counter scans one digit at a time fast enough to look continuous.
//
// Segment bit order: seg = {g,f,e,d,c,b,a} (active low). dp active low.
// This is purely a debug/visualization convenience and carries no system role.
// ============================================================================

module seven_seg #(
    parameter integer REFRESH_BITS = 17    // ~ (2^17)/Fclk per digit step
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] value,              // 8 hex nibbles to show
    input  wire [7:0]  dp_in,              // decimal points (1 = lit), per digit
    output reg  [6:0]  seg,                // {g,f,e,d,c,b,a}, active low
    output reg         dp,                 // active low
    output reg  [7:0]  an                  // digit anodes, active low
);

    // ---- Refresh / digit scan --------------------------------------------
    reg [REFRESH_BITS+2:0] refresh;
    always @(posedge clk) begin
        if (rst) refresh <= 0;
        else     refresh <= refresh + 1'b1;
    end
    wire [2:0] digit = refresh[REFRESH_BITS+2:REFRESH_BITS];   // 0..7

    // ---- Select the active digit's nibble --------------------------------
    reg [3:0] nibble;
    always @(*) begin
        case (digit)
            3'd0: nibble = value[3:0];
            3'd1: nibble = value[7:4];
            3'd2: nibble = value[11:8];
            3'd3: nibble = value[15:12];
            3'd4: nibble = value[19:16];
            3'd5: nibble = value[23:20];
            3'd6: nibble = value[27:24];
            3'd7: nibble = value[31:28];
        endcase
    end

    // ---- Hex -> 7-segment (active low) -----------------------------------
    // seg bits {g,f,e,d,c,b,a}; 0 = segment ON.
    reg [6:0] seg_n;     // active-high pattern, inverted below
    always @(*) begin
        case (nibble)
            4'h0: seg_n = 7'b0111111;
            4'h1: seg_n = 7'b0000110;
            4'h2: seg_n = 7'b1011011;
            4'h3: seg_n = 7'b1001111;
            4'h4: seg_n = 7'b1100110;
            4'h5: seg_n = 7'b1101101;
            4'h6: seg_n = 7'b1111101;
            4'h7: seg_n = 7'b0000111;
            4'h8: seg_n = 7'b1111111;
            4'h9: seg_n = 7'b1101111;
            4'hA: seg_n = 7'b1110111;
            4'hB: seg_n = 7'b1111100;
            4'hC: seg_n = 7'b0111001;
            4'hD: seg_n = 7'b1011110;
            4'hE: seg_n = 7'b1111001;
            4'hF: seg_n = 7'b1110001;
        endcase
    end

    always @(posedge clk) begin
        if (rst) begin
            seg <= 7'h7F;
            dp  <= 1'b1;
            an  <= 8'hFF;
        end else begin
            seg <= ~seg_n;                         // active-low segments
            dp  <= ~dp_in[digit];                  // active-low decimal point
            an  <= ~(8'b0000_0001 << digit);       // one anode active (low)
        end
    end

endmodule
