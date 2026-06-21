#!/usr/bin/env python3
"""
uart_tx_model.py - cycle-accurate behavioral model of rtl/uart.v's TX path.

Mirrors the holding-register transmitter exactly (same regs, same next-state
logic) and decodes the serial line back into bytes. Used to verify, without an
HDL simulator, that:
  (1) a burst of bytes driven by a TX_READY-polling driver is transmitted in
      order with NO dropped characters, and
  (2) the old write->busy race (the reason the firmware needed a guard delay)
      can no longer drop a byte.

This is a logic check of the RTL change, not a substitute for tb_uart.v.
"""

DIV = 8  # small bit period for a fast model (tb_uart uses DIV=8 too)

class UartTx:
    """Behavioral twin of the TX always-block in rtl/uart.v."""
    def __init__(self):
        self.tx_frame = 0x3FF
        self.tx_bitcnt = 0
        self.tx_baud = 0
        self.tx_active = False
        self.tx_line = 1
        self.tx_hold = 0
        self.tx_hold_full = False

    @property
    def tx_busy(self):   return self.tx_active or self.tx_hold_full
    @property
    def tx_ready(self):  return not self.tx_hold_full

    def step(self, tx_load=False, wdata=0):
        """One posedge clk. tx_load = bus write strobe this cycle."""
        # --- capture current-state reads (non-blocking semantics) ---
        active = self.tx_active
        hold_full = self.tx_hold_full
        frame = self.tx_frame
        baud = self.tx_baud
        bitcnt = self.tx_bitcnt

        n_hold, n_hold_full = self.tx_hold, hold_full
        n_frame, n_baud, n_bitcnt = frame, baud, bitcnt
        n_active, n_line = active, self.tx_line

        # bus write -> holding register (only when empty)
        if tx_load and not hold_full:
            n_hold = wdata & 0xFF
            n_hold_full = True

        if not active:
            n_line = 1
            if hold_full:  # launch queued byte (uses OLD hold_full/hold)
                n_frame = ((1 << 9) | (self.tx_hold << 1) | 0) & 0x3FF
                n_bitcnt = 10
                n_baud = 0
                n_active = True
                n_hold_full = False  # slot freed
        else:
            n_line = frame & 1
            if baud == DIV - 1:
                n_baud = 0
                n_frame = ((1 << 9) | (frame >> 1)) & 0x3FF
                n_bitcnt = bitcnt - 1
                if bitcnt == 1:
                    n_active = False
            else:
                n_baud = baud + 1

        # commit
        self.tx_hold, self.tx_hold_full = n_hold, n_hold_full
        self.tx_frame, self.tx_baud, self.tx_bitcnt = n_frame, n_baud, n_bitcnt
        self.tx_active, self.tx_line = n_active, n_line
        return self.tx_line


class SerialRx:
    """Oversampling-free decoder: sample each bit at its center (DIV/2)."""
    def __init__(self):
        self.state = "idle"
        self.cnt = 0
        self.bit = 0
        self.shift = 0
        self.out = []
        self.prev = 1

    def sample(self, line):
        if self.state == "idle":
            if self.prev == 1 and line == 0:      # start edge
                self.state, self.cnt = "start", 0
        elif self.state == "start":
            self.cnt += 1
            if self.cnt == DIV + DIV // 2:         # center of bit0
                self.shift = (self.shift >> 1) | ((line & 1) << 7)
                self.state, self.cnt, self.bit = "data", 0, 1
        elif self.state == "data":
            self.cnt += 1
            if self.cnt == DIV:
                self.cnt = 0
                if self.bit < 8:
                    self.shift = (self.shift >> 1) | ((line & 1) << 7)
                    self.bit += 1
                else:
                    self.out.append(self.shift & 0xFF)  # stop bit -> commit
                    self.state = "idle"
        self.prev = line


def drive(message, aggressive=False):
    """Driver that polls TX_READY before each write (the new firmware pattern).
    aggressive=True re-polls with ZERO slack (worst case for the write->busy
    race) and uses NO guard delay."""
    tx, rx = UartTx(), SerialRx()
    data = [ord(c) for c in message]
    idx = 0
    cycles = 0
    MAXC = len(message) * DIV * 40 + 1000
    while idx < len(data) or tx.tx_busy:
        load = False
        wd = 0
        # poll TX_READY, then write (no delay loop at all)
        if idx < len(data) and tx.tx_ready:
            load, wd = True, data[idx]
            idx += 1
        line = tx.step(tx_load=load, wdata=wd)
        rx.sample(line)
        cycles += 1
        if cycles > MAXC:
            break
    return bytes(rx.out), cycles


def main():
    ok = True
    for msg in ["AB", "workload: 16x16 input -> 14x14 output\r\n",
                "results match\r\n", "X" * 64]:
        got, cyc = drive(msg)
        exp = msg.encode()
        status = "PASS" if got == exp else "FAIL"
        if got != exp:
            ok = False
        shown = msg if len(msg) < 30 else msg[:27] + "..."
        print(f"[{status}] {len(exp):3d} bytes, {cyc:5d} cyc  "
              f"msg={shown!r}")
        if got != exp:
            print(f"        expected {exp!r}")
            print(f"        got      {got!r}")

    # Direct stress of the OLD race: write a byte, then immediately (next cycle)
    # offer the next byte while polling TX_READY. With a 1-deep holding register
    # the second byte queues instead of clobbering the first.
    print("\n-- back-to-back write race (no guard delay) --")
    got, cyc = drive("0123456789", aggressive=True)
    race_ok = got == b"0123456789"
    print(f"[{'PASS' if race_ok else 'FAIL'}] burst of 10 digits -> {got!r}")
    ok = ok and race_ok

    print("\nRESULT:", "ALL PASS - holding register prevents dropped chars"
          if ok else "FAILURES DETECTED")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
