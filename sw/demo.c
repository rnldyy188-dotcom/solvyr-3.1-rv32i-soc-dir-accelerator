#include "solvyr3.h"

static void uart_putc(char c) {
    while (UART_STATUS & UART_TXBUSY) {}
    UART_TXD = (uint8_t)c;
}

static void uart_puts(const char *s) {
    while (*s) uart_putc(*s++);
}

void trap_handler(uint32_t mcause, uint32_t mepc) {
    (void)mcause;
    (void)mepc;

    while (1) {
        GPIO_LED = 0xBAD;
    }
}

int main(void) {
    uint32_t n = 0;

    while (1) {
        uart_puts("UART TEST Solvyr-3\r\n");
        GPIO_LED = n++;

        for (volatile uint32_t i = 0; i < 5000000; i++);
    }

    return 0;
}
