#!/usr/bin/env python3
# ============================================================================
# rv32i.py  -  Tiny RV32I assembler + reference ISA simulator for Solvyr-3
#
# Purpose: generate the hand-written test programs (correct-by-construction
# machine code) AND compute golden expected values for the Verilog testbenches.
# This is the verification substitute used when a Verilog simulator is not
# available in the build environment; run the actual RTL testbenches with
# Icarus Verilog (./run_sim.sh) to confirm cycle-level behaviour.
#
# Supports the RV32I base ISA plus the machine CSR ops, ECALL/EBREAK/MRET, and
# a handful of assembler pseudo-instructions (li, mv, j, nop, ret, beqz, ...).
# The simulator models a flat byte-addressable memory and machine-mode trap
# behaviour (mtvec/mepc/mcause + MRET); it does not model the pipeline timing,
# peripherals, or interrupts (those are covered by dedicated RTL testbenches).
# ============================================================================
import sys, struct

# ---- register name table ---------------------------------------------------
ABI = {
    'zero':0,'ra':1,'sp':2,'gp':3,'tp':4,'t0':5,'t1':6,'t2':7,
    's0':8,'fp':8,'s1':9,'a0':10,'a1':11,'a2':12,'a3':13,'a4':14,'a5':15,
    'a6':16,'a7':17,'s2':18,'s3':19,'s4':20,'s5':21,'s6':22,'s7':23,
    's8':24,'s9':25,'s10':26,'s11':27,'t3':28,'t4':29,'t5':30,'t6':31,
}
for i in range(32): ABI['x%d'%i] = i

CSRS = {'mstatus':0x300,'misa':0x301,'mie':0x304,'mtvec':0x305,
        'mscratch':0x340,'mepc':0x341,'mcause':0x342,'mtval':0x343,
        'mip':0x344,'cycle':0xC00,'instret':0xC02}

def reg(r):
    r = r.strip().lower()
    if r in ABI: return ABI[r]
    raise ValueError("bad register %r" % r)

def u32(x): return x & 0xFFFFFFFF
def sx(x, bits):
    m = 1 << (bits-1)
    return (x & (m-1)) - (x & m)

# ---- instruction encoders --------------------------------------------------
def R(f7,rs2,rs1,f3,rd,op): return u32((f7<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|(rd<<7)|op)
def I(imm,rs1,f3,rd,op):    return u32(((imm&0xFFF)<<20)|(rs1<<15)|(f3<<12)|(rd<<7)|op)
def S(imm,rs2,rs1,f3,op):
    imm&=0xFFF
    return u32((((imm>>5)&0x7F)<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|((imm&0x1F)<<7)|op)
def B(imm,rs2,rs1,f3,op):
    imm&=0x1FFF
    b12=(imm>>12)&1; b11=(imm>>11)&1; b10_5=(imm>>5)&0x3F; b4_1=(imm>>1)&0xF
    return u32((b12<<31)|(b10_5<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|(b4_1<<8)|(b11<<7)|op)
def U(imm,rd,op):  return u32((u32(imm)&0xFFFFF000)|(rd<<7)|op)
def J(imm,rd,op):
    imm&=0x1FFFFF
    b20=(imm>>20)&1; b10_1=(imm>>1)&0x3FF; b11=(imm>>11)&1; b19_12=(imm>>12)&0xFF
    return u32((b20<<31)|(b10_1<<21)|(b11<<20)|(b19_12<<12)|(rd<<7)|op)

OPI=0x13; OP=0x33; LD=0x03; ST=0x23; BR=0x63; SYS=0x73
def alu_imm(f3,rd,rs1,imm,f7=0):  # for slli/srli/srai f7 in imm top
    return I(imm,rs1,f3,rd,OPI)

# ---- assembler -------------------------------------------------------------
def assemble(lines, base=0):
    """lines: list of strings. Two-pass: resolve labels, then encode."""
    # pass 1: collect labels and a normalized instruction list
    insns=[]; labels={}; pc=base
    for raw in lines:
        line=raw.split('#')[0].strip()
        if not line: continue
        # labels (possibly multiple "lbl:" prefixes)
        while ':' in line.split()[0]:
            lbl,_,rest=line.partition(':')
            labels[lbl.strip()]=pc
            line=rest.strip()
            if not line: break
        if not line: continue
        insns.append((pc,line)); pc+=4
    words=[]
    for pc,line in insns:
        toks=line.replace(',',' ').split()
        op=toks[0].lower(); a=toks[1:]
        def L(name):
            if name in labels: return labels[name]-pc
            return imm(name)
        def imm(v):
            v=v.strip()
            if v in labels: return labels[v]
            return int(v,0)
        words.append(encode(op,a,L,imm,labels,pc))
    return words, labels

def encode(op,a,L,imm,labels,pc):
    r=reg
    # pseudo-instructions
    if op=='nop':   return alu_imm(0,0,0,0)
    if op=='li':
        rd=r(a[0]); v=u32(imm(a[1]))
        lo=v&0xFFF; hi=v>>12
        if lo & 0x800: hi=(hi+1)&0xFFFFF   # account for sign-extension of addi
        if hi==0: return I(v,0,0,rd,OPI)           # addi rd,x0,v  (small)
        # NOTE: assembler emits a single instr only when it fits; otherwise
        # callers should split lui+addi explicitly. Keep simple: require fit.
        raise ValueError("li needs lui+addi; use explicit for 0x%X"%v)
    if op=='mv':    return I(0,r(a[1]),0,r(a[0]),OPI)            # addi rd,rs,0
    if op=='j':     return J(L(a[0]),0,0x6F)                     # jal x0,off
    if op=='jr':    return I(0,r(a[0]),0,0,0x67)                 # jalr x0,0(rs)
    if op=='ret':   return I(0,1,0,0,0x67)                       # jalr x0,0(ra)
    if op=='beqz':  return B(L(a[1]),0,r(a[0]),0,BR)
    if op=='bnez':  return B(L(a[1]),0,r(a[0]),1,BR)
    if op=='call':  return J(L(a[0]),1,0x6F)                     # jal ra,off
    # U-type
    if op=='lui':   return U(imm(a[1])<<12 if imm(a[1])<0x1000 else imm(a[1]),r(a[0]),0x37)
    if op=='auipc': return U(imm(a[1])<<12 if imm(a[1])<0x1000 else imm(a[1]),r(a[0]),0x17)
    # jumps
    if op=='jal':
        if len(a)==1: return J(L(a[0]),1,0x6F)
        return J(L(a[1]),r(a[0]),0x6F)
    if op=='jalr':
        # jalr rd, rs1, imm  OR  jalr rd, imm(rs1)
        if '(' in a[1]:
            off,rs1=parse_mem(a[1]); return I(off,rs1,0,r(a[0]),0x67)
        return I(imm(a[2]) if len(a)>2 else 0,r(a[1]),0,r(a[0]),0x67)
    # branches: b** rs1,rs2,label
    BF={'beq':0,'bne':1,'blt':4,'bge':5,'bltu':6,'bgeu':7}
    if op in BF: return B(L(a[2]),r(a[1]),r(a[0]),BF[op],BR)
    # loads: l* rd, off(rs1)
    LF={'lb':0,'lh':1,'lw':2,'lbu':4,'lhu':5}
    if op in LF:
        off,rs1=parse_mem(a[1]); return I(off,rs1,LF[op],r(a[0]),LD)
    # stores: s* rs2, off(rs1)
    SF={'sb':0,'sh':1,'sw':2}
    if op in SF:
        off,rs1=parse_mem(a[1]); return S(off,r(a[0]),rs1,SF[op],ST)
    # imm ALU
    IF={'addi':0,'slti':2,'sltiu':3,'xori':4,'ori':6,'andi':7}
    if op in IF: return I(imm(a[2]),r(a[1]),IF[op],r(a[0]),OPI)
    if op=='slli': return I(imm(a[2])&0x1F,r(a[1]),1,r(a[0]),OPI)
    if op=='srli': return I(imm(a[2])&0x1F,r(a[1]),5,r(a[0]),OPI)
    if op=='srai': return I(0x400|(imm(a[2])&0x1F),r(a[1]),5,r(a[0]),OPI)
    # reg ALU
    RF={'add':(0,0),'sub':(0x20,0),'sll':(0,1),'slt':(0,2),'sltu':(0,3),
        'xor':(0,4),'srl':(0,5),'sra':(0x20,5),'or':(0,6),'and':(0,7)}
    if op in RF:
        f7,f3=RF[op]; return R(f7,r(a[2]),r(a[1]),f3,r(a[0]),OP)
    # CSR
    CF={'csrrw':1,'csrrs':2,'csrrc':3,'csrrwi':5,'csrrsi':6,'csrrci':7}
    if op in CF:
        csr=CSRS.get(a[1].lower(), None)
        csr=csr if csr is not None else int(a[1],0)
        if op.endswith('i'):
            return I(csr,imm(a[2])&0x1F,CF[op],r(a[0]),SYS)
        return I(csr,r(a[2]),CF[op],r(a[0]),SYS)
    if op=='ecall':  return I(0x000,0,0,0,SYS)
    if op=='ebreak': return I(0x001,0,0,0,SYS)
    if op=='mret':   return I(0x302,0,0,0,SYS)
    if op=='fence':  return u32(0x0FF0000F)
    raise ValueError("unknown op %r" % op)

def parse_mem(tok):
    # "off(rs1)"
    off,_,rest=tok.partition('(')
    rs1=rest.replace(')','').strip()
    return (int(off,0) if off.strip() else 0), reg(rs1)

# ---- simulator -------------------------------------------------------------
class CPU:
    def __init__(self, words, base=0, memwords=4096):
        self.x=[0]*32
        self.pc=base
        self.imem={base+4*i: w for i,w in enumerate(words)}
        self.mem=bytearray(memwords*4)
        self.csr={k:0 for k in ['mstatus','mtvec','mepc','mcause','mtval','mie','mip','mscratch']}
        self.halted=False
        self.retired=0
        self.mmio=None    # optional peripheral model: .handles(a)/.load(a,n)/.store(a,n,v)
    def ld(self,a,n,signed):
        if self.mmio and self.mmio.handles(a):
            v=self.mmio.load(a,n)
        else:
            v=int.from_bytes(self.mem[a:a+n],'little')
        return sx(v,n*8) if signed else v
    def st(self,a,n,val):
        if self.mmio and self.mmio.handles(a):
            self.mmio.store(a,n,u32(val)); return
        self.mem[a:a+n]=(u32(val)&((1<<(n*8))-1)).to_bytes(n,'little')
    def step(self):
        w=self.imem.get(self.pc,0x13)  # NOP if out of range
        op=w&0x7F; rd=(w>>7)&0x1F; f3=(w>>12)&7; rs1=(w>>15)&0x1F
        rs2=(w>>20)&0x1F; f7=(w>>25)&0x7F
        x=self.x; npc=u32(self.pc+4)
        def wr(d,v):
            if d!=0: x[d]=u32(v)
        immI=sx(w>>20,12)
        immS=sx(((w>>25)<<5)|((w>>7)&0x1F),12)
        immB=sx(((w>>31)<<12)|(((w>>7)&1)<<11)|(((w>>25)&0x3F)<<5)|(((w>>8)&0xF)<<1),13)
        immU=w&0xFFFFF000
        immJ=sx(((w>>31)<<20)|(((w>>12)&0xFF)<<12)|(((w>>20)&1)<<11)|(((w>>21)&0x3FF)<<1),21)
        a=x[rs1]; b=x[rs2]; asx=sx(a,32); bsx=sx(b,32)
        if op==OP:
            r={ (0,0):a+b,(0x20,0):a-b,(0,1):a<<(b&31),(0,2):int(asx<bsx),
                (0,3):int(a<b),(0,4):a^b,(0,5):a>>(b&31),
                (0x20,5):u32(asx>>(b&31)),(0,6):a|b,(0,7):a&b }[(f7,f3)]
            wr(rd,r)
        elif op==OPI:
            if f3==1: wr(rd,a<<(immI&31))
            elif f3==5:
                wr(rd, u32(asx>>(immI&31)) if (f7&0x20) else a>>(immI&31))
            elif f3==0: wr(rd,a+immI)
            elif f3==2: wr(rd,int(asx<immI))
            elif f3==3: wr(rd,int(a<u32(immI)))
            elif f3==4: wr(rd,a^u32(immI))
            elif f3==6: wr(rd,a|u32(immI))
            elif f3==7: wr(rd,a&u32(immI))
        elif op==LD:
            addr=u32(a+immI)
            v={0:self.ld(addr,1,True),1:self.ld(addr,2,True),2:self.ld(addr,4,True),
               4:self.ld(addr,1,False),5:self.ld(addr,2,False)}[f3]
            wr(rd,v)
        elif op==ST:
            addr=u32(a+immS); n={0:1,1:2,2:4}[f3]; self.st(addr,n,b)
        elif op==BR:
            take={0:a==b,1:a!=b,4:asx<bsx,5:asx>=bsx,6:a<b,7:a>=b}[f3]
            if take: npc=u32(self.pc+immB)
        elif op==0x6F:  # jal
            wr(rd,self.pc+4); npc=u32(self.pc+immJ)
        elif op==0x67:  # jalr
            wr(rd,self.pc+4); npc=u32((a+immI)&~1)
        elif op==0x37:  wr(rd,immU)             # lui
        elif op==0x17:  wr(rd,u32(self.pc+immU))# auipc
        elif op==SYS:
            if f3==0:
                code=(w>>20)&0xFFF
                if code==0:   self.trap(11,0); return   # ecall
                elif code==1: self.trap(3,self.pc); return  # ebreak
                elif code==0x302:  # mret
                    self.pc=self.csr['mepc']; self.retired+=1; return
                else: self.trap(2,w); return
            else:
                name={v:k for k,v in CSRS.items()}.get((w>>20)&0xFFF)
                old=self.csr.get(name,0) if name in self.csr else 0
                src=x[rs1] if f3<4 else rs1
                if f3 in (1,5):   newv=src
                elif f3 in (2,6): newv=old|src
                else:             newv=old&~src
                wr(rd,old)
                if name in self.csr and not (f3 in (2,3,6,7) and (rs1==0)):
                    self.csr[name]=u32(newv)
        else:
            self.trap(2,w); return
        self.pc=npc; self.retired+=1
    def trap(self,cause,tval):
        self.csr['mepc']=self.pc; self.csr['mcause']=cause; self.csr['mtval']=tval
        self.pc=self.csr['mtvec']; self.retired+=1
    def run(self, max_steps=100000, stop_pc=None):
        for _ in range(max_steps):
            if stop_pc is not None and self.pc==stop_pc: break
            prev=self.pc; self.step()
            if self.pc==prev and self.imem.get(prev,0x13)&0x7F==BR:
                break   # self-branch = halt idiom
        return self

# ---- program library -------------------------------------------------------
SYSTEM_TEST = """
    addi x1, x0, 5          # x1 = 5
    addi x2, x0, 10         # x2 = 10
    add  x3, x1, x2         # x3 = 15   (forward x1,x2)
    sub  x4, x3, x1         # x4 = 10   (forward x3)
    lui  x5, 0x1            # x5 = 0x1000  (Data BRAM base)
    sw   x3, 4(x5)          # DBRAM[1] = 15
    lw   x6, 4(x5)          # x6 = 15
    add  x7, x6, x1         # x7 = 20   (load-use: 1-cycle stall)
    beq  x1, x1, skip       # taken branch -> flush the next instr
    addi x7, x0, 99         # (skipped)
skip:
    addi x8, x0, 42         # x8 = 42
done:
    beq  x0, x0, done       # halt (self-branch)
"""

# CSR / trap test: set mtvec, trigger ECALL, handler sets a marker, MRET back.
# (Program loads at base 0, so a label value is its absolute address and fits
#  in a 12-bit immediate for a small image.)
CSR_TEST = """
    addi  x6, x0, handler   # x6 = handler address
    csrrw x0, mtvec, x6     # mtvec = handler
    addi  x1, x0, 1         # x1 = 1 (pre-trap marker)
    ecall                   # -> trap to handler (mcause = 11)
    addi  x2, x0, 7         # x2 = 7 (runs after MRET returns here)
    beq   x0, x0, done
handler:
    csrr  x3, mcause        # x3 = mcause (expect 11)
    csrr  x4, mepc          # x4 = mepc (address of the ecall)
    addi  x7, x4, 4         # return to the instruction after ecall
    csrrw x0, mepc, x7      # mepc = ecall + 4
    addi  x8, x0, 42        # x8 = 42 (handler marker)
    mret                    # return
done:
    beq   x0, x0, done
"""

# Timer-interrupt test: enable mtvec/mie/mstatus, arm the timer, spin until the
# handler sets x2. (The Python ISA model has no timer/interrupts, so this is
# assembled only; the RTL testbench tb_irq.v checks the result.)
IRQ_TEST = """
    addi  x6, x0, handler
    csrrw x0, mtvec, x6        # mtvec = handler
    addi  x5, x0, 0x80
    csrrw x0, mie, x5          # mie.MTIE = 1 (timer)
    addi  x5, x0, 0x8
    csrrs x0, mstatus, x5      # mstatus.MIE = 1 (global)
    lui   x10, 0x3             # timer base 0x3000
    addi  x11, x0, 8
    sw    x11, 4(x10)          # MTIMECMP = 8
    addi  x11, x0, 3
    sw    x11, 8(x10)          # CTRL = EN | IE
spin:
    addi  x1, x1, 1            # count while waiting
    beq   x2, x0, spin         # loop until handler sets x2
    beq   x0, x0, done
handler:
    addi  x2, x0, 1            # mark interrupt taken
    addi  x12, x0, 1
    sw    x12, 0xC(x10)        # STATUS = clear match (W1C) -> deassert irq
    mret
done:
    beq   x0, x0, done
"""

# Stand-alone board demo (no toolchain needed): count on the LEDs with a delay.
DEMO_BLINK = """
    lui   x10, 0x2          # GPIO base 0x2000
    addi  x1, x0, 0         # LED counter
loop:
    sw    x1, 0(x10)        # LED_OUT = counter
    addi  x1, x1, 1
    lui   x2, 0x40          # delay ~ 0x40000 iterations
delay:
    addi  x2, x2, -1
    bne   x2, x0, delay
    beq   x0, x0, loop
"""

# GPIO integration test: write LED register, read it back, read switches.
GPIO_TEST = """
    lui   x10, 0x2            # GPIO base 0x2000
    addi  x11, x0, 0xAB
    sw    x11, 0(x10)         # LED_OUT = 0xAB
    lw    x12, 0(x10)         # x12 = LED_OUT readback (0xAB)
    lw    x13, 4(x10)         # x13 = switch inputs (driven by tb)
done:
    beq   x0, x0, done
"""

def csr_pseudo(line):
    # expand csrr rd, csr  -> csrrs rd, csr, x0
    t=line.split()
    if t and t[0]=='csrr':
        return "csrrs %s %s x0"%(t[1].rstrip(','),t[2])
    return line

def build(name, text, base=0):
    lines=[csr_pseudo(l) for l in text.strip('\n').split('\n')]
    words,labels=assemble(lines, base)
    return words,labels

def write_hex(path, words):
    with open(path,'w') as f:
        for w in words: f.write("%08x\n"%(w&0xFFFFFFFF))

# ---- 2D convolution reference (for the DIR accelerator testbench) ----------
def conv2d(img, W, H, kern, K, shift):
    """valid 2D convolution, signed; returns flat list of (W-K+1)*(H-K+1)."""
    OW=W-K+1; OH=H-K+1; out=[]
    for oy in range(OH):
        for ox in range(OW):
            acc=0
            for ky in range(K):
                for kx in range(K):
                    acc += sx(img[(oy+ky)*W+(ox+kx)],16) * sx(kern[ky*K+kx],16)
            out.append(u32(acc>>shift))
    return out

if __name__=='__main__':
    import os
    here=os.path.dirname(os.path.abspath(__file__))
    tb=os.path.normpath(os.path.join(here,'..','tb'))

    # ---- system test ----
    w,lab=build('system', SYSTEM_TEST)
    write_hex(os.path.join(tb,'test_prog.hex'), w)
    cpu=CPU(w).run()
    print("== SYSTEM_TEST ==  (%d words)"%len(w))
    for i in [1,2,3,4,5,6,7,8]:
        print("  x%-2d = %d (0x%08x)"%(i,sx(cpu.x[i],32),cpu.x[i]))
    print("  DBRAM word[1] (addr 0x1004) = %d"%cpu.ld(0x1004,4,True))
    assert cpu.x[1]==5 and cpu.x[3]==15 and cpu.x[4]==10
    assert cpu.x[6]==15 and cpu.x[7]==20 and cpu.x[8]==42
    assert cpu.x[5]==0x1000 and cpu.ld(0x1004,4,True)==15
    print("  OK")

    # ---- CSR / trap test ----
    w2,lab2=build('csr', CSR_TEST)
    write_hex(os.path.join(tb,'test_csr.hex'), w2)
    cpu2=CPU(w2).run()
    print("== CSR_TEST ==  (%d words)"%len(w2))
    for i in [1,2,3,4,8]:
        print("  x%-2d = %d (0x%08x)"%(i,sx(cpu2.x[i],32),cpu2.x[i]))
    print("  labels: handler=0x%x"%lab2['handler'])
    print("  mcause(x3)=%d (exp 11) ; mepc(x4)=0x%x ; x8(marker)=%d ; x2(after-mret)=%d"
          %(cpu2.x[3],cpu2.x[4],cpu2.x[8],cpu2.x[2]))
    assert cpu2.x[1]==1 and cpu2.x[3]==11 and cpu2.x[8]==42 and cpu2.x[2]==7
    print("  OK")

    # ---- timer-interrupt test (assemble only) ----
    w3,lab3=build('irq', IRQ_TEST)
    write_hex(os.path.join(tb,'test_irq.hex'), w3)
    print("== IRQ_TEST ==  (%d words)  handler=0x%x  (RTL-checked in tb_irq.v)"
          %(len(w3), lab3['handler']))

    # ---- GPIO integration test ----
    w4,lab4=build('gpio', GPIO_TEST)
    write_hex(os.path.join(tb,'test_gpio.hex'), w4)
    print("== GPIO_TEST ==  (%d words)  expect LED=0xAB, x12=0xAB"%len(w4))

    # ---- stand-alone board demo image (LED counter) ----
    # Written to sw/blink.hex, NOT sw/demo.hex: sw/demo.hex is the program baked
    # into the FPGA bitstream (and the slot the C build `cd sw && make` writes),
    # so regenerating test programs here must never clobber it. sw/demo.hex ships
    # as the LED counter; restore it any time with `cp sw/blink.hex sw/demo.hex`.
    sw_dir=os.path.normpath(os.path.join(here,'..','sw'))
    if os.path.isdir(sw_dir):
        wd,_=build('blink', DEMO_BLINK)
        write_hex(os.path.join(sw_dir,'blink.hex'), wd)
        print("== DEMO_BLINK ==  (%d words)  -> sw/blink.hex  (LED counter)"%len(wd))

    # ---- accelerator reference ----
    # 5x5 input ramp, 3x3 box-ish kernel, shift 0
    W=H=5; K=3
    img=[ (r*W+c) for r in range(H) for c in range(W) ]
    kern=[1,0,1, 0,1,0, 1,0,1]      # 'X' kernel
    out=conv2d(img,W,H,kern,K,0)
    print("== DIR conv reference ==  out %dx%d ="%(W-K+1,H-K+1), out)
    print("ALL REFERENCE CHECKS COMPLETE")
