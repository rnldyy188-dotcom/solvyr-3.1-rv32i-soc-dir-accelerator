// ============================================================================
// dir_accel.v  -  DIR Accelerator: memory-mapped 2D windowed image/depth filter
//
// A workload-specific hardware accelerator for DIR-oriented image/depth
// processing, controlled by the RISC-V CPU over the custom memory-mapped bus.
//
//   EXTERNAL view : a 2D convolution / windowed filter over a depth/image tile
//                   (valid convolution, K x K kernel, configurable scaling).
//   INTERNAL view : a streaming multiply-accumulate / dot-product engine built
//                   around a DSP48E1 MAC (dsp_mac.v). Each output pixel is the
//                   dot product of the flattened K x K window with the kernel.
//
// Two bus slave ports:
//   - Register block   @ 0x5000 (ACC_CONTROL/STATUS/INPUT_BASE/OUTPUT_BASE/
//                                 CONFIG/KERNEL_CONFIG/RESULT/INT_ACK)
//   - Scratchpad       @ 0x6000 (true dual-port BRAM, port A = CPU)
// The accelerator datapath uses scratchpad port B (pixels / coeffs / results).
//
// Software flow:
//   1. CPU writes input tile + K*K kernel coefficients into the scratchpad.
//   2. CPU programs INPUT_BASE/OUTPUT_BASE/CONFIG/KERNEL_CONFIG, coeff_base.
//   3. CPU writes ACC_CONTROL.START=1.  -> accelerator asserts BUSY.
//   4. Accelerator loads coeffs, convolves, writes the output tile back to the
//      scratchpad, latches the last sample in ACC_RESULT, asserts DONE (+ IRQ).
//   5. CPU polls DONE or takes the accelerator interrupt, reads the output,
//      then clears DONE via INT_ACK.
//
// Scratchpad data format: one sample per 32-bit word, signed 16-bit in [15:0].
// Addresses in the registers are WORD offsets into the scratchpad.
// ============================================================================
`include "solvyr3_defs.vh"

module dir_accel #(
    parameter integer SCRATCH_WORDS = 1024,
    parameter integer SCR_ABITS     = 10,    // log2(SCRATCH_WORDS)
    parameter integer MAXK          = 7      // maximum kernel dimension
) (
    input  wire        clk,
    input  wire        rst,

    // ---- Register-block slave port (0x5000) ----
    input  wire        rreq,
    input  wire        rwe,
    input  wire [31:0] raddr,
    input  wire [31:0] rwdata,
    input  wire [3:0]  rbyte_en,
    output reg  [31:0] rrdata,
    output reg         rready,

    // ---- Scratchpad slave port (0x6000), CPU = port A ----
    input  wire        sreq,
    input  wire        swe,
    input  wire [31:0] saddr,
    input  wire [31:0] swdata,
    input  wire [3:0]  sbyte_en,
    output wire [31:0] srdata,
    output reg         sready,

    // ---- Interrupt + status ----
    output wire        irq_accel,
    output wire        acc_busy,
    output wire        acc_done
);

    // ======================================================================
    //  Configuration registers (written by the CPU before START)
    // ======================================================================
    reg [31:0] input_base;       // word offset of input tile
    reg [31:0] output_base;      // word offset of output tile
    reg [15:0] img_w, img_h;     // input tile dimensions
    reg [3:0]  kdim;             // kernel dimension K (<= MAXK)
    reg [3:0]  rshift;           // output right-shift (fixed-point scaling)
    reg [11:0] coeff_base;       // word offset of K*K kernel coefficients
    reg        irq_en;           // interrupt enable

    wire [5:0] rwidx = raddr[7:2];
    wire       rwr   = rreq && rwe;

    wire start_pulse = rwr && (rwidx == (`ACC_CONTROL >> 2)) && rwdata[`ACC_CTRL_START];
    wire int_ack     = rwr && (rwidx == (`ACC_INT_ACK >> 2)) && rwdata[0];

    always @(posedge clk) begin
        if (rst) begin
            input_base  <= 32'd0;
            output_base <= 32'd0;
            img_w       <= 16'd0;
            img_h       <= 16'd0;
            kdim        <= 4'd0;
            rshift      <= 4'd0;
            coeff_base  <= 12'd0;
            irq_en      <= 1'b0;
        end else if (rwr) begin
            case (rwidx)
                (`ACC_CONTROL >> 2)      : irq_en <= rwdata[`ACC_CTRL_IRQEN];
                (`ACC_INPUT_BASE >> 2)   : input_base  <= rwdata;
                (`ACC_OUTPUT_BASE >> 2)  : output_base <= rwdata;
                (`ACC_CONFIG >> 2)       : begin img_w <= rwdata[15:0]; img_h <= rwdata[31:16]; end
                (`ACC_KERNEL_CONFIG >> 2): begin
                    kdim       <= rwdata[3:0];
                    rshift     <= rwdata[11:8];
                    coeff_base <= rwdata[27:16];
                end
                default: ;
            endcase
        end
    end

    // ======================================================================
    //  FSM + datapath state
    // ======================================================================
    // Streaming FSM: the coefficient load and the per-pixel MAC are PIPELINED.
    // Each cycle presents the next scratchpad address while consuming (storing /
    // MACing) the operand fetched the previous cycle, hiding the 1-cycle BRAM
    // read latency -> ~1 cycle per tap instead of 2 (address-then-data).
    localparam [2:0]
        S_IDLE   = 3'd0,
        S_LC     = 3'd1,   // pipelined coefficient load
        S_PINIT  = 3'd2,   // per-output-pixel init
        S_STREAM = 3'd3,   // pipelined MAC stream (1 cycle / tap)
        S_WRITE  = 3'd4,
        S_DONE   = 3'd5;

    reg [2:0]  state;
    reg        busy, done, error;
    reg [31:0] result_reg;

    // working (latched) copy of the configuration for the running job
    reg [31:0] w_in_base, w_out_base;
    reg [4:0]  w_k;
    reg [3:0]  w_shift;
    reg [11:0] w_coeff_base;
    reg [15:0] w_out_w, w_out_h;

    // counters / pipeline registers
    reg [15:0] ox, oy;           // output pixel position
    reg [4:0]  kx, ky;           // window position (address being presented)
    reg [6:0]  tap;              // tap index being presented (0 .. K*K)
    reg [6:0]  ci;               // coeff-load index being presented
    reg [6:0]  sci_d;            // coeff-load store index (1 cycle behind ci)
    reg        lc_valid_d;       // a coeff read is in flight
    reg        st_valid_d;       // a pixel read is in flight (MAC pending)

    // Incremental scratchpad address pointers (strength reduction). The FSM
    // scans the output grid and each K x K window in raster order, so every
    // address step is a CONSTANT increment. Keeping these as registers removes
    // the per-cycle (oy+ky)*img_w / oy*out_w multiplies from the BRAM-address
    // path -- those inferred DSP48E1s and were the 100 MHz critical path. The
    // strides reuse existing config registers:
    //   within a window, a row wrap adds (W-K+1) = w_out_w to pix_ptr;
    //   between output pixels, a row wrap adds (W-out_w+1) = w_k to win_base.
    reg [31:0] win_base;         // window top-left word offset  (in_base + oy*W + ox)
    reg [31:0] pix_ptr;          // current tap word offset      (win_base + ky*W + kx)
    reg [31:0] out_ptr;          // current output word offset   (out_base + oy*out_w + ox)

    // coefficient buffer (loaded once per job)
    reg signed [15:0] coeff_buf [0:MAXK*MAXK-1];
    reg signed [15:0] coeff_d;   // coeff aligned to the in-flight pixel
    reg               first_d;   // first tap of the current dot product

    wire [7:0] kk      = w_k * w_k;                      // taps per window
    wire       present = (state == S_LC)     ? (ci  < kk) :
                         (state == S_STREAM) ? (tap < kk) : 1'b0;

    // ======================================================================
    //  Scratchpad (true dual-port) + DSP MAC
    // ======================================================================
    reg         b_en, b_we;
    reg  [31:0] b_addr, b_wdata;
    reg  [3:0]  b_byte_en;
    wire [31:0] b_rdata;
    wire [31:0] a_rdata;

    dpram_be #(.DEPTH_WORDS(SCRATCH_WORDS), .ADDR_BITS(SCR_ABITS)) u_scratch (
        .clk(clk),
        .a_en(sreq), .a_we(swe & sreq), .a_addr(saddr),
        .a_wdata(swdata), .a_byte_en(sbyte_en), .a_rdata(a_rdata),
        .b_en(b_en), .b_we(b_we), .b_addr(b_addr),
        .b_wdata(b_wdata), .b_byte_en(b_byte_en), .b_rdata(b_rdata)
    );
    assign srdata = a_rdata;

    reg                mac_en, mac_clear;
    reg signed [15:0]  mac_a, mac_b;
    wire signed [47:0] mac_acc;

    dsp_mac u_mac (
        .clk(clk), .rst(rst),
        .clear(mac_clear), .en(mac_en),
        .a(mac_a), .b(mac_b), .acc(mac_acc)
    );

    // ---- Convenience: shifted/truncated output sample ---------------------
    wire signed [47:0] mac_shifted = mac_acc >>> w_shift;
    wire [31:0]        out_sample  = mac_shifted[31:0];

    wire last_pix = (ox == w_out_w - 16'd1) && (oy == w_out_h - 16'd1);

    // ======================================================================
    //  Combinational datapath control (scratchpad B port + MAC)
    // ======================================================================
    always @(*) begin
        b_en      = 1'b0;
        b_we      = 1'b0;
        b_addr    = 32'd0;
        b_wdata   = 32'd0;
        b_byte_en = 4'b0000;
        mac_en    = 1'b0;
        mac_clear = 1'b0;
        mac_a     = 16'sd0;
        mac_b     = 16'sd0;

        case (state)
            // Coefficient load: present coeff[ci] address while the previous
            // coeff's data is being stored (in the sequential block).
            S_LC: begin
                if (present) begin
                    b_en   = 1'b1;
                    b_addr = (w_coeff_base + ci) << 2;
                end
            end
            // MAC stream: present pixel[tap] address, and MAC the pixel fetched
            // last cycle (st_valid_d) against its aligned coefficient.
            S_STREAM: begin
                if (present) begin
                    b_en   = 1'b1;
                    b_addr = pix_ptr << 2;
                end
                if (st_valid_d) begin
                    mac_en    = 1'b1;
                    mac_clear = first_d;
                    mac_a     = b_rdata[15:0];   // in-flight pixel (signed 16-bit)
                    mac_b     = coeff_d;         // its aligned coefficient
                end
            end
            S_WRITE: begin
                b_en      = 1'b1;
                b_we      = 1'b1;
                b_byte_en = 4'b1111;
                b_addr    = out_ptr << 2;
                b_wdata   = out_sample;
            end
            default: ;
        endcase
    end

    // ======================================================================
    //  Sequential FSM
    // ======================================================================
    always @(posedge clk) begin
        if (rst) begin
            state      <= S_IDLE;
            busy       <= 1'b0;
            done       <= 1'b0;
            error      <= 1'b0;
            result_reg <= 32'd0;
            ox <= 16'd0; oy <= 16'd0;
            kx <= 5'd0;  ky <= 5'd0;
            tap <= 7'd0; ci <= 7'd0; sci_d <= 7'd0;
            lc_valid_d <= 1'b0; st_valid_d <= 1'b0;
            coeff_d <= 16'sd0; first_d <= 1'b0;
            win_base <= 32'd0; pix_ptr <= 32'd0; out_ptr <= 32'd0;
        end else begin
            if (int_ack) done <= 1'b0;     // CPU acknowledges/clears the interrupt

            case (state)
                // ----------------------------------------------------------
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start_pulse) begin
                        // Latch the configuration for this job.
                        w_in_base    <= input_base;
                        w_out_base   <= output_base;
                        w_k          <= {1'b0, kdim};
                        w_shift      <= rshift;
                        w_coeff_base <= coeff_base;
                        w_out_w      <= img_w - {12'd0, kdim} + 16'd1;
                        w_out_h      <= img_h - {12'd0, kdim} + 16'd1;
                        // Validate: K in [1, MAXK] and tile at least K x K.
                        if (kdim == 4'd0 || kdim > MAXK[3:0] ||
                            img_w < {12'd0, kdim} || img_h < {12'd0, kdim}) begin
                            error <= 1'b1;
                            done  <= 1'b1;       // signal completion (with error)
                            busy  <= 1'b0;
                        end else begin
                            error      <= 1'b0;
                            done       <= 1'b0;
                            busy       <= 1'b1;
                            ci         <= 7'd0;
                            lc_valid_d <= 1'b0;
                            win_base   <= input_base;    // address pointers for output (0,0)
                            out_ptr    <= output_base;
                            state      <= S_LC;
                        end
                    end
                end
                // ---- pipelined coefficient load --------------------------
                S_LC: begin
                    // store the coeff fetched last cycle
                    if (lc_valid_d) coeff_buf[sci_d] <= b_rdata[15:0];
                    sci_d      <= ci;
                    lc_valid_d <= present;
                    if (present) ci <= ci + 7'd1;
                    // last coeff stored this cycle -> begin compute
                    if (!present && lc_valid_d) begin
                        ox <= 16'd0; oy <= 16'd0;
                        state <= S_PINIT;
                    end
                end
                // ---- per-output-pixel init -------------------------------
                S_PINIT: begin
                    kx <= 5'd0; ky <= 5'd0; tap <= 7'd0;
                    pix_ptr    <= win_base;     // read pointer = this window's top-left
                    st_valid_d <= 1'b0;
                    state <= S_STREAM;
                end
                // ---- pipelined MAC stream (1 cycle / tap) ----------------
                S_STREAM: begin
                    if (present) begin
                        coeff_d <= coeff_buf[tap];
                        first_d <= (tap == 7'd0);
                        tap     <= tap + 7'd1;
                        // advance the window scan and the matching read pointer
                        // (constant strides, no multiply): a row wrap moves to
                        // the next image row of the window (+ w_out_w = W-K+1).
                        if (kx == w_k - 5'd1) begin
                            kx <= 5'd0; ky <= ky + 5'd1;
                            pix_ptr <= pix_ptr + {16'd0, w_out_w};
                        end else begin
                            kx <= kx + 5'd1;
                            pix_ptr <= pix_ptr + 32'd1;
                        end
                    end
                    st_valid_d <= present;
                    // last tap MAC issued this cycle -> write the result next
                    if (!present && st_valid_d)
                        state <= S_WRITE;
                end
                // ---- write output sample + advance pixel -----------------
                S_WRITE: begin
                    result_reg <= out_sample;
                    if (last_pix) begin
                        state <= S_DONE;
                    end else begin
                        // advance the output pixel and the matching pointers
                        // (no multiply): the output buffer is contiguous, so
                        // out_ptr just increments; a row wrap moves win_base to
                        // the next window row (+ w_k = W-out_w+1).
                        out_ptr <= out_ptr + 32'd1;
                        if (ox == w_out_w - 16'd1) begin
                            ox <= 16'd0; oy <= oy + 16'd1;
                            win_base <= win_base + {27'd0, w_k};
                        end else begin
                            ox <= ox + 16'd1;
                            win_base <= win_base + 32'd1;
                        end
                        state <= S_PINIT;
                    end
                end
                // ----------------------------------------------------------
                S_DONE: begin
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    assign irq_accel = done & irq_en;
    assign acc_busy  = busy;
    assign acc_done  = done;

    // ======================================================================
    //  Register-block read path + scratchpad ready
    // ======================================================================
    always @(posedge clk) begin
        if (rst) begin
            rrdata <= 32'd0;
            rready <= 1'b0;
            sready <= 1'b0;
        end else begin
            rready <= rreq;
            sready <= sreq;
            case (rwidx)
                (`ACC_CONTROL >> 2)      : rrdata <= {29'd0, 1'b0, irq_en, 1'b0};
                (`ACC_STATUS >> 2)       : rrdata <= {29'd0, error, done, busy};
                (`ACC_INPUT_BASE >> 2)   : rrdata <= input_base;
                (`ACC_OUTPUT_BASE >> 2)  : rrdata <= output_base;
                (`ACC_CONFIG >> 2)       : rrdata <= {img_h, img_w};
                (`ACC_KERNEL_CONFIG >> 2): rrdata <= {4'd0, coeff_base, 4'd0, rshift, 4'd0, kdim};
                (`ACC_RESULT >> 2)       : rrdata <= result_reg;
                default                  : rrdata <= 32'd0;
            endcase
        end
    end

endmodule
