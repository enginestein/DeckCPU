# DeckOS backend for DeckCPU

A subset of the DeckOS console onto DeckCPU, running on the simulated processor in `sim/testbenches/deckos_tb.sv`

## Console commands

```
help                 commands: help about echo time gpio peek poke calc sleep exec exit
about                DeckOS/1.0 DeckCPU console
echo <words…>        prints its arguments
time                 t=<8 hex-digit TIMER COUNT>
gpio <pin 0-31> <0|1>  sets DIR + OUT, prints "gpio <pin 2-digit> -> <0|1>"
peek <addr>          prints the 32-bit word at <addr> as 8 hex digits
poke <addr> <val>    writes the 32-bit <val> to <addr> (echoes <val>)
calc <a> <op> <b>    integer ALU expression; ops + - * & | ^ (result in hex)
sleep <ticks>        busy-waits <ticks> TIMER COUNT deltas, prints "slept 0x<delta>"
exec <addr>          CALLs the 4-byte-aligned code word at <addr>
                     (the target's RET returns to the shell) — the shell
                     can run code poked into RAM, i.e. a stored program demo
exit                 HALT the simulated CPU and stop the simulation
```

## Building and verifying

From the repo root:

```
make build/sim/deckos     # compile the deterministic netlist testbench
make run-deckos-tb        # run it (vvp) -> deckos_tb: PASS
make run-deckos           # interactive console (above)
make term-check           # scripted UART round-trip -> deckos_term: PASS
make test                 # full suite: isa, docs, lint, sim, asm check, term
```