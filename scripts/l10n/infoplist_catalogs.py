#!/usr/bin/env python3
"""Generates the InfoPlist.xcstrings and ServicesMenu.xcstrings catalogs from project.yml.

Usage: python3 -I scripts/l10n/infoplist_catalogs.py [--check] [--root DIR]

  (no option)  write <info dir>/InfoPlist.xcstrings for every target with an `info:` block, and
               <info dir>/ServicesMenu.xcstrings for every one whose info has NSServices
  --check      write nothing; exit 1 if any catalog differs from what project.yml generates,
               if a committed Info.plist disagrees with project.yml, or if an InfoPlist.xcstrings
               or ServicesMenu.xcstrings exists that no target owns
  --root DIR   the repo root (default: two levels above this script)

Exit 0 = OK, 1 = drift or a project.yml problem, 2 = usage error. Stdlib only, no Xcode.

What goes in a catalog (English only, every entry extractionState "manual"):
- Bundle-level keys, keyed by the plist key name: CFBundleDisplayName, NSHumanReadableCopyright
  when set, and CFBundleName for the macOS app (its menu bar name; $(PRODUCT_NAME) is resolved
  from the target's settings).
- Nested values, keyed by their English value, which is how InfoPlist.strings localizes them:
  CFBundleDocumentTypes[].CFBundleTypeName and UT{Imported,Exported}TypeDeclarations[].UTTypeDescription.
- NSServices is not in InfoPlist: AppKit looks a Service's menu title up in the bundle's
  ServicesMenu.strings, keyed by its NSMenuItem `default` value. So a target with NSServices gets
  a ServicesMenu.xcstrings next to its InfoPlist.xcstrings, with one key per NSMenuItem title,
  and the build compiles it into <lang>.lproj/ServicesMenu.strings.

The catalog lives next to the target's Info.plist. That directory must be a source directory of
that target and of no other target, so xcodegen adds the catalog to exactly one bundle.

InfoPlist.xcstrings and ServicesMenu.xcstrings are generator-owned; the catalog sync and the code-key
check skip them; regenerate with scripts/l10n/infoplist_catalogs.py.
"""

import argparse
import json
import os
import re
import subprocess
import sys

SOURCE_LANGUAGE = "en"


# ---------------------------------------------------------------------------
# A small YAML subset reader: block mappings and sequences, single-line flow [..] and {..},
# quoted and plain scalars, comments, anchors (&a) and aliases (*a). Every scalar stays a str.
# That is all project.yml uses; anything else raises YamlError instead of guessing.

class YamlError(Exception):
    pass


def _strip_comment(text):
    quote = None
    i = 0
    while i < len(text):
        c = text[i]
        if quote:
            if c == "\\" and quote == '"':
                i += 2
                continue
            if c == quote:
                quote = None
        elif c in "\"'":
            quote = c
        elif c == "#" and (i == 0 or text[i - 1] in " \t"):
            return text[:i].rstrip()
        i += 1
    return text.rstrip()


def _split_key(text):
    """Returns (key, rest) if `text` is `key: rest` / `key:`, else None."""
    quote = None
    i = 0
    if text[:1] in "[{":
        return None
    while i < len(text):
        c = text[i]
        if quote:
            if c == "\\" and quote == '"':
                i += 2
                continue
            if c == quote:
                quote = None
        elif c in "\"'" and i == 0:
            quote = c
        elif c == ":" and (i + 1 == len(text) or text[i + 1] in " \t"):
            return _scalar(text[:i].strip()), text[i + 1:].strip()
        i += 1
    return None


def _scalar(text):
    if len(text) >= 2 and text[0] == '"' and text[-1] == '"':
        return json.loads(text)
    if len(text) >= 2 and text[0] == "'" and text[-1] == "'":
        return text[1:-1].replace("''", "'")
    return text


class _Flow:
    def __init__(self, text, anchors, lineno):
        self.s, self.i, self.anchors, self.lineno = text, 0, anchors, lineno

    def error(self, msg):
        raise YamlError(f"project.yml:{self.lineno}: {msg}")

    def ws(self):
        while self.i < len(self.s) and self.s[self.i] in " \t":
            self.i += 1

    def value(self):
        self.ws()
        c = self.s[self.i:self.i + 1]
        if c == "[":
            self.i += 1
            out = []
            self.ws()
            if self.s[self.i:self.i + 1] == "]":
                self.i += 1
                return out
            while True:
                out.append(self.value())
                self.ws()
                c = self.s[self.i:self.i + 1]
                self.i += 1
                if c == "]":
                    return out
                if c != ",":
                    self.error("bad flow sequence")
        if c == "{":
            self.i += 1
            out = {}
            self.ws()
            if self.s[self.i:self.i + 1] == "}":
                self.i += 1
                return out
            while True:
                key = self.value()
                self.ws()
                if self.s[self.i:self.i + 1] != ":":
                    self.error("bad flow mapping")
                self.i += 1
                out[key] = self.value()
                self.ws()
                c = self.s[self.i:self.i + 1]
                self.i += 1
                if c == "}":
                    return out
                if c != ",":
                    self.error("bad flow mapping")
        if c in "\"'":
            j = self.i + 1
            while j < len(self.s):
                if self.s[j] == "\\" and c == '"':
                    j += 2
                    continue
                if self.s[j] == c:
                    if c == "'" and self.s[j + 1:j + 2] == "'":
                        j += 2
                        continue
                    break
                j += 1
            token, self.i = self.s[self.i:j + 1], j + 1
            return _scalar(token)
        if c == "*":
            m = re.match(r"\*([\w.-]+)", self.s[self.i:])
            self.i += m.end()
            return self.anchors[m.group(1)]
        m = re.match(r"[^,\]\}:]*(?::(?! )[^,\]\}:]*)*", self.s[self.i:])
        self.i += m.end()
        return m.group(0).strip()


def parse_yaml(text):
    lines = []
    for n, raw in enumerate(text.splitlines(), 1):
        if "\t" in raw[: len(raw) - len(raw.lstrip())]:
            raise YamlError(f"project.yml:{n}: tab indentation")
        body = _strip_comment(raw)
        if body.strip():
            lines.append((len(body) - len(body.lstrip(" ")), body.strip(), n))
    anchors = {}
    pos = [0]

    def inline(text, lineno, indent):
        """Value written after `key:` or `- `; may open a nested block."""
        anchor = None
        m = re.match(r"&([\w.-]+)\s*(.*)$", text)
        if m:
            anchor, text = m.group(1), m.group(2)
        if text == "":
            nxt = lines[pos[0]] if pos[0] < len(lines) else None
            if nxt and (nxt[0] > indent or (nxt[0] == indent and nxt[1].startswith("- "))):
                value = block(nxt[0])
            else:
                value = None
        elif text.startswith("*"):
            value = anchors[text[1:]]
        elif text[0] in "[{":
            flow = _Flow(text, anchors, lineno)
            value = flow.value()
            if text[flow.i:].strip():
                raise YamlError(f"project.yml:{lineno}: text after a flow value")
        elif text[0] in "|>":
            raise YamlError(f"project.yml:{lineno}: block scalars are not supported")
        else:
            value = _scalar(text)
        if anchor:
            anchors[anchor] = value
        return value

    def block(indent):
        first = lines[pos[0]]
        if first[1] == "-" or first[1].startswith("- "):
            out = []
            while pos[0] < len(lines) and lines[pos[0]][0] == indent and (
                    lines[pos[0]][1] == "-" or lines[pos[0]][1].startswith("- ")):
                _, text, n = lines[pos[0]]
                rest = text[1:].strip()
                kv = _split_key(rest) if rest else None
                if kv:
                    # `- key: value`: a mapping whose keys sit at indent + 2.
                    lines[pos[0]] = (indent + 2, rest, n)
                    out.append(block(indent + 2))
                else:
                    pos[0] += 1
                    out.append(inline(rest, n, indent))
            return out
        out = {}
        while pos[0] < len(lines) and lines[pos[0]][0] == indent:
            _, text, n = lines[pos[0]]
            if text.startswith("- "):
                break
            kv = _split_key(text)
            if not kv:
                raise YamlError(f"project.yml:{n}: expected `key: value`")
            pos[0] += 1
            key, rest = kv
            if key in out:
                raise YamlError(f"project.yml:{n}: duplicate key {key!r}")
            out[key] = inline(rest, n, indent)
        if pos[0] < len(lines) and lines[pos[0]][0] > indent:
            raise YamlError(f"project.yml:{lines[pos[0]][2]}: unexpected indentation")
        return out

    if not lines:
        return {}
    doc = block(lines[0][0])
    if pos[0] != len(lines):
        raise YamlError(f"project.yml:{lines[pos[0]][2]}: unexpected indentation")
    return doc


# ---------------------------------------------------------------------------
# Catalog contents

COPY_DO_NOT_TRANSLATE = "Lutik is the app name: do not translate it."
COPY_PROPER_NAMES = "Format and product names in it (such as ZIP, RAR or Android) are proper names."

EXTENSION_KINDS = {
    "com.apple.quicklook.preview": "Quick Look preview extension",
    "com.apple.quicklook.thumbnail": "Quick Look thumbnail extension",
}


def _where_kind_shows(platform):
    if platform == "macOS":
        return "Finder shows it in the Kind column and in Get Info."
    return "The Files app shows it as the file's kind."


def bundle_key_comment(key, target, platform, kind):
    if key == "CFBundleDisplayName":
        if kind == "application":
            where = ("Shown in Finder and the Dock." if platform == "macOS"
                     else "Shown under the app icon on the Home Screen.")
            return f"App name (CFBundleDisplayName). {where} {COPY_DO_NOT_TRANSLATE}"
        what = EXTENSION_KINDS.get(kind, "app extension")
        where = (" Shown in System Settings > General > Login Items & Extensions > Quick Look."
                 if platform == "macOS" else "")
        return (f"Name of Lutik's {what} (CFBundleDisplayName).{where} "
                f"{COPY_DO_NOT_TRANSLATE} Translate the rest.")
    if key == "CFBundleName":
        return ("Short app name (CFBundleName), shown as the application menu title in the menu bar. "
                f"{COPY_DO_NOT_TRANSLATE}")
    if key == "NSHumanReadableCopyright":
        return "Copyright notice (NSHumanReadableCopyright), shown in the About window and Get Info."
    raise AssertionError(key)


EXPORTED_WITHOUT_FILES = "ExportedTypeWithoutFiles"


def value_comment(roles, platform):
    if roles == {EXPORTED_WITHOUT_FILES}:
        # An exported type no file name maps to (the items Copy puts on the pasteboard): no file on
        # disk has it, so no Kind column or Get Info shows it.
        return ("Description of an exported type (UTTypeDescription): the data Lutik puts on the "
                "pasteboard when items are copied or cut in an archive window. No file has this type. "
                f"{COPY_DO_NOT_TRANSLATE} Translate the rest.")
    if EXPORTED_WITHOUT_FILES in roles:
        raise ProjectError(f"{sorted(roles)}: an exported pasteboard-only type shares its description")
    if roles == {"CFBundleTypeName", "UTTypeDescription"}:
        what = ("File type name, used both as a document type name (CFBundleTypeName) "
                "and as an imported type's description (UTTypeDescription).")
    elif roles == {"CFBundleTypeName"}:
        what = "Document type name (CFBundleTypeName)."
    else:
        what = "Description of an imported file type (UTTypeDescription)."
    return f"{what} {_where_kind_shows(platform)} {COPY_PROPER_NAMES}"


def services_menu_comment(service):
    types = service.get("NSSendFileTypes") or []
    what = ("any selected files and folders" if types == ["public.item"]
            else "the selected archives")
    return ("Name of a Finder Service (NSServices menu item title), shown in Finder's context menu "
            f"under Quick Actions or Services, and in the Services menu, for {what}. "
            f"{COPY_DO_NOT_TRANSLATE} Translate the rest.")


class ProjectError(Exception):
    pass


def _source_dirs(target):
    out = []
    for src in target.get("sources") or []:
        path = src.get("path") if isinstance(src, dict) else src
        if path:
            out.append(os.path.normpath(path))
    return out


CATALOG_NAMES = ("InfoPlist.xcstrings", "ServicesMenu.xcstrings")


def plan_catalogs(project):
    """Returns [(target name, catalog path, {key: (value, comment)})], sorted by path: each
    target's InfoPlist.xcstrings, and its ServicesMenu.xcstrings when it has NSServices."""
    targets = project.get("targets") or {}
    plans = []
    for name, target in targets.items():
        info = target.get("info")
        if not info:
            continue
        platform = target.get("platform")
        props = info.get("properties") or {}
        info_dir = os.path.normpath(os.path.dirname(info["path"]))
        catalog = os.path.join(info_dir, "InfoPlist.xcstrings")
        owners = [other for other, t in targets.items() if any(
            info_dir == d or info_dir.startswith(d + os.sep) for d in _source_dirs(t))]
        if owners != [name]:
            raise ProjectError(f"{catalog}: its directory is a source of {owners or 'no target'}, "
                               f"not only of {name}")
        ext_point = ((props.get("NSExtension") or {}).get("NSExtensionPointIdentifier"))
        kind = ext_point or target.get("type")
        entries = {}

        def resolve(value, key):
            if "$(" in value:
                raise ProjectError(f"{name}: {key} {value!r} uses a build setting")
            return value

        for key in ("CFBundleDisplayName", "NSHumanReadableCopyright"):
            if key in props:
                entries[key] = (resolve(props[key], key),
                                bundle_key_comment(key, name, platform, kind))
        if target.get("type") == "application" and platform == "macOS":
            bundle_name = props.get("CFBundleName", "$(PRODUCT_NAME)")
            if bundle_name == "$(PRODUCT_NAME)":
                settings = (target.get("settings") or {}).get("base") or {}
                bundle_name = settings.get("PRODUCT_NAME", name)
            entries["CFBundleName"] = (resolve(bundle_name, "CFBundleName"),
                                       bundle_key_comment("CFBundleName", name, platform, kind))

        roles = {}
        for doc_type in props.get("CFBundleDocumentTypes") or []:
            roles.setdefault(doc_type["CFBundleTypeName"], set()).add("CFBundleTypeName")
        for decl_key in ("UTImportedTypeDeclarations", "UTExportedTypeDeclarations"):
            for decl in props.get(decl_key) or []:
                if "UTTypeDescription" in decl:
                    role = ("UTTypeDescription"
                            if decl_key == "UTImportedTypeDeclarations" or decl.get("UTTypeTagSpecification")
                            else EXPORTED_WITHOUT_FILES)
                    roles.setdefault(decl["UTTypeDescription"], set()).add(role)
        for value, value_roles in roles.items():
            if value in entries:
                raise ProjectError(f"{name}: {value!r} collides with a bundle key")
            entries[resolve(value, "type name")] = (value, value_comment(value_roles, platform))
        plans.append((name, catalog, entries))

        services = props.get("NSServices") or []
        if services:
            menu = {}
            for service in services:
                title = (service.get("NSMenuItem") or {}).get("default")
                if not title:
                    raise ProjectError(f"{name}: an NSServices entry has no NSMenuItem default title")
                if title in menu:
                    raise ProjectError(f"{name}: two NSServices entries are titled {title!r}")
                menu[resolve(title, "NSMenuItem")] = (title, services_menu_comment(service))
            plans.append((name, os.path.join(info_dir, "ServicesMenu.xcstrings"), menu))
    return sorted(plans, key=lambda p: p[1])


# ---------------------------------------------------------------------------
# Xcode's .xcstrings text: JSONEncoder [.prettyPrinted, .sortedKeys]: 2-space indent, " : ",
# no trailing newline. Keys are sorted the way Foundation's sortedKeys does it (checked against
# `xcrun xcstringstool sync` output on Xcode 26.6), which for these ASCII keys is plain code
# point order.

def xcode_sort_key(key):
    return key.encode("utf-16-be")


def to_xcode_json(value, indent=0):
    pad = "  " * (indent + 1)
    if isinstance(value, dict):
        if not value:
            return "{\n\n" + "  " * indent + "}"
        items = [f"{pad}{json.dumps(k, ensure_ascii=False)} : {to_xcode_json(value[k], indent + 1)}"
                 for k in sorted(value, key=xcode_sort_key)]
        return "{\n" + ",\n".join(items) + "\n" + "  " * indent + "}"
    if isinstance(value, list):
        if not value:
            return "[\n\n" + "  " * indent + "]"
        items = [pad + to_xcode_json(v, indent + 1) for v in value]
        return "[\n" + ",\n".join(items) + "\n" + "  " * indent + "]"
    return json.dumps(value, ensure_ascii=False).replace("/", "\\/")


def catalog_text(entries):
    strings = {}
    for key, (value, comment) in entries.items():
        strings[key] = {
            "comment": comment,
            "extractionState": "manual",
            "localizations": {
                SOURCE_LANGUAGE: {"stringUnit": {"state": "translated", "value": value}},
            },
        }
    return to_xcode_json({"sourceLanguage": SOURCE_LANGUAGE, "strings": strings, "version": "1.0"})


# ---------------------------------------------------------------------------

def load_plist(path):
    """plistlib, or plutil when this Python's pyexpat is broken (seen with Homebrew 3.15)."""
    try:
        import plistlib
        with open(path, "rb") as f:
            return plistlib.load(f)
    except ImportError:
        out = subprocess.run(["plutil", "-convert", "json", "-o", "-", path], capture_output=True)
        if out.returncode:
            raise ProjectError(f"{path}: plutil can't read it: "
                               f"{out.stderr.decode(errors='replace').strip()}")
        return json.loads(out.stdout)
    except OSError:
        raise
    except Exception as e:  # ExpatError, plistlib.InvalidFileException, ...
        raise ProjectError(f"{path}: not a valid plist: {e}") from None


def plist_strings(path):
    """The localizable strings a committed Info.plist carries, as {key: value}."""
    plist = load_plist(path)
    out = {}
    for key in ("CFBundleDisplayName", "NSHumanReadableCopyright"):
        if key in plist:
            out[key] = plist[key]
    for doc_type in plist.get("CFBundleDocumentTypes", []):
        out[doc_type["CFBundleTypeName"]] = doc_type["CFBundleTypeName"]
    for decl_key in ("UTImportedTypeDeclarations", "UTExportedTypeDeclarations"):
        for decl in plist.get(decl_key, []):
            if "UTTypeDescription" in decl:
                out[decl["UTTypeDescription"]] = decl["UTTypeDescription"]
    return out


def run(root, check):
    with open(os.path.join(root, "project.yml"), encoding="utf-8") as f:
        project = parse_yaml(f.read())
    plans = plan_catalogs(project)
    problems = []
    expected = set()
    for name, catalog, entries in plans:
        expected.add(catalog)
        text = catalog_text(entries)
        path = os.path.join(root, catalog)
        info_path = os.path.join(os.path.dirname(path), "Info.plist")
        if os.path.basename(catalog) == "InfoPlist.xcstrings" and os.path.exists(info_path):
            from_plist = plist_strings(info_path)
            from_yml = {k: v for k, (v, _) in entries.items() if k != "CFBundleName"}
            if from_plist != from_yml:
                missing = sorted(set(from_yml) - set(from_plist))
                extra = sorted(set(from_plist) - set(from_yml))
                differ = sorted(k for k in set(from_yml) & set(from_plist)
                                if from_yml[k] != from_plist[k])
                problems.append(f"{os.path.relpath(info_path, root)} does not match project.yml "
                                f"(run xcodegen): only in project.yml {missing}, "
                                f"only in Info.plist {extra}, different values for {differ}")
        if check:
            try:
                with open(path, encoding="utf-8") as f:
                    current = f.read()
            except FileNotFoundError:
                problems.append(f"{catalog}: missing ({name}); run scripts/l10n/infoplist_catalogs.py")
                continue
            if current != text:
                problems.append(f"{catalog}: differs from project.yml ({name}); "
                                "run scripts/l10n/infoplist_catalogs.py")
        else:
            with open(path, "w", encoding="utf-8") as f:
                f.write(text)
            print(f"wrote {catalog} ({name}, {len(entries)} keys)")
    for top in ("App", "Extensions"):
        for dirpath, dirnames, filenames in os.walk(os.path.join(root, top)):
            dirnames[:] = [d for d in dirnames if not d.startswith(".")]
            for catalog_name in CATALOG_NAMES:
                if catalog_name not in filenames:
                    continue
                rel = os.path.relpath(os.path.join(dirpath, catalog_name), root)
                if rel not in expected:
                    owner = ("no target with an Info.plist in this directory owns it"
                             if catalog_name == "InfoPlist.xcstrings"
                             else "no target with NSServices in its Info.plist in this directory owns it")
                    problems.append(f"{rel}: {owner}")
    for p in problems:
        print(f"infoplist_catalogs: error: {p}", file=sys.stderr)
    if check and not problems:
        print(f"infoplist_catalogs: OK ({len(plans)} catalogs match project.yml)")
    return 1 if problems else 0


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Generate or check the InfoPlist.xcstrings catalogs from project.yml.")
    parser.add_argument("--check", action="store_true",
                        help="write nothing; exit 1 if the catalogs drift from project.yml")
    parser.add_argument("--root", default=os.path.normpath(
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")),
        help="repo root (default: two levels above this script)")
    args = parser.parse_args(argv)
    try:
        return run(args.root, args.check)
    except (YamlError, ProjectError, KeyError) as e:
        print(f"infoplist_catalogs: error: {e}", file=sys.stderr)
        return 1
    except (OSError, ValueError) as e:
        # A wrong --root, a missing project.yml, a file that isn't UTF-8 (UnicodeDecodeError is
        # a ValueError): a message, not a traceback.
        print(f"infoplist_catalogs: error: {type(e).__name__}: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
