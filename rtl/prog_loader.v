// ============================================================================
// prog_loader.v  -  Optional UART program loader / boot helper
//
// When `enable` is asserted (e.g. tied to a "boot" slide switch), this module
// receives a program image over UART and writes it into instruction BRAM via
// the data-side port, holding the CPU in reset until the load completes. When
// `enable` is low it does nothing and immediately reports `load_done` (the
// program then comes from the BRAM $readmemh image instead).
//
// Wire protocol (little-endian):
//   [4 bytes]  word_count N
//   [N words]  4 bytes each -> written to IBRAM word addresses 0,1,2,...
//
// The 8-N-1 receive FSM is the shared uart_rx_core module (also used by uart.v).
// The loader instantiates its own copy and owns the line during boot, so it
// stays independent of the system UART that the CPU owns at runtime.
// Custom-bus master to IBRAM port B (single-cycle writes; BRAM accepts each).
// ============================================================================

module prog_loader #(
    parameter integer CLK_HZ     = 100_000_000,
    parameter integer BAUD       = 115_200,
    parameter integer IMEM_WORDS = 1024
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        enable,           // boot-select; 0 => skip loading
    input  wire        uart_rx,          // serial input

    // ---- IBRAM port-B master ----
    output reg         imem_req,
    output reg         imem_we,
    output reg [31:0]  imem_addr,
    output reg [31:0]  imem_wdata,
    output reg [3:0]   imem_byte_en,
    output wire        load_done         // 1 when image is loaded (or disabled)
);

    // ======================================================================
    //  8-N-1 UART receiver -> (rx_byte, rx_strobe)
    //  Shared with the system UART through the uart_rx_core module. The loader
    //  instantiates its own copy and owns the line during boot, so it stays
    //  independent of the CPU's runtime UART.
    // ======================================================================
    wire [7:0] rx_byte;
    wire       rx_strobe;

    uart_rx_core #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_rx (
        .clk(clk), .rst(rst), .rx(uart_rx),
        .data(rx_byte), .strobe(rx_strobe)
    );

    // ======================================================================
    //  Loader FSM
    // ======================================================================
    localparam [1:0] L_WAIT=2'd0, L_LEN=2'd1, L_DATA=2'd2, L_DONE=2'd3;
    reg [1:0]  lstate;
    reg [1:0]  bsel;          // byte index within the current word (0..3)
    reg [31:0] word_buf;
    reg [31:0] word_count;
    reg [31:0] word_idx;
    reg        done_r;

    assign load_done = done_r;

    always @(posedge clk) begin
        if (rst) begin
            lstate <= L_WAIT; bsel <= 0; word_buf <= 0;
            word_count <= 0; word_idx <= 0; done_r <= 1'b0;
            imem_req <= 1'b0; imem_we <= 1'b0;
            imem_addr <= 0; imem_wdata <= 0; imem_byte_en <= 4'h0;
        end else begin
            imem_req <= 1'b0;
            imem_we  <= 1'b0;
            case (lstate)
                L_WAIT: begin
                    if (!enable) begin
                        done_r <= 1'b1;              // no load required
                    end else begin
                        done_r <= 1'b0;
                        bsel <= 0; word_idx <= 0;
                        lstate <= L_LEN;
                    end
                end
                // Collect 4 little-endian bytes of the word count.
                L_LEN: if (rx_strobe) begin
                    word_buf <= {rx_byte, word_buf[31:8]};
                    if (bsel == 2'd3) begin
                        word_count <= {rx_byte, word_buf[31:8]};
                        bsel   <= 0;
                        lstate <= L_DATA;
                    end else bsel <= bsel + 1'b1;
                end
                // Collect program words and write each into IBRAM.
                L_DATA: begin
                    if (word_idx == word_count) begin
                        lstate <= L_DONE;
                    end else if (rx_strobe) begin
                        word_buf <= {rx_byte, word_buf[31:8]};
                        if (bsel == 2'd3) begin
                            imem_req     <= 1'b1;
                            imem_we      <= 1'b1;
                            imem_byte_en <= 4'hF;
                            imem_addr    <= word_idx << 2;
                            imem_wdata   <= {rx_byte, word_buf[31:8]};
                            word_idx     <= word_idx + 1'b1;
                            bsel         <= 0;
                        end else bsel <= bsel + 1'b1;
                    end
                end
                L_DONE: done_r <= 1'b1;
                default: lstate <= L_WAIT;
            endcase
        end
    end

endmodule
