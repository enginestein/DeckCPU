# DeckOS backend for DeckCPU

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
                     (the target's RET returns to the shell) the shell
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
make build/sim/deckos_c   # compile the deckc CIOS testbench
make run-deckos_c         # run it -> deckos_c_tb: PASS
make build/sim/cshell     # compile the deckc console testbench
make run-cshell           # run it -> cshell_tb: PASS
make run-cshell-term      # interactive deckc console terminal
make term-check-cshell    # scripted UART round-trip -> cshell_term: PASS
make deckc-check          # golden artefact + interpreter transcript pytest
make test                 # full suite: isa, docs, lint, sim, asm/deckc check, term
```