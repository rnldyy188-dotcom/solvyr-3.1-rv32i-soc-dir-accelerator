#!/usr/bin/env python3
# ============================================================================
# gen_bench.py  -  Generate + verify the toolchain-free benchmark image
#
# Produces bench/bench.hex: a hand-written RV32I program that computes the same
# K x K windowed MAC (dot product) two ways and time-stamps each with rdcycle:
#   (1) in SOFTWARE on the base RV32I core   -- the "normal processor" baseline
#       (RV32I has no hardware multiplier, so it calls a shift-add routine)
#   (2) on the DIR ACCELERATOR (one 7x7 convolution window = a 49-tap MAC)
#   and stores both results + cycle counts to Data BRAM for tb_bench.v to print.
#
# This program is verified end-to-end here with the ISA reference simulator plus
# an accelerator MMIO model (correctness only; real cycle counts come from the
# RTL run). The C version in bench/bench.c runs a full 2D-conv workload.
# ============================================================================
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rv32i import build, write_hex, CPU, conv2d, sx

# K=7 window  -> 49-tap MAC. Input ramp i, kernel ramp i  -> sum(i*i), i=0..48.
BENCH = """
    # ---- init scratchpad: img[i]=i (words 0..48), kern[i]=i (words 64..112) ----
    lui   s2, 0x6              # s2 = scratchpad base 0x6000
    addi  t2, x0, 0           # i = 0
    addi  t6, x0, 49          # N = 49
init:
    slli  t3, t2, 2
    add   t4, s2, t3          # &img[i]
    sw    t2, 0(t4)           # img[i]  = i
    addi  t5, t4, 256         # &kern[i] = &img[i] + 64 words
    sw    t2, 0(t5)           # kern[i] = i
    addi  t2, t2, 1
    bne   t2, t6, init

    # ---- (1) software dot product (shift-add multiply) ----
    csrr  s0, cycle           # start cycle
    addi  s3, x0, 0           # acc = 0
    addi  t2, x0, 0           # i = 0
swloop:
    slli  t3, t2, 2
    add   t4, s2, t3
    lw    a0, 0(t4)           # img[i]
    addi  t5, t4, 256
    lw    a1, 0(t5)           # kern[i]
    call  mul                 # a0 = img[i] * kern[i]
    add   s3, s3, a0          # acc += product
    addi  t2, t2, 1
    bne   t2, t6, swloop
    csrr  s1, cycle           # end cycle
    sub   s4, s1, s0          # sw_cycles
    lui   s5, 0x1             # Data BRAM base 0x1000
    sw    s3, 0(s5)           # [0x1000] sw_result
    sw    s4, 4(s5)           # [0x1004] sw_cycles

    # ---- (2) DIR accelerator: one 7x7 window ----
    csrr  s0, cycle
    lui   s6, 0x5             # accel base 0x5000
    sw    x0, 8(s6)           # INPUT_BASE  = 0
    addi  t0, x0, 128
    sw    t0, 12(s6)          # OUTPUT_BASE = 128
    addi  t1, x0, 7
    slli  t0, t1, 16
    or    t0, t0, t1          # 0x00070007
    sw    t0, 16(s6)          # CONFIG: w=7, h=7
    addi  t1, x0, 64
    slli  t0, t1, 16
    addi  t2, x0, 7
    or    t0, t0, t2          # 0x00400007
    sw    t0, 20(s6)          # KCONFIG: coeff_base=64, shift=0, K=7
    addi  t0, x0, 1
    sw    t0, 0(s6)           # CONTROL = START
accwait:
    lw    t0, 4(s6)           # STATUS
    andi  t0, t0, 2           # DONE bit
    beq   t0, x0, accwait
    addi  t0, x0, 512
    add   t1, s2, t0
    lw    s7, 0(t1)           # hw_result (scratch[128])
    csrr  s1, cycle
    sub   s8, s1, s0          # hw_cycles
    sw    s7, 8(s5)           # [0x1008] hw_result
    sw    s8, 12(s5)          # [0x100C] hw_cycles

    # ---- correctness flag ----
    addi  s9, x0, 0
    bne   s3, s7, nomatch
    addi  s9, x0, 1
nomatch:
    sw    s9, 16(s5)          # [0x1010] match (1 = sw == hw)
halt:
    beq   x0, x0, halt

# ---- shift-add unsigned multiply: a0 = a0 * a1 (clobbers t0,t1) ----
mul:
    addi  t0, x0, 0
mulL:
    beq   a1, x0, mulD
    andi  t1, a1, 1
    beq   t1, x0, mulS
    add   t0, t0, a0
mulS:
    slli  a0, a0, 1
    srli  a1, a1, 1
    beq   x0, x0, mulL
mulD:
    addi  a0, t0, 0
    ret
"""

class AccelMMIO:
    """Minimal model of dir_accel for the ISA simulator (registers @0x5000)."""
    def __init__(self, cpu): self.cpu=cpu; self.regs={}; self.done=0
    def handles(self, a): return 0x5000 <= a < 0x5100
    def load(self, a, n):
        off=a-0x5000
        if off==0x04: return self.done << 1          # STATUS.DONE
        return self.regs.get(off, 0)
    def store(self, a, n, val):
        off=a-0x5000; self.regs[off]=val
        if off==0x00 and (val & 1): self._run()
    def _run(self):
        SB=0x6000
        rd=lambda w: int.from_bytes(self.cpu.mem[SB+w*4:SB+w*4+4],'little')
        wr=lambda w,v: self.cpu.mem.__setitem__(slice(SB+w*4,SB+w*4+4),(v&0xFFFFFFFF).to_bytes(4,'little'))
        ib=self.regs.get(0x08,0); ob=self.regs.get(0x0C,0)
        cfg=self.regs.get(0x10,0); W=cfg&0xFFFF; H=(cfg>>16)&0xFFFF
        kc=self.regs.get(0x14,0); K=kc&0xF; sh=(kc>>8)&0xF; co=(kc>>16)&0xFFF
        OW,OH=W-K+1,H-K+1; last=0
        for oy in range(OH):
            for ox in range(OW):
                acc=0
                for ky in range(K):
                    for kx in range(K):
                        acc+=sx(rd(ib+(oy+ky)*W+(ox+kx)),16)*sx(rd(co+ky*K+kx),16)
                v=(acc>>sh)&0xFFFFFFFF; wr(ob+oy*OW+ox,v); last=v
        self.regs[0x18]=last; self.done=1

if __name__=='__main__':
    here=os.path.dirname(os.path.abspath(__file__))
    bench=os.path.normpath(os.path.join(here,'..','bench'))
    words,labels=build('bench', BENCH)
    write_hex(os.path.join(bench,'bench.hex'), words)

    # verify correctness end-to-end (sw path + accelerator model)
    cpu=CPU(words, memwords=8192); cpu.mmio=AccelMMIO(cpu); cpu.run(max_steps=200000)
    sw_res=cpu.ld(0x1000,4,False); hw_res=cpu.ld(0x1008,4,False); match=cpu.ld(0x1010,4,False)
    img=list(range(49)); kern=list(range(49))
    golden=conv2d(img,7,7,kern,7,0)[0]
    print("== BENCH (49-tap MAC) ==  (%d words) -> bench/bench.hex"%len(words))
    print("  golden sum(i*i,0..48) = %d"%golden)
    print("  sw_result=%d  hw_result=%d  match=%d"%(sw_res,hw_res,match))
    assert sw_res==golden and hw_res==golden and match==1, "BENCH VERIFY FAILED"
    print("  OK  (cycle counts are produced by the RTL run in tb_bench.v)")
