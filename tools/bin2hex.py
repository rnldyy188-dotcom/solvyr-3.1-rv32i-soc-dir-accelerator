#!/usr/bin/env python3
# ============================================================================
# bin2hex.py  -  Convert a flat little-endian .bin into a $readmemh word image
#
#   python3 bin2hex.py demo.bin demo.hex
#
# Emits one 32-bit word per line (8 hex digits, big-endian text), which is what
# Verilog $readmemh expects for a [31:0] memory written one word per entry.
# Zero-pads the final partial word.
# ============================================================================
import sys, struct

def main():
    if len(sys.argv) != 3:
        print("usage: bin2hex.py <in.bin> <out.hex>"); sys.exit(1)
    data = open(sys.argv[1], 'rb').read()
    if len(data) % 4:
        data += b'\x00' * (4 - len(data) % 4)
    with open(sys.argv[2], 'w') as f:
        for i in range(0, len(data), 4):
            (word,) = struct.unpack('<I', data[i:i+4])
            f.write("%08x\n" % word)
    print("wrote %d words to %s" % (len(data)//4, sys.argv[2]))

if __name__ == '__main__':
    main()
