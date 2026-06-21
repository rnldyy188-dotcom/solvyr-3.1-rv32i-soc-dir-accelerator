# ============================================================================
# startup.s  -  Reset + trap entry for Solvyr-3 bare-metal programs
#
# On reset (PC = 0x0) this sets up the stack, clears .bss, installs the trap
# vector, and calls main(). The trap entry saves the caller-saved registers,
# calls the C trap_handler(mcause, mepc), restores, and returns with MRET.
# RV32I, machine mode only.
# ============================================================================
    .section .text.init
    .globl _start
_start:
    # ---- global pointer / stack pointer ----
    la   gp, __global_pointer$
    la   sp, __stack_top

    # ---- clear .bss ----
    la   t0, __bss_start
    la   t1, __bss_end
1:  bge  t0, t1, 2f
    sw   zero, 0(t0)
    addi t0, t0, 4
    j    1b
2:
    # ---- install trap vector (direct mode) ----
    la   t0, trap_entry
    csrw mtvec, t0

    # ---- run main ----
    call main

    # ---- main returned: spin ----
hang:
    j    hang

# ----------------------------------------------------------------------------
# Trap entry. Saves caller-saved GPRs, dispatches to C, restores, MRET.
# (mepc is left untouched here: synchronous handlers that need to skip the
#  faulting instruction should adjust mepc themselves; the demo only uses
#  interrupts, which resume the interrupted instruction.)
# ----------------------------------------------------------------------------
    .align 4
    .globl trap_entry
trap_entry:
    addi sp, sp, -64
    sw   ra,  0(sp)
    sw   t0,  4(sp)
    sw   t1,  8(sp)
    sw   t2, 12(sp)
    sw   a0, 16(sp)
    sw   a1, 20(sp)
    sw   a2, 24(sp)
    sw   a3, 28(sp)
    sw   a4, 32(sp)
    sw   a5, 36(sp)
    sw   a6, 40(sp)
    sw   a7, 44(sp)
    sw   t3, 48(sp)
    sw   t4, 52(sp)
    sw   t5, 56(sp)
    sw   t6, 60(sp)

    csrr a0, mcause
    csrr a1, mepc
    call trap_handler

    lw   ra,  0(sp)
    lw   t0,  4(sp)
    lw   t1,  8(sp)
    lw   t2, 12(sp)
    lw   a0, 16(sp)
    lw   a1, 20(sp)
    lw   a2, 24(sp)
    lw   a3, 28(sp)
    lw   a4, 32(sp)
    lw   a5, 36(sp)
    lw   a6, 40(sp)
    lw   a7, 44(sp)
    lw   t3, 48(sp)
    lw   t4, 52(sp)
    lw   t5, 56(sp)
    lw   t6, 60(sp)
    addi sp, sp, 64
    mret
