#!/usr/bin/env python3
r"""Code keys exist in their table's catalog (check 5 of check-catalogs.py).

Usage: python3 -I scripts/l10n/code_keys.py --self-test
       (the check itself runs from check-catalogs.py; --report-unused is an option there)

A key the code looks up but its table's catalog lacks shows the code's English literal as the
fallback, so in English nothing looks wrong; every translation of it is lost, though. That's
what a ' vs ’ or "..." vs "…" drift between the code and the catalog does.

What it reads: every *.swift under App/ and Extensions/ (not Tests/), with a small Swift lexer
(comments, "…", multi-line strings, raw #"…"#, escapes, `\(…)` interpolation, #if os(…)).
The extracted forms (the key must be a lone string literal, followed by `,` or `)`):
  - String(localized: "…" [, defaultValue:] [, table: "T"] [, bundle:] …),
    AttributedString(localized: …), LocalizedStringResource("…" [, table: "T"] …),
    NSLocalizedString("…", tableName: "T" …)
  - Text("…" [, tableName: "T"] [, bundle:] …); never Text(verbatim:)
  - the SwiftUI views and modifiers in LSK_TYPES / LSK_MODIFIERS, whose first unlabeled
    parameter is a LocalizedStringKey: Button("…"), Toggle("…", isOn:), .help("…"), …
A ternary of literals in those positions (`Button(sel ? "Done" : "Select")`, `Text(a ? "A" : "B")`,
nested ones too; a branch that is a variable is skipped) counts both literals as keys, as Xcode
extracts both. String(localized:) and the other always-localized forms take none.
Interpolations become format specifiers the way Xcode's extractor makes them (String → %@,
Int → %lld, a literal 1.5 → %lf, `specifier: "…"` as given; `%` in the text → `%%`). The type
of `\(x)` comes from a conservative same-file lookup that only trusts %@ and %lld; any other
type, or one it isn't certain of, makes that slot match any specifier. An empty key "" is skipped.
The table is `table:`/`tableName:`, else Localizable; the catalog is <table>.xcstrings in a
source dir of each application/app-extension target in project.yml that compiles the file
(code under `#if os(…)` only for that platform's targets). App/Shared code is compiled into
both apps, so its default-table keys must be in both apps' Localizable.xcstrings.

Not checked, reported as "unresolved" (info): a key that isn't a lone literal (a variable, a
`+` of literals, a ternary inside String(localized:) & co., a `+` branch of a ternary), a table
that isn't a literal, a bundle: that isn't the target's own (`.main`, `Bundle.main`, `Bundle(for: X.self)`, `.forClass(X.self)`, `bundle`, `X.bundle`).

A call that only looks like a key (a custom `.help(_ s: String)`, an enum named Menu) opts out
with the marker `// l10n-lint: not-a-key` followed by a reason, e.g.
`// l10n-lint: not-a-key — URL scheme, not UI text`, at the end of the call's line (any line from
the call to its key), or starting the comment line just above it. A marker with no reason isn't
honoured: the key is still checked and the marker gets a warning.

A file the lexer can't read is skipped with a warning, never an error or a crash.

A key missing from its catalog is an error unless scripts/l10n/code-keys-baseline.txt lists it
as `table<TAB>key<TAB>file` (key escaped: \n, \t, \\; an untyped slot shows as %?). A listed
entry with no miss is a warning: delete it. The baseline only shrinks.
"""

import json
import os
import re
import sys
import tempfile

SCAN_DIRS = ("App", "Extensions")
BASELINE = os.path.join("scripts", "l10n", "code-keys-baseline.txt")
DEFAULT_TABLE = "Localizable"
TARGET_TYPES = {"application", "app-extension"}
PLATFORMS = ("macOS", "iOS")

# SwiftUI initializers whose first unlabeled parameter is a LocalizedStringKey (when it gets a
# literal: the StringProtocol overloads are @_disfavoredOverload).
LSK_TYPES = {
    "Button", "Toggle", "Picker", "TextField", "SecureField", "Label", "Section", "Menu",
    "DisclosureGroup", "TableColumn", "ContentUnavailableView", "LabeledContent", "Link",
    "NavigationLink", "Stepper", "ProgressView", "GroupBox", "ControlGroup", "Tab", "Window",
    "WindowGroup", "CommandMenu",
}
LSK_MODIFIERS = {
    "navigationTitle", "navigationSubtitle", "help", "accessibilityLabel", "accessibilityHint",
    "accessibilityValue", "alert", "confirmationDialog",
}
# Forms that are always localized: a first argument that isn't a lone literal is "unresolved".
#   name: (first argument label, table label)
LOCALIZED_CALLS = {
    "String": ("localized", "table"),
    "AttributedString": ("localized", "table"),
    "LocalizedStringResource": (None, "table"),
    "NSLocalizedString": (None, "tableName"),
    "Text": (None, "tableName"),
}

ANY_SPEC = (r"%(?:\d+\$)?[-+ #0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|h|ll|l|q|L|z|t|j)?"
            r"[@dDiuUxXoOfFeEgGaAcCsSp]")
# Xcode's specifier per declared type. Only %@ and %lld are trusted from the same-file lookup
# (INFERRED_SPECS): for the other numeric types the extractor's choice rests on what a regex over
# one file can't see (typealiases, CGFloat vs Double, Int32 → %d or %ld, a Float that's really
# Double), and a wrong guess would be a false error that blocks an MR. Those slots match any
# specifier instead; the table stays so the mapping is written down in one place.
# Checked against an Xcode extraction of the iOS targets (2026-11-14): its .stringsdata has
# only %@ and %lld (String-ish and Int/count slots, as here); no key interpolates a Double, Float,
# Int32 or UInt, so the %lf/%f/%d/%u/%llu rows have no Xcode evidence yet. Indirect: Foundation's
# _FormatSpecifiable gives Int8/16/32 an Int32 _Arg (%d), UInt/UInt64 a UInt64 (%llu), UInt8/16/32
# a UInt32 (%u), Float a Float, Double and CGFloat their own type; %f vs %lf is only a convention.
TYPE_SPECS = {
    "String": "%@", "Substring": "%@", "Character": "%@", "AttributedString": "%@",
    "URL": "%@", "Date": "%@", "Text": "%@",
    "Int": "%lld", "Int64": "%lld", "Int32": "%d", "Int16": "%d", "Int8": "%d",
    "UInt": "%llu", "UInt64": "%llu", "UInt32": "%u", "UInt16": "%u", "UInt8": "%u",
    "Double": "%lf", "CGFloat": "%lf", "TimeInterval": "%lf", "Float": "%f",
}
INFERRED_SPECS = {"%@", "%lld"}
STRING_MEMBERS = {"localizedDescription", "lastPathComponent", "pathExtension"}
NOT_KEY = "// l10n-lint: not-a-key"
# The marker, then (after spaces or a dash/colon) the reason: group 1, empty when there's none.
NOT_KEY_RE = re.compile(re.escape(NOT_KEY) + r"(?![\w-])[\s\-—–:;,.]*(.*)$")
OWN_BUNDLE = re.compile(r"^(?:\.main|Bundle\.main|Bundle\(for:\s*\w+\.self\)|\.forClass\(\w+\.self\)"
                        r"|(?:[A-Za-z_]\w*\.)?bundle)$")


# ---------------------------------------------------------------------------
# Lexer

class Lit:
    """A string literal: items are str (text) or ('interp', source)."""

    def __init__(self, items):
        self.items = items

    @property
    def interpolated(self):
        return any(isinstance(i, tuple) for i in self.items)

    def text(self):
        return "".join(i if isinstance(i, str) else f"\\({i[1]})" for i in self.items)


class Tok:
    __slots__ = ("kind", "value", "line", "plat")

    def __init__(self, kind, value, line, plat):
        self.kind, self.value, self.line, self.plat = kind, value, line, plat

    def __repr__(self):
        return f"Tok({self.kind}, {self.value!r}, {self.line})"


class LexError(Exception):
    pass


ESCAPES = {"0": "\0", "\\": "\\", "t": "\t", "n": "\n", "r": "\r", '"': '"', "'": "'"}


class Lexer:
    def __init__(self, src):
        src = src.replace("\r\n", "\n").replace("\r", "\n")
        self.src = src
        self.code = list(src)  # src with comments blanked out, for the type lookup

    def line_at(self, pos):
        return self.src.count("\n", 0, pos) + 1

    def skip_comment(self, i):
        """i at '/': returns the end of a comment starting there, or i."""
        s = self.src
        if s.startswith("//", i):
            j = s.find("\n", i)
            j = len(s) if j < 0 else j
        elif s.startswith("/*", i):
            depth, j = 1, i + 2
            while depth and j < len(s):
                if s.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif s.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            if depth:
                raise LexError(f"line {self.line_at(i)}: unterminated /* comment")
        else:
            return i
        for k in range(i, j):
            if self.code[k] != "\n":
                self.code[k] = " "
        return j

    def string_at(self, i):
        """If a string literal starts at i, returns (Lit, end); else None."""
        s = self.src
        j = i
        while j < len(s) and s[j] == "#":
            j += 1
        hashes = j - i
        if not s.startswith('"', j):
            return None
        multi = s.startswith('"""', j)
        start = j + (3 if multi else 1)
        if multi:
            nl = s.find("\n", start)
            if nl < 0 or s[start:nl].strip():
                raise LexError(f"line {self.line_at(i)}: a multi-line string must start a new line")
            _, end, close = self._scan(start, hashes, True, None)
            last_nl = s.rfind("\n", 0, close)
            indent = s[last_nl + 1:close]
            if indent.strip():
                raise LexError(f"line {self.line_at(i)}: closing \"\"\" must be on its own line")
            items, end, _ = self._scan(nl + 1, hashes, True, indent)
            if items and isinstance(items[-1], str) and items[-1].endswith("\n"):
                items[-1] = items[-1][:-1]  # the newline before the closing delimiter
            return Lit([x for x in items if x != ""]), end
        items, end, _ = self._scan(start, hashes, False, None)
        return Lit(items), end

    def _scan(self, i, hashes, multi, indent):
        """Reads a literal's body from i. Returns (items, end after delimiter, delimiter start)."""
        s, n = self.src, len(self.src)
        close = ('"""' if multi else '"') + "#" * hashes
        esc = "\\" + "#" * hashes
        items, buf = [], []
        at_line_start = multi
        while True:
            if i >= n:
                raise LexError("unterminated string literal")
            if at_line_start and indent is not None:
                k = 0
                while k < len(indent) and i + k < n and s[i + k] == indent[k]:
                    k += 1
                i += k
                at_line_start = False
                continue
            at_line_start = False
            if s.startswith(close, i):
                items.append("".join(buf))
                return [x for x in items if x != ""] or [""], i + len(close), i
            c = s[i]
            if c == "\n" and not multi:
                raise LexError(f"line {self.line_at(i)}: newline in a string literal")
            if s.startswith(esc, i):
                k = i + len(esc)
                d = s[k] if k < n else ""
                if d == "(":
                    items.append("".join(buf))
                    buf = []
                    expr, k = self._interp(k + 1)
                    items.append(("interp", expr))
                    i = k
                    continue
                if d == "u" and s.startswith("{", k + 1):
                    e = s.find("}", k + 2)
                    try:
                        if e < 0:
                            raise ValueError("no closing }")
                        buf.append(chr(int(s[k + 2:e], 16)))
                    except (ValueError, OverflowError) as err:
                        raise LexError(f"line {self.line_at(i)}: bad \\u{{…}} escape: {err}")
                    i = e + 1
                    continue
                if d in ESCAPES:
                    buf.append(ESCAPES[d])
                    i = k + 1
                    continue
                if multi:  # `\` + spaces + newline: a line continuation
                    m = re.match(r"[ \t]*\n", s[k:])
                    if m:
                        i = k + m.end()
                        at_line_start = True
                        continue
                raise LexError(f"line {self.line_at(i)}: unknown escape {esc}{d}")
            buf.append(c)
            i += 1
            if c == "\n":
                at_line_start = True

    def _interp(self, i):
        """i just after `\\(`: returns (source of the expression, position after `)`)."""
        s, depth, start = self.src, 1, i
        while i < len(s):
            c = s[i]
            if c == "/" and (s.startswith("//", i) or s.startswith("/*", i)):
                i = self.skip_comment(i)
                continue
            lit = self.string_at(i) if c in '"#' else None
            if lit:
                i = lit[1]
                continue
            if c in "([{":
                depth += 1
            elif c in ")]}":
                depth -= 1
                if depth == 0:
                    return s[start:i].strip(), i + 1
            i += 1
        raise LexError("unterminated interpolation")

    def tokens(self):
        s, n, i = self.src, len(self.src), 0
        out = []
        stack = []  # [(active platforms, any earlier branch definitely true per platform)]

        def plat():
            act = set(PLATFORMS)
            for frame in stack:
                act &= frame[0]
            return frozenset(act)

        line_start = True
        while i < n:
            c = s[i]
            if c == "\n":
                line_start = True
                i += 1
                continue
            if c in " \t\r":
                i += 1
                continue
            if c == "/" and (s.startswith("//", i) or s.startswith("/*", i)):
                i = self.skip_comment(i)
                continue
            if c == "#" and line_start:
                m = re.match(r"#(if|elseif|else|endif)\b([^\n]*)", s[i:])
                if m:
                    cond = re.sub(r"//.*|/\*.*?\*/", "", m.group(2)).strip()
                    self._directive(stack, m.group(1), cond, i)
                    i += m.end()
                    continue
            line_start = False
            m = re.match(r"(#+)/", s[i:]) if c == "#" else None
            if m:  # #/regex/#: skipped, a `"` in it isn't a string
                close = "/" + m.group(1)
                e = s.find(close, i + m.end())
                if e < 0:
                    raise LexError(f"line {self.line_at(i)}: unterminated regex literal")
                i = e + len(close)
                continue
            if c == '"' or (c == "#" and re.match(r'#+"', s[i:])):
                lit, end = self.string_at(i)
                out.append(Tok("str", lit, self.line_at(i), plat()))
                i = end
                continue
            m = re.match(r"[A-Za-z_][A-Za-z0-9_]*|`[^`]+`", s[i:])
            if m:
                out.append(Tok("id", m.group().strip("`"), self.line_at(i), plat()))
                i += m.end()
                continue
            m = re.match(r"\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][-+]?\d+)?|0x[0-9a-fA-F_]+", s[i:])
            if m:
                out.append(Tok("num", m.group(), self.line_at(i), plat()))
                i += m.end()
                continue
            out.append(Tok("p", c, self.line_at(i), plat()))
            i += 1
        if stack:
            raise LexError("#if without #endif")
        return out

    def _directive(self, stack, kind, cond, pos):
        if kind == "if":
            vals = {p: eval_condition(cond, p) for p in PLATFORMS}
            stack.append(({p for p in PLATFORMS if vals[p] is not False},
                          {p for p in PLATFORMS if vals[p] is True}))
            return
        if not stack:
            raise LexError(f"line {self.line_at(pos)}: #{kind} without #if")
        _, done = stack.pop()
        if kind == "endif":
            return
        vals = {p: (eval_condition(cond, p) if kind == "elseif" else True) for p in PLATFORMS}
        active = {p for p in PLATFORMS if p not in done and vals[p] is not False}
        stack.append((active, done | {p for p in PLATFORMS if vals[p] is True}))


def eval_condition(cond, platform):
    """Three-valued: True, False, or None (unknown, e.g. DEBUG) for one platform."""
    toks = re.findall(r"&&|\|\||!|\(|\)|[A-Za-z_]\w*\s*\([^()]*\)|[A-Za-z_]\w*", cond)
    pos = 0

    def atom(t):
        m = re.match(r"(os|canImport|targetEnvironment)\s*\(\s*(\w+)\s*\)", t)
        if not m:
            return None
        fn, arg = m.groups()
        if fn == "os":
            return {"macOS": "macOS", "iOS": "iOS"}.get(arg) == platform if arg in (
                "macOS", "iOS", "watchOS", "tvOS", "visionOS", "Linux", "Windows") else None
        if fn == "canImport" and arg in ("AppKit", "UIKit"):
            return (arg == "AppKit") == (platform == "macOS")
        return None

    def unary():
        nonlocal pos
        if pos < len(toks) and toks[pos] == "!":
            pos += 1
            v = unary()
            return None if v is None else not v
        if pos < len(toks) and toks[pos] == "(":
            pos += 1
            v = disj()
            pos += 1  # ')'
            return v
        t = toks[pos] if pos < len(toks) else ""
        pos += 1
        return atom(t)

    def conj():
        nonlocal pos
        v = unary()
        while pos < len(toks) and toks[pos] == "&&":
            pos += 1
            w = unary()
            v = False if (v is False or w is False) else (None if None in (v, w) else True)
        return v

    def disj():
        nonlocal pos
        v = conj()
        while pos < len(toks) and toks[pos] == "||":
            pos += 1
            w = conj()
            v = True if (v is True or w is True) else (None if None in (v, w) else False)
        return v

    return disj()


# ---------------------------------------------------------------------------
# Interpolation types

class Types:
    """Same-file type lookup for `\\(x)`; returns a specifier or None (unknown)."""

    def __init__(self, code):
        self.code = code
        self.cache = {}

    def spec(self, expr, depth=0):
        expr = expr.strip()
        m = re.match(r"^(.*?),\s*specifier:\s*\"([^\"]*)\"\s*$", expr, re.S)
        if m:
            return m.group(2) if re.fullmatch(ANY_SPEC, m.group(2)) else None
        if "," in expr or "?" in expr or "!" in expr:
            return None
        if re.fullmatch(r"-?\d[\d_]*", expr):
            return "%lld"
        if re.fullmatch(r"-?\d[\d_]*\.\d[\d_]*", expr):
            return "%lf"
        if re.fullmatch(r'"[^"\\]*"', expr) or re.match(r"String\(", expr):
            return "%@"
        if re.search(r"\.formatted\([^()]*\)$", expr):
            return "%@"
        m = re.fullmatch(r"(?:[A-Za-z_]\w*\.)*([A-Za-z_]\w*)", expr)
        if not m:
            return None
        last = m.group(1)
        if expr != last and not expr.startswith("self."):
            if last == "count":
                return "%lld"
            if last in STRING_MEMBERS:
                return "%@"
            return None
        return self.lookup(last, depth)

    def lookup(self, name, depth):
        if (name, depth) in self.cache:
            return self.cache[(name, depth)]
        self.cache[(name, depth)] = None  # cycles stay unknown
        code, n = self.code, re.escape(name)
        found = set()
        # Bindings with no visible type spoil the lookup: closure and for-in params, patterns.
        if (re.search(r"\{\s*\(?[\w\s,]{0,200}\b" + n + r"\b[\w\s,]{0,200}\)?\s+in\b", code)
                or re.search(r"\bfor\s+(?:case\s+(?:let|var)\s+)?\(?[\w\s,]{0,200}\b" + n
                             + r"\b[\w\s,]{0,200}\)?\s+in\b", code)
                or re.search(r"\b(?:let|var)\s+" + n + r"\s*[,)]", code)
                or re.search(r"\b(?:if|guard|while)\s+(?:let|var)\s+" + n + r"\s*(?:[,{]|else\b)", code)
                or re.search(r"\b(?:let|var)\s+\.?\w+\([^)]*\b" + n + r"\b", code)):
            return None
        for m in re.finditer(r"\b" + n + r"\s*:\s*(?!:)", code):
            rest = code[m.end():m.end() + 80]
            t = re.match(r"([A-Z]\w*)(?![\w.(<])(\?|!)?", rest)
            if t:
                found.add(None if t.group(2) else TYPE_SPECS.get(t.group(1)))
            elif re.match(r"[\[(A-Z]|some\b|any\b|inout\b|@", rest):
                found.add(None)
            # else: a call's argument label (`name: value`), not a declaration
        if depth < 2:
            for m in re.finditer(r"\b(?:let|var)\s+" + n + r"\s*=\s*([^\n;]+)", code):
                found.add(self.spec(m.group(1), depth + 1))
        result = found.pop() if len(found) == 1 else None
        if result not in INFERRED_SPECS:
            result = None  # see TYPE_SPECS: only %@ and %lld are trusted from a lookup
        self.cache[(name, depth)] = result
        return result


def key_of(lit, types):
    """(display key, regex or None, untyped slots). The regex is set when a slot is untyped."""
    if not lit.interpolated:
        return lit.items[0] if lit.items else "", None, 0
    disp, pattern, untyped = [], [], 0
    for item in lit.items:
        if isinstance(item, str):
            esc = item.replace("%", "%%")
            disp.append(esc)
            pattern.append(re.escape(esc))
        else:
            spec = types.spec(item[1])
            if spec is None:
                untyped += 1
                disp.append("%?")
                pattern.append(ANY_SPEC)
            else:
                disp.append(spec)
                pattern.append(re.escape(spec))
    return "".join(disp), (re.compile("".join(pattern), re.S) if untyped else None), untyped


# ---------------------------------------------------------------------------
# Extraction

class Use:
    def __init__(self, file, line, key, regex, table, plat, form, untyped):
        self.file, self.line, self.key, self.regex = file, line, key, regex
        self.table, self.plat, self.form, self.untyped = table, plat, form, untyped


def split_args(toks, open_idx):
    """Arguments of the call whose '(' is at open_idx: [(label or None, [tokens])], close idx."""
    depth, args, cur = 0, [], []
    i = open_idx
    while i < len(toks):
        t = toks[i]
        if t.kind == "p" and t.value in "([{":
            depth += 1
            if depth > 1:
                cur.append(t)
        elif t.kind == "p" and t.value in ")]}":
            depth -= 1
            if depth == 0:
                if cur:
                    args.append(cur)
                break
            cur.append(t)
        elif depth == 1 and t.kind == "p" and t.value == ",":
            args.append(cur)
            cur = []
        else:
            cur.append(t)
        i += 1
    out = []
    for a in args:
        if len(a) >= 2 and a[0].kind == "id" and a[1].kind == "p" and a[1].value == ":" and not (
                len(a) >= 3 and a[2].kind == "p" and a[2].value == ":"):
            out.append((a[0].value, a[2:]))
        else:
            out.append((None, a))
    return out, i


def literal_only(toks):
    """'lit' for one lone literal, 'mixed' for literals joined by ?: or +, else None."""
    if len(toks) == 1 and toks[0].kind == "str":
        return "lit"
    if any(t.kind == "str" for t in toks):
        ops = [t for t in toks if t.kind == "p"]
        strs = [t for t in toks if t.kind == "str"]
        if strs and all(t.value in "?:+" for t in ops) and (
                any(t.value == "+" for t in ops) or len(strs) >= 2):
            return "mixed"
    return None


def _is_p(t, ch):
    return t.kind == "p" and t.value == ch


def _is_ternary_q(toks, i):
    """Whether the `?` token at i can be a ternary's: not `??`, not `as?` / `try?`, and not
    optional chaining (`x?.y`, `x?[0]`, `x?(…)`)."""
    nxt = toks[i + 1] if i + 1 < len(toks) else None
    prv = toks[i - 1] if i > 0 else None
    if nxt is not None and nxt.kind == "p" and nxt.value in "?.[(":
        return False
    if prv is not None and (_is_p(prv, "?") or (prv.kind == "id" and prv.value in ("as", "try"))):
        return False
    return True


def ternary_branches(toks):
    """[branch tokens] (true branch first, nested ternaries flattened) of an expression that is a
    top-level `cond ? a : b`, else None. A `?` is a ternary's unless it is `??`, `as?`, `try?` or
    optional chaining (`x?.y`, `x?[0]`, `x?(…)`); the condition can be anything. The tokens carry
    no spacing, so a ternary whose true branch starts with `.` or `(` (`c ? .member : …`,
    `c ? ("A") : …`) looks like optional chaining and is not resolved: that can only miss keys,
    never report a false error."""
    depth, q = 0, None
    for i, t in enumerate(toks):
        if t.kind != "p":
            continue
        if t.value in "([{":
            depth += 1
        elif t.value in ")]}":
            depth -= 1
        elif t.value == "?" and depth == 0 and q is None and _is_ternary_q(toks, i):
            q = i
    if q is None:
        return None
    depth, nested, colon = 0, 0, None
    for i in range(q + 1, len(toks)):
        t = toks[i]
        if t.kind != "p":
            continue
        if t.value in "([{":
            depth += 1
        elif t.value in ")]}":
            depth -= 1
        elif depth == 0 and t.value == "?":
            if _is_ternary_q(toks, i):
                nested += 1
        elif depth == 0 and t.value == ":":
            if nested == 0:
                colon = i
                break
            nested -= 1
    if colon is None:
        return None
    out = []
    for branch in (toks[q + 1:colon], toks[colon + 1:]):
        inner = ternary_branches(branch)
        out.extend(inner if inner is not None else [branch])
    return out


def ternary_literals(toks):
    """(lone-literal tokens of a ternary's branches, branches that join literals with `+`), or
    (None, []) when toks is no ternary or none of its branches is a lone literal."""
    branches = ternary_branches(toks)
    if branches is None:
        return None, []
    lits = [b[0] for b in branches if len(b) == 1 and b[0].kind == "str"]
    joined = [b for b in branches if not (len(b) == 1 and b[0].kind == "str")
              and any(t.kind == "str" for t in b)]
    return (lits or None), joined


def src_of(toks):
    out = []
    for t in toks:
        out.append(t.value.text() if t.kind == "str" else t.value)
    return re.sub(r"\s*([.()])\s*", r"\1", " ".join(out)).replace(": ", ":").replace(":", ": ")


def not_key_reason(line):
    """None when the line has no not-a-key marker, else the reason after it ("" if none)."""
    m = NOT_KEY_RE.search(line)
    return None if m is None else m.group(1).strip()


def marked_not_key(lines, first, last):
    """A not-a-key marker with a reason on lines first..last (1-based), or starting the comment
    line just above first. Mirrors check 4's not-plural marker, but a reason is required."""
    if any(not_key_reason(lines[j - 1]) for j in range(first, min(last, len(lines)) + 1)):
        return True
    above = lines[first - 2].strip() if first >= 2 else ""
    return above.startswith(NOT_KEY) and bool(not_key_reason(above))


def extract(src, file="<snippet>"):
    """Returns (uses, unresolved [(file, line, reason)]). Raises LexError."""
    lexer = Lexer(src)
    toks = lexer.tokens()
    types = Types("".join(lexer.code))
    lines = lexer.src.split("\n")
    uses, unresolved = [], []
    for i, t in enumerate(toks):
        if t.kind != "id" or i + 1 >= len(toks) or toks[i + 1].value != "(" or toks[i + 1].kind != "p":
            continue
        prev = toks[i - 1] if i > 0 else None
        after_dot = prev is not None and prev.kind == "p" and prev.value == "."
        if prev is not None and prev.kind == "id" and prev.value in ("func", "init", "case"):
            continue
        name = t.value
        if after_dot:
            if name not in LSK_MODIFIERS:
                continue
            form, first_label, table_label = "." + name, None, None
        elif name in LOCALIZED_CALLS:
            first_label, table_label = LOCALIZED_CALLS[name]
            form = name + ("(localized:)" if first_label else "()")
        elif name in LSK_TYPES:
            form, first_label, table_label = name + "()", None, None
        else:
            continue
        args, _ = split_args(toks, i + 1)
        if not args:
            continue
        label, first = args[0]
        if label != first_label:
            continue
        if marked_not_key(lines, t.line, max([x.line for x in first] or [t.line])):
            continue
        always = name in LOCALIZED_CALLS and not after_dot
        where = (file, t.line)
        # `cond ? "A" : "B"` in a LocalizedStringKey position (Button, Text, .help, …): Xcode
        # extracts both literals. String(localized:) & co. take no ternary of literals.
        lits = joined = None
        if not (always and name != "Text"):
            lits, joined = ternary_literals(first)
        if lits is not None:
            for b in joined:
                unresolved.append((*where, f"{form}: a ternary branch isn't a lone literal "
                                           f"({src_of(b)})"))
        else:
            kind = literal_only(first)
            if kind != "lit":
                if kind == "mixed" or (always and name != "Text"):
                    unresolved.append((*where, f"{form}: the key isn't a lone literal "
                                               f"({src_of(first)})"))
                continue
            lits = [first[0]]
        table = DEFAULT_TABLE
        reason = None
        for lab, val in args[1:]:
            if table_label and lab == table_label:
                if len(val) == 1 and val[0].kind == "str" and not val[0].value.interpolated:
                    table = val[0].value.text()
                else:
                    reason = f"{form}: {lab}: isn't a literal ({src_of(val)})"
            elif lab == "bundle" and (name in LOCALIZED_CALLS):
                b = src_of(val)
                if not OWN_BUNDLE.match(b):
                    reason = f"{form}: bundle: {b} may not be the target's own bundle"
        if reason:
            unresolved.append((*where, reason))
            continue
        for tok in lits:
            key, regex, untyped = key_of(tok.value, types)
            if key == "":
                continue  # Text(""): nothing to translate
            uses.append(Use(file, tok.line, key, regex, table, tok.plat, form, untyped))
    return uses, unresolved


# ---------------------------------------------------------------------------
# The check

def load_catalog_keys(path):
    with open(path, encoding="utf-8") as f:
        doc = json.load(f)
    return set((doc.get("strings") or {}).keys())


def escape_key(key):
    return key.replace("\\", "\\\\").replace("\n", "\\n").replace("\t", "\\t")


def read_baseline(root):
    entries = {}
    path = os.path.join(root, BASELINE)
    if not os.path.exists(path):
        return entries
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line.strip() or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) != 3:
                raise ValueError(f"line {n}: expected `table<TAB>key<TAB>file`: {line!r}")
            entries[tuple(parts)] = n
    return entries


def targets_of(project, source_dirs):
    """[(name, platform, [source dirs])] of the application and app-extension targets."""
    out = []
    for name, target in sorted((project.get("targets") or {}).items()):
        if isinstance(target, dict) and target.get("type") in TARGET_TYPES:
            out.append((name, target.get("platform"), source_dirs(target)))
    return out


def inside(rel, dirs):
    return any(rel == d or rel.startswith(d + os.sep) for d in dirs)


def swift_files(root):
    for top in SCAN_DIRS:
        for dirpath, dirnames, filenames in os.walk(os.path.join(root, top)):
            dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
            for name in sorted(filenames):
                if name.endswith(".swift"):
                    yield os.path.join(dirpath, name)


def check(report, project, source_dirs, catalog_paths, report_unused=False):
    root = report.root
    targets = targets_of(project, source_dirs)
    rels = [os.path.relpath(p, root) for p in catalog_paths]
    tables = {}  # target -> {table: catalog rel path}
    for name, _, dirs in targets:
        tables[name] = {}
        for rel in rels:
            if inside(rel, dirs):
                tables[name][os.path.splitext(os.path.basename(rel))[0]] = rel
    keys = {}
    for rel in rels:
        if os.path.basename(rel) == "InfoPlist.xcstrings":
            continue
        try:
            keys[rel] = load_catalog_keys(os.path.join(root, rel))
        except (OSError, ValueError):
            keys[rel] = set()  # check 1 reports it
    try:
        baseline = read_baseline(root)
    except (ValueError, OSError) as e:
        report.error(BASELINE, str(e))
        baseline = {}

    checked = {}  # catalog -> set of keys
    used = {rel: set() for rel in keys}
    hits, misses, unresolved, untyped, uses_n, marked = set(), [], [], 0, 0, 0
    for path in swift_files(root):
        rel = os.path.relpath(path, root)
        owners = [(n, p) for n, p, dirs in targets if inside(rel, dirs)]
        if not owners:
            continue
        try:
            with open(path, encoding="utf-8") as f:
                src = f.read()
        except (OSError, UnicodeDecodeError) as e:
            report.error(rel, f"unreadable: {e}")
            continue
        # A lexer gap or a bug here must not block an MR or crash the gate: the file is skipped,
        # loudly.
        try:
            uses, unres = extract(src, rel)
        except LexError as e:
            report.warning(rel, f"code keys: skipped {rel}: can't read this Swift: {e}")
            continue
        except Exception as e:
            report.warning(rel, f"code keys: skipped {rel}: {type(e).__name__}: {e}")
            continue
        for n, line in enumerate(src.replace("\r\n", "\n").replace("\r", "\n").split("\n"), 1):
            reason = not_key_reason(line)
            if reason:
                marked += 1
            elif reason == "":
                report.warning(f"{rel}:{n}", f"not-a-key marker needs a reason, so it's ignored and "
                                             f"the key is checked: {NOT_KEY} — <why>")
        unresolved += unres
        for use in uses:
            uses_n += 1
            untyped += use.untyped
            for tname, tplat in owners:
                if tplat in PLATFORMS and tplat not in use.plat:
                    continue
                catalog = tables[tname].get(use.table)
                if catalog is not None and catalog in keys:
                    ck = keys[catalog]
                    checked.setdefault(catalog, set()).add(use.key)
                    if use.regex is None:
                        found = {use.key} & ck
                    else:
                        found = {k for k in ck if use.regex.fullmatch(k)}
                    if found:
                        used[catalog] |= found
                        continue
                    missing_from = catalog
                else:
                    missing_from = f"{tname} (it has no {use.table}.xcstrings)"
                bkey = (use.table, escape_key(use.key), rel)
                if bkey in baseline:
                    hits.add(bkey)
                    continue
                misses.append((use, missing_from))
    seen = set()
    for use, missing_from in misses:
        k = (use.file, use.line, use.key, missing_from)
        if k in seen:
            continue
        seen.add(k)
        report.error(f"{use.file}:{use.line}",
                     f"{use.form} key {use.key!r} (table {use.table}) is not in {missing_from}. "
                     "Fix the code or the catalog so they match exactly (’ vs ', … vs ...)")
    for bkey, n in sorted(baseline.items(), key=lambda kv: kv[1]):
        if bkey not in hits:
            report.warning(f"{BASELINE}:{n}", "no longer missing, delete the entry: "
                                              + "\t".join(bkey))
    for file, line, reason in unresolved:
        report.info(f"code keys: unresolved: {file}:{line}: {reason}")
    if report_unused:
        for rel in sorted(used):
            for key in sorted(keys[rel] - used[rel]):
                report.info(f"code keys: unused: {rel}: {key!r}")
    per = ", ".join(f"{rel} {len(v)}" for rel, v in sorted(checked.items()))
    report.info(f"code keys: {uses_n} use(s), keys checked per catalog: {per or 'none'}; "
                f"{len(hits)} in the baseline, {len(unresolved)} unresolved, "
                f"{untyped} untyped slot(s), {marked} {NOT_KEY} marker(s)")


# ---------------------------------------------------------------------------
# Self-test

def self_test():
    failures = []

    def expect(name, got, want):
        if got != want:
            failures.append(f"{name}: got {got!r}, want {want!r}")

    def keys(src):
        uses, unres = extract(src)
        return [(u.key, u.table) for u in uses], unres

    # Interpolation types.
    src = '''
    func f(name: String, count: Int, ratio: Double, n: Int32) {
        _ = String(localized: "“\\(name)” has \\(count) items, \\(ratio) full, \\(n)")
        _ = String(localized: "\\(items.count) left of \\(total)")
        _ = String(localized: "\\(error.localizedDescription) at \\(5)")
        _ = Text("\\(ratio, specifier: "%.1f") %")
    }'''
    got, _ = keys(src)
    expect("interpolation types", got, [
        ("“%@” has %lld items, %? full, %?", "Localizable"),
        ("%lld left of %?", "Localizable"),
        ("%@ at %lld", "Localizable"),
        ("%.1f %%", "Localizable")])
    # An untyped slot matches any specifier; a typed one only its own.
    uses, _ = extract('let x = String(localized: "\\(total) left")')
    expect("untyped matches %lld", bool(uses[0].regex.fullmatch("%lld left")), True)
    expect("untyped matches %@", bool(uses[0].regex.fullmatch("%@ left")), True)
    # Conflicting declarations in one file: unknown.
    got, _ = keys('var a: Int = 1\nstruct S { var a: String }\nlet t = String(localized: "\\(a)!")')
    expect("conflicting types", got, [("%?!", "Localizable")])
    # A closure parameter has no visible type.
    got, _ = keys('let size: Int = 0\nlet v = xs.map { size in String(localized: "\\(size) B") }')
    expect("closure param", got, [("%? B", "Localizable")])
    # table: and tableName:, a non-literal table, bundle:.
    got, unres = keys('''
        String(localized: "Delete", table: "Shared", comment: "x")
        Text("MB", tableName: "Shared")
        String(localized: "Open", table: name)
        String(localized: "Size", bundle: PreviewFormatting.bundle, comment: "c")
        String(localized: "Other", bundle: Bundle(identifier: "com.apple.AppKit")!)
        NSLocalizedString("Legacy", tableName: "Old", comment: "")''')
    expect("tables", got, [("Delete", "Shared"), ("MB", "Shared"), ("Size", "Localizable"),
                           ("Legacy", "Old")])
    expect("unresolved table/bundle", len(unres), 2)
    # Escapes, raw strings, multi-line strings, comments.
    got, _ = keys(r'''
        // Text("in a comment")
        /* Button("in /* a nested */ comment") */
        Button("Say \"hi\"\tnow \u{2026}")
        Label(#"Raw "quoted" \n"#, systemImage: "x")
        Toggle("""
            Two \
            lines
              indented
            """, isOn: $on)''')
    expect("escapes and multi-line", got, [
        ('Say "hi"\tnow …', "Localizable"), ('Raw "quoted" \\n', "Localizable"),
        ("Two lines\n  indented", "Localizable")])
    # Not keys: Text(verbatim:), a variable, members and declarations named like SwiftUI types.
    got, unres = keys('''
        Text(verbatim: "v"); Text(name); Button(action: go) { }; x.Button("m")
        func Label(_ s: String) {}; logger.error("log"); NSMenuItem(title: "t", action: nil)
        .alert(state.title ?? "", isPresented: $p)
        Text(a ?? "nil-coalescing")
        String(localized: someKey)
        String(localized: flag ? "A" : "B")''')
    expect("non-keys", got, [])
    expect("unresolved variable and String(localized:) ternary",
           [u[2].split(": ")[0] for u in unres], ["String(localized:)", "String(localized:)"])
    # A ternary of literals in a LocalizedStringKey position: Xcode extracts both branches, so
    # both are keys (the condition can be anything, nested ternaries and optional chaining too);
    # a branch that isn't a lone literal is skipped, a `+` branch is reported as unresolved.
    got, unres = keys('''
        Button(state.isSelecting ? "Done" : "Select", action: go)
        Text(flag ? "A" : "B")
        Text(x?.ok == true ? "Yes" : n > 1 ? "Many" : "One", tableName: "Shared")
        .help(a ? "Help" : name)
        Label(f(a ? 1 : 2) ? "L1" : "L2", systemImage: "x")
        .navigationTitle(isOn ? "T" + suffix : "U")
        Text(a ?? "nil-coalescing"); Text(b ? c : d)
        Text(v as? Foo != nil ? "AsYes" : "AsNo")
        Text(try? load() == nil ? "TryYes" : "TryNo")
        Text(try? f() ?? 0 > 1 ? "Mixed" : "Rest")''')
    expect("ternary branches", got, [
        ("Done", "Localizable"), ("Select", "Localizable"), ("A", "Localizable"),
        ("B", "Localizable"), ("Yes", "Shared"), ("Many", "Shared"), ("One", "Shared"),
        ("Help", "Localizable"), ("L1", "Localizable"), ("L2", "Localizable"),
        ("U", "Localizable"), ("AsYes", "Localizable"), ("AsNo", "Localizable"),
        ("TryYes", "Localizable"), ("TryNo", "Localizable"), ("Mixed", "Localizable"),
        ("Rest", "Localizable")])
    expect("ternary + branch unresolved", [u[2].split(": ")[0] for u in unres], [".navigationTitle"])
    # #if os(…): platforms per token.
    uses, _ = extract('#if os(macOS)\nText("Mac")\n#elseif os(iOS)\nText("iOS")\n#else\n'
                      'Text("none")\n#endif\n#if DEBUG\nText("debug")\n#endif')
    expect("platforms", [(u.key, sorted(u.plat)) for u in uses],
           [("Mac", ["macOS"]), ("iOS", ["iOS"]), ("none", []), ("debug", ["iOS", "macOS"])])
    # Inferred types other than %@/%lld match any specifier; literals and specifier: stay.
    got, _ = keys('let f: Float = 1\nlet u: UInt8 = 2\nlet d = 1.5\nlet s: String = ""\n'
                  'Text("\\(f) \\(u) \\(d) \\(s) \\(2.5) \\(f, specifier: "%.2f")")')
    expect("inferred non-%@/%lld", got, [("%? %? %? %@ %lf %.2f", "Localizable")])
    # not-a-key: with a reason, on a line of the call or starting the comment line just above.
    # Bare, or two lines up: not honoured, the key is checked.
    got, _ = keys('x.help("same") // l10n-lint: not-a-key — a custom help(String)\n'
                  '// l10n-lint: not-a-key: an enum named Menu\nMenu("above")\n'
                  'Text(\n    "on the key line" // l10n-lint: not-a-key - reason\n)\n'
                  '// l10n-lint: not-a-key — too far up\n\nButton("two up")\n'
                  'Button("bare") // l10n-lint: not-a-key\n'
                  '// l10n-lint: not-a-key\nButton("bare above")\n'
                  'Button("dash only") // l10n-lint: not-a-key —')
    expect("not-a-key marker", [k for k, _ in got], ["two up", "bare", "bare above", "dash only"])
    # An empty key has nothing to translate.
    got, _ = keys('Text("")\nButton("""\n    """) {}\nText("x")')
    expect("empty key skipped", got, [("x", "Localizable")])
    # CRLF and lone CR line ends: same keys and lines as LF.
    uses, _ = extract('Text("crlf")\r\nToggle("""\r\n    a\r\n    b\r\n    """, isOn: $x)\r\n'
                      'Text("a")\rText("b")')
    expect("CRLF", [(u.key, u.line) for u in uses],
           [("crlf", 1), ("a\nb", 2), ("a", 6), ("b", 7)])
    # A bad \u{…} escape is a LexError, not a crash.
    for bad in ('Text("\\u{zz}")', 'Text("\\u{110000}")', 'Text("\\u{41")'):
        try:
            extract(bad)
            expect(f"bad escape {bad}", "no error", "LexError")
        except LexError:
            pass
        except Exception as e:
            expect(f"bad escape {bad}", type(e).__name__, "LexError")
    # ’ vs ' and … vs ...: the check must flag them.

    class R:
        def __init__(self, root):
            self.root, self.errors, self.lines = root, [], []

        def error(self, where, msg):
            self.errors.append(f"{where}: {msg}")

        def warning(self, where, msg):
            self.lines.append(f"warning: {where}: {msg}")

        def info(self, msg):
            self.lines.append(msg)

    with tempfile.TemporaryDirectory(prefix="code-keys-self-test-") as tmp:
        os.makedirs(os.path.join(tmp, "App", "macOS"))
        with open(os.path.join(tmp, "App", "macOS", "Localizable.xcstrings"), "w") as f:
            json.dump({"sourceLanguage": "en", "strings": {
                "Can’t Open": {}, "Saving “%@”…": {}, "%lld items": {}, "Unused": {}}}, f)
        with open(os.path.join(tmp, "App", "macOS", "V.swift"), "w") as f:
            f.write('func v(name: String, n: Int) {\n'
                    '  Text("Can\'t Open")\n'
                    '  Text("Saving “\\(name)”...")\n'
                    '  Text("\\(n) items")\n'
                    '  Text("Saving “\\(name)”…")\n}\n')
        project = {"targets": {"KernirMac": {"type": "application", "platform": "macOS",
                                             "sources": ["App/macOS"]}}}
        cat = [os.path.join(tmp, "App", "macOS", "Localizable.xcstrings")]
        r = R(tmp)
        check(r, project, lambda t: t["sources"], cat, report_unused=True)
        expect("drift flagged", [e.split(":")[1] for e in r.errors], ["2", "3"])
        expect("unused reported", [x for x in r.lines if "unused" in x],
               ["code keys: unused: App/macOS/Localizable.xcstrings: 'Can’t Open'",
                "code keys: unused: App/macOS/Localizable.xcstrings: 'Unused'"])
        os.makedirs(os.path.join(tmp, "scripts", "l10n"))
        with open(os.path.join(tmp, BASELINE), "w") as f:
            f.write("# c\nLocalizable\tCan't Open\tApp/macOS/V.swift\n"
                    "Localizable\tGone\tApp/macOS/V.swift\n")
        r = R(tmp)
        check(r, project, lambda t: t["sources"], cat)
        expect("baselined", [e.split(":")[1] for e in r.errors], ["3"])
        expect("stale baseline warned", sum("no longer missing" in x for x in r.lines), 1)
        # A file the lexer can't read is skipped with a warning; a bare marker gets a warning.
        with open(os.path.join(tmp, "App", "macOS", "B.swift"), "w") as f:
            f.write('Text("bad \\u{zz}")\n')
        with open(os.path.join(tmp, "App", "macOS", "M.swift"), "w") as f:
            f.write('Text("Unused") // l10n-lint: not-a-key\n'
                    'Text("Nope") // l10n-lint: not-a-key — a reason\n')
        r = R(tmp)
        check(r, project, lambda t: t["sources"], cat)
        expect("bad escape skipped", [x.split(": can't")[0] for x in r.lines if "skipped" in x],
               ["warning: App/macOS/B.swift: code keys: skipped App/macOS/B.swift"])
        expect("bare marker warned", [x.split(": not-a-key")[0] for x in r.lines if "needs a reason" in x],
               ["warning: App/macOS/M.swift:1"])
        expect("marked counted", sum("1 // l10n-lint: not-a-key marker(s)" in x for x in r.lines), 1)
        expect("with B.swift and M.swift", [e.split(":")[1] for e in r.errors], ["3"])
        # Any other exception while reading a file: skipped with a warning, the gate goes on.
        real = globals()["extract"]

        def boom(src, file="<snippet>"):
            raise RuntimeError("boom")

        globals()["extract"] = boom
        try:
            r = R(tmp)
            check(r, project, lambda t: t["sources"], cat)
        finally:
            globals()["extract"] = real
        expect("crash skipped", sum("code keys: skipped" in x and "RuntimeError: boom" in x
                                    for x in r.lines), 3)

    for f in failures:
        print(f"self-test FAIL: {f}")
    print(f"code_keys self-test: {'FAIL' if failures else 'OK'} ({len(failures)} failure(s))")
    return 1 if failures else 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    print(__doc__.strip().splitlines()[2], file=sys.stderr)
    sys.exit(2)
