#!/usr/bin/env python3
"""DeckCPU / DeckOS interactive host terminal bridge.

`make run-deckos` launches the DeckCPU netlist simulation (vvp) with this
script, which is only the transport between your terminal and the simulated
UART:

host terminal <-> this bridge <-> UART RX/TX (RTL) <-> DeckCPU <-> DeckOS console

The CPU, bus, RAM, UART and the DeckOS console program do all of the work;
this script never emulates a command, calculates a result, or reaches into
simulated RAM. It just:

  * creates a FIFO and starts `vvp <binary> +rx=<fifo>`;
  * forwards every UART TX byte (emitted as raw bytes on the simulator's
    stdout) to your terminal;
  * forwards your keystrokes into the FIFO so they enter through the UART RX
    path (rx_push/rx_byte), one byte at a time;
  * terminates cleanly on Ctrl-C (0x03), Ctrl-D / EOF (0x04 / stdin EOF),
    or when the simulator itself exits (the DeckOS `exit` command HALTs the
    CPU and the testbench $finishes; the shell's stdout then closes).

Terminal settings are always restored (raw/cbreak are only used while the
terminal is attached) and the vvp child is always waited/terminated so no
orphan processes are left behind.

Usage: deckcpu_terminal.py [path-to-vvp-binary]
"""

import os
import select
import signal
import subprocess
import sys
import tempfile
import termios
import tty

CTRL_C = 0x03
CTRL_D = 0x04


class Bridge:
    def __init__(self, vvp_bin, cwd=None):
        self.vvp_bin = vvp_bin
        self.cwd = cwd or os.getcwd()
        self.fifo_path = None
        self.rfd = None
        self.proc = None
        self.stdin_fd = sys.stdin.fileno()
        self._raw = False
        self._saved = None
        self._tmpdir = None

    # ---- lifecycle ----
    def start(self):
        if not os.path.exists(self.vvp_bin):
            raise FileNotFoundError(
                f"simulator binary not found: {self.vvp_bin} "
                "(run 'make build/sim/deckos_term' first)"
            )
        self._tmpdir = tempfile.mkdtemp(prefix="deckcpu-term-")
        self.fifo_path = os.path.join(self._tmpdir, "rx")
        os.mkfifo(self.fifo_path)
        # O_RDWR so opening never blocks and writes never SIGPIPE before the
        # simulator's read end exists (and never after it closes early).
        self.rfd = os.open(self.fifo_path, os.O_RDWR)
        self.proc = subprocess.Popen(
            [self.vvp_bin, f"+rx={self.fifo_path}"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            cwd=self.cwd,
        )

    def set_raw(self):
        if not sys.stdin.isatty():
            return
        self._saved = termios.tcgetattr(self.stdin_fd)
        tty.setraw(self.stdin_fd)
        self._raw = True

    def restore_term(self):
        if self._raw and self._saved is not None:
            try:
                termios.tcsetattr(self.stdin_fd, termios.TCSADRAIN, self._saved)
            except termios.error:
                pass
            self._raw = False

    def shutdown(self, reason, rc=0):
        """Restore the terminal and make sure the simulator is gone."""
        self.restore_term()
        if self.rfd is not None:
            try:
                os.close(self.rfd)          # sim sees EOF -> $finish
            except OSError:
                pass
            self.rfd = None
        if self.proc is not None and self.proc.poll() is None:
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.terminate()
                try:
                    self.proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
                    self.proc.wait()
        if self._tmpdir is not None:
            try:
                if self.fifo_path:
                    os.unlink(self.fifo_path)
                os.rmdir(self._tmpdir)
            except OSError:
                pass
            self._tmpdir = None
        if reason:
            print(f"\n[deckos] {reason} -> bye (sim rc={rc})", file=sys.stderr)
        return rc

    # ---- loop ----
    def run(self):
        self.start()
        self.set_raw()

        def _sig(*_):
            raise ShutdownRequested()

        previous = {
            s: signal.signal(s, _sig) for s in (signal.SIGINT, signal.SIGTERM)
        }
        try:
            self._loop()
            rc = self.proc.returncode if self.proc.returncode is not None else 0
            return self.shutdown("terminal detached", rc)
        except ShutdownRequested:
            return self.shutdown("interrupted")
        except KeyboardInterrupt:
            return self.shutdown("interrupted")
        finally:
            for s, h in previous.items():
                signal.signal(s, h)

    def _loop(self):
        fds = [self.proc.stdout.fileno(), self.stdin_fd]
        stdin_open = True
        while self.proc.poll() is None:
            rl, _, _ = select.select(fds, [], [], 0.25)
            for fd in rl:
                if fd == self.proc.stdout.fileno():
                    data = os.read(fd, 65536)
                    if not data:            # simulator exited
                        self._drain_stdout()
                        return
                    self._emit(data)
                else:                       # host keyboard
                    data = os.read(fd, 4096)
                    if not data:            # host EOF (e.g. piped input closed)
                        return
                    for b in data:
                        if b in (CTRL_C, CTRL_D):
                            return
                    self._send(data)
        self._drain_stdout()

    def _send(self, data):
        os.write(self.rfd, data)

    def _emit(self, data):
        os.write(sys.stdout.fileno(), data)

    def _drain_stdout(self):
        fd = self.proc.stdout.fileno()
        while True:
            rl, _, _ = select.select([fd], [], [], 0.25)
            if not rl:
                break
            data = os.read(fd, 65536)
            if not data:
                break
            self._emit(data)
        try:
            sys.stdout.flush()
        except BrokenPipeError:
            pass


class ShutdownRequested(Exception):
    pass


def main(argv):
    if len(argv) > 2:
        print("usage: deckcpu_terminal.py [path-to-vvp-binary]", file=sys.stderr)
        return 2
    vvp_bin = argv[1] if len(argv) == 2 else "build/sim/deckos_term"
    try:
        rc = Bridge(vvp_bin).run()
    except FileNotFoundError as e:
        print(f"[deckos] {e}", file=sys.stderr)
        return 1
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))