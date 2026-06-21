#!/usr/bin/env python3
# ============================================================================
# uart_load.py  -  Host-side UART program loader for Solvyr-3
#
# Sends a compiled program image to the on-chip UART boot loader (rtl/prog_loader.v)
# so you can iterate on the C/firmware WITHOUT rebuilding the FPGA bitstream.
#
# Wire protocol (must match prog_loader.v exactly, little-endian):
#     [4 bytes]  word_count N
#     [N words]  4 bytes each  -> IMEM word addresses 0,1,2,...
# The loader holds the CPU in reset until all N words are written, then releases
# it to run from PC=0. There is no ack/checksum in the RTL, so this is send-only.
#
# Board requirements:
#   * Bitstream built with USE_LOADER=1  (./build_fpga.sh --loader ...)
#   * Boot switch SW15 = ON (1)          (selects UART boot)
#   * Press CPU_RESETN once so the loader is waiting, THEN run this script.
#   * SW15 = OFF (0) runs the baked-in IMEM_INIT image instead (the fallback).
#
# Usage:
#   python3 uart_load.py COM5 ../bench/bench_c.hex            # Windows
#   python3 uart_load.py /dev/ttyUSB1 ../bench/bench_c.hex    # Linux/macOS
#   python3 uart_load.py COM5 bench_c.hex --monitor          # then print output
#
# Requires pyserial:  pip install pyserial
# ============================================================================
import argparse
import struct
import sys
import time

try:
    import serial  # pyserial
except ImportError:
    sys.exit("ERROR: pyserial not installed.  Run:  pip install pyserial")


def load_words(path):
    """Return a list of 32-bit words from a .hex ($readmemh) or flat .bin image."""
    if path.lower().endswith(".bin"):
        data = open(path, "rb").read()
        if len(data) % 4:
            data += b"\x00" * (4 - len(data) % 4)   # zero-pad final word
        return [struct.unpack_from("<I", data, i)[0] for i in range(0, len(data), 4)]

    # $readmemh text: one 8-hex-digit word per line; tolerate @addr / comments.
    words = []
    for raw in open(path):
        line = raw.split("//")[0].strip()
        if not line:
            continue
        for tok in line.split():
            if tok.startswith("@"):
                continue        # address directive: assume contiguous from 0
            words.append(int(tok, 16) & 0xFFFFFFFF)
    return words


MAGIC = 0xA55AC33C   # must equal MAGIC in rtl/prog_loader.v (sync-header build)


def build_payload(words, use_magic=False):
    """Optional 4-byte sync MAGIC, then word_count (LE), then each word (LE).
    The MAGIC lets a sync-enabled loader discard any spurious leading byte (e.g. a
    serial-port-open line glitch) and lock onto the real stream. Omit it for the
    original loader bitstream (which expects the count first)."""
    payload = struct.pack("<I", MAGIC) if use_magic else b""
    payload += struct.pack("<I", len(words))
    payload += b"".join(struct.pack("<I", w) for w in words)
    return payload


def main():
    ap = argparse.ArgumentParser(description="Solvyr-3 UART program loader (host side).")
    ap.add_argument("port", help="serial port, e.g. COM5 or /dev/ttyUSB1")
    ap.add_argument("image", help="program image: .hex ($readmemh) or .bin")
    ap.add_argument("-b", "--baud", type=int, default=115200, help="baud (default 115200)")
    ap.add_argument("--imem-words", type=int, default=1024,
                    help="IMEM depth check (default 1024)")
    ap.add_argument("--chunk", type=int, default=256,
                    help="bytes per write burst (default 256)")
    ap.add_argument("--monitor", action="store_true",
                    help="after loading, print the program's UART output")
    ap.add_argument("--monitor-seconds", type=float, default=8.0,
                    help="how long to monitor (default 8 s)")
    ap.add_argument("--magic", action="store_true",
                    help="prepend the 4-byte sync header (use ONLY with a loader "
                         "bitstream built from the sync-enabled prog_loader.v)")
    args = ap.parse_args()

    words = load_words(args.image)
    n = len(words)
    if n == 0:
        sys.exit("ERROR: image has 0 words.")
    if n > args.imem_words:
        sys.exit(f"ERROR: {n} words exceeds IMEM depth ({args.imem_words}). "
                 f"Shrink the program or rebuild IMEM larger.")

    payload = build_payload(words, use_magic=args.magic)
    print(f"image     : {args.image}{'  (+sync MAGIC)' if args.magic else ''}")
    print(f"words     : {n}  ({n*4} program bytes, {n*100//args.imem_words}% of IMEM)")
    print(f"payload   : {len(payload)} bytes  (4-byte count + {n} words)")
    print(f"port/baud : {args.port} @ {args.baud} 8-N-1")
    print("Make sure SW15=ON and you pressed CPU_RESETN so the loader is waiting...")

    try:
        # Open WITHOUT toggling DTR/RTS: on many USB-UART bridges those modem
        # lines glitch the FPGA RX line on open and inject a spurious start bit,
        # which shifts the whole stream by one byte -> the loader's word count is
        # wrong and load_done never asserts (CPU stays in reset, no program runs).
        ser = serial.Serial()
        ser.port = args.port
        ser.baudrate = args.baud
        ser.timeout = 1
        ser.dtr = False
        ser.rts = False
        ser.open()
    except Exception as e:
        sys.exit(f"ERROR: cannot open {args.port}: {e}")
    time.sleep(0.1)                 # let the line settle after open
    ser.reset_input_buffer()       # drop any glitch byte before we start
    ser.reset_output_buffer()

    # The loader processes each byte in one cycle, far faster than the byte
    # arrival rate, so no flow control is needed; chunking just gives progress.
    t0 = time.time()
    sent = 0
    for i in range(0, len(payload), args.chunk):
        ser.write(payload[i:i + args.chunk])
        sent += len(payload[i:i + args.chunk])
        print(f"\r  sent {sent}/{len(payload)} bytes", end="", flush=True)
    ser.flush()
    dt = time.time() - t0
    print(f"\nDONE: loaded {n} words in {dt:.2f}s. CPU should now be running the program.")

    if args.monitor:
        print(f"--- monitoring UART for {args.monitor_seconds:.0f}s (Ctrl-C to stop) ---")
        ser.timeout = 0.2
        end = time.time() + args.monitor_seconds
        try:
            while time.time() < end:
                data = ser.read(4096)
                if data:
                    sys.stdout.write(data.decode("ascii", "replace"))
                    sys.stdout.flush()
        except KeyboardInterrupt:
            pass
        print("\n--- end monitor ---")

    ser.close()


if __name__ == "__main__":
    main()
