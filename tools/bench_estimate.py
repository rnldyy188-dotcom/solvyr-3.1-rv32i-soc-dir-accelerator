#!/usr/bin/env python3
"""
bench_estimate.py - first-order cycle model for the Solvyr-3 conv benchmark.

Purpose: ground the "what workload gets us toward ~40x?" question in the ONE
hard data point we have from the real board, instead of guessing.

Measured anchor (real board, bench_c.hex, 16x16 input, 3x3 "X" kernel {1,0,1,...}):
    software cycles    = 53963
    accelerator cycles = 4702
    end-to-end speedup  = 11.47x

The model below is calibrated to reproduce that point, then used to PREDICT the
speedup for higher-intensity workloads. It is a planning tool, not a promise:
the real number must be re-measured on the board. It exists so the 40x target
is justified by the architecture, not asserted.

Key physical insight it encodes
-------------------------------
RV32I has no hardware multiply, so each software tap costs a fixed overhead
(call/ret + two loads + address math + accumulate) PLUS a shift-add multiply
whose length is the BIT-LENGTH of the coefficient. The original 0/1 kernel is a
best case for software (coefficients are 0 or 1 -> the shift-add loop runs ~0-1
times), which UNDERSTATES the accelerator. Real fixed-point image/depth filters
use multi-bit coefficients, for which software MAC is genuinely expensive and
the single-DSP accelerator (~1 tap/cycle) wins by much more.
"""
import math

# ---- calibrated constants (fit to the 11.47x board point) ------------------
SW_BASE    = 28.4   # fixed software cycles per tap (call/ret, loads, index, acc)
SW_PERBIT  = 4.0    # extra cycles per significant coefficient bit (shift-add)
HW_COPY    = 8.7    # cycles to move one word CPU->scratchpad (load+MMIO store+loop)
HW_CONFIG  = 40     # accelerator register programming
HW_PIXOVH  = 3      # accelerator per-output overhead (PINIT + WRITE + pipe fill)

def bitlen(v):
    v = abs(int(v))
    return v.bit_length()        # 0 -> 0, 1 -> 1, 255 -> 8, 1024 -> 11

def sw_cycles(out_w, out_h, kernel):
    per_px = sum(SW_BASE + SW_PERBIT * bitlen(c) for c in kernel)
    return out_w * out_h * per_px

def hw_cycles(img_w, img_h, k, out_w, out_h):
    kk = k * k
    copy   = HW_COPY * (img_w * img_h + kk)      # input tile + coeffs -> scratch
    accel  = kk + out_w * out_h * (kk + HW_PIXOVH)
    return copy + HW_CONFIG + accel

def predict(img_w, img_h, k, kernel, label=""):
    ow, oh = img_w - k + 1, img_h - k + 1
    sw = sw_cycles(ow, oh, kernel)
    hw = hw_cycles(img_w, img_h, k, ow, oh)
    avg_bits = sum(bitlen(c) for c in kernel) / len(kernel)
    print(f"{label:<34} K={k} out={ow}x{oh} avgCoeffBits={avg_bits:4.1f}  "
          f"sw={sw:8.0f}  hw={hw:6.0f}  speedup={sw/hw:5.1f}x")
    return sw / hw

# ---- realistic fixed-point kernels -----------------------------------------
def gaussian_q(k, sigma, scale, floor=1):
    """K x K Gaussian, fixed-point (xscale), floored so no tap is 0."""
    c = (k - 1) / 2.0
    out = []
    for y in range(k):
        for x in range(k):
            r2 = (x - c) ** 2 + (y - c) ** 2
            w = math.exp(-r2 / (2 * sigma * sigma))
            out.append(max(floor, int(round(w * scale))))
    return out

def c_array(name, kernel, k):
    rows = []
    for y in range(k):
        row = ", ".join(f"{kernel[y*k+x]:4d}" for x in range(k))
        rows.append("    " + row + ",")
    body = "\n".join(rows)
    return f"static const int16_t {name}[{k}*{k}] = {{\n{body}\n}};"

def main():
    print("=== calibration check (must reproduce the board anchor) ===")
    x_kernel = [1,0,1, 0,1,0, 1,0,1]
    predict(16, 16, 3, x_kernel, "anchor: 16x16, 3x3 X-kernel")
    print("   (target: sw~53963 hw~4702 speedup~11.5x)\n")

    print("=== effect of arithmetic intensity + realistic coefficients ===")
    # bigger kernel alone (still cheap 0/1-ish) does not reach 40x:
    predict(16, 16, 5, [1]*25, "16x16, 5x5 all-ones")
    predict(16, 16, 7, [1]*49, "16x16, 7x7 all-ones")
    # realistic multi-bit fixed-point kernels:
    for sigma, scale, tag in [(1.2, 256, "Q8"), (2.0, 512, "Q9"), (2.5, 1024, "Q10")]:
        k = gaussian_q(7, sigma, scale, floor=8)
        predict(16, 16, 7, k, f"16x16, 7x7 Gaussian {tag}")
    print()

    print("=== chosen workload for the ~40x target ===")
    K = 7
    chosen = gaussian_q(K, sigma=2.2, scale=1024, floor=16)
    sp = predict(16, 16, K, chosen, ">> 16x16, 7x7 Gaussian Q10")
    print()
    print("Predicted end-to-end speedup ~ {:.0f}x (RE-MEASURE on the board).".format(sp))
    print("Coefficient C array for bench.c:\n")
    print(c_array("krn", chosen, K))

if __name__ == "__main__":
    main()
