#!/usr/bin/env python3
# ============================================================================
# accel_model.py  -  Cycle-accurate model of dir_accel.v's controller + MAC
#
# Mirrors the RTL exactly, including the 1-cycle scratchpad read latency and the
# DSP MAC timing. The inner loops (coefficient load AND the per-pixel MAC) are
# PIPELINED: each cycle presents the next scratchpad address while consuming the
# operand fetched the previous cycle, hiding the BRAM latency. This is ~1 cycle
# per tap (vs. 2 in the address-then-data version), roughly halving compute time.
#
# Running this validates the pipelined timing produces the correct convolution
# before it is trusted in RTL (tb_dir_accel.v confirms on the real hardware).
# ============================================================================
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rv32i import conv2d, sx

MASK32 = 0xFFFFFFFF
MASK48 = (1 << 48) - 1
def sx16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v
def sgn48(a):
    return a - (1 << 48) if a & (1 << 47) else a

def run(img, W, H, kern, K, shift, in_base=0, co_base=64, out_base=128):
    DEPTH = 2048
    mem = [0]*DEPTH
    for i, v in enumerate(img):  mem[in_base+i] = v & MASK32
    for i, v in enumerate(kern): mem[co_base+i] = v & MASK32

    OW, OH = W-K+1, H-K+1
    KK = K*K
    coeff = [0]*KK

    # registers
    state = 'LC'
    ci = 0; sci_d = 0; lc_valid_d = 0          # coeff-load pipeline
    kx = ky = tap = 0                          # compute window position
    coeff_d = 0; first_d = 0; st_valid_d = 0   # compute pipeline
    ox = oy = 0
    acc = 0; b_rdata = 0; result = 0
    cycles = 0

    for _ in range(500000):
        cycles += 1
        # ---------------- combinational outputs ----------------
        b_en = b_we = 0; b_addr = 0; b_wdata = 0
        mac_en = mac_clear = 0; mac_a = mac_b = 0
        present = 0
        if state == 'LC':
            present = ci < KK
            if present: b_en = 1; b_addr = co_base + ci
        elif state == 'STREAM':
            present = tap < KK
            if present: b_en = 1; b_addr = in_base + (oy+ky)*W + (ox+kx)
            if st_valid_d:
                mac_en = 1; mac_clear = first_d; mac_a = sx16(b_rdata); mac_b = coeff_d
        elif state == 'WRITE':
            b_en = 1; b_we = 1; b_addr = out_base + oy*OW + ox
            b_wdata = (sgn48(acc) >> shift) & MASK32

        # ---------------- next-state ----------------
        ns = state
        n_ci, n_sci_d, n_lcv = ci, sci_d, lc_valid_d
        n_kx, n_ky, n_tap = kx, ky, tap
        n_coeff_d, n_first_d, n_stv = coeff_d, first_d, st_valid_d
        n_ox, n_oy, n_result = ox, oy, result

        if state == 'LC':
            if lc_valid_d: coeff[sci_d] = sx16(b_rdata)
            n_sci_d = ci; n_lcv = present
            if present: n_ci = ci + 1
            if (not present) and lc_valid_d:
                ns = 'PINIT'
        elif state == 'PINIT':
            n_kx = n_ky = n_tap = 0; n_stv = 0
            ns = 'STREAM'
        elif state == 'STREAM':
            if present:
                n_coeff_d = coeff[tap]; n_first_d = 1 if tap == 0 else 0
                n_tap = tap + 1
                if kx == K-1: n_kx = 0; n_ky = ky + 1
                else: n_kx = kx + 1
            n_stv = present
            if (not present) and st_valid_d:
                ns = 'WRITE'
        elif state == 'WRITE':
            n_result = (sgn48(acc) >> shift) & MASK32
            if ox == OW-1 and oy == OH-1:
                ns = 'DONE'
            else:
                if ox == OW-1: n_ox = 0; n_oy = oy + 1
                else: n_ox = ox + 1
                ns = 'PINIT'
        elif state == 'DONE':
            ns = 'DONE'

        # ---------------- dpram (1-cycle read) ----------------
        n_b_rdata = b_rdata
        if b_en:
            if b_we: mem[b_addr] = b_wdata & MASK32
            n_b_rdata = mem[b_addr]

        # ---------------- DSP MAC ----------------
        prod = mac_a * mac_b
        n_acc = acc
        if mac_clear and mac_en: n_acc = prod & MASK48
        elif mac_clear:          n_acc = 0
        elif mac_en:             n_acc = (acc + prod) & MASK48

        # ---------------- commit ----------------
        state = ns
        ci, sci_d, lc_valid_d = n_ci, n_sci_d, n_lcv
        kx, ky, tap = n_kx, n_ky, n_tap
        coeff_d, first_d, st_valid_d = n_coeff_d, n_first_d, n_stv
        ox, oy, result = n_ox, n_oy, n_result
        b_rdata = n_b_rdata; acc = n_acc
        if state == 'DONE':
            break

    out = [mem[out_base + oy*OW + ox] for oy in range(OH) for ox in range(OW)]
    return out, result, cycles

if __name__ == '__main__':
    ok = True
    # Test 1: 5x5 ramp (X) 3x3
    W = H = 5; K = 3
    img = [r*W+c for r in range(H) for c in range(W)]
    kern = [1,0,1, 0,1,0, 1,0,1]
    out, result, cyc = run(img, W, H, kern, K, 0)
    golden = conv2d(img, W, H, kern, K, 0)
    print("5x5 (X) 3x3:  out =", out)
    print("    golden    =", golden, " result=%d (exp %d)  cycles=%d" % (result, golden[-1], cyc))
    ok &= (out == golden and result == golden[-1])

    # Test 2: 7x7 ramp (ramp) 7x7 -> single 49-tap dot product (the benchmark)
    W = H = 7; K = 7
    img = list(range(49)); kern = list(range(49))
    out2, result2, cyc2 = run(img, W, H, kern, K, 0, in_base=0, co_base=64, out_base=128)
    golden2 = conv2d(img, W, H, kern, K, 0)
    print("7x7 (ramp) 7x7: out =", out2, " golden =", golden2, " cycles=%d" % cyc2)
    ok &= (out2 == golden2)

    print("PIPELINED ACCELERATOR MODEL MATCHES GOLDEN  ✓" if ok else "MISMATCH ✗")
    sys.exit(0 if ok else 1)
