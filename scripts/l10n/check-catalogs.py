#!/usr/bin/env python3
r"""Slot-free String Catalog gate for Kernir. Run it on every MR that touches strings.

Usage: python3 -I scripts/l10n/check-catalogs.py [--root DIR] [--quiet] [--report-unused]

Checks, with no Xcode, no build and no app launch:
  1. Every *.xcstrings under App/ and Extensions/ (there must be at least one):
     - is valid JSON with no duplicate keys at any level (a git merge can silently add one)
     - has sourceLanguage "en" and only "en" localizations (0.1.0 ships English only)
     - has state "translated" in every en stringUnit, plural cases and substitutions included
     - has "one" and "other" in every plural variation
     - uses the same format specifiers in each value as in its key (a plural case may drop one,
       as in "One item"; positions and length modifiers count, flags and widths don't)
     - has a non-empty comment on every key (the InfoPlist ones too: their generator writes them)
     - warning: a key with extractionState "stale" (the code no longer uses it; delete it)
  2. No target in project.yml has two same-named catalogs in its source paths: they would be
     one table, and which one wins is undefined. Source `excludes:` are not taken into account.
  3. scripts/l10n/infoplist_catalogs.py --check: the InfoPlist catalogs, and the ServicesMenu
     catalog of a target with NSServices (its Services menu titles), match project.yml.
  4. Swift under App/ and Extensions/ has no new English-only plural ternary.
     Caught: a count compared with the plural boundary (`== 1`, `!= 1`, `1 == n`, `1 != n`,
     `> 1`, `>= 2`, `< 2`, `<= 1`) right before `? "` or `? String(localized`, also when the
     line breaks just before or after the `?`.
     Not caught: if/switch statements, a ternary whose first branch is a variable, Text(...)
     or any other call, a comparison more than one line break away from its `?`, and the
     reversed `1 < n` forms.
     Known hits live in scripts/l10n/lint-baseline.txt as `path<TAB>line text` (a ternary on
     two lines is one hit: both lines, stripped, joined by one space). A hit that isn't in the
     baseline is an error; a baseline entry with no hit is a warning, so the entry can be
     deleted. The baseline is for plurals still to fix. A line that only looks like one (say,
     `number == 1 ? "" : " \(number)"` picking a free file name) opts out with the marker
     `// l10n-lint: not-plural` at the end of that line, or starting the comment line just
     above it (a reason may follow the marker).
  5. scripts/l10n/code_keys.py: every key the Swift under App/ and Extensions/ looks up
     (String(localized:), Text("…"), Button("…") and the other forms in its header) is in its
     table's catalog for each app or appex target that compiles the file. A ' vs ’ or ... vs …
     drift shows the English fallback, so only this catches it. A miss is an error unless
     scripts/l10n/code-keys-baseline.txt lists it (`table<TAB>key<TAB>file`); a listed entry with
     no miss is a warning. Keys it can't work out (not a literal, a variable table) are counted
     as unresolved, never errors. A call that only looks like a key opts out with
     `// l10n-lint: not-a-key — <reason>` (placed like not-plural; the reason is required, a bare
     marker is ignored and warned about). --report-unused also lists catalog keys no code uses
     (info).
     Self-test: python3 -I scripts/l10n/code_keys.py --self-test
     Self-test of check 1's comment rule: python3 -I scripts/l10n/check-catalogs.py --self-test

Exit 0 = pass (warnings allowed), 1 = at least one error, 2 = usage error. A wrong --root, a
missing project.yml or an unreadable file is an error with a message, not a traceback.
"""

import argparse
import collections
import importlib.util
import io
import json
import os
import re
import sys
from contextlib import redirect_stderr, redirect_stdout

SCAN_DIRS = ("App", "Extensions")
SOURCE_LANGUAGE = "en"
ALLOWED_LANGUAGES = {"en"}
BASELINE = os.path.join("scripts", "l10n", "lint-baseline.txt")
TERNARY = re.compile(
    r"(?:[!=]=\s*1|\b1\s*[!=]=\s*[\w.]+|>\s*1|>=\s*2|<\s*2|<=\s*1)"
    r'\s*\?\s*(?:"|String\(localized\b)')
NOT_PLURAL = "// l10n-lint: not-plural"

# printf-style specifiers as Foundation reads them: optional position, flags, width, precision,
# length modifier and conversion. `%%` and `%#@name@` (substitutions) are handled separately.
SPECIFIER = re.compile(
    r"%(?:(?P<pos>\d+)\$)?[-+ #0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?"
    r"(?P<len>hh|h|ll|l|q|L|z|t|j)?(?P<conv>[@dDiuUxXoOfFeEgGaAcCsSp])")
SUBSTITUTION = re.compile(r"%(?:(?P<pos>\d+)\$)?#@(?P<name>[^@]+)@")


class Report:
    def __init__(self, root, quiet):
        self.root, self.quiet = root, quiet
        self.errors, self.warnings = 0, 0

    def error(self, where, msg):
        self.errors += 1
        print(f"error: {where}: {msg}")

    def warning(self, where, msg):
        self.warnings += 1
        print(f"warning: {where}: {msg}")

    def info(self, msg):
        if not self.quiet:
            print(msg)


# ---------------------------------------------------------------------------
# Format specifiers

def specifiers(text):
    """{position: 'len+conv'} for a format string; None if positions clash."""
    out, nxt = {}, 1
    text = text.replace("%%", "")
    for m in SPECIFIER.finditer(text):
        conv = m.group("conv")
        conv = {"i": "d", "D": "ld", "U": "lu", "O": "lo", "F": "f"}.get(conv, conv)
        kind = (m.group("len") or "").replace("q", "ll") + conv
        if m.group("pos"):
            pos = int(m.group("pos"))
        else:
            pos, nxt = nxt, nxt + 1
        if pos in out and out[pos] != kind:
            return None
        out[pos] = kind
    return out


def value_specifiers(value, substitutions):
    """Specifiers of a value whose `%#@name@` tokens stand for substitution arguments."""
    subs = {}
    nxt = 1

    def repl(m):
        nonlocal nxt
        sub = (substitutions or {}).get(m.group("name")) or {}
        pos = sub.get("argNum") or (int(m.group("pos")) if m.group("pos") else None)
        if pos is None:
            pos, nxt = nxt, nxt + 1
        fmt = sub.get("formatSpecifier", "@")
        subs[pos] = specifiers("%" + fmt).get(1) if specifiers("%" + fmt) else fmt
        return ""

    plain = SUBSTITUTION.sub(repl, value)
    out = specifiers(plain)
    if out is None:
        return None
    if subs and not re.search(r"%\d+\$", plain):
        # Substitution args are numbered; unnumbered plain ones fill the free positions.
        renumbered, free = {}, 1
        for pos in sorted(out):
            while free in subs:
                free += 1
            renumbered[free] = out[pos]
            free += 1
        out = renumbered
    if subs:
        for pos, kind in subs.items():
            if pos in out and out[pos] != kind:
                return None
            out[pos] = kind
    return out


def describe(specs):
    return ", ".join(f"{p}:%{k}" for p, k in sorted(specs.items())) or "none"


# ---------------------------------------------------------------------------
# Catalogs

def load_json_no_dupes(text):
    dupes = []

    def hook(pairs):
        seen = {}
        for k, v in pairs:
            if k in seen:
                dupes.append(k)
            seen[k] = v
        return seen

    return json.loads(text, object_pairs_hook=hook), dupes


def line_numbers(text, key):
    needle = re.compile(re.escape(json.dumps(key, ensure_ascii=False)) + r"\s*:")
    return [text.count("\n", 0, m.start()) + 1 for m in needle.finditer(text)]


def check_unit(report, where, key_specs, value, substitutions, may_drop):
    if key_specs is None:
        return
    got = value_specifiers(value, substitutions)
    if got is None:
        report.error(where, f"value {value!r} uses one argument position with two types")
        return
    ok = (all(key_specs.get(p) == k for p, k in got.items()) if may_drop else got == key_specs)
    if not ok:
        report.error(where, f"format specifiers {describe(got)} in {value!r} "
                            f"don't match the key's ({describe(key_specs)})")


def walk_variations(report, where, key_specs, node, substitutions, may_drop, in_sub):
    """node is a localization (or a variation case): {stringUnit} or {variations}."""
    if not isinstance(node, dict):
        report.error(where, "expected an object")
        return
    unit = node.get("stringUnit")
    if unit is not None:
        value = unit.get("value") if isinstance(unit, dict) else None
        state = unit.get("state") if isinstance(unit, dict) else None
        if isinstance(unit, dict) and state != "translated":
            report.error(where, f"stringUnit state is {state!r}, not 'translated'")
        if not isinstance(value, str):
            report.error(where, "stringUnit has no string value")
        elif not in_sub:
            check_unit(report, where, key_specs, value, substitutions, may_drop)
    variations = node.get("variations")
    if variations is None:
        return
    if not isinstance(variations, dict):
        report.error(where, "variations is not an object")
        return
    for vtype, cases in variations.items():
        if not isinstance(cases, dict):
            report.error(f"{where} > {vtype}", "expected an object")
            continue
        if vtype == "plural":
            missing = [c for c in ("one", "other") if c not in cases]
            if missing:
                report.error(f"{where} > plural", f"missing {', '.join(missing)}")
        for case, sub in cases.items():
            drop = may_drop or (vtype == "plural" and case != "other")
            walk_variations(report, f"{where} > {vtype}.{case}", key_specs, sub,
                            substitutions, drop, in_sub)


def check_catalog(report, path):
    rel = os.path.relpath(path, report.root)
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except (OSError, UnicodeDecodeError) as e:
        report.error(rel, f"unreadable: {e}")
        return 0
    try:
        doc, dupes = load_json_no_dupes(text)
    except json.JSONDecodeError as e:
        report.error(f"{rel}:{e.lineno}", f"invalid JSON: {e.msg}")
        return 0
    for key in sorted(set(dupes)):
        lines = ", ".join(map(str, line_numbers(text, key)))
        report.error(rel, f"duplicate key {key!r} (lines {lines})")
    if not isinstance(doc, dict):
        report.error(rel, "top level is not an object")
        return 0
    if doc.get("sourceLanguage") != SOURCE_LANGUAGE:
        report.error(rel, f"sourceLanguage is {doc.get('sourceLanguage')!r}, not {SOURCE_LANGUAGE!r}")
    strings = doc.get("strings")
    if not isinstance(strings, dict):
        report.error(rel, "no \"strings\" object")
        return 0
    for key, entry in strings.items():
        where = f"{rel}: {key!r}"
        if not isinstance(entry, dict):
            report.error(where, "entry is not an object")
            continue
        comment = entry.get("comment")
        if not (isinstance(comment, str) and comment.strip()):
            report.error(where, "no comment: say where the string shows and what it means")
        if entry.get("extractionState") == "stale":
            report.warning(where, "extractionState is \"stale\": the code no longer uses it; "
                                  "delete the key")
        key_specs = specifiers(key)
        if key_specs is None:
            report.error(where, "key uses one argument position with two types")
        localizations = entry.get("localizations") or {}
        if not isinstance(localizations, dict):
            report.error(where, "localizations is not an object")
            continue
        for lang, loc in localizations.items():
            if lang not in ALLOWED_LANGUAGES:
                report.error(where, f"localization {lang!r}: 0.1.0 ships English only")
                continue
            substitutions = loc.get("substitutions") if isinstance(loc, dict) else None
            walk_variations(report, f"{where} [{lang}]", key_specs, loc, substitutions,
                            may_drop=False, in_sub=False)
            for name, sub in (substitutions or {}).items():
                walk_variations(report, f"{where} [{lang}] %#@{name}@", None, sub, None,
                                may_drop=True, in_sub=True)
    return len(strings)


def catalogs(root):
    for top in SCAN_DIRS:
        for dirpath, dirnames, filenames in os.walk(os.path.join(root, top)):
            dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
            for name in sorted(filenames):
                if name.endswith(".xcstrings"):
                    yield os.path.join(dirpath, name)


# ---------------------------------------------------------------------------
# InfoPlist catalogs

def load_module(name):
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), name + ".py")
    sys.dont_write_bytecode = True  # no __pycache__ in the checkout
    spec = importlib.util.spec_from_file_location(name, script)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_infoplist_catalogs():
    return load_module("infoplist_catalogs")


def check_targets(report, module, found):
    """Two same-named catalogs in one target's source paths would be one table."""
    try:
        with open(os.path.join(report.root, "project.yml"), encoding="utf-8") as f:
            project = module.parse_yaml(f.read())
    except (OSError, UnicodeDecodeError, module.YamlError):
        return  # infoplist_catalogs.py --check reports it
    rels = [os.path.relpath(p, report.root) for p in found]
    for name, target in sorted((project.get("targets") or {}).items()):
        if not isinstance(target, dict):
            continue
        dirs = module._source_dirs(target)
        by_name = collections.defaultdict(list)
        for rel in rels:
            if any(rel == d or rel.startswith(d + os.sep) for d in dirs):
                by_name[os.path.basename(rel)].append(rel)
        for base, paths in sorted(by_name.items()):
            if len(paths) > 1:
                report.error(f"project.yml: {name}", f"two catalogs named {base} in its sources "
                                                     f"({', '.join(paths)}); rename or move one")


def check_code_keys(report, module, found, report_unused):
    try:
        with open(os.path.join(report.root, "project.yml"), encoding="utf-8") as f:
            project = module.parse_yaml(f.read())
    except (OSError, UnicodeDecodeError, module.YamlError):
        return  # infoplist_catalogs.py --check reports it
    try:
        code_keys = load_module("code_keys")
    except (OSError, SyntaxError) as e:
        report.error("code_keys.py", f"can't load it: {e}")
        return
    code_keys.check(report, project, module._source_dirs, found, report_unused)


def check_infoplist(report, module):
    out, err = io.StringIO(), io.StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        rc = module.main(["--check", "--root", report.root])
    for line in err.getvalue().splitlines():
        report.error("infoplist_catalogs.py --check", line.replace("infoplist_catalogs: error: ", ""))
    if rc and not err.getvalue():
        report.error("infoplist_catalogs.py --check", f"exit {rc}")
    if rc == 0:
        report.info(out.getvalue().strip())


# ---------------------------------------------------------------------------
# Plural ternary lint

def read_baseline(root):
    entries = collections.Counter()
    path = os.path.join(root, BASELINE)
    if not os.path.exists(path):
        return entries
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line.strip() or line.startswith("#"):
                continue
            file, sep, text = line.partition("\t")
            if not sep:
                raise ValueError(f"expected `path<TAB>line text`: {line!r}")
            entries[(file, text.strip())] += 1
    return entries


def ternary_hits(lines):
    """[(line number, text)] of the plural ternaries in a file's lines, minus marked ones."""
    out = []
    for i, line in enumerate(lines):
        text, end = line.strip(), i
        nxt = lines[i + 1].strip() if i + 1 < len(lines) else ""
        if nxt and (nxt.startswith("?") or text.endswith("?")):
            text, end = f"{text} {nxt}", i + 1
        if not TERNARY.search(text):
            continue
        above = lines[i - 1].strip() if i > 0 else ""
        if any(NOT_PLURAL in lines[j] for j in range(i, end + 1)) or above.startswith(NOT_PLURAL):
            continue
        out.append((i + 1, text))
    return out


def lint_swift(report):
    hits = collections.Counter()
    where = {}
    marked = 0
    for top in SCAN_DIRS:
        for dirpath, dirnames, filenames in os.walk(os.path.join(report.root, top)):
            dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
            for name in sorted(filenames):
                if not name.endswith(".swift"):
                    continue
                path = os.path.join(dirpath, name)
                rel = os.path.relpath(path, report.root)
                try:
                    with open(path, encoding="utf-8") as f:
                        lines = f.read().splitlines()
                except (OSError, UnicodeDecodeError) as e:
                    report.error(rel, f"unreadable: {e}")
                    continue
                marked += sum(NOT_PLURAL in line for line in lines)
                for n, text in ternary_hits(lines):
                    k = (rel, text)
                    hits[k] += 1
                    where.setdefault(k, []).append(n)
    try:
        baseline = read_baseline(report.root)
    except (ValueError, OSError) as e:  # UnicodeDecodeError is a ValueError
        report.error(BASELINE, str(e))
        baseline = collections.Counter()
    for k, count in sorted(hits.items()):
        new = count - baseline.get(k, 0)
        if new > 0:
            lines = ", ".join(map(str, where[k]))
            report.error(f"{k[0]}:{lines}",
                         f"English-only plural ternary: {k[1]}. Use String(localized:) with a "
                         "plural variation in the catalog instead")
    for k, count in sorted(baseline.items()):
        gone = count - hits.get(k, 0)
        if gone > 0:
            report.warning(BASELINE, f"no longer found, remove it: {k[0]}\t{k[1]}")
    known = sum(min(c, baseline.get(k, 0)) for k, c in hits.items())
    report.info(f"plural ternary lint: {sum(hits.values())} hit(s), {known} in the baseline, "
                f"{marked} {NOT_PLURAL} marker(s)")


def self_test():
    """Check 1's comment rule: every key of every catalog needs a non-blank comment."""
    import tempfile
    failures = []

    class R:
        def __init__(self, root):
            self.root, self.errors = root, []

        def error(self, where, msg):
            self.errors.append(f"{where}: {msg}")

        def warning(self, where, msg):
            pass

        def info(self, msg):
            pass

    entries = {"None": {}, "Blank": {"comment": "  "}, "Ok": {"comment": "Where it shows."}}
    with tempfile.TemporaryDirectory(prefix="check-catalogs-self-test-") as tmp:
        for rel in ("App/Shared/Shared.xcstrings", "App/macOS/Localizable.xcstrings",
                    "App/iOS/Localizable.xcstrings", "App/iOS/Other.xcstrings",
                    "App/iOS/InfoPlist.xcstrings"):
            path = os.path.join(tmp, *rel.split("/"))
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as f:
                json.dump({"sourceLanguage": "en", "strings": entries}, f)
            r = R(tmp)
            check_catalog(r, path)
            got = sorted(e.split(": ")[1] for e in r.errors if "no comment" in e)
            if got != ["'Blank'", "'None'"]:
                failures.append(f"{rel}: comment errors for {got!r}, want 'Blank' and 'None'")
    for f in failures:
        print(f"self-test FAIL: {f}")
    print(f"check-catalogs self-test: {'FAIL' if failures else 'OK'} ({len(failures)} failure(s))")
    return 1 if failures else 0


def main(argv=None):
    if (sys.argv[1:] if argv is None else argv) == ["--self-test"]:
        return self_test()
    parser = argparse.ArgumentParser(
        description="Slot-free String Catalog checks (see the header of this file).")
    parser.add_argument("--root", default=os.path.normpath(
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")),
        help="repo root (default: two levels above this script)")
    parser.add_argument("--quiet", "-q", action="store_true", help="print only errors and warnings")
    parser.add_argument("--report-unused", action="store_true",
                        help="also list catalog keys that no code key uses (info, never an error)")
    args = parser.parse_args(argv)
    report = Report(os.path.abspath(args.root), args.quiet)

    total = 0
    found = list(catalogs(report.root))
    if not found:
        report.error(report.root, f"no .xcstrings under {' or '.join(SCAN_DIRS)} (wrong --root?)")
    for path in found:
        count = check_catalog(report, path)
        total += count
        report.info(f"checked {os.path.relpath(path, report.root)} ({count} keys)")
    module = None
    try:
        module = load_infoplist_catalogs()
    except (OSError, SyntaxError) as e:
        report.error("infoplist_catalogs.py", f"can't load it: {e}")
    else:
        check_targets(report, module, found)
        check_infoplist(report, module)
    lint_swift(report)
    if module is not None:
        check_code_keys(report, module, found, args.report_unused)

    status = "FAIL" if report.errors else "OK"
    print(f"check-catalogs: {status}: {len(found)} catalogs, {total} keys, "
          f"{report.errors} error(s), {report.warnings} warning(s)")
    return 1 if report.errors else 0


if __name__ == "__main__":
    sys.exit(main())
