"""deckc code generator: AST -> DeckCPU assembly.

Calling convention:
  - arguments evaluated right-to-left and PUSHed on the hardware SP; the
    CALLER removes them after the call returns
  - CALL pushes the return address
  - callee prologue: PUSH r15; RDSP r2; MOV r15, r2  (FP = SP), then
    RDSP r2; SUBI r2, r2, FRAME; WRSP r2
  - param i lives at [FP + 8 + 4*i]; local/temp slot k at [FP - off]
  - r0 is the expression result / return-value register; r15 is the frame
    pointer; every other general register is caller-scratch

Conditional branches on this ISA are flags-only: the operands of Bcc are
ignored by the CPU, so every branch is immediately preceded by CMP/CMPI and
nothing flag-modifying may sit between them.
"""

from __future__ import annotations

from .parser import CompileError as _CE, T_int, T_char, T_ptr


class CodegenError(Exception):
    pass


_ARITH = {"+": "ADD", "-": "SUB", "*": "MUL", "&": "AND", "|": "OR",
          "^": "XOR"}


def _align4(n):
    return (n + 3) & ~3


class Codegen:
    def __init__(self, globals_):
        self.globals = globals_ or {}
        self.lines = []
        self.strs = []           # (label, bytes)
        self._strmap = {}
        self._n = 0
        self._scopes = [{}]      # name -> (offset, type); block scoping
        self._used = 4           # frame bytes allocated so far ([FP] holds saved r15)
        self._loops = []         # (break_label, continue_label)

    # ------------------------------------------------------------------ util
    def out(self, line):
        self.lines.append(line)

    def newlabel(self, pre="L"):
        self._n += 1
        return f"L{pre}{self._n}"

    def temp(self):
        off = self._used
        self._used += 4
        return off

    def alloc_local(self, name, t):
        if name in self._scopes[-1]:
            raise CodegenError(f"duplicate local '{name}' in scope")
        off = self._used
        sz = _align4(t["size"])
        if sz > off:
            off = sz            # keep multi-word locals wholly below FP
        self._used = off + sz
        self._scopes[-1][name] = (off, t)
        return off

    def lookup(self, name):
        for sc in reversed(self._scopes):
            if name in sc:
                return sc[name]
        return None

    def emit_load_const(self, reg, v):
        v &= 0xFFFFFFFF
        lo, hi = v & 0xFFFF, (v >> 16) & 0xFFFF
        if v <= 0xFFFF:
            self.out(f"LI {reg}, {lo}")
        elif lo == 0:
            self.out(f"LIH {reg}, {hi}")
        else:
            self.out(f"LI {reg}, {lo}")
            self.out(f"MOV r3, {reg}")
            self.out(f"LI {reg}, 0")
            self.out(f"LIH {reg}, {hi}")
            self.out(f"OR {reg}, {reg}, r3")

    def emit_addr(self, reg, sym):
        """Byte address of a symbol < 0x10000 (all our data lives there)."""
        self.out(f"LI {reg}, LO({sym})")

    # ------------------------------------------------------------ type logic
    def store_insn(self, t):
        if t["k"] == "int" and t.get("size") == 1:
            return "ST.B"
        if t["k"] == "int" and t.get("size") == 2:
            return "ST.H"
        return "ST"

    def load_insn(self, t):
        if t["k"] == "int" and t.get("size") == 1:
            return "LD.B"
        if t["k"] == "int" and t.get("size") == 2:
            return "LD.H"
        return "LD"

    def type_of(self, node):
        k = node["kind"]
        if k == "const":
            return T_int(True)
        if k == "str":
            return T_ptr(T_char())
        if k == "id":
            loc = self.lookup(node["name"])
            if loc is not None:
                return loc[1]
            g = self.globals.get(node["name"])
            if g is None or g.get("type") is None:
                raise CodegenError(f"undefined identifier '{node['name']}'")
            return g["type"]
        if k == "paren":
            return self.type_of(node["expr"])
        if k == "cast":
            return node["type"]
        if k == "unary":
            if node["op"] == "&":
                return T_ptr(self.type_of(node["expr"]))
            if node["op"] == "*":
                inner = self.type_of(node["expr"])
                if inner["k"] != "ptr":
                    raise CodegenError("dereferenced a non-pointer")
                return inner["to"]
            return T_int(True)
        if k == "idx":
            bt = self.type_of(node["base"])
            if bt["k"] == "ptr":
                return bt["to"]
            return bt["elem"]
        if k == "field":
            bt = self.type_of(node["base"])
            if bt["k"] == "ptr":
                bt = bt["to"]
            for nm, _off, ft in bt.get("fields", []):
                if nm == node["name"]:
                    return ft
            raise CodegenError(f"no field '{node['name']}'")
        if k == "bin":
            return T_int(self._is_signed(node["lhs"]) and
                         self._is_signed(node["rhs"]))
        if k == "cond":
            return self.type_of(node["then"])
        if k == "call":
            g = self.globals.get(node["name"])
            if g is None:
                raise CodegenError(f"call to undefined '{node['name']}'")
            return g["type"]["ret"]
        if k == "assign":
            return self.type_of(node["lhs"])
        if k == "postinc":
            return self.type_of(node["expr"])
        if k in ("sizeof", "sizeoftype"):
            return T_int(True)
        raise CodegenError(f"no type for node '{k}'")

    def _is_signed(self, node):
        t = self.type_of(node)
        if t["k"] == "int":
            return t.get("signed", True)
        return False   # pointers and unsigned ints

    # ------------------------------------------------------------ addressing
    def gen_addr(self, node):
        """Compute the byte address of an lvalue into r0."""
        k = node["kind"]
        if k == "id":
            loc = self.lookup(node["name"])
            if loc is not None:
                self.out(f"SUBI r0, r15, {loc[0]}")
            else:
                self.emit_addr("r0", node["name"])
            return
        if k == "paren":
            return self.gen_addr(node["expr"])
        if k == "unary" and node["op"] == "*":
            self.gen_val(node["expr"])
            return
        if k == "field":
            bt = self.type_of(node["base"])
            if bt["k"] == "ptr":
                self.gen_val(node["base"])
                bt = bt["to"]
            else:
                self.gen_addr(node["base"])
            for nm, off, _ft in bt.get("fields", []):
                if nm == node["name"]:
                    self.out(f"ADDI r0, r0, {off}")
                    return
            raise CodegenError(f"no field '{node['name']}'")
        if k == "idx":
            bt = self.type_of(node["base"])
            if bt["k"] == "ptr":
                elem = bt["to"]
                self.gen_val(node["base"])
            else:
                elem = bt["elem"]
                self.gen_addr(node["base"])
            esz = elem["size"]
            tb = self.temp()
            self.out(f"ST r0, r15, -{tb}")
            self.gen_val(node["index"])
            self.out("MOV r1, r0")
            if esz != 1:
                self.out(f"MULI r1, r1, {esz}")
            self.out(f"LD r0, r15, -{tb}")
            self.out("ADD r0, r0, r1")
            return
        raise CodegenError(f"'{k}' is not an lvalue")

    # ---------------------------------------------------------------- values
    def gen_val(self, node):
        k = node["kind"]
        if k == "const":
            self.emit_load_const("r0", node["val"])
            return
        if k == "str":
            self.emit_addr("r0", self._str_for(node["bytes"]))
            return
        if k == "paren":
            self.gen_val(node["expr"])
            return
        if k == "cast":
            self.gen_val(node["expr"])
            t = node["type"]
            if t["k"] == "int" and t.get("size") == 1:
                self.out("ANDI r0, r0, 255")
            return
        if k == "sizeof":
            self.emit_load_const("r0", self.type_of(node["expr"])["size"])
            return
        if k == "sizeoftype":
            self.emit_load_const("r0", node["type"]["size"])
            return
        if k == "id" or k == "field" or k == "idx" or \
                (k == "unary" and node["op"] == "*"):
            self.gen_addr(node)
            t = self.type_of(node)
            if t["k"] != "array":
                self.out(f"{self.load_insn(t)} r0, r0, 0")
            return
        if k == "unary":
            return self.gen_unary(node)
        if k == "bin":
            return self.gen_bin(node)
        if k == "cond":
            return self.gen_cond(node)
        if k == "assign":
            return self.gen_assign(node)
        if k == "postinc":
            return self.gen_postinc(node["op"], node["expr"])
        if k == "call":
            return self.gen_call(node)
        raise CodegenError(f"cannot evaluate node '{k}'")

    def gen_unary(self, node):
        op = node["op"]
        if op == "&":
            self.gen_addr(node["expr"])
            return
        if op == "+":
            self.gen_val(node["expr"])
            return
        if op == "-":
            self.gen_val(node["expr"])
            self.out("MOV r1, r0")
            self.out("LI r0, 0")
            self.out("SUB r0, r0, r1")
            return
        if op == "~":
            self.gen_val(node["expr"])
            self.out("NOT r0, r0")
            return
        if op == "!":
            self.gen_bool_val(node)
            return
        if op in ("++", "--"):
            delta = 1 if op == "++" else -1
            at = self.temp()
            self.gen_addr(node["expr"])
            self.out(f"ST r0, r15, -{at}")
            self.out(f"LD r0, r15, -{at}")
            t = self.type_of(node["expr"])
            self.out(f"{self.load_insn(t)} r0, r0, 0")
            if delta == 1:
                self.out("ADDI r1, r0, 1")
            else:
                self.out("SUBI r1, r0, 1")
            self.out(f"LD r2, r15, -{at}")
            self.out(f"{self.store_insn(t)} r1, r2, 0")
            return                   # result = new value in r0
        raise CodegenError(f"unsupported unary '{op}'")

    def gen_bool_val(self, cond):
        L1 = self.newlabel("bv")
        L2 = self.newlabel("bv")
        self.branch_if_true(cond, L1)
        self.out("LI r0, 0")
        self.out(f"JMP {L2}")
        self.out(f"{L1}:")
        self.out("LI r0, 1")
        self.out(f"{L2}:")

    def gen_bin(self, node):
        op = node["op"]
        if op in ("&&", "||"):
            self.gen_bool_val(node)
            return
        if op in ("==", "!=", "<", ">", "<=", ">="):
            self.gen_bool_val(node)
            return
        if op in ("/", "%"):
            left = self.temp()
            right = self.temp()
            self.gen_val(node["lhs"])
            self.out(f"ST r0, r15, -{left}")
            self.gen_val(node["rhs"])
            self.out(f"ST r0, r15, -{right}")
            self.out(f"LD r0, r15, -{right}")
            self.out("PUSH r0")
            self.out(f"LD r0, r15, -{left}")
            self.out("PUSH r0")
            unsigned = not (self._is_signed(node["lhs"]) and
                            self._is_signed(node["rhs"]))
            u = "u" if unsigned else ""
            self.out(f"CALL __decko_{u}div" if op == "/"
                     else f"CALL __decko_{u}mod")
            self.out("RDSP r2")
            self.out("ADDI r2, r2, 8")
            self.out("WRSP r2")
            return
        mnem = "SHL" if op == "<<" else ("SHR" if op == ">>" else _ARITH[op])
        left = self.temp()
        self.gen_val(node["lhs"])
        self.out(f"ST r0, r15, -{left}")
        self.gen_val(node["rhs"])
        self.out("MOV r1, r0")
        self.out(f"LD r0, r15, -{left}")
        self.out(f"{mnem} r0, r0, r1")

    def gen_cond(self, node):
        Lf = self.newlabel("el")
        Ld = self.newlabel("done")
        self.branch_if_false(node["cond"], Lf)
        self.gen_val(node["then"])
        self.out(f"JMP {Ld}")
        self.out(f"{Lf}:")
        self.gen_val(node["else"])
        self.out(f"{Ld}:")

    def gen_assign(self, node):
        if node["op"] != "=":
            self.gen_compound(node)
            return
        lt = self.type_of(node["lhs"])
        if lt["k"] == "struct":
            self.gen_struct_copy(node["lhs"], node["rhs"])
            return
        at = self.temp()
        self.gen_addr(node["lhs"])
        self.out(f"ST r0, r15, -{at}")
        self.gen_val(node["rhs"])
        self.out(f"LD r1, r15, -{at}")
        self.out(f"{self.store_insn(lt)} r0, r1, 0")

    def gen_compound(self, node):
        op = node["op"]
        baseop = op[:-1]
        lt = self.type_of(node["lhs"])
        if baseop in ("/", "%"):
            # rewrite lhs = lhs op rhs (structless, handles / % and shifts)
            lhs = node["lhs"]
            rhs = node["rhs"]
            tmp = self.temp()
            self.gen_addr(lhs)
            self.out("ST r0, r15, -%d" % self._stash_addr()) if False else None
            self.out(f"ST r0, r15, -{tmp}")
            self.out(f"LD r0, r15, -{tmp}")
            self.out("ST r0, r15, -%d" % self._stash_addr()) if False else None
            repl = {"kind": "assign", "op": "=", "lhs": lhs, "rhs": {
                "kind": "bin", "op": baseop, "lhs": {
                    "kind": "unary", "op": "*",
                    "expr": {"kind": "cast", "type": T_ptr(lt),
                             "expr": {"kind": "id", "name": "_tmp_"}}}}}
            self.gen_assign(repl)
            return
        at = self.temp()
        ot = self.temp()
        self.gen_addr(node["lhs"])
        self.out("MOV r2, r0")
        self.out("ST r2, r15, -%d" % at)
        self.out(f"LD r0, r2, 0")
        self.out(f"ST r0, r15, -{ot}")
        self.gen_val(node["rhs"])
        self.out("MOV r1, r0")
        self.out(f"LD r0, r15, -{ot}")
        if baseop == "<<":
            self.out("SHL r0, r0, r1")
        elif baseop == ">>":
            self.out("SHR r0, r0, r1")
        else:
            self.out(f"{_ARITH[baseop]} r0, r0, r1")
        self.out(f"LD r1, r15, -{at}")
        self.out(f"{self.store_insn(lt)} r0, r1, 0")

    def gen_struct_copy(self, lhs, rhs):
        nw = self.type_of(lhs)["size"] // 4
        ats = self.temp()
        atd = self.temp()
        self.gen_addr(lhs)
        self.out(f"ST r0, r15, -{ats}")
        self.gen_addr(rhs)
        self.out(f"ST r0, r15, -{atd}")
        self.out(f"LD r1, r15, -{ats}")
        self.out(f"LD r2, r15, -{atd}")
        for w in range(nw):
            self.out(f"LD r0, r2, {w * 4}")
            self.out(f"ST r0, r1, {w * 4}")
        self.out("LI r0, 0")

    def gen_postinc(self, op, lv):
        delta = 1 if op == "++" else -1
        at = self.temp()
        ot = self.temp()
        self.gen_addr(lv)
        self.out(f"ST r0, r15, -{at}")
        self.out(f"LD r0, r15, -{at}")
        t = self.type_of(lv)
        self.out(f"{self.load_insn(t)} r0, r0, 0")
        self.out(f"ST r0, r15, -{ot}")
        if delta == 1:
            self.out("ADDI r1, r0, 1")
        else:
            self.out("SUBI r1, r0, 1")
        self.out(f"LD r2, r15, -{at}")
        self.out(f"{self.store_insn(t)} r1, r2, 0")
        self.out(f"LD r0, r15, -{ot}")

    def gen_call(self, node):
        name = node["name"]
        g = self.globals.get(name)
        if g is None or g["type"]["k"] != "func":
            raise CodegenError(f"call to non-function '{name}'")
        for arg in reversed(node["args"]):
            self.gen_val(arg)
            self.out("PUSH r0")
        self.out(f"CALL {name}")
        n = len(node["args"])
        if n:
            self.out("RDSP r2")
            self.out(f"ADDI r2, r2, {4 * n}")
            self.out("WRSP r2")

    # ------------------------------------------------------------ conditions
    def branch_if_true(self, cond, L):
        k = cond["kind"]
        if k == "paren":
            return self.branch_if_true(cond["expr"], L)
        if k == "unary" and cond["op"] == "!":
            return self.branch_if_false(cond["expr"], L)
        if k == "bin" and cond["op"] == "&&":
            Ld = self.newlabel("and")
            self.branch_if_false(cond["lhs"], Ld)
            self.branch_if_true(cond["rhs"], L)
            self.out(f"{Ld}:")
            return
        if k == "bin" and cond["op"] == "||":
            self.branch_if_true(cond["lhs"], L)
            self.branch_if_true(cond["rhs"], L)
            return
        if k == "bin" and cond["op"] in ("==", "!=", "<", ">", "<=", ">=", ">"):
            return self._branch_compare(cond, L, False)
        self.gen_val(cond)
        self.out("CMPI r0, 0")
        self.out(f"BNE r0, r0, {L}")

    def branch_if_false(self, cond, L):
        k = cond["kind"]
        if k == "paren":
            return self.branch_if_false(cond["expr"], L)
        if k == "unary" and cond["op"] == "!":
            return self.branch_if_true(cond["expr"], L)
        if k == "bin" and cond["op"] == "&&":
            self.branch_if_false(cond["lhs"], L)
            self.branch_if_false(cond["rhs"], L)
            return
        if k == "bin" and cond["op"] == "||":
            hold = self.newlabel("orf")
            self.branch_if_true(cond["lhs"], hold)
            self.branch_if_true(cond["rhs"], hold)
            self.out(f"JMP {L}")
            self.out(f"{hold}:")
            return
        if k == "bin" and cond["op"] in ("==", "!=", "<", ">", "<=", ">=", ">"):
            return self._branch_compare(cond, L, True)
        self.gen_val(cond)
        self.out("CMPI r0, 0")
        self.out(f"BEQ r0, r0, {L}")

    def _branch_compare(self, cond, L, invert):
        """Materialise lhs=r0, rhs=r1, then CMP + conditional branches."""
        unsigned = not (self._is_signed(cond["lhs"]) and
                        self._is_signed(cond["rhs"]))
        lts = "BLTU" if unsigned else "BLT"
        ges = "BGEU" if unsigned else "BGE"
        # (op, invert) -> (cmp_a, cmp_b, [branches]) with a=r0(lhs), b=r1(rhs)
        tbl = {
            ("==", False): ("r0", "r1", ["BEQ"]),
            ("!=", False): ("r0", "r1", ["BNE"]),
            ("<", False):  ("r0", "r1", [lts]),
            (">", False):  ("r1", "r0", [lts]),
            ("<=", False): ("r0", "r1", ["BEQ", lts]),
            (">=", False): ("r0", "r1", [ges]),
            ("==", True):  ("r0", "r1", ["BNE"]),
            ("!=", True):  ("r0", "r1", ["BEQ"]),
            ("<", True):   ("r0", "r1", [ges]),
            (">", True):   ("r1", "r0", [ges]),
            ("<=", True):  ("r1", "r0", [lts]),
            (">=", True):  ("r0", "r1", [lts]),
        }
        ca, cb, brs = tbl[(cond["op"], invert)]
        left = self.temp()
        self.gen_val(cond["lhs"])
        self.out(f"ST r0, r15, -{left}")
        self.gen_val(cond["rhs"])
        self.out("MOV r1, r0")
        self.out(f"LD r0, r15, -{left}")
        self.out(f"CMP {ca}, {cb}")
        for b in brs:
            self.out(f"{b} r0, r0, {L}")

    # ------------------------------------------------------------- statements
    def gen_block(self, stmts):
        self._scopes.append({})
        for s in stmts:
            self.gen_stmt(s)
        self._scopes.pop()

    def gen_stmt(self, s):
        k = s["kind"]
        if k == "block":
            self.gen_block(s["stmts"])
            return
        if k == "decl":
            for name, t, init in s["decls"]:
                self.alloc_local(name, t)
                if init is not None:
                    self.gen_val(init)
                    off = self.lookup(name)[0]
                    self.out(f"{self.store_insn(t)} r0, r15, -{off}")
            return
        if k == "expr":
            self.gen_val(s["expr"])
            return
        if k == "if":
            if s.get("else") is not None:
                L_else = self.newlabel("el")
                L_end = self.newlabel("ifend")
                self.branch_if_false(s["cond"], L_else)
                self.gen_stmt(s["then"])
                self.out(f"JMP {L_end}")
                self.out(f"{L_else}:")
                self.gen_stmt(s["else"])
                self.out(f"{L_end}:")
            else:
                L_end = self.newlabel("ifend")
                self.branch_if_false(s["cond"], L_end)
                self.gen_stmt(s["then"])
                self.out(f"{L_end}:")
            return
        if k == "while":
            L_top = self.newlabel("w")
            L_end = self.newlabel("wend")
            self.out(f"{L_top}:")
            self.branch_if_false(s["cond"], L_end)
            self._loops.append((L_end, L_top))
            self.gen_stmt(s["body"])
            self._loops.pop()
            self.out(f"JMP {L_top}")
            self.out(f"{L_end}:")
            return
        if k == "do":
            L_top = self.newlabel("do")
            L_end = self.newlabel("dend")
            self.out(f"{L_top}:")
            self._loops.append((L_end, L_top))
            self.gen_stmt(s["body"])
            self._loops.pop()
            self.branch_if_true(s["cond"], L_top)
            self.out(f"{L_end}:")
            return
        if k == "for":
            self._scopes.append({})
            if s["init"] is not None:
                self.gen_stmt(s["init"])
            L_cond = self.newlabel("for")
            L_end = self.newlabel("fend")
            L_step = self.newlabel("fstep")
            self.out(f"{L_cond}:")
            if s["cond"] is not None:
                self.branch_if_false(s["cond"], L_end)
            self._loops.append((L_end, L_step))
            self.gen_stmt(s["body"])
            self._loops.pop()
            self.out(f"{L_step}:")
            if s["step"] is not None:
                self.gen_val(s["step"])
            self.out(f"JMP {L_cond}")
            self.out(f"{L_end}:")
            self._scopes.pop()
            return
        if k == "return":
            if s["expr"] is not None:
                self.gen_val(s["expr"])
            self.emit_epilogue()
            return
        if k == "break":
            if not self._loops:
                raise CodegenError("break outside loop")
            self.out(f"JMP {self._loops[-1][0]}")
            return
        if k == "continue":
            if not self._loops:
                raise CodegenError("continue outside loop")
            self.out(f"JMP {self._loops[-1][1]}")
            return
        if k == "switch":
            self.gen_switch(s)
            return
        raise CodegenError(f"unknown statement '{k}'")

    def gen_switch(self, s):
        L_end = self.newlabel("swend")
        treg = self.temp()
        self.gen_val(s["expr"])
        self.out(f"ST r0, r15, -{treg}")
        case_lbls = [self.newlabel("case") for _ in s["cases"]]
        for (const, _stmts), Lc in zip(s["cases"], case_lbls):
            self.out(f"LD r0, r15, -{treg}")
            self.emit_load_const("r1", const)
            self.out("CMP r0, r1")
            self.out(f"BEQ r0, r0, {Lc}")
        if s["default"] is not None:
            Ld = self.newlabel("dflt")
            self.out(f"JMP {Ld}")
        else:
            Ld = L_end
            self.out(f"JMP {L_end}")
        self._loops.append((L_end, self._loops[-1][1] if self._loops else L_end))
        for (const, stmts), Lc in zip(s["cases"], case_lbls):
            self.out(f"{Lc}:")
            for st in stmts:
                self.gen_stmt(st)
        if s["default"] is not None:
            self.out(f"{Ld}:")
            for st in s["default"]:
                self.gen_stmt(st)
        self._loops.pop()
        self.out(f"{L_end}:")

    def emit_epilogue(self):
        self.out("MOV r2, r15")
        self.out("WRSP r2")
        self.out("POP r15")
        self.out("RET")

    # ------------------------------------------------------------------ funcs
    def gen_func(self, decl):
        name = decl["name"]
        ftype = decl["type"]
        self._scopes = [{}]
        self._used = 4
        body_start = len(self.lines)
        self.lines.append("")
        self.lines.append(f"; ---- function {name}")
        self.lines.append(f"{name}:")
        self.lines.append("PUSH r15")
        self.lines.append("RDSP r2")
        self.lines.append("MOV r15, r2")
        prologue_end = len(self.lines)
        for i, (pname, pt) in enumerate(ftype["params"]):
            if pname is not None:
                self._scopes[0][pname] = (-(8 + 4 * i), pt)
        self.gen_block(decl["body"]["stmts"])
        self.emit_epilogue()
        frame = self._used
        if frame:
            alloc = ["RDSP r2", f"SUBI r2, r2, {frame}", "WRSP r2"]
            self.lines[prologue_end:prologue_end] = alloc

    # ------------------------------------------------------------------ data
    def _str_for(self, bytes_):
        key = tuple(bytes_)
        lbl = self._strmap.get(key)
        if lbl is None:
            self._n += 1
            lbl = f"LSTR{self._n}"
            self._strmap[key] = lbl
            self.strs.append((lbl, bytes_))
        return lbl

    @staticmethod
    def _byte_rows(values):
        rows, row = [], []
        for v in values:
            row.append(str(v & 0xFF))
            if len(row) == 16:
                rows.append(", ".join(row))
                row = []
        if row:
            rows.append(", ".join(row))
        return rows or ["0"]

    def gen_data(self, decls):
        out_lines = []
        off = 0

        def emit_bytes(vals):
            """Emit .byte rows and pad to a word boundary; track offset."""
            nonlocal off
            if not vals:
                return
            rows = self._byte_rows(vals)
            for r in rows:
                out_lines.append(f".byte {r}")
            off += len(vals)
            pad = (4 - off) % 4
            if pad:
                out_lines.append(".byte " + ", ".join("0" for _ in range(pad)))
                off += pad

        for d in decls:
            if d["kind"] != "vardecl" or d["storage"] == "extern":
                continue
            t = d["type"]
            name = d["name"]
            init = d["init"]
            out_lines.append(f"{name}:")
            size = t["size"]
            if t["k"] == "int" and size == 4:
                v = init["val"] if init is not None and \
                    init["kind"] == "const" else 0
                out_lines.append(f".word {v & 0xFFFFFFFF}")
                off += 4
            elif size > 0:
                vals = []
                if init is not None and init["kind"] == "const" and \
                        t["k"] == "int":
                    z = init["val"] & 0xFFFFFFFF
                    for i in range(size):
                        vals.append((z >> (8 * (i % 4))) & 0xFF if
                                    (z >> (8 * (i % 4))) & 0xFF else 0)
                else:
                    vals = [0] * size
                emit_bytes(vals)
            # size == 0 (void/empty): nothing
        for lbl, bytes_ in self.strs:
            out_lines.append(f"{lbl}:")
            emit_bytes(list(bytes_) + [0])
        return out_lines


def emit_program(decls, globals_):
    cg = Codegen(globals_)
    for d in decls:
        if d["kind"] == "funcdef":
            cg.gen_func(d)
    data = cg.gen_data(decls)
    return cg.lines, data