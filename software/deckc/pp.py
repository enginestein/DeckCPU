"""Hyper-minimal C preprocessor + tokenizer for deckc.

Handles the subset the DeckOS vendors actually use:
  - // and /* */ comment stripping
  - #include <x> and #include "x" (path search, include-once by realpath)
  - #define object-like and simple function-like macros (no # / ##)
  - #undef
  - #if/#ifdef/#ifndef/#elif/#else/#endif with a small constant-expression
    evaluator (integers, !, comparisons, ==/!=, &&, ||, defined())
  - #pragma once, #error
  - __attribute__((...)) swallowing

Input/output are C token streams. Tokens are dicts:
  {'t': 'ID'|'NUM'|'CHAR'|'STR'|'PUNCT', 'v': raw text, 'raw': raw text}
with NEWLINE markers during directive scanning.
"""

from __future__ import annotations

import os
import re

TK = type("TK", (), {"ID": "ID", "NUM": "NUM", "CHAR": "CHAR",
                     "STR": "STR", "PUNCT": "PUNCT", "NEW": "NEW"})

PUNCTS = ["...", "<<=", ">>=", "&&", "||", "++", "--", "+=", "-=", "*=", "/=", "%=",
          "&=", "|=", "^=", "==", "!=", "<=", ">=", "->", "<<", ">>",
          "(", ")", "{", "}", "[", "]", ";", ",", ".", ":", "?", "~", "+",
          "-", "*", "/", "%", "&", "|", "^", "<", ">", "=", "!", "#"]
PUNCT_SORTED = sorted(PUNCTS, key=len, reverse=True)

_RE_TOK = re.compile(
    r'"(?:\\.|[^"\\])*"'
    r"|'(?:\\.|[^'\\])*'"
    r"|0[xX][0-9a-fA-F]+|0[bB][01]+|\d+"
    r"|[A-Za-z_][A-Za-z0-9_]*"
    r"|" + "|".join(re.escape(p) for p in PUNCT_SORTED),
)


def tokenize(text: str):
    """C token stream with NEWLINE markers (for directive scanning)."""
    toks = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c in " \t\r":
            i += 1
            continue
        if c == "\n":
            toks.append({"t": TK.NEW, "v": "\n", "raw": "\n"})
            i += 1
            continue
        if text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        if text.startswith("/*", i):
            j = text.find("*/", i + 2)
            if j < 0:
                raise ValueError("unterminated block comment")
            i = j + 2
            continue
        m = _RE_TOK.match(text, i)
        if not m:
            raise ValueError(f"unexpected character {c!r} at offset {i}")
        val = m.group(0)
        if val[0] in "\"'":
            toks.append({"t": TK.STR if val[0] == '"' else TK.CHAR,
                         "v": val, "raw": val})
        elif val[0].isdigit():
            toks.append({"t": TK.NUM, "v": val, "raw": val})
        elif val[0].isalpha() or val[0] == "_":
            toks.append({"t": TK.ID, "v": val, "raw": val})
        else:
            toks.append({"t": TK.PUNCT, "v": val, "raw": val})
        i = m.end()
    return toks


def _line(toks):
    """Split a token stream into [[tokens...], ...] by NEWLINE markers."""
    lines, cur = [], []
    for t in toks:
        if t["t"] == TK.NEW:
            lines.append(cur)
            cur = []
        else:
            cur.append(t)
    if cur:
        lines.append(cur)
    return lines


class Macro:
    __slots__ = ("params", "body")

    def __init__(self, params, body):
        self.params = params      # list of names for function-like, None object-like
        self.body = body          # list of replacement tokens


def _strip_attr(toks):
    """Remove __attribute__ (( ... )) groups (with possible nesting)."""
    out, i, n = [], 0, len(toks)
    while i < n:
        t = toks[i]
        if t["v"] == "__attribute__":
            j = i + 1
            if j < n and toks[j]["v"] == "(":
                depth = 0
                while j < n:
                    if toks[j]["v"] == "(":
                        depth += 1
                    elif toks[j]["v"] == ")":
                        depth -= 1
                        if depth == 0:
                            break
                    j += 1
                i = j + 1
                continue
        out.append(t)
        i += 1
    return out


class Preprocessor:
    def __init__(self, include_dirs):
        self.include_dirs = [os.path.abspath(d) for d in include_dirs]
        self.macros = {}
        self._once = set()
        self._base = ""

    # ---- macro helpers ----
    def _define(self, toks):
        if not toks:
            return
        name = toks[0]["v"]
        rest = toks[1:]
        params = None
        if rest and rest[0]["v"] == "(":
            depth, j = 1, 1
            params, cur = [], []
            while j < len(rest):
                tv = rest[j]["v"]
                if tv == "," and depth == 1:
                    params.append(cur[0]["v"] if cur else "")
                    cur = []
                elif tv == "(":
                    depth += 1
                elif tv == ")":
                    depth -= 1
                    if depth == 0:
                        break
                else:
                    cur.append(rest[j])
                j += 1
            if cur:
                params.append(cur[0]["v"] if cur else "")
            body = rest[j + 1:]
        else:
            body = rest
        self.macros[name] = Macro(params, body)

    def _substitute(self, toks, pname, arg):
        arg = [dict(a) for a in arg]
        out = []
        for t in toks:
            if t["t"] == TK.ID and t["v"] == pname:
                out.extend(arg)
            else:
                out.append(t)
        return out

    def _split_args(self, toks):
        args, cur, depth = [], [], 0
        for t in toks:
            v = t["v"]
            if v == "(":
                depth += 1
            elif v == ")":
                depth -= 1
            if v == "," and depth == 0:
                args.append(cur)
                cur = []
            else:
                cur.append(t)
        if cur:
            args.append(cur)
        return args

    def _expand_macros(self, toks):
        toks = [dict(t) for t in toks]
        for _ in range(8):
            changed = False
            out, i, n = [], 0, len(toks)
            while i < n:
                t = toks[i]
                m = None
                if t["t"] == TK.ID:
                    m = self.macros.get(t["v"])
                if m is None:
                    out.append(t)
                    i += 1
                    continue
                changed = True
                if m.params is None:
                    out.extend(dict(x) for x in m.body)
                    i += 1
                    continue
                j = i + 1
                if j < n and toks[j]["v"] == "(":
                    depth, k = 0, j
                    while k < n:
                        if toks[k]["v"] == "(":
                            depth += 1
                        elif toks[k]["v"] == ")":
                            depth -= 1
                            if depth == 0:
                                break
                        k += 1
                    args = self._split_args(toks[j + 1:k])
                    if len(args) == len(m.params):
                        body = m.body
                        for pname, ap in zip(m.params, args):
                            body = self._substitute(body, pname, ap)
                        out.extend(body)
                        i = k + 1
                        continue
                out.append(t)
                i += 1
            toks = out
            if not changed:
                break
        return toks

    # ---- #if evaluation ----
    def _eval_if(self, cond_toks) -> int:
        cond = " ".join(t["v"] for t in cond_toks)
        cond = re.sub(r"\bdefined\s*\(\s*(\w+)\s*\)",
                      lambda m: "1" if m.group(1) in self.macros else "0", cond)
        for name in list(self.macros):
            m = self.macros[name]
            while m and m.params is None and m.body:
                b = [t for t in m.body if t["t"] in (TK.NUM, TK.PUNCT)]
                val = re.sub(r"\s*defined\b.*$", "", " ".join(x["v"] for x in b))
                cond = cond.replace(name, val)
                break
        cond = re.sub(r"\b[A-Za-z_]\w*\b", "0", cond)
        cond = cond.replace("&&", " and ").replace("||", " or ")
        try:
            return int(eval(cond, {}, {}))  # noqa: S307 - tokenized ints/ops only
        except Exception:
            return 0

    # ---- include resolution ----
    def _resolve_include(self, target, base_dir):
        raw = target[1:-1] if target[:1] in ('"', "<") else target
        cands = []
        if base_dir:
            cands.append(os.path.join(base_dir, raw))
        for d in self.include_dirs:
            cands.append(os.path.join(d, raw))
        for c in cands:
            if os.path.isfile(c):
                return os.path.abspath(c)
        return None

    def define(self, name, value="1"):
        self.macros[name] = Macro(None, [{"t": TK.NUM, "v": str(value), "raw": str(value)}])

    # ---- file driver ----
    def process_file(self, path):
        ap = os.path.abspath(path)
        if ap in self._once:
            return []
        self._once.add(ap)
        with open(ap, "r", encoding="utf-8") as fh:
            text = fh.read()
        return self.process_text(text, os.path.dirname(ap))

    def process_text(self, text, base_dir=""):
        toks = tokenize(text)
        out = []
        cond_stack = []               # (parent_active, this_active)
        active = True
        lines = _line(toks)
        i = 0
        while i < len(lines):
            line = lines[i]
            if line and line[0]["v"] == "#":
                cmd = line[1]["v"] if len(line) > 1 else ""
                if cmd == "include":
                    if active and len(line) > 2:
                        target = line[2]["v"]
                        if line[2]["t"] != TK.STR:
                            target = "".join(
                                t["v"] for t in line[2:])
                        resolved = self._resolve_include(target, base_dir)
                        if resolved is None:
                            raise ValueError(f"include not found: {line[2]['v']}")
                        out.extend(self.process_file(resolved))
                elif cmd == "define":
                    if active:
                        self._define(line[2:])
                elif cmd == "undef":
                    if active and len(line) > 2:
                        self.macros.pop(line[2]["v"], None)
                elif cmd == "ifdef":
                    cond_stack.append((active, active and line[2]["v"] in self.macros))
                    active = cond_stack[-1][1]
                elif cmd == "ifndef":
                    cond_stack.append((active, active and line[2]["v"] not in self.macros))
                    active = cond_stack[-1][1]
                elif cmd == "if":
                    v = int(bool(active)) and self._eval_if(line[2:])
                    cond_stack.append((active, bool(v)))
                    active = cond_stack[-1][1]
                elif cmd == "elif":
                    if cond_stack:
                        parent, was = cond_stack[-1]
                        take = parent and not was and bool(self._eval_if(line[2:]))
                        cond_stack[-1] = (parent, take)
                        active = take
                elif cmd == "else":
                    if cond_stack:
                        parent, was = cond_stack[-1]
                        cond_stack[-1] = (parent, parent and not was)
                        active = cond_stack[-1][1]
                elif cmd == "endif":
                    if cond_stack:
                        parent, _ = cond_stack.pop()
                        active = parent
                elif cmd == "pragma":
                    pass            # include-once handled at file level
                elif cmd == "error":
                    if active:
                        raise ValueError("#error directive")
                i += 1
                continue
            if active:
                out.extend(self._expand_macros(line))
            i += 1
        return _strip_attr(out)