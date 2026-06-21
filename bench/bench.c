// ============================================================================
// bench.c  -  Solvyr-3 performance benchmark: software vs DIR accelerator
// Clean explainable-output version: task + samples + cycles/time.
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

// Per-character TX guard.
// At 100 MHz / 115200 baud, one UART frame is about 8680 cycles.
// 12000 is safe and prevents dropped '\r\n' bytes.
#ifndef UART_TX_GUARD
#define UART_TX_GUARD 12000u
#endif

#define MAILBOX       (DMEM_BASE + 0x0A00u)
#define MB_SW_CYCLES  (*(volatile uint32_t *)(MAILBOX + 0x00))
#define MB_HW_CYCLES  (*(volatile uint32_t *)(MAILBOX + 0x04))
#define MB_MATCH      (*(volatile uint32_t *)(MAILBOX + 0x08))

static inline uint32_t rdcycle(void) {
    uint32_t c;
    __asm__ volatile ("rdcycle %0" : "=r"(c));
    return c;
}

// Minimal software multiply/divide support for RV32I-only build.
int __mulsi3(unsigned a, unsigned b) {
    int r = 0;
    while (b) {
        if (b & 1u) r += a;
        a <<= 1;
        b >>= 1;
    }
    return r;
}

unsigned __udivsi3(unsigned n, unsigned d) {
    if (d == 0u) return 0xFFFFFFFFu;

    unsigned q = 0;
    unsigned r = 0;

    for (int i = 31; i >= 0; i--) {
        r = (r << 1) | ((n >> i) & 1u);
        if (r >= d) {
            r -= d;
            q |= (1u << i);
        }
    }

    return q;
}

unsigned __umodsi3(unsigned n, unsigned d) {
    if (d == 0u) return n;

    unsigned r = 0;

    for (int i = 31; i >= 0; i--) {
        r = (r << 1) | ((n >> i) & 1u);
        if (r >= d) r -= d;
    }

    return r;
}

void trap_handler(uint32_t mcause, uint32_t mepc) {
    (void)mcause;
    (void)mepc;

    while (1) {
        GPIO_LED = 0xBAD;
    }
}

// -----------------------------------------------------------------------------
// UART print helpers
// -----------------------------------------------------------------------------

static void uputc(char c) {
    while (!(UART_STATUS & UART_TXRDY)) { }
    UART_TXD = (uint8_t)c;

#if UART_TX_GUARD
    for (volatile uint32_t i = 0; i < UART_TX_GUARD; i++) { }
#endif
}

static void uputs(const char *s) {
    while (*s) uputc(*s++);
}

static void uputu(uint32_t v) {
    char b[12];
    int n = 0;

    do {
        b[n++] = (char)('0' + (v % 10u));
        v /= 10u;
    } while (v);

    while (n) uputc(b[--n]);
}

static void uputi(int32_t v) {
    if (v < 0) {
        uputc('-');
        uputu((uint32_t)(-v));
    } else {
        uputu((uint32_t)v);
    }
}

// At 100 MHz: 1 cycle = 10 ns = 0.01 us.
static void put_us(uint32_t cycles) {
    uint32_t us_i = cycles / 100u;
    uint32_t us_f = cycles % 100u;

    uputu(us_i);
    uputc('.');
    if (us_f < 10u) uputc('0');
    uputu(us_f);
    uputs(" us");
}

static void put_cycles_time(const char *name, uint32_t cycles) {
    uputs(name);
    uputs(" cycles : ");
    uputu(cycles);
    uputs("\r\n");

    uputs(name);
    uputs(" time   : ");
    put_us(cycles);
    uputs("\r\n");
}

static void put_sample(const char *name, int32_t sw, int32_t hw) {
    uputs(name);
    uputs("\r\n");

    uputs("  software    = ");
    uputi(sw);
    uputs("\r\n");

    uputs("  accelerator = ");
    uputi(hw);
    uputs("\r\n");
}

// -----------------------------------------------------------------------------
// Benchmark data
// -----------------------------------------------------------------------------

static int16_t img[IMG_W * IMG_H];

#if BENCH_40X
static const int16_t krn[K * K] = {
     920,  930,  945,  974,  967,  959,  924,
     967,  948,  911,  977,  911,  948,  967,
     964,  611,  833,  923,  833,  611,  364,
     404,  677,  993, 1024,  923,  977,  904,
     364,  611,  833,  923,  833,  911,  964,
     967,  448,  611,  677,  611,  448,  967,
     959,  967,  364,  904,  964,  297,  959,
};
#else
static const int16_t krn[K * K] = {
    1, 0, 1,
    0, 1, 0,
    1, 0, 1
};
#endif

static int32_t out_sw[OUT_W * OUT_H];

static void make_input(void) {
    for (int i = 0; i < IMG_W * IMG_H; i++) {
        img[i] = (int16_t)(i & 0xFF);
    }
}

// -----------------------------------------------------------------------------
// Software convolution on RV32I
// -----------------------------------------------------------------------------

static void conv_sw(void) {
    for (int oy = 0; oy < OUT_H; oy++) {
        for (int ox = 0; ox < OUT_W; ox++) {
            int32_t acc = 0;

            for (int ky = 0; ky < K; ky++) {
                for (int kx = 0; kx < K; kx++) {
                    int img_idx = (oy + ky) * IMG_W + (ox + kx);
                    int krn_idx = ky * K + kx;
                    acc += img[img_idx] * krn[krn_idx];
                }
            }

            out_sw[oy * OUT_W + ox] = acc;
        }
    }
}

// -----------------------------------------------------------------------------
// Hardware convolution through DIR accelerator
// -----------------------------------------------------------------------------

#define IN_BASE  0
#define CO_BASE  256
#define OUT_BASE 512

static void conv_hw(void) {
    for (int i = 0; i < IMG_W * IMG_H; i++) {
        SCRATCH(IN_BASE + i) = (uint32_t)(int32_t)img[i];
    }

    for (int i = 0; i < K * K; i++) {
        SCRATCH(CO_BASE + i) = (uint32_t)(int32_t)krn[i];
    }

    ACC_INBASE  = IN_BASE;
    ACC_OUTBASE = OUT_BASE;
    ACC_CONFIG  = ((uint32_t)IMG_H << 16) | (uint32_t)IMG_W;
    ACC_KCONFIG = ((uint32_t)CO_BASE << 16) | (0u << 8) | (uint32_t)K;
    ACC_CONTROL = ACC_START;

    while (!(ACC_STATUS & ACC_DONE)) { }
}

static int32_t calc_one(int oy, int ox) {
    int32_t acc = 0;

    for (int ky = 0; ky < K; ky++) {
        for (int kx = 0; kx < K; kx++) {
            int img_idx = (oy + ky) * IMG_W + (ox + kx);
            int krn_idx = ky * K + kx;
            acc += img[img_idx] * krn[krn_idx];
        }
    }

    return acc;
}

// -----------------------------------------------------------------------------
// Main benchmark
// -----------------------------------------------------------------------------

int main(void) {
    make_input();

    uint32_t t0 = rdcycle();
    conv_sw();
    uint32_t sw_cycles = rdcycle() - t0;

    t0 = rdcycle();
    conv_hw();
    uint32_t hw_cycles = rdcycle() - t0;

    int mismatch = 0;

    for (int i = 0; i < OUT_W * OUT_H; i++) {
        if ((uint32_t)out_sw[i] != SCRATCH(OUT_BASE + i)) {
            mismatch = 1;
            break;
        }
    }

    MB_SW_CYCLES = sw_cycles;
    MB_HW_CYCLES = hw_cycles;
    MB_MATCH     = mismatch ? 0u : 1u;

    int mid  = (OUT_H / 2) * OUT_W + (OUT_W / 2);
    int last = OUT_W * OUT_H - 1;

    uint32_t speed_x10 = hw_cycles ? (sw_cycles * 10u) / hw_cycles : 0u;

    uputs("\r\n");
    uputs("============================================================\r\n");
    uputs(" Solvyr-3 benchmark\r\n");
    uputs(" Software RV32I vs DIR Accelerator\r\n");
    uputs("============================================================\r\n");

    uputs("\r\n[Task]\r\n");
    uputs("  Valid 2D convolution\r\n");
    uputs("  Formula : out[y][x] = sum(input * kernel)\r\n");

    uputs("\r\n[Problem size]\r\n");
    uputs("  Input   : ");
    uputu(IMG_W);
    uputc('x');
    uputu(IMG_H);
    uputs("\r\n");

    uputs("  Kernel  : ");
    uputu(K);
    uputc('x');
    uputu(K);
    uputs("\r\n");

    uputs("  Output  : ");
    uputu(OUT_W);
    uputc('x');
    uputu(OUT_H);
    uputs("\r\n");

    uputs("  MACs    : ");
    uputu((uint32_t)(OUT_W * OUT_H * K * K));
    uputs("\r\n");

    uputs("\r\n[Performance]\r\n");
    put_cycles_time("  SW ", sw_cycles);
    put_cycles_time("  ACC", hw_cycles);

    uputs("  Speedup : ");
    uputu(speed_x10);
    uputs("/10 = ");
    uputu(speed_x10 / 10u);
    uputc('.');
    uputu(speed_x10 % 10u);
    uputs("x\r\n");

    uputs("\r\n[Answer samples]\r\n");
    put_sample("  out[0][0]", out_sw[0],    (int32_t)SCRATCH(OUT_BASE + 0));
    put_sample("  out[mid] ", out_sw[mid],  (int32_t)SCRATCH(OUT_BASE + mid));
    put_sample("  out[last]", out_sw[last], (int32_t)SCRATCH(OUT_BASE + last));

    uputs("\r\n[Manual check]\r\n");
    uputs("  out[0][0] by formula = ");
    uputi(calc_one(0, 0));
    uputs("\r\n");

    uputs("\r\n[Result]\r\n");
    uputs(mismatch ? "  MISMATCH\r\n" : "  MATCH\r\n");

    uputs("============================================================\r\n");

    for (;;) {
        GPIO_LED = hw_cycles;
    }

    return 0;
}