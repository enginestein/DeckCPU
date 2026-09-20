"""DeckCPU C compiler backend (deckc).

Compiles a portable C subset to DeckCPU assembly (the format of
software/assembler), then to a golden image via the assembler. The runtime
(software/deckc/rt) supplies printf/string/divmod plus native asm HAL
primitives; the DeckOS bring-up lives in deckos-port/cios and compiles
verbatim kernel sources from the original DeckOS repository.
"""

__version__ = "0.1.0"