// ============================================================================
// demo.c  -  Solvyr-3 bare-metal demo
//
// Exercises the whole SoC: prints a banner over UART, runs a 2D convolution on
// the DIR accelerator and prints the result, enables a periodic timer interrupt
// that animates the LEDs, and echoes the slide switches. Build with the riscv32
// toolchain (see Makefile); startup.s sets up the stack and trap vector.
// ============================================================================
#include "solvyr3.h"

// ---- UART helpers ----------------------------------------------------------
static void uart_putc(char c) {
    while (UART_STATUS & UART_TXBUSY) { }
    UART_TXD = (uint8_t)c;
}
static void uart_puts(const char *s) { while (*s) uart_putc(*s++); }
static void uart_puthex(uint32_t v) {
    uart_puts("0x");
    for (int i = 28; i >= 0; i -= 4)
        uart_putc("0123456789ABCDEF"[(v >> i) & 0xF]);
}
static void uart_putdec(int32_t v) {
    char buf[12]; int n = 0;
    if (v < 0) { uart_putc('-'); v = -v; }
    do { buf[n++] = '0' + (v % 10); v /= 10; } while (v);
    while (n) uart_putc(buf[--n]);
}

// ---- DIR accelerator : run one valid 2D convolution ------------------------
// Loads a WxH input tile and a KxK kernel into the scratchpad, kicks the
// accelerator, waits for DONE (polling), and leaves the output tile in the
// scratchpad at out_base. Returns ACC_RESULT (the last output sample).
static uint32_t accel_conv(const int16_t *img, int W, int H,
                           const int16_t *kern, int K, int shift) {
    const uint32_t in_base = 0, co_base = 256, out_base = 512;
    for (int i = 0; i < W * H; i++)  SCRATCH(in_base + i) = (uint32_t)(int32_t)img[i];
    for (int i = 0; i < K * K; i++)  SCRATCH(co_base + i) = (uint32_t)(int32_t)kern[i];

    ACC_INBASE  = in_base;
    ACC_OUTBASE = out_base;
    ACC_CONFIG  = ((uint32_t)H << 16) | (uint32_t)W;
    ACC_KCONFIG = ((uint32_t)co_base << 16) | ((uint32_t)shift << 8) | (uint32_t)K;
    ACC_CONTROL = ACC_START;

    while (!(ACC_STATUS & ACC_DONE)) { }      // poll for completion
    return ACC_RESULT;
}

// ---- Timer interrupt : animate LEDs ----------------------------------------
volatile uint32_t g_ticks = 0;

void on_timer_irq(void) {
    g_ticks++;
    GPIO_LED = g_ticks;                       // walking LED counter
    TMR_STATUS = 0x1;                         // W1C: clear match -> deassert irq
}

// C-level trap dispatch, called from startup.s trap_entry.
void trap_handler(uint32_t mcause, uint32_t mepc) {
    (void)mepc;
    if (mcause & 0x80000000u) {               // interrupt
        uint32_t code = mcause & 0xFu;
        if (code == 7) on_timer_irq();        // machine timer
    }
    // synchronous exceptions fall through (handled minimally for the demo)
}

int main(void) {
    uart_puts("\r\n=== Solvyr-3 RV32I Mini-SoC + DIR Accelerator ===\r\n");

    // ---- DIR accelerator demo: 5x5 ramp convolved with an 'X' kernel -------
    static const int16_t img[25] = {
        0,1,2,3,4, 5,6,7,8,9, 10,11,12,13,14,
        15,16,17,18,19, 20,21,22,23,24 };
    static const int16_t xk[9] = { 1,0,1, 0,1,0, 1,0,1 };
    uart_puts("DIR accel 5x5 (X) 3x3 -> output tile:\r\n");
    accel_conv(img, 5, 5, xk, 3, 0);
    for (int oy = 0; oy < 3; oy++) {
        for (int ox = 0; ox < 3; ox++) { uart_putdec((int32_t)SCRATCH(512 + oy*3 + ox)); uart_putc(' '); }
        uart_puts("\r\n");
    }
    uart_puts("ACC_RESULT = "); uart_puthex(ACC_RESULT); uart_puts("\r\n");

    // ---- Periodic timer interrupt to animate the LEDs ----------------------
    TMR_MTIMECMP = 5000000;                   // ~50 ms at 100 MHz
    TMR_CTRL     = TMR_EN | TMR_IE | TMR_ARLD;
    set_csr(mie, MIE_MTIE);
    set_csr(mstatus, MSTATUS_MIE);            // global interrupt enable

    uart_puts("Running. Switches mirror to upper LEDs; timer animates lower.\r\n");
    for (;;) {
        // Mirror switches onto the high LED bits; timer IRQ drives the low bits.
        uint32_t sw = GPIO_SW & 0xFFFF;
        GPIO_LED = (GPIO_LED & 0x0FFF) | ((sw & 0xF) << 12);
    }
    return 0;
}
