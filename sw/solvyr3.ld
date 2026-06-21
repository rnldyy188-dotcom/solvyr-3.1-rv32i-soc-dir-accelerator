/* ===========================================================================
 * solvyr3.ld  -  Linker script for Solvyr-3 bare-metal programs
 *
 * Harvard split that matches the SoC memory map:
 *   IMEM  0x0000_0000 (4 KB)  : .text + .rodata    (also data-readable via the
 *                               dual-port instruction BRAM at 0x0)
 *   DMEM  0x0000_1000 (4 KB)  : .bss + stack       (read/write data region)
 *
 * The demo has no non-zero initialized writable globals, so there is no .data
 * load/copy step; startup.s clears .bss. The stack grows down from the top of
 * the data BRAM. Reset entry (_start) sits at address 0x0.
 * =========================================================================== */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
    IMEM (rx)  : ORIGIN = 0x00000000, LENGTH = 4K
    DMEM (rw)  : ORIGIN = 0x00001000, LENGTH = 4K
}

SECTIONS {
    .text : {
        KEEP(*(.text.init))      /* _start must be first (reset vector 0x0) */
        *(.text .text.*)
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
        . = ALIGN(4);
    } > IMEM

    /* No writable initialized data is used; keep .data adjacent for safety. */
    .data : {
        . = ALIGN(4);
        *(.data .data.*)
        *(.sdata .sdata.*)
        . = ALIGN(4);
    } > DMEM

    .bss (NOLOAD) : {
        . = ALIGN(4);
        __bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > DMEM

    /* global pointer near the start of small-data; stack at the top of DMEM */
    __global_pointer$ = ORIGIN(DMEM) + 0x800;
    __stack_top       = ORIGIN(DMEM) + LENGTH(DMEM);

    /DISCARD/ : { *(.comment) *(.eh_frame) *(.riscv.attributes) }
}
