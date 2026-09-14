#!/usr/bin/env python3
"""Deterministic scripted DeckOS terminal round-trip test (CI-safe).

Boots the same interactive DeckOS netlist binary the human terminal uses
(build/sim/deckos_term + sim/terminal/deckcpu_terminal.py share this path),
types a fixed session through the same UART RX FIFO, and asserts the console's
real responses came back through UART TX. Nothing here emulates DeckOS: the
DeckCPU executes the image and produces every asserted byte.

Session typed at the machine:
    help
    about
    echo hello world
    time
    calc 6 * 7
    calc 2 + 3
    poke f100 cafebeef
    peek f100
    exit            <- shell HALTs; the simulator must stop by itself

Usage: deckos_term_test.py [path-to-vvp-binary]
Exit:  0 = pass, 1 = fail.
"""

import os
import select
import subprocess
import sys
import tempfile

SESSION = (
    b"help\r"
    b"about\r"
    b"echo hello world\r"
    b"time\r"
    b"calc 6 * 7\r"
    b"calc 2 + 3\r"
    b"poke f100 cafebeef\r"
    b"peek f100\r"
    b"exit\r"
)

TIMEOUT_S = 180


def contains(transcript, needle):
    return needle in transcript


def run_test(vvp_bin):
    if not os.path.exists(vvp_bin):
        print(f"FAIL: simulator binary not found: {vvp_bin}", file=sys.stderr)
        return 1

    tmpdir = tempfile.mkdtemp(prefix="deckcpu-termtest-")
    fifo = os.path.join(tmpdir, "rx")
    os.mkfifo(fifo)
    rfd = os.open(fifo, os.O_RDWR)

    transcript = bytearray()
    try:
        proc = subprocess.Popen(
            [vvp_bin, f"+rx={fifo}"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        # Type the whole session up front; the bridge services the console
        # byte-by-byte as it consumes each one. Keep rfd open until the end so
        # the simulator only sees EOF after it has finished anyway.
        os.write(rfd, SESSION)

        outfd = proc.stdout.fileno()
        while proc.poll() is None:
            rl, _, _ = select.select([outfd], [], [], 0.25)
            if not rl:
                continue
            data = os.read(outfd, 65536)
            if not data:
                break
            transcript.extend(data)

        # drain anything still held after the process exited
        while True:
            rl, _, _ = select.select([outfd], [], [], 0.25)
            if not rl:
                break
            data = os.read(outfd, 65536)
            if not data:
                break
            transcript.extend(data)

        try:
            rc = proc.wait(timeout=TIMEOUT_S)
        except subprocess.TimeoutExpired:
            proc.kill()
            print("FAIL: simulator did not exit after 'exit' command", file=sys.stderr)
            proc.wait()
            return 1

        txt = bytes(transcript).decode("latin-1")

        ok = True
        checks = [
            ("banner", "DeckOS/1.0 DeckCPU console"),
            ("help response", "commands: help about echo time gpio peek poke "
                              "calc sleep exec exit"),
            ("echo response", "hello world"),
            ("about response", "DeckOS/1.0 DeckCPU console"),
            ("time response (t=", "t="),
            ("calc 6 * 7 -> 0x2a", "0000002a"),
            ("calc 2 + 3 -> 5", "00000005"),
            ("peek/poke cafebeef round-trip", chr(10).join(["", "cafebeef"]) if False else "cafebeef"),
        ]
        if txt.count("cafebeef") < 2:
            ok = False
            print("FAIL: expected 'cafebeef' at least twice (poke echo + peek "
                  "read-back), saw %d" % txt.count("cafebeef"))
        for label, needle in checks:
            if not contains(txt, needle):
                ok = False
                print(f"FAIL: transcript lacks '{label}' needle: {needle!r}")

        if rc != 0:
            ok = False
            print(f"FAIL: simulator exited rc={rc} (want 0)")

        if ok:
            print(f"deckos_term: PASS (scripted UART round-trip, "
                  f"{len(transcript)} chars, rc={rc})")
            return 0

        print("---- transcript tail ----")
        print(txt[-2000:])
        return 1
    finally:
        try:
            os.close(rfd)
        except OSError:
            pass
        try:
            os.unlink(fifo)
            os.rmdir(tmpdir)
        except OSError:
            pass


def main(argv):
    if len(argv) > 2:
        print("usage: deckos_term_test.py [path-to-vvp-binary]", file=sys.stderr)
        return 2
    vvp_bin = argv[1] if len(argv) == 2 else "build/sim/deckos_term"
    return run_test(vvp_bin)


if __name__ == "__main__":
    sys.exit(main(sys.argv))