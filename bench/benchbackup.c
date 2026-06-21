// ============================================================================
// bench.c  -  Solvyr-3 performance benchmark: software vs DIR accelerator
//
// Computes the SAME valid 2D convolution two ways and times each with the
// rdcycle CSR:
//   (A) in pure software on the base RV32I core -- the "normal processor"
//       baseline. RV32I has no hardware multiplier, so every multiply is a
//       shift-add routine (__mulsi3), exactly as a compiler targets a core
//       without the M extension. The cost of one tap therefore scales with the
//       BIT-LENGTH of the coefficient (the shift-add loop length).
//   (B) on the DIR accelerator (DSP48E1 MAC), driven over the memory-mapped bus.
//
// It publishes the cycle counts + match flag to a Data BRAM mailbox (for the
// simulation testbench) and prints them over UART (for the board). Build with
// the riscv toolchain (see Makefile).
//
// ---- Workload profiles -----------------------------------------------------
// BENCH_40X = 0 : 16x16 input, 3x3 "X" kernel {1,0,1,0,1,0,1,0,1}.
//                 This is the VERIFIED board point: sw 53963 / hw 4702 = 11.4x.
//                 Note the 0/1 coefficients are a BEST CASE for software (the
//                 shift-add multiply terminates in ~0-1 iterations), so this
//                 understates the accelerator.
// BENCH_40X = 1 : 16x16 input, 7x7 fixed-point (Q10) Gaussian kernel (default).
//                 Realistic multi-bit coefficients + higher arithmetic
//                 intensity. tools/bench_estimate.py (calibrated to the 11.4x
//                 point) predicts ~40x end-to-end. RE-MEASURE on the board.
// ============================================================================
#include "solvyr3.h"

#ifndef BENCH_40X
#define BENCH_40X 1
#endif

#define IMG_W 16
#define IMG_H 16
#if BENCH_40X
#define K 7
#else
#define K 3
#endif
#define OUT_W (IMG_W - K + 1)
#define OUT_H (IMG_H - K + 1)

// ---- UART per-character guard delay ----------------------------------------
// The TX path now has a 1-deep holding register (rtl/uart.v), so the software
// handshake (poll TX_READY, then write) is reliable and NO guard is needed.
// This delay is kept ONLY so the firmware still prints correctly on an OLD
// bitstream built before the UART fix. After you rebuild the bitstream with the
// fixed uart.v, set UART_TX_GUARD to 0 (the simulation is unaffected either way
// because results are published before any UART printing -- see main()).
#ifndef UART_TX_GUARD
#define UART_TX_GUARD 12000u
#endif

// ---- Simulation result mailbox (mirrored in Data BRAM) ---------------------
// Fixed high DMEM offset that never collides with .bss (img/out_sw end ~0x1513)
// or the descending stack (top of DMEM). 0x1A00 = DMEM word 640. MUST stay in
// sync with the RESULT_W localparam in bench/tb_bench.v.
#define MAILBOX       (DMEM_BASE + 0x0A00u)
#define MB_SW_CYCLES  (*(volatile uint32_t *)(MAILBOX + 0x00))
#define MB_HW_CYCLES  (*(volatile uint32_t *)(MAILBOX + 0x04))
#define MB_MATCH      (*(volatile uint32_t *)(MAILBOX + 0x08))

// ---- read the cycle counter (rdcycle) --------------------------------------
static inline uint32_t rdcycle(void) {
    uint32_t c; __asm__ volatile ("rdcycle %0" : "=r"(c)); return c;
}

// ---- software 32x32 multiply (RV32I has no MUL) ----------------------------
// The compiler emits calls to this for every `*` on a no-M core. Its cost is
// proportional to the bit-length of `b` -- which is exactly why multi-bit
// coefficients make the software baseline realistically expensive.
int __mulsi3(unsigned a, unsigned b) {
    int r = 0;
    while (b) { if (b & 1) r += a; a <<= 1; b >>= 1; }
    return r;
}

// ---- software unsigned divide/modulo helpers for -nostdlib RV32I ----------
unsigned __udivsi3(unsigned n, unsigned d) {
    if (d == 0) return 0xFFFFFFFFu;
    unsigned q = 0, r = 0;
    for (int i = 31; i >= 0; i--) {
        r = (r << 1) | ((n >> i) & 1u);
        if (r >= d) { r -= d; q |= (1u << i); }
    }
    return q;
}
unsigned __umodsi3(unsigned n, unsigned d) {
    if (d == 0) return n;
    unsigned r = 0;
    for (int i = 31; i >= 0; i--) {
        r = (r << 1) | ((n >> i) & 1u);
        if (r >= d) r -= d;
    }
    return r;
}

// ---- trap handler required by startup.s ------------------------------------
void trap_handler(uint32_t mcause, uint32_t mepc) {
    (void)mcause; (void)mepc;
    while (1) { GPIO_LED = 0xBAD; }
}

// ---- UART helpers (poll TX_READY -- the reliable holding-register flag) -----
static void uputc(char c) {
    while (!(UART_STATUS & UART_TXRDY)) { }   // wait until the TX FIFO slot is free
    UART_TXD = (uint8_t)c;
#if UART_TX_GUARD
    for (volatile uint32_t i = 0; i < UART_TX_GUARD; i++) { }  // legacy-bitstream guard
#endif
}
static void uputs(const char *s) { while (*s) uputc(*s++); }
static void uputu(uint32_t v) { char b[12]; int n = 0;
    do { b[n++] = '0' + (v % 10); v /= 10; } while (v);
    while (n) uputc(b[--n]); }

// ---- the input tile and kernel (shared by both paths) ----------------------
static int16_t img[IMG_W * IMG_H];                   // .bss (filled at runtime)
#if BENCH_40X
// 7x7 Gaussian in Q10 fixed-point (peak 1024 = 1.0), floored so no tap is 0 --
// a realistic image/depth filter. Generated by tools/bench_estimate.py.
static const int16_t krn[K * K] = {
     159,  267,  364,  404,  364,  267,  159,
     267,  448,  611,  677,  611,  448,  267,
     364,  611,  833,  923,  833,  611,  364,
     404,  677,  923, 1024,  923,  677,  404,
     364,  611,  833,  923,  833,  611,  364,
     267,  448,  611,  677,  611,  448,  267,
     159,  267,  364,  404,  364,  267,  159,
};
#else
static const int16_t krn[K * K] = { 1,0,1, 0,1,0, 1,0,1 };   // "X" kernel
#endif
static int32_t out_sw[OUT_W * OUT_H];                // .bss

static void make_input(void) {
    // realistic 8-bit depth/intensity ramp (0..255)
    for (int i = 0; i < IMG_W * IMG_H; i++) img[i] = (int16_t)(i & 0xFF);
}

// ---- (A) software valid 2D convolution -------------------------------------
static void conv_sw(void) {
    for (int oy = 0; oy < OUT_H; oy++)
        for (int ox = 0; ox < OUT_W; ox++) {
            int32_t acc = 0;
            for (int ky = 0; ky < K; ky++)
                for (int kx = 0; kx < K; kx++)
                    acc += img[(oy + ky) * IMG_W + (ox + kx)] * krn[ky * K + kx];
            out_sw[oy * OUT_W + ox] = acc;
        }
}

// ---- (B) DIR accelerator convolution ---------------------------------------
// scratchpad layout: input @0, kernel @256, output @512 (word offsets)
#define IN_BASE 0
#define CO_BASE 256
#define OUT_BASE 512
static void conv_hw(void) {
    for (int i = 0; i < IMG_W * IMG_H; i++) SCRATCH(IN_BASE + i) = (uint32_t)(int32_t)img[i];
    for (int i = 0; i < K * K; i++)         SCRATCH(CO_BASE + i) = (uint32_t)(int32_t)krn[i];
    ACC_INBASE  = IN_BASE;
    ACC_OUTBASE = OUT_BASE;
    ACC_CONFIG  = ((uint32_t)IMG_H << 16) | (uint32_t)IMG_W;
    ACC_KCONFIG = ((uint32_t)CO_BASE << 16) | (0u << 8) | (uint32_t)K;
    ACC_CONTROL = ACC_START;
    while (!(ACC_STATUS & ACC_DONE)) { }
}

int main(void) {
    make_input();

    uint32_t t0 = rdcycle();
    conv_sw();
    uint32_t sw_cycles = rdcycle() - t0;

    t0 = rdcycle();
    conv_hw();
    uint32_t hw_cycles = rdcycle() - t0;

    // correctness: compare the two output tiles
    int mismatch = 0;
    for (int i = 0; i < OUT_W * OUT_H; i++)
        if ((uint32_t)out_sw[i] != SCRATCH(OUT_BASE + i)) { mismatch = 1; break; }

    // Publish to the Data BRAM mailbox FIRST -- before any (slow) UART printing
    // -- so the simulation testbench finishes the instant compute completes
    // instead of waiting out the entire serial dump. (This, not the guard delay,
    // is what stops tb_bench.v from timing out.)
    MB_SW_CYCLES = sw_cycles;
    MB_HW_CYCLES = hw_cycles;
    MB_MATCH     = mismatch ? 0u : 1u;

    // Human-readable report over UART (board path).
    uputs("\r\n=== Solvyr-3 benchmark: software vs DIR accelerator ===\r\n");
    uputs("workload: "); uputu(IMG_W); uputc('x'); uputu(IMG_H);
    uputs(" input, "); uputu(K); uputc('x'); uputu(K);
    uputs(" kernel -> "); uputu(OUT_W); uputc('x'); uputu(OUT_H); uputs(" output\r\n");
    uputs("software cycles    : "); uputu(sw_cycles); uputs("\r\n");
    uputs("accelerator cycles : "); uputu(hw_cycles); uputs("\r\n");
    uputs("speedup x10        : ");                       // one-decimal fixed point
    uputu(hw_cycles ? (sw_cycles * 10u) / hw_cycles : 0); uputs("  (=> divide by 10)\r\n");
    uputs(mismatch ? "RESULTS MISMATCH\r\n" : "results match\r\n");

    for (;;) { GPIO_LED = hw_cycles; }   // park (LEDs show hw cycle count)
    return 0;
}
