"""deckc parser: C subset -> AST.

Covers the constructs used by the DeckOS vendors and the deckc runtime:
types int/uint/char/enum/typedef/struct/array/pointer/void/function,
storage static/const/extern, statements (blocks, if, while, do, for,
switch, return, break, continue, expression, local declarations with
initializers), and full expressions including ?, &&, ||, casts, ++/--,
pointer arithmetic, subscript, field access, and variadic calls.

Global symbol references are resolved lazily (by name) at codegen time so
bodies can call functions declared anywhere in the translation unit.
"""

from __future__ import annotations

from .pp import TK

# --------------------------------------------------------------------------
# types
# --------------------------------------------------------------------------

_TYPE_KW = ("char", "short", "int", "long", "void", "unsigned", "signed",
            "const", "static", "struct", "enum", "register")
_DECL_KW = ("char", "short", "int", "long", "void", "unsigned", "signed",
            "const", "static")


def T_int(signed=True):
    return {"k": "int", "signed": signed, "size": 4}


def T_char():
    return {"k": "int", "signed": False, "size": 1}


def T_void():
    return {"k": "void", "size": 0}


def T_ptr(to):
    return {"k": "ptr", "size": 4, "to": to}


def T_array(elem, count):
    return {"k": "array", "elem": elem, "count": count,
            "size": elem["size"] * count}


def T_func(ret, params, variadic=False):
    return {"k": "func", "ret": ret, "params": params, "variadic": variadic}


def T_struct(name, fields, size):
    return {"k": "struct", "name": name, "fields": fields, "size": size}


def is_ptr_t(t):
    return t["k"] == "ptr"


class CompileError(Exception):
    pass


def layout_struct(fields):
    """fields: list of (name, type). Returns (list[(name,off,type)], size)."""
    off = 0
    laid = []
    for name, ft in fields:
        off = (off + 3) & ~3
        laid.append((name, off, ft))
        off += ft["size"]
    off = (off + 3) & ~3
    return laid, off


class Tok:
    __slots__ = ("t", "v", "raw")

    def __init__(self, t, v, raw=None):
        self.t = t
        self.v = v
        self.raw = raw if raw is not None else v


class Parser:
    def __init__(self, toks):
        self.toks = toks
        self.pos = 0
        self.typedefs = {}
        self.enum_consts = {}
        self.globals = {}
        self.structs = {}
        self.decls = []

    # ---------- token helpers ----------
    def peek(self, k=0):
        i = self.pos + k
        return self.toks[i] if i < len(self.toks) else None

    def next(self):
        t = self.peek()
        if t is None:
            raise CompileError("unexpected end of input")
        self.pos += 1
        return t

    def at(self, v):
        t = self.peek()
        return t is not None and t.v == v

    def at_punct(self, v):
        t = self.peek()
        return t is not None and t.t == TK.PUNCT and t.v == v

    def at_id(self, v):
        t = self.peek()
        return t is not None and t.t == TK.ID and t.v == v

    def eat(self, v):
        if self.at(v):
            self.pos += 1
            return True
        return False

    def expect(self, v):
        if not self.eat(v):
            raise CompileError(f"expected '{v}', got "
                               f"{(self.peek() and self.peek().v)!r}")

    def err(self, msg):
        raise CompileError(msg)

    # ---------- types ----------
    def parse_type(self, allow_typedef=True):
        signed = True
        base = None
        consumed = True
        while True:
            t = self.peek()
            if t is None:
                break
            if t.t == TK.ID and t.v in ("unsigned", "signed"):
                self.next()
                signed = t.v == "signed"
                continue
            if t.t == TK.ID and t.v == "const":
                self.next()
                continue
            if t.t == TK.ID and t.v == "volatile":
                self.next()
                continue
            if t.t == TK.ID and t.v in ("char",):
                self.next()
                base = {"k": "int", "signed": signed, "size": 1}
                break
            if t.t == TK.ID and t.v in ("short", "int", "long"):
                self.next()
                base = {"k": "int", "signed": signed, "size": 4}
                break
            if t.t == TK.ID and t.v == "void":
                self.next()
                base = T_void()
                break
            if t.t == TK.ID and t.v == "struct":
                self.next()
                base = self.parse_struct_body()
                break
            if t.t == TK.ID and t.v == "enum":
                self.next()
                base = self.parse_enum_body()
                break
            if allow_typedef and t.t == TK.ID and t.v in self.typedefs:
                base = self.typedefs[self.next().v]
                break
            if t.t == TK.ID and t.v in ("unsigned", "signed", "const", "struct",
                                        "enum"):
                continue
            consumed = False
            break
        if base is None:
            raise CompileError(f"expected a type, got "
                               f"{(t is not None and t.v)!r}")
        return base

    def parse_struct_body(self):
        name = None
        if self.peek() and self.peek().t == TK.ID and not self.at("{"):
            name = self.next().v
        if self.at("{"):
            self.next()
            raw = []
            while not self.at("}"):
                ft = self.parse_type()
                while True:
                    d = self.parse_declarator(ft)
                    raw.append((d["name"], d["type"]))
                    if not self.eat(","):
                        break
                self.expect(";")
            self.expect("}")
            laid, size = layout_struct(raw)
            st = T_struct(name, laid, size)
            if name:
                self.structs[name] = st
            return st
        st = self.structs.get(name)
        if st is None:
            st = T_struct(name, [], 0)
            self.structs[name] = st
        return st

    def parse_enum_body(self):
        if self.at("{"):
            self.next()
            val = 0
            while not self.at("}"):
                t = self.next()
                if t.t != TK.ID:
                    self.err("enum needs an identifier")
                if self.eat("="):
                    val = self.parse_const_expr()
                self.enum_consts[t.v] = val
                val += 1
                if not self.eat(","):
                    break
            self.expect("}")
        return {"k": "int", "signed": True, "size": 4}

    def parse_const_expr(self):
        return self._eval_const(self.parse_expr())

    def _eval_const(self, n):
        k = n["kind"]
        if k == "const":
            return n["val"]
        if k == "id":
            v = self.enum_consts.get(n["name"])
            if v is None:
                self.err(f"'{n['name']}' is not a constant")
            return v
        if k == "bin":
            l = self._eval_const(n["lhs"])
            r = self._eval_const(n["rhs"])
            o = n["op"]
            return {
                "+": lambda: l + r, "-": lambda: l - r, "*": lambda: l * r,
                "/": lambda: l // r if r else 0,
                "%": lambda: l % r if r else 0,
                "<<": lambda: l << r, ">>": lambda: l >> r,
                "&": lambda: l & r, "|": lambda: l | r,
                "^": lambda: l ^ r,
                "==": lambda: int(l == r), "!=": lambda: int(l != r),
                "<": lambda: int(l < r), ">": lambda: int(l > r),
                "<=": lambda: int(l <= r), ">=": lambda: int(l >= r),
                "&&": lambda: int(bool(l) and bool(r)),
                "||": lambda: int(bool(l) or bool(r)),
            }[o]()
        if k == "unary":
            v = self._eval_const(n["expr"])
            if n["op"] == "-":
                return -v
            if n["op"] == "!":
                return int(not v)
            if n["op"] == "~":
                return (~v) & 0xFFFFFFFF
        self.err("not a constant expression")

    def parse_declarator(self, base):
        stars = 0
        while self.at_punct("*"):
            self.next()
            stars += 1
        t = base
        for _ in range(stars):
            t = T_ptr(t)
        return self.parse_direct_declarator(t)

    def parse_direct_declarator(self, base):
        t = base
        name = None
        if self.peek() and self.peek().t == TK.ID:
            name = self.next().v
        while self.at("["):
            self.next()
            count = 1
            if not self.at("]"):
                count = self.parse_const_expr()
            self.expect("]")
            t = T_array(t, count)
        return {"name": name, "type": t}

    def parse_params(self, ret):
        self.expect("(")
        params = []
        variadic = False
        if not self.at(")"):
            while True:
                if self.at("..."):
                    self.next()
                    variadic = True
                    break
                pt = self.parse_type()
                pd = self.parse_declarator(pt)
                t = pd["type"]
                if t["k"] == "void":
                    params = []
                    break
                if t["k"] == "array":
                    t = T_ptr(t["elem"])
                params.append((pd["name"], t))
                if not self.eat(","):
                    break
        self.expect(")")
        return T_func(ret, params, variadic)

    # ---------- top level ----------
    def parse(self):
        while self.pos < len(self.toks):
            self.parse_toplevel()
        return self.decls

    def parse_toplevel(self):
        storage = "auto"
        while self.at_id("static") or self.at_id("extern"):
            if self.at_id("static"):
                storage = "static"
            self.next()
        if self.at_id("typedef"):
            self.next()
            base = self.parse_type()
            while True:
                d = self.parse_declarator(base)
                self.typedefs[d["name"]] = d["type"]
                if not self.eat(","):
                    break
            self.expect(";")
            return
        base = self.parse_type()
        decl = self.parse_declarator(base)
        name = decl["name"]
        if self.at("("):
            ftype = self.parse_params(decl["type"])
            self.globals[name] = {"type": ftype, "defined": False,
                                  "storage": storage}
            if self.at("{"):
                body = self.parse_block()
                self.globals[name]["defined"] = True
                self.decls.append({"kind": "funcdef", "name": name,
                                   "type": ftype, "body": body})
            else:
                self.expect(";")
                self.decls.append({"kind": "funcdecl", "name": name,
                                   "type": ftype})
            return
        if self.at("("):
            self.err("function declarators must follow the name")
        self.globals[name] = {"type": decl["type"], "defined": True,
                              "storage": storage}
        init = None
        if self.eat("="):
            init = self.parse_global_init()
        self.expect(";")
        self.decls.append({"kind": "vardecl", "name": name,
                           "type": decl["type"], "init": init,
                           "storage": storage})

    def parse_global_init(self):
        return self.parse_expr()

    # ---------- statements ----------
    def parse_block(self):
        self.expect("{")
        stmts = []
        while not self.at("}"):
            stmts.append(self.parse_statement())
        self.expect("}")
        return {"kind": "block", "stmts": stmts}

    def parse_statement(self):
        t = self.peek()
        if t is None:
            self.err("unexpected end of input in statement")
        if t.v == "{":
            return self.parse_block()
        if t.t == TK.ID and t.v in _DECL_KW:
            return self.parse_local_decl()
        if t.t == TK.ID and t.v in self.typedefs:
            # typedef name starting a statement: declaration iff next token
            # begins a declarator (identifier, '*' pointer, or '[' array).
            nxt = self.peek(1)
            if nxt is not None and (
                    nxt.t == TK.ID or (nxt.t == TK.PUNCT and nxt.v in ("*", "["))):
                return self.parse_local_decl()
        return self.parse_statement_tail()

    def parse_local_decl(self):
        base = self.parse_type()
        decls = []
        while True:
            d = self.parse_declarator(base)
            init = None
            if self.eat("="):
                init = self.parse_expr()
            decls.append((d["name"], d["type"], init))
            if not self.eat(","):
                break
        self.expect(";")
        return {"kind": "decl", "decls": decls}

    def parse_statement_tail(self):
        if self.peek() is None:
            self.err("expected a statement")
        t = self.peek()
        v = t.v
        if v == "if":
            self.next()
            self.expect("(")
            c = self.parse_expr()
            self.expect(")")
            a = self.parse_statement()
            b = None
            if self.at_id("else"):
                self.next()
                b = self.parse_statement()
            return {"kind": "if", "cond": c, "then": a, "else": b}
        if v == "while":
            self.next()
            self.expect("(")
            c = self.parse_expr()
            self.expect(")")
            body = self.parse_statement()
            return {"kind": "while", "cond": c, "body": body}
        if v == "do":
            self.next()
            body = self.parse_statement()
            if not self.at_id("while"):
                self.err("do needs while")
            self.next()
            self.expect("(")
            c = self.parse_expr()
            self.expect(")")
            self.expect(";")
            return {"kind": "do", "body": body, "cond": c}
        if v == "for":
            self.next()
            self.expect("(")
            init = None
            if self.at(";"):
                self.next()
            elif self.peek().t == TK.ID and self.peek().v in _DECL_KW:
                init = self.parse_local_decl()
            else:
                e = self.parse_expr()
                self.expect(";")
                init = {"kind": "expr", "expr": e}
            cond = None
            if not self.at(";"):
                cond = self.parse_expr()
            self.expect(";")
            step = None
            if not self.at(")"):
                step = self.parse_expr()
            self.expect(")")
            body = self.parse_statement()
            return {"kind": "for", "init": init, "cond": cond,
                    "step": step, "body": body}
        if v == "return":
            self.next()
            if self.at(";"):
                self.next()
                return {"kind": "return", "expr": None}
            e = self.parse_expr()
            self.expect(";")
            return {"kind": "return", "expr": e}
        if v == "break":
            self.next()
            self.expect(";")
            return {"kind": "break"}
        if v == "continue":
            self.next()
            self.expect(";")
            return {"kind": "continue"}
        if v == "switch":
            self.next()
            self.expect("(")
            e = self.parse_expr()
            self.expect(")")
            return self.parse_switch(e)
        if v in ("case", "default", "else"):
            self.err(f"'{v}' outside its context")
        e = self.parse_expr()
        self.expect(";")
        return {"kind": "expr", "expr": e}

    def parse_switch(self, expr):
        self.expect("{")
        cases = []
        default = None
        while not self.at("}"):
            if self.at_id("case"):
                self.next()
                const = self.parse_const_expr()
                self.expect(":")
                cases.append((const, self._case_stmts()))
            elif self.at_id("default"):
                self.next()
                self.expect(":")
                default = self._case_stmts()
            else:
                default = self._case_stmts()
        self.expect("}")
        return {"kind": "switch", "expr": expr, "cases": cases,
                "default": default}

    def _case_stmts(self):
        stmts = []
        while not (self.at("}") or self.at_id("case") or self.at_id("default")):
            stmts.append(self.parse_statement())
        return stmts

    # ---------- expressions ----------
    def parse_expr(self):
        return self.parse_assign()

    def parse_assign(self):
        l = self.parse_cond()
        if self.at_punct("=") or (
                self.peek() is not None and self.peek().t == TK.PUNCT and
                self.peek().v in ("+=", "-=", "*=", "/=", "%=", "&=", "|=",
                                  "^=", "<<=", ">>=")):
            op = self.next().v
            r = self.parse_assign()
            l = {"kind": "assign", "op": op, "lhs": l, "rhs": r}
        return l

    def parse_cond(self):
        c = self.parse_binary(0)
        if self.at("?"):
            self.next()
            a = self.parse_expr()
            self.expect(":")
            b = self.parse_cond()
            return {"kind": "cond", "cond": c, "then": a, "else": b}
        return c

    _LEVELS = [
        ("||",), ("&&",), ("|",), ("^",), ("&",), ("==", "!="),
        ("<", ">", "<=", ">="), ("<<", ">>"), ("+", "-"), ("*", "/", "%"),
    ]

    def parse_binary(self, level):
        if level >= len(self._LEVELS):
            return self.parse_unary()
        l = self.parse_binary(level + 1)
        while True:
            t = self.peek()
            if t is None or t.t != TK.PUNCT or t.v not in self._LEVELS[level]:
                break
            self.next()
            r = self.parse_binary(level + 1)
            l = {"kind": "bin", "op": t.v, "lhs": l, "rhs": r}
        return l

    def parse_unary(self):
        t = self.peek()
        if t is not None and t.t == TK.PUNCT and t.v in (
                "*", "&", "-", "~", "!", "+", "++", "--"):
            self.next()
            e = self.parse_unary()
            if t.v in ("++", "--"):
                return {"kind": "unary", "op": t.v, "prefix": True, "expr": e}
            return {"kind": "unary", "op": t.v, "expr": e}
        if t is not None and t.t == TK.ID and t.v == "sizeof":
            self.next()
            if self.at("("):
                save = self.pos
                self.next()
                if self._looks_like_type():
                    ty = self.parse_type()
                    while self.at_punct("*"):
                        self.next()
                        ty = T_ptr(ty)
                    self.expect(")")
                    return {"kind": "sizeoftype", "type": ty}
                self.pos = save
                e = self.parse_unary()
                return {"kind": "sizeof", "expr": e}
            e = self.parse_unary()
            return {"kind": "sizeof", "expr": e}
        if self.at("("):
            save = self.pos
            self.next()
            if self._looks_like_type():
                ty = self.parse_type()
                while self.at_punct("*"):
                    self.next()
                    ty = T_ptr(ty)
                self.expect(")")
                return {"kind": "cast", "type": ty, "expr": self.parse_unary()}
            self.pos = save
        return self.parse_postfix()

    def _looks_like_type(self):
        save = self.pos
        try:
            self.parse_type()
            while self.at_punct("*"):
                self.next()
            nxt = self.peek()
            return nxt is None or nxt.v == ")"
        except CompileError:
            return False
        finally:
            self.pos = save

    def parse_postfix(self):
        e = self.parse_primary()
        while True:
            t = self.peek()
            if t is None:
                break
            if t.t == TK.PUNCT and t.v == "[":
                self.next()
                idx = self.parse_expr()
                self.expect("]")
                e = {"kind": "idx", "base": e, "index": idx}
            elif t.t == TK.PUNCT and t.v == ".":
                self.next()
                f = self.next()
                if f.t != TK.ID:
                    self.err("expected field name")
                e = {"kind": "field", "base": e, "name": f.v}
            elif t.t == TK.PUNCT and t.v == "->":
                self.next()
                f = self.next()
                if f.t != TK.ID:
                    self.err("expected field name")
                e = {"kind": "field",
                     "base": {"kind": "unary", "op": "*", "expr": e},
                     "name": f.v}
            elif t.t == TK.PUNCT and t.v == "(":
                self.next()
                args = []
                if not self.at(")"):
                    while True:
                        args.append(self.parse_assign())
                        if not self.eat(","):
                            break
                self.expect(")")
                if e["kind"] != "id":
                    self.err("only direct function calls are supported")
                e = {"kind": "call", "name": e["name"], "args": args}
            elif t.t == TK.PUNCT and t.v in ("++", "--"):
                self.next()
                e = {"kind": "postinc", "op": t.v, "expr": e}
            else:
                break
        return e

    def parse_primary(self):
        t = self.next()
        if t.t == TK.NUM:
            return {"kind": "const", "val": self._num(t.v)}
        if t.t == TK.CHAR:
            return {"kind": "const", "val": self._char(t.v)}
        if t.t == TK.STR:
            return {"kind": "str", "bytes": self._str(t.v)}
        if t.t == TK.ID:
            if t.v in self.enum_consts:
                return {"kind": "const", "val": self.enum_consts[t.v]}
            if t.v == "true":
                return {"kind": "const", "val": 1}
            if t.v == "false":
                return {"kind": "const", "val": 0}
            return {"kind": "id", "name": t.v}
        if t.t == TK.PUNCT and t.v == "(":
            e = self.parse_expr()
            self.expect(")")
            return {"kind": "paren", "expr": e}
        raise CompileError(f"unexpected token {t.v!r} in expression")

    @staticmethod
    def _num(v):
        neg = v[0] == "-"
        if neg:
            v = v[1:]
        if v[:2].lower() == "0x":
            return int(v[2:], 16) if v[2:] else 0
        if v[:2].lower() == "0b":
            return int(v[2:], 2) if v[2:] else 0
        return int(v, 10) if v else 0

    @staticmethod
    def _char(lit):
        s = lit[1:-1]
        if len(s) == 1:
            return ord(s)
        return {"n": 10, "r": 13, "t": 9, "0": 0, "\\": 92,
                "'": 39, '"': 34}.get(s[1:] if s[:1] == "\\" else s, 0)

    @staticmethod
    def _str(lit):
        s = lit[1:-1]
        out = []
        i = 0
        n = len(s)
        esc = {"n": 10, "r": 13, "t": 9, "a": 7, "b": 8, "f": 12, "0": 0,
               "\\": 92, '"': 34, "'": 39}
        while i < n:
            c = s[i]
            if c != "\\":
                out.append(ord(c))
                i += 1
                continue
            i += 1
            if i >= n:
                break
            e = s[i]
            if e in "01234567":
                octs = ""
                while i < n and s[i] in "01234567" and len(octs) < 3:
                    octs += s[i]
                    i += 1
                out.append(int(octs, 8))
            elif e in esc:
                out.append(esc[e])
                i += 1
            elif e == "x":
                i += 1
                hexs = ""
                while i < n and s[i] in "0123456789abcdefABCDEF" and len(hexs) < 2:
                    hexs += s[i]
                    i += 1
                out.append(int(hexs, 16) if hexs else 0)
            else:
                out.append(ord(e))
                i += 1
        return out


def parse_tokens(toks):
    p = Parser([
        t if isinstance(t, Tok) else Tok(t["t"], t["v"], t.get("raw", t["v"]))
        for t in toks
    ])
    return p.parse(), p.globals, p.typedefs, p.enum_consts, p.structs