// ============================================================================
// solvyr3.h  -  Bare-metal register map for the Solvyr-3 SoC
//
// Memory-mapped peripheral bases and register offsets, plus small inline access
// helpers and machine-CSR macros. Matches rtl/solvyr3_defs.vh and the system
// memory map. Include from demo.c / startup-adjacent C code.
// ============================================================================
#ifndef SOLVYR3_H
#define SOLVYR3_H
#include <stdint.h>

#define REG32(addr) (*(volatile uint32_t *)(addr))

// ---- Peripheral bases ------------------------------------------------------
#define IMEM_BASE     0x00000000u
#define DMEM_BASE     0x00001000u
#define GPIO_BASE     0x00002000u
#define TIMER_BASE    0x00003000u
#define UART_BASE     0x00004000u
#define ACC_BASE      0x00005000u
#define SCRATCH_BASE  0x00006000u

// ---- GPIO ------------------------------------------------------------------
#define GPIO_LED      REG32(GPIO_BASE + 0x00)
#define GPIO_SW       REG32(GPIO_BASE + 0x04)
#define GPIO_BTN      REG32(GPIO_BASE + 0x08)

// ---- Timer -----------------------------------------------------------------
#define TMR_MTIME     REG32(TIMER_BASE + 0x00)
#define TMR_MTIMECMP  REG32(TIMER_BASE + 0x04)
#define TMR_CTRL      REG32(TIMER_BASE + 0x08)   // [0]EN [1]IE [2]ARLD
#define TMR_STATUS    REG32(TIMER_BASE + 0x0C)   // [0]MATCH (W1C)
#define TMR_EN        0x1u
#define TMR_IE        0x2u
#define TMR_ARLD      0x4u

// ---- UART ------------------------------------------------------------------
// TX has a 1-deep holding register: poll TXRDY (holding slot free) before
// writing TXD. TXBUSY stays high from the write until the frame finishes, so a
// poll-before-write driver is race-free -- no per-character delay required.
#define UART_TXD      REG32(UART_BASE + 0x00)
#define UART_RXD      REG32(UART_BASE + 0x04)
#define UART_STATUS   REG32(UART_BASE + 0x08)    // [0]TXBUSY [1]TXRDY [2]RXVALID [3]OVR
#define UART_TXBUSY   0x1u                       // shifter active OR byte queued
#define UART_TXRDY    0x2u                       // holding register can accept a byte
#define UART_RXVALID  0x4u

// ---- DIR accelerator -------------------------------------------------------
#define ACC_CONTROL   REG32(ACC_BASE + 0x00)     // [0]START [1]IRQEN [2]SIGNED
#define ACC_STATUS    REG32(ACC_BASE + 0x04)     // [0]BUSY [1]DONE [2]ERROR
#define ACC_INBASE    REG32(ACC_BASE + 0x08)
#define ACC_OUTBASE   REG32(ACC_BASE + 0x0C)
#define ACC_CONFIG    REG32(ACC_BASE + 0x10)     // [15:0]w [31:16]h
#define ACC_KCONFIG   REG32(ACC_BASE + 0x14)     // [3:0]K [11:8]shift [27:16]coeff_base
#define ACC_RESULT    REG32(ACC_BASE + 0x18)
#define ACC_INT_ACK   REG32(ACC_BASE + 0x1C)
#define ACC_START     0x1u
#define ACC_IRQEN     0x2u
#define ACC_BUSY      0x1u
#define ACC_DONE      0x2u
#define ACC_ERR       0x4u
#define SCRATCH(i)    REG32(SCRATCH_BASE + ((i) << 2))   // word i

// ---- Machine CSRs ----------------------------------------------------------
#define read_csr(reg) ({ uint32_t __v; \
    __asm__ volatile ("csrr %0, " #reg : "=r"(__v)); __v; })
#define write_csr(reg, val) \
    __asm__ volatile ("csrw " #reg ", %0" :: "r"(val))
#define set_csr(reg, bits) \
    __asm__ volatile ("csrs " #reg ", %0" :: "r"(bits))
#define clear_csr(reg, bits) \
    __asm__ volatile ("csrc " #reg ", %0" :: "r"(bits))

#define MSTATUS_MIE   0x00000008u
#define MIE_MTIE      0x00000080u   // machine timer interrupt enable
#define MIE_MEIE      0x00000800u   // machine external (DIR accel) enable

#endif // SOLVYR3_H
