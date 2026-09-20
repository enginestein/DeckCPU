# DeckCPU ISA Reference

**Status:** implemented verified by make test

**This document is generated from `isa/isa.json`. Do not edit directly.**

## Machine model

| Property | Value |
|---|---|
| Word width | 32 bits |
| Instruction width | 32 bits |
| Byte order | little-endian |
| General-purpose registers | r0–r15 (16 regs) |
| Architectural registers | PC, SP, FLAGS (dedicated, outside GPR file) |
| Stack | grows down, full-descending (SP decrements before push) |
| Reset PC | 0x00000000 |
| Reset SP | 0x0000FFFC |

## Flags

| Code | Bit | Meaning |
|---|---|---|
| I | 0 | interrupt enable (I=1 allows IRQ entry) |
| Z | 1 | result zero |
| N | 2 | result negative (bit 31 of result) |
| C | 3 | carry out / borrow from arithmetic, shift-out for shifts |
| V | 4 | signed overflow |

> `FLAGS[31:5]` are reserved and read as 0. `WRFLAG` sets all defined bits.

## Interrupts

| Property | Value |
|---|---|
| Vector base | `0x00000000` |
| Slots | 8 × 4 bytes |
| Global enable | `FLAGS.I` (`EI`/`DI`) |

**Entry model:** on IRQ: push PC, push FLAGS, clear FLAGS.I, PC = vector_base + 4*slot; slot holds a JMP to the handler. IRET pops FLAGS, pops PC.

| Slot | Source | Note |
|---|---|---|
| 0 | RESET | reset enters with PC=vector_base, slot 0 is the first instruction |
| 1 | TIMER |  |
| 2 | UART_RX |  |
| 3 | UART_TX |  |
| 4 | GPIO |  |
| 5 | SPI |  |
| 6 | RESERVED |  |
| 7 | RESERVED |  |

## Instruction encoding formats

### R 3-register ALU / register move

| Field | Bits | Width |
|---|---|---|
| `op` | bits 31:24 | 8 |
| `rd` | bits 23:20 | 4 |
| `rs1` | bits 19:16 | 4 |
| `rs2` | bits 15:12 | 4 |
| `funct` | bits 11:8 | 4 |
| `spare` | bits 7:0 | 8 |

### I immediate / load-store with offset

| Field | Bits | Width |
|---|---|---|
| `op` | bits 31:24 | 8 |
| `rd` | bits 23:20 | 4 |
| `rs1` | bits 19:16 | 4 |
| `imm16` | bits 15:0 | 16 |

### B branch / jump

| Field | Bits | Width |
|---|---|---|
| `op` | bits 31:24 | 8 |
| `rs1` | bits 23:20 | 4 |
| `rs2` | bits 19:16 | 4 |
| `off16` | bits 15:0 | 16 |

Field ordering is MSB-first; the whole word is little-endian in memory.

## Instruction set

| Mnemonic | Opcode | Format | Operands | Semantics | Sets | Cycles | Memory |
|---|---|---|---|---|---|---|---|
| `NOP` | `0x00` | R | `–` | do nothing | – | 3 | none |
| `ADD` | `0x01` | R | `rd, rs1, rs2` | rd = rs1 + rs2 | Z, N, C, V | 4 | none |
| `SUB` | `0x02` | R | `rd, rs1, rs2` | rd = rs1 - rs2 | Z, N, C, V | 4 | none |
| `MUL` | `0x03` | R | `rd, rs1, rs2` | rd = (rs1 * rs2)[31:0] | Z, N | 4 | none |
| `AND` | `0x04` | R | `rd, rs1, rs2` | rd = rs1 & rs2 | Z, N | 4 | none |
| `OR` | `0x05` | R | `rd, rs1, rs2` | rd = rs1 | rs2 | Z, N | 4 | none |
| `XOR` | `0x06` | R | `rd, rs1, rs2` | rd = rs1 ^ rs2 | Z, N | 4 | none |
| `NOT` | `0x07` | R | `rd, rs1` | rd = ~rs1 | Z, N | 4 | none |
| `SHL` | `0x08` | R | `rd, rs1, rs2` | rd = rs1 << (rs2[4:0]) | Z, N, C | 4 | none |
| `SHR` | `0x09` | R | `rd, rs1, rs2` | rd = rs1 >> (rs2[4:0]) | Z, N, C | 4 | none |
| `CMP` | `0x0a` | R | `rs1, rs2` | flags = rs1 - rs2 (no writeback) | Z, N, C, V | 4 | none |
| `ADDI` | `0x11` | I | `rd, rs1, imm16` | rd = rs1 + sext(imm16) | Z, N, C, V | 4 | none |
| `SUBI` | `0x12` | I | `rd, rs1, imm16` | rd = rs1 - sext(imm16) | Z, N, C, V | 4 | none |
| `MULI` | `0x13` | I | `rd, rs1, imm16` | rd = (rs1 * sext(imm16))[31:0] | Z, N | 4 | none |
| `ANDI` | `0x14` | I | `rd, rs1, imm16` | rd = rs1 & sext(imm16) | Z, N | 4 | none |
| `ORI` | `0x15` | I | `rd, rs1, imm16` | rd = rs1 | sext(imm16) | Z, N | 4 | none |
| `XORI` | `0x16` | I | `rd, rs1, imm16` | rd = rs1 ^ sext(imm16) | Z, N | 4 | none |
| `SHLI` | `0x17` | I | `rd, rs1, imm16` | rd = rs1 << (imm16[4:0]) | Z, N, C | 4 | none |
| `SHRI` | `0x18` | I | `rd, rs1, imm16` | rd = rs1 >> (imm16[4:0]) | Z, N, C | 4 | none |
| `CMPI` | `0x19` | I | `rs1, imm16` | flags = rs1 - sext(imm16) (no writeback) | Z, N, C, V | 4 | none |
| `LI` | `0x20` | I | `rd, imm16` | rd = zext(imm16) | – | 4 | none |
| `LIH` | `0x21` | I | `rd, imm16` | rd = {imm16, 16'h0000} | – | 4 | none |
| `MOV` | `0x22` | R | `rd, rs1` | rd = rs1 | – | 4 | none |
| `LD` (alias: LOAD) | `0x30` | I | `rd, rs1, off` | rd = mem32[rs1 + sext(imm16)] | – | 5 | read 4 bytes |
| `LD.H` | `0x31` | I | `rd, rs1, off` | rd = zext32(mem16[rs1 + sext(imm16)]) | – | 5 | read 2 bytes |
| `LD.B` | `0x32` | I | `rd, rs1, off` | rd = zext32(mem8[rs1 + sext(imm16)]) | – | 5 | read 1 byte |
| `ST` (alias: STORE) | `0x34` | I | `rs_data->[rd], rs1, off` | mem32[rs1 + sext(imm16)] = rs_data | – | 4 | write 4 bytes |
| `ST.H` | `0x35` | I | `rs_data->[rd], rs1, off` | mem16[rs1 + sext(imm16)] = rs_data[15:0] | – | 4 | write 2 bytes |
| `ST.B` | `0x36` | I | `rs_data->[rd], rs1, off` | mem8[rs1 + sext(imm16)] = rs_data[7:0] | – | 4 | write 1 byte |
| `JMP` | `0x40` | B | `off` | PC = PC + sext(off16) | – | 4 | none |
| `CALL` | `0x41` | B | `off` | push PC(return); PC = PC + sext(off16) | – | 4 | write 4 bytes |
| `RET` | `0x42` | B | `–` | PC = pop() | – | 5 | read 4 bytes |
| `JMPR` | `0x43` | R | `rs1` | PC = rs1 | – | 4 | none |
| `BEQ` | `0x44` | B | `rs1, rs2, off` | if rs1 == rs2 then PC = PC + sext(off16) | – | 4 | none |
| `BNE` | `0x45` | B | `rs1, rs2, off` | if rs1 != rs2 then PC = PC + sext(off16) | – | 4 | none |
| `BLT` | `0x46` | B | `rs1, rs2, off` | if rs1 < rs2 (signed) then PC = PC + sext(off16) | – | 4 | none |
| `BGE` | `0x47` | B | `rs1, rs2, off` | if rs1 >= rs2 (signed) then PC = PC + sext(off16) | – | 4 | none |
| `BLTU` | `0x48` | B | `rs1, rs2, off` | if rs1 < rs2 (unsigned) then PC = PC + sext(off16) | – | 4 | none |
| `BGEU` | `0x49` | B | `rs1, rs2, off` | if rs1 >= rs2 (unsigned) then PC = PC + sext(off16) | – | 4 | none |
| `PUSH` | `0x50` | R | `rs1` | SP = SP - 4; mem32[SP] = rs1 | – | 4 | write 4 bytes |
| `POP` | `0x51` | R | `rd` | rd = mem32[SP]; SP = SP + 4 | – | 5 | read 4 bytes |
| `RDSP` | `0x52` | R | `rd` | rd = SP | – | 4 | none |
| `WRSP` | `0x53` | R | `rs1` | SP = rs1 | – | 4 | none |
| `RDFLAG` | `0x54` | R | `rd` | rd = FLAGS | – | 4 | none |
| `WRFLAG` | `0x55` | R | `rs1` | FLAGS = rs1 | I, Z, N, C, V | 4 | none |
| `EI` | `0x56` | R | `–` | FLAGS.I = 1 | I | 3 | none |
| `DI` | `0x57` | R | `–` | FLAGS.I = 0 | I | 3 | none |
| `IRET` | `0x58` | B | `–` | FLAGS = pop(); PC = pop() | I, Z, N, C, V | 6 | read 8 bytes |
| `HALT` | `0x60` | R | `–` | stop execution; PC stays | – | 3 | none |

## Canonical encoding rules

* Reserved fields (`funct`, `spare`, unused register fields, `imm16` where unused) must be **zero** in canonical encodings emitted by the assembler.
* `off16` / `imm16` are sign-extended unless marked `u` (zero-extended).
* Branch offsets are byte offsets; they must be a multiple of 4 and are added to `PC` of the branch instruction.
* Opcode `0x00` is `NOP` (all-zeros word).

* **NOP:** All-zeros word. The decoder treats opcode 0x00 as NOP regardless of the other bits.
* **ADD:** two's-complement add
* **SUB:** C = borrow (0 when result >= 0 unsigned), sets overflow
* **MUL:** low 32 bits of product; C,V cleared
* **AND:** C,V cleared
* **OR:** C,V cleared
* **XOR:** C,V cleared
* **NOT:** unary; rs2 must be 0
* **SHL:** C = last bit shifted out, V cleared
* **SHR:** logical shift; C = last bit shifted out, V cleared
* **CMP:** rd must be 0; supports signed/unsigned compare branches
* **SHRI:** logical
* **CMPI:** rd must be 0
* **LI:** zero-extended 16-bit immediate
* **LIH:** 16-bit immediate into high half; LI+LIH build full 32-bit constants
* **MOV:** register-to-register copy
* **LD:** 32-bit load
* **LD.H:** 16-bit load, zero-extended
* **LD.B:** 8-bit load, zero-extended
* **ST:** 32-bit store; NOTE: data register lives in the rd field
* **ST.H:** 16-bit store
* **ST.B:** 8-bit store
* **JMP:** off16 is a byte offset, must be a multiple of 4
* **CALL:** full-descending stack link for subroutine calls
* **RET:** pops return address into PC
* **JMPR:** absolute jump through register; for dispatch tables
* **BEQ:** off16 byte offset, multiple of 4
* **BLT:** uses N != V
* **BGE:** uses N == V
* **BLTU:** uses borrow C=1
* **BGEU:** uses borrow C=0
* **RDSP:** read the dedicated stack pointer
* **WRSP:** set the dedicated stack pointer
* **RDFLAG:** read status register
* **WRFLAG:** write entire status register
* **EI:** enable interrupts
* **DI:** disable interrupts
* **IRET:** interrupt return; must be last-returned from handler pushed by IRQ entry
* **HALT:** CPU enters halted state until reset; asserts dbg.halted
