#!/usr/bin/env python3
"""Scripted DeckC console terminal round-trip test (CI-safe).

Boots the same netlist binary `make run-cshell-term` uses, types a fixed
session into the UART RX FIFO, and checks the console's real responses came
back over UART TX. Nothing here emulates the console — the DeckCPU runs the
deckc-compiled image. The session ends with `exit`, which HALTs the console
so the simulator must stop by itself.

Usage: cshell_term_test.py [path-to-vvp-binary]
Exit:  0 = pass, 1 = fail.
"""

import os
import select
import subprocess
import sys
import tempfile

SESSION = (
    b"help\r"
    b"echo hello world\r"
    b"time\r"
    b"calc 6 * 7\r"
    b"calc 2 + 3\r"
    b"poke f100 cafebeef\r"
    b"peek f100\r"
    b"gpio 0 1\r"
    b"gpio 2 0\r"
    b"clear\r"
    b"exit\r"
)

TIMEOUT_S = 240


def contains(transcript, needle):
    return needle in transcript


def run_test(vvp_bin):
    if not os.path.exists(vvp_bin):
        print(f"FAIL: simulator binary not found: {vvp_bin}", file=sys.stderr)
        return 1

    tmpdir = tempfile.mkdtemp(prefix="deckcpu-cshell-termtest-")
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
        # byte-by-byte as it consumes each one.
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
            ("banner", "deckc/1.0 DeckCPU console"),
            ("help response", "commands: help echo time gpio peek poke "
                              "calc clear exit"),
            ("echo response", "hello world"),
            ("time response (t=", "t="),
            ("calc 6 * 7 -> 0x2a", "0000002a"),
            ("calc 2 + 3 -> 5", "00000005"),
            ("gpio out 0 -> 1", "gpio 0 -> 1"),
            ("gpio out 2 -> 0", "gpio 2 -> 0"),
            ("syslog cleared", "syslog cleared"),
            ("bye", "bye"),
            ("prompt", "deckc> "),
        ]
        if txt.count("cafebeef") < 2:
            ok = False
            print("FAIL: expected 'cafebeef' at least twice (poke echo + "
                  "peek read-back), saw %d" % txt.count("cafebeef"))
        for label, needle in checks:
            if not contains(txt, needle):
                ok = False
                print(f"FAIL: transcript lacks '{label}' needle: {needle!r}")

        if rc != 0:
            ok = False
            print(f"FAIL: simulator exited rc={rc} (want 0)")

        if ok:
            print(f"cshell_term: PASS (scripted UART round-trip, "
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
        print("usage: cshell_term_test.py [path-to-vvp-binary]", file=sys.stderr)
        return 2
    vvp_bin = argv[1] if len(argv) == 2 else "build/sim/cshell_term"
    return run_test(vvp_bin)


if __name__ == "__main__":
    sys.exit(main(sys.argv))