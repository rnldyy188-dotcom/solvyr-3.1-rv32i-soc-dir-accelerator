#!/usr/bin/env bash
# ============================================================================
# build_fpga.sh  -  One command: firmware -> Vivado generic -> bitstream -> timing
#
# Replaces the error-prone manual sequence (and the silent "empty IMEM_INIT"
# trap) with a single reproducible flow:
#   1. build the firmware image with the RISC-V toolchain
#   2. verify the image exists and is non-empty
#   3. run Vivado, passing it into instruction BRAM via the IMEM_INIT generic
#   4. surface the post-route WNS/TNS so timing is never over-claimed
#
# Usage:
#   ./build_fpga.sh bench            # bench/bench_c.hex  (software-vs-accel demo)
#   ./build_fpga.sh demo             # sw/demo.hex        (UART banner + animation)
#   ./build_fpga.sh bench <part>     # override the FPGA part
#   ./build_fpga.sh bench --loader   # ALSO compile in the UART boot loader, so you
#                                    # can reload programs over UART (tools/uart_load.py)
#                                    # WITHOUT rebuilding -> writes solvyr3_loader.bit.
#
# The official, timing-clean benchmark bitstream is the NON-loader build (solvyr3.bit);
# --loader produces a separate solvyr3_loader.bit so the verified result is untouched.
#
# Requires: a riscv*-gcc on PATH (auto-detected by the Makefiles) and `vivado`.
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"

# Parse: positional TARGET/PART plus an optional --loader flag (in any position).
USE_LOADER=0; POS=()
for a in "$@"; do
    if [ "$a" = "--loader" ]; then USE_LOADER=1; else POS+=("$a"); fi
done
TARGET="${POS[0]:-bench}"
PART="${POS[1]:-xc7a100tcsg324-1}"
BITNAME=$([ "$USE_LOADER" = 1 ] && echo solvyr3_loader || echo solvyr3)

case "$TARGET" in
    bench) HEX="bench/bench_c.hex"; MAKE_DIR="bench"; MAKE_TGT="bench_c.hex" ;;
    demo)  HEX="sw/demo.hex";       MAKE_DIR="sw";    MAKE_TGT="demo.hex" ;;
    *) echo "usage: $0 {bench|demo} [part] [--loader]"; exit 1 ;;
esac

echo "=== [1/4] build firmware: $HEX ==="
make -C "$MAKE_DIR" "$MAKE_TGT"

echo "=== [2/4] verify firmware image is non-empty ==="
if [ ! -s "$HEX" ]; then
    echo "ERROR: $HEX is missing or empty -- aborting before a blank bitstream is built." >&2
    exit 1
fi
printf '     %s : %s bytes, first word = %s\n' "$HEX" "$(wc -c < "$HEX")" "$(head -n1 "$HEX")"

echo "=== [3/4] Vivado synth -> impl -> bitstream (IMEM_INIT=$HEX, USE_LOADER=$USE_LOADER) ==="
if ! command -v vivado >/dev/null 2>&1; then
    echo "ERROR: 'vivado' not on PATH. Open the Vivado shell, then run:" >&2
    echo "       vivado -mode batch -source vivado/build.tcl -tclargs $PART $HEX $USE_LOADER" >&2
    exit 1
fi
vivado -mode batch -source vivado/build.tcl -tclargs "$PART" "$HEX" "$USE_LOADER"

echo "=== [4/4] timing summary (post-route) ==="
RPTSUF=$([ "$USE_LOADER" = 1 ] && echo _loader || echo "")
RPT="vivado/out/post_route_timing${RPTSUF}.rpt"
if [ -f "$RPT" ]; then
    # Save a timestamped copy so each bitstream's timing is on record.
    STAMP="$(date +%Y%m%d_%H%M%S)"
    cp "$RPT" "vivado/out/timing_${TARGET}${RPTSUF}_${STAMP}.rpt"
    echo "     full report: vivado/out/timing_${TARGET}${RPTSUF}_${STAMP}.rpt"
    grep -E "Worst Negative Slack|Total Negative Slack|Worst Hold Slack|All user specified" "$RPT" || true
else
    echo "     (no timing report found at $RPT)"
fi
echo "=== done: vivado/out/$BITNAME.bit ==="
if [ "$USE_LOADER" = 1 ]; then
    echo "    Loader bitstream. Program it once, set SW15=ON, press CPU_RESETN, then:"
    echo "      make -C bench bench_c.hex && python3 tools/uart_load.py <PORT> bench/bench_c.hex --monitor"
fi
