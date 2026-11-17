#!/usr/bin/env python3
"""Builds the committed fixture corpus in Fixtures/ and writes Fixtures/manifest.json.

Expected entries come from the in-code trees below, not from reading the archives back
with libarchive, so the manifest is an independent oracle for KernirCore. Third-party
samples (rar, lha, cab) are the exception: their expectations come from libarchive's own
test suite and are cross-checked by verify_corpus.py.

Usage (from the repo root):
    python3 -I scripts/fixtures/build_corpus.py [--libarchive-src DIR]

Needs: python3, zip, ditto, 7zz (brew install sevenzip), gcab (brew install gcab),
zstd, xar, bsdtar, hdiutil. --libarchive-src points at an unpacked libarchive release
(3.7.7); without it the third-party samples already in Fixtures/third-party are kept.
"""

import argparse
import binascii
import bz2
import gzip
import hashlib
import io
import json
import lzma
import os
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import unicodedata
import warnings
import zipfile
import zlib
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / "Fixtures"
PASSWORD = "kernir"
WRONG_PASSWORD = "not-kernir"
# 2026-01-02T03:04:05Z. Even seconds, so DOS timestamps are exact.
MTIME = 1767323045
DOS_TIME = (2026, 1, 2, 3, 4, 5)


# MARK: - Content


def blob(n: int, seed: str) -> bytes:
    """Deterministic incompressible bytes."""
    out = bytearray()
    counter = 0
    while len(out) < n:
        out += hashlib.sha256(f"{seed}:{counter}".encode()).digest()
        counter += 1
    return bytes(out[:n])


def text_blob(n: int) -> bytes:
    line = b"The quick brown fox jumps over the lazy dog. 0123456789\n"
    return (line * (n // len(line) + 1))[:n]


class Tree:
    """Files (path -> bytes), explicit directories, symlinks (path -> target)."""

    def __init__(self, files, dirs=(), symlinks=None):
        self.files = dict(files)
        self.dirs = set(dirs)
        self.symlinks = dict(symlinks or {})

    def all_dirs(self):
        out = set(self.dirs)
        for p in list(self.files) + list(self.symlinks) + list(self.dirs):
            parts = p.split("/")[:-1]
            for i in range(1, len(parts) + 1):
                out.add("/".join(parts[:i]))
        return out

    def ordered(self):
        """Dirs before their contents, sorted, as most archivers emit them."""
        items = [(d, "dir") for d in self.all_dirs()]
        items += [(f, "file") for f in self.files]
        items += [(s, "symlink") for s in self.symlinks]
        return sorted(items, key=lambda x: x[0].split("/"))

    def stage(self, root: Path):
        for d in sorted(self.all_dirs()):
            (root / d).mkdir(parents=True, exist_ok=True)
        for p, data in self.files.items():
            (root / p).parent.mkdir(parents=True, exist_ok=True)
            (root / p).write_bytes(data)
            os.chmod(root / p, 0o644)
        for p, target in self.symlinks.items():
            os.symlink(target, root / p)
        for d in self.all_dirs():
            os.chmod(root / d, 0o755)
        # mtimes last, deepest first, so directory mtimes are not bumped afterwards.
        for p in sorted(list(self.files) + list(self.all_dirs()), key=lambda x: -x.count("/")):
            os.utime(root / p, (MTIME, MTIME))
        for p in self.symlinks:
            os.utime(root / p, (MTIME, MTIME), follow_symlinks=False)
        return sorted(p for p in os.listdir(root))

    def manifest_entries(self):
        """Paths in NFC: KernirCore normalizes every name it lists."""
        return [dict(e, path=unicodedata.normalize("NFC", e["path"])) for e in self._entries()]

    def _entries(self):
        out = []
        for path, kind in self.ordered():
            if kind == "dir":
                out.append({"path": path, "dir": True})
            elif kind == "file":
                data = self.files[path]
                out.append({"path": path, "dir": False, "size": len(data),
                            "sha256": hashlib.sha256(data).hexdigest()})
            else:
                out.append({"path": path, "dir": False, "symlink": self.symlinks[path]})
        return out


BASIC = Tree(
    files={
        "hello.txt": b"Hello, Kernir!\n",
        "empty.txt": b"",
        "docs/readme.md": b"# Kernir fixture\n\nA small tree used across formats.\n",
        "docs/notes.txt": text_blob(20_000),
        "docs/nested/deep/data.bin": blob(70_000, "basic-data"),
    },
    dirs={"empty-dir"},
)

UNICODE = Tree(
    files={
        "Привет мир.txt": "Привет, Kernir!\n".encode(),
        "日本語/ファイル.txt": "こんにちは\n".encode(),
        "café.txt": "NFC é\n".encode(),
        "emoji 🎉.txt": "party\n".encode(),
        "spaces and (parens) [1].txt": b"punctuation\n",
    },
)

# Decomposed names, as HFS+ stored them and Archive Utility zips still carry them.
NFD = Tree(files={
    unicodedata.normalize("NFD", "café.txt"): b"nfd\n",
    unicodedata.normalize("NFD", "Ångström/über.txt"): b"nfd umlaut\n",
    unicodedata.normalize("NFD", "Йошкар-Ола.txt"): b"nfd cyrillic\n",
})

# Names a Windows user with a Russian locale produces (Explorer "Send to > Compressed folder").
CP866 = Tree(files={
    "Привет.txt": "cp866 name\n".encode(),
    "Документы/отчёт.txt": "report\n".encode(),
})
CP437 = Tree(files={
    "café.txt": b"cp437 name\n",
    "Ångström/über.txt": b"umlaut\n",
})

# One archive per legacy code page, no UTF-8 flag (the detector table). CP932's "表" ends in byte 0x5C, so
# "表/一覧表.txt" checks the trail-byte fix-up next to a real separator.
LEGACY = {
    "cp1251": ["Отчёт за май.docx", "отчет.txt", "Фото/Лето 2024.jpg"],
    "cp866": ["Привет.txt", "Отчёт_2024.doc"],
    "koi8r": ["Документы/письмо.txt", "приказ.doc"],
    "cp932": ["表/一覧表.txt", "ひらがな.txt", "カタカナ資料.doc", "資料v2.xlsx", "漢字.txt"],
    "gb18030": ["中文文件名.txt", "报告/会议记录.docx"],
    "big5": ["報告書.txt", "會議記錄.docx"],
    "cp949": ["한국어 파일.txt", "보고서/회의록.hwp"],
    "cp1252": ["Größe.txt", "Café crème.doc", "Ångström.pdf"],
    "cp1250": ["Žluťoučký kůň.txt", "Łódź.doc"],
}
LEGACY_CODEC = {"koi8r": "koi8_r"}
LEGACY_TREES = {key: Tree(files={name: f"{key} {i}\n".encode() for i, name in enumerate(names)})
                for key, names in LEGACY.items()}

SOLID = Tree(files={f"text/file{i:02}.txt": text_blob(3_000 + i) for i in range(12)}
             | {"bin/random.bin": blob(40_000, "solid")})

SYMLINKS = Tree(
    files={"hello.txt": b"Hello, Kernir!\n", "docs/readme.md": b"readme\n"},
    symlinks={"link-to-hello": "hello.txt", "link-to-docs": "docs", "dangling": "missing.txt"},
)

LONG = "a-very-long-directory-name-to-exceed-the-ustar-limit/" * 3
LONG_NAMES = Tree(files={LONG + "long-file-name-" + "x" * 80 + ".txt": b"long\n",
                         "short.txt": b"short\n"})


# MARK: - Manifest


FIXTURES = []


def record(rel, fmt, entries, *, open_="ok", extract="ok", password=None, encrypted=False,
           extract_without_password=None, wrong_password=None, extract_expect=None, detect="same",
           extract_with_wrong_password=None, tags=(), notes="", source="generated", mtime=None,
           complete=True, entry_count=None, volumes=None, comment=None, entry_comments=None,
           mac_metadata=None):
    """open_/extract: "ok", an ArchiveError case name, "error" (any ArchiveError) or "any"
    (must not crash or hang). See docs/qa/fixtures.md for every field."""
    if complete and entry_count is None:
        entry_count = len(entries)
    # Only multi-volume rows carry "volumes", and only rows that set them carry "comment", "entryComments"
    # and "macMetadata": an unchanged row keeps its committed bytes (main()).
    FIXTURES.append(({"volumes": volumes} if volumes else {}) | {
        "file": rel,
        "format": fmt,
        "detect": fmt if detect == "same" else detect,
        "open": open_,
        "password": password,
        "encrypted": encrypted,
        "extract": extract,
        "extractWithoutPassword": extract_without_password,
        "openWithWrongPassword": wrong_password,
        "extractWithWrongPassword": extract_with_wrong_password,
        "extractExpect": extract_expect,
        "mtime": mtime,
        "entriesComplete": complete,
        "entryCount": entry_count,
        "entries": entries,
        "tags": list(tags),
        "notes": notes,
        "source": source,
    } | {k: v for k, v in (("comment", comment), ("entryComments", entry_comments),
                           ("macMetadata", mac_metadata)) if v is not None})


def out(rel) -> Path:
    p = OUT / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    if p.exists():
        p.unlink()
    return p


def run(*args, cwd=None, input=None):
    subprocess.run([str(a) for a in args], cwd=cwd, input=input, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


# MARK: - ZIP


def zip_with_python(rel, tree, method=zipfile.ZIP_DEFLATED, dir_entries=True, stream=False):
    path = out(rel)

    class Unseekable(io.RawIOBase):
        def __init__(self, f): self.f = f
        def writable(self): return True
        def write(self, b): return self.f.write(b)

    with open(path, "wb") as raw:
        target = Unseekable(raw) if stream else raw
        with zipfile.ZipFile(target, "w", compression=method) as zf:
            for p, kind in tree.ordered():
                if kind == "dir":
                    if not dir_entries:
                        continue
                    zi = zipfile.ZipInfo(p + "/", DOS_TIME)
                    zi.external_attr = (0o40755 << 16) | 0x10
                    zi.create_system = 3
                    zf.writestr(zi, b"")
                elif kind == "file":
                    zi = zipfile.ZipInfo(p, DOS_TIME)
                    zi.external_attr = 0o100644 << 16
                    zi.create_system = 3
                    zi.compress_type = method
                    zf.writestr(zi, tree.files[p])
                else:
                    zi = zipfile.ZipInfo(p, DOS_TIME)
                    zi.external_attr = 0o120777 << 16
                    zi.create_system = 3
                    zf.writestr(zi, tree.symlinks[p].encode())


def zip_raw(rel, members, utf8_flag):
    """Minimal zip writer for names in a legacy code page. members: [(name_bytes, data|None)] or
    [(name_bytes, data|None, utf8_flag, extra_field_bytes)] to set the flag and extra per entry."""
    path = out(rel)
    dos_time = (DOS_TIME[3] << 11) | (DOS_TIME[4] << 5) | (DOS_TIME[5] // 2)
    dos_date = ((DOS_TIME[0] - 1980) << 9) | (DOS_TIME[1] << 5) | DOS_TIME[2]
    body, central = bytearray(), bytearray()
    for name, data, *own in members:
        flags = 0x800 if (own[0] if own else utf8_flag) else 0
        extra = own[1] if own else b""
        is_dir = data is None
        data = data or b""
        crc = zlib.crc32(data)
        comp = zlib.compressobj(9, zlib.DEFLATED, -15)
        cdata = comp.compress(data) + comp.flush() if data else b""
        method = 8 if data else 0
        offset = len(body)
        body += struct.pack("<IHHHHHIIIHH", 0x04034B50, 20, flags, method, dos_time, dos_date,
                            crc, len(cdata), len(data), len(name), len(extra)) + name + extra + cdata
        # made by MS-DOS (0) so readers apply code-page heuristics like they do for Explorer zips
        central += struct.pack("<IHHHHHHIIIHHHHHII", 0x02014B50, 20, 20, flags, method, dos_time,
                               dos_date, crc, len(cdata), len(data), len(name), len(extra), 0, 0, 0,
                               0x10 if is_dir else 0x20, offset) + name + extra
    eocd = struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, len(members), len(members), len(central),
                       len(body), 0)
    path.write_bytes(bytes(body + central + eocd))


def tree_members(tree, encoding):
    members = []
    for p, kind in tree.ordered():
        if kind == "dir":
            members.append(((p + "/").encode(encoding), None))
        else:
            members.append((p.encode(encoding), tree.files[p]))
    return members


def build_zip(stage_root):
    zip_with_python("zip/deflate.zip", BASIC)
    record("zip/deflate.zip", "zip", BASIC.manifest_entries(), tags=["baseline"])

    zip_with_python("zip/store.zip", BASIC, method=zipfile.ZIP_STORED)
    record("zip/store.zip", "zip", BASIC.manifest_entries())

    zip_with_python("zip/bzip2-method.zip", BASIC, method=zipfile.ZIP_BZIP2)
    record("zip/bzip2-method.zip", "zip", BASIC.manifest_entries(), notes="ZIP compression method 12")

    zip_with_python("zip/lzma-method.zip", BASIC, method=zipfile.ZIP_LZMA)
    record("zip/lzma-method.zip", "zip", BASIC.manifest_entries(), tags=["libarchive-bug"],
           notes="ZIP compression method 14. libarchive 3.7.4 fails on the zero-length LZMA entry empty.txt "
                 "('lzma unknown error 10'); 7-Zip reads it fine.")

    no_dirs = Tree({k: v for k, v in BASIC.files.items()})
    zip_with_python("zip/no-dir-entries.zip", no_dirs, dir_entries=False)
    record("zip/no-dir-entries.zip", "zip", no_dirs.manifest_entries(), tags=["synthesized-dirs"],
           notes="Archive has no directory entries; Kernir must synthesize docs, docs/nested, docs/nested/deep.")

    zip_with_python("zip/data-descriptor.zip", BASIC, stream=True)
    record("zip/data-descriptor.zip", "zip", BASIC.manifest_entries(),
           notes="Written to an unseekable stream: sizes/CRC in trailing data descriptors (Java, web servers).")

    # Info-ZIP with forced zip64 records (-fz); small, so it stays in the corpus.
    d = stage_root / "zip64"
    names = BASIC.stage(d)
    p = out("zip/zip64.zip")
    run("zip", "-q", "-X", "-fz", "-r", p, *names, cwd=d)
    record("zip/zip64.zip", "zip", BASIC.manifest_entries(), tags=["zip64"],
           notes="Info-ZIP -fz: zip64 extra fields + zip64 end of central directory on a small archive.")

    zip_with_python("zip/unicode-utf8-flag.zip", UNICODE)
    record("zip/unicode-utf8-flag.zip", "zip", UNICODE.manifest_entries(), tags=["unicode"])

    zip_raw("zip/unicode-no-flag.zip", tree_members(UNICODE, "utf-8"), utf8_flag=False)
    record("zip/unicode-no-flag.zip", "zip", UNICODE.manifest_entries(), tags=["unicode", "charset-heuristic"],
           notes="UTF-8 names without general purpose bit 11 (old macOS / Linux zip). Expected: decoded as UTF-8.")

    zip_with_python("zip/nfd-names.zip", NFD)
    record("zip/nfd-names.zip", "zip", NFD.manifest_entries(), tags=["unicode", "nfd"],
           notes="NFD names with the UTF-8 flag; listed as NFC.")

    # zipfile warns on a repeated name but writes both members (and both central directory records).
    final = b"second, longer copy\n"
    p = out("zip/duplicates.zip")
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", UserWarning)
        with zipfile.ZipFile(p, "w", compression=zipfile.ZIP_STORED) as zf:
            for name, content in (("dup.txt", b"first\n"), ("other.txt", b"other\n"), ("dup.txt", final)):
                zf.writestr(zipfile.ZipInfo(name, DOS_TIME), content)
    record("zip/duplicates.zip", "zip",
           [{"path": "dup.txt", "dir": False, "size": len(final), "sha256": hashlib.sha256(final).hexdigest()},
            {"path": "other.txt", "dir": False, "size": 6, "sha256": hashlib.sha256(b"other\n").hexdigest()}],
           tags=["duplicates"],
           notes="dup.txt stored twice, different contents. Last member wins, one row (in the first one's place).")

    many = Tree({f"d{i // 100:03}/f{i % 100:02}.txt": f"{i}\n".encode() for i in range(10_000)})
    zip_with_python("zip/many-entries.zip", many, method=zipfile.ZIP_STORED, dir_entries=False)
    sample = [e for e in many.manifest_entries() if e["path"].startswith("d000") or e["path"].startswith("d099")]
    record("zip/many-entries.zip", "zip", sample, complete=False, entry_count=10_100,
           tags=["many-entries", "synthesized-dirs"],
           notes="10,000 files in 100 synthesized dirs (10,100 entries). entries lists only d000 and d099; "
                 "path pattern d{NNN}/f{NN}.txt, content '{index}\\n'.")

    zip_raw("zip/cp866.zip", tree_members(CP866, "cp866"), utf8_flag=False)
    record("zip/cp866.zip", "zip", CP866.manifest_entries(), tags=["charset-heuristic", "cp866"],
           notes="Russian Windows Explorer zip: CP866 names, no UTF-8 flag. Ideal: Cyrillic decoded. "
                 "Minimum: open succeeds and names are not empty.")

    zip_raw("zip/cp437.zip", tree_members(CP437, "cp437"), utf8_flag=False)
    record("zip/cp437.zip", "zip", CP437.manifest_entries(), tags=["charset-heuristic", "cp437"],
           notes="Western Windows zip: CP437 names, no UTF-8 flag (the ZIP spec default).")

    for key, tree in LEGACY_TREES.items():
        codec = LEGACY_CODEC.get(key, key)
        zip_raw(f"zip/legacy-{key}.zip", tree_members(tree, codec), utf8_flag=False)
        record(f"zip/legacy-{key}.zip", "zip", tree.manifest_entries(),
               tags=["charset-heuristic", "legacy-encoding", key],
               notes=f"{codec} names, no UTF-8 flag, made by MS-DOS. Automatic "
                     "detection must pick this one encoding for the whole archive. A zip save keeps every "
                     "kept entry's raw name bytes and flag; added entries are UTF-8 with bit 11.")

    # Declared names are never reinterpreted: bit 11 (UTF-8) and Info-ZIP's Unicode Path extra 0x7075
    # (version 1, CRC-32 of the header name, UTF-8 name). The 0x7075 entry's header name is CP866, so
    # reading it with the archive's CP1251 would give the wrong text.
    flagged = "Привет мир.txt"
    unicode_path, unicode_raw = "Лето.jpg", "Лето.jpg".encode("cp866")
    up = struct.pack("<BI", 1, zlib.crc32(unicode_raw)) + unicode_path.encode()
    mixed = [(flagged.encode(), b"utf-8 flagged\n", True, b""),
             ("Отчёт за май.docx".encode("cp1251"), b"cp1251 0\n", False, b""),
             ("отчет.txt".encode("cp1251"), b"cp1251 1\n", False, b""),
             (unicode_raw, b"0x7075\n", False, struct.pack("<HH", 0x7075, len(up)) + up)]
    zip_raw("zip/legacy-mixed-flagged.zip", mixed, utf8_flag=False)
    mixed_tree = Tree(files={flagged: b"utf-8 flagged\n", "Отчёт за май.docx": b"cp1251 0\n",
                             "отчет.txt": b"cp1251 1\n", unicode_path: b"0x7075\n"})
    record("zip/legacy-mixed-flagged.zip", "zip", mixed_tree.manifest_entries(),
           tags=["charset-heuristic", "legacy-encoding", "cp1251"],
           notes="One bit-11 UTF-8 name, two undeclared CP1251 names, and Лето.jpg whose header name is "
                 "CP866 with a 0x7075 Unicode Path extra. Declared names stay as declared; only the two "
                 "undeclared ones go through detection (CP1251).")

    zip_with_python("zip/symlinks.zip", SYMLINKS)
    record("zip/symlinks.zip", "zip", SYMLINKS.manifest_entries(), tags=["symlink"],
           notes="Unix symlinks (mode 0120777). 'dangling' points nowhere.")

    empty_dirs = Tree({}, dirs={"a/b/c", "x", "y/z"})
    zip_with_python("zip/empty-dirs.zip", empty_dirs)
    record("zip/empty-dirs.zip", "zip", empty_dirs.manifest_entries(), tags=["empty-dirs"])

    p = out("zip/empty.zip")
    p.write_bytes(struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, 0, 0, 0, 0, 0))
    record("zip/empty.zip", "zip", [], notes="Valid zip with zero entries (end of central directory only).")

    build_macosx_zip(stage_root)

    d = stage_root / "enc"
    names = BASIC.stage(d)
    for rel, method, label, password, extra in (
        ("zip/aes256.zip", "AES256", "WinZip AES-256", PASSWORD, []),
        ("zip/aes128.zip", "AES128", "WinZip AES-128", PASSWORD, []),
        ("zip/zipcrypto.zip", "ZipCrypto", "traditional PKWARE ZipCrypto", PASSWORD, []),
        ("zip/aes256-store.zip", "AES256", "WinZip AES-256, stored", PASSWORD, ["-mx=0"]),
        ("zip/aes128-store.zip", "AES128", "WinZip AES-128, stored", PASSWORD, ["-mx=0"]),
        ("zip/zipcrypto-store.zip", "ZipCrypto", "ZipCrypto, stored", PASSWORD, ["-mx=0"]),
        # 7-Zip refuses non-ASCII ZIP passwords on create (E_INVALIDARG) but reads them; libarchive writes UTF-8.
        ("zip/aes256-cyrillic-password.zip", "AES256", "WinZip AES-256 written by libarchive, password 'пароль' "
         "(UTF-8 bytes)", "пароль", None),
    ):
        p = out(rel)
        if extra is None:
            run("bsdtar", "-c", "--no-mac-metadata", "--format", "zip", "--options", "zip:encryption=aes256", "--passphrase", password,
                "-f", p, *names, cwd=d)
        else:
            run("7zz", "a", "-tzip", f"-mem={method}", f"-p{password}", *extra, "-bd", "-y", p, *names, cwd=d)
        record(rel, "zip", zip_encryption_flags(p, BASIC.manifest_entries()), password=password, encrypted=True,
               extract_without_password="passwordRequired", wrong_password="wrongPassword",
               extract_with_wrong_password="wrongPassword",
               tags=["encrypted"] + (["password-unicode"] if password != PASSWORD else []),
               notes=f"{label}, data encrypted, names visible: open() lists without a password. "
                     f"Per-entry 'encrypted' comes from the ZIP flag bit 0.")

    # Mixed: hello.txt and docs/** encrypted (AES-256), the rest appended in the clear. plain.txt is the plain
    # entry with content: zero-length entries carry no encryption state worth asserting after a repack.
    plain = Tree({"plain.txt": b"Stored without encryption in a mixed archive.\n"})
    plain_dir = stage_root / "enc-plain"
    plain.stage(plain_dir)
    p = out("zip/mixed-encryption.zip")
    run("7zz", "a", "-tzip", "-mem=AES256", f"-p{PASSWORD}", "-bd", "-y", p, "hello.txt", "docs", cwd=d)
    run("7zz", "a", "-tzip", "-bd", "-y", p, "empty.txt", "empty-dir", cwd=d)
    run("7zz", "a", "-tzip", "-bd", "-y", p, "plain.txt", cwd=plain_dir)
    mixed_entries = sorted(BASIC.manifest_entries() + plain.manifest_entries(), key=lambda e: e["path"].split("/"))
    record("zip/mixed-encryption.zip", "zip", zip_encryption_flags(p, mixed_entries),
           password=PASSWORD, encrypted=True, extract_without_password="passwordRequired",
           wrong_password="wrongPassword", extract_with_wrong_password="wrongPassword",
           tags=["encrypted", "mixed-encryption"],
           notes="Some entries AES-256, some plain. Plain entries extract without a password; extract(nil) "
                 "without a password throws passwordRequired. Repack with options nil encrypts every non-empty "
                 "entry with the source's method.")


def zip_encryption_flags(path, entries):
    """Adds per-entry 'encrypted' from the central directory flag bit (read with zipfile, not libarchive)."""
    with zipfile.ZipFile(path) as zf:
        flags = {zi.filename.rstrip("/"): bool(zi.flag_bits & 1) for zi in zf.infolist()}
    return [dict(e, encrypted=flags.get(e["path"], False)) for e in entries]


def build_macosx_zip(stage_root):
    """Finder "Compress": ditto with resource forks sequestered into __MACOSX/._*."""
    d = stage_root / "macosx" / "Project"
    tree = Tree({"hello.txt": b"Hello, Kernir!\n", "docs/readme.md": b"readme\n"})
    d.mkdir(parents=True)
    tree.stage(d)
    run("xattr", "-wx", "com.apple.ResourceFork", (b"KERNIR-RSRC" * 8).hex(), d / "hello.txt")
    run("xattr", "-w", "com.apple.metadata:kMDItemWhereFroms", "fixture", d / "docs/readme.md")
    for p in ("hello.txt", "docs/readme.md", "docs", "."):
        os.utime(d / p, (MTIME, MTIME))
    p = out("zip/macos-finder.zip")
    run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", d, p)
    # AppleDouble bytes come from ditto; read them back with Python's zipfile (not libarchive).
    entries, seen_dirs = [], set()
    with zipfile.ZipFile(p) as zf:
        for zi in zf.infolist():
            name = zi.filename.rstrip("/")
            parts = name.split("/")
            for i in range(1, len(parts)):
                seen_dirs.add("/".join(parts[:i]))
            if zi.is_dir():
                seen_dirs.add(name)
            else:
                data = zf.read(zi)
                entries.append({"path": name, "dir": False, "size": len(data),
                                "sha256": hashlib.sha256(data).hexdigest()})
    entries += [{"path": x, "dir": True} for x in seen_dirs]
    entries.sort(key=lambda e: e["path"].split("/"))
    record("zip/macos-finder.zip", "zip", entries, tags=["macosx", "resource-fork"],
           mac_metadata=["__MACOSX", "__MACOSX/Project", "__MACOSX/Project/._docs", "__MACOSX/Project/._hello.txt",
                         "__MACOSX/Project/docs", "__MACOSX/Project/docs/._readme.md"],
           notes="Made with ditto like Finder > Compress. Contains __MACOSX/ AppleDouble ._ files, listed raw. "
                 "libarchive built with HAVE_COPYFILE_H (Apple) merges them into their files and hides them "
                 "from the listing; a repack must still keep all of them byte-identical.")


# MARK: - 7z


def build_7z(stage_root):
    d = stage_root / "7z-basic"
    names = BASIC.stage(d)
    variants = [
        ("7z/lzma2.7z", ["-m0=lzma2", "-ms=off"], "LZMA2, non-solid", ["baseline"]),
        ("7z/lzma.7z", ["-m0=lzma", "-ms=off"], "LZMA (v1)", []),
        ("7z/ppmd.7z", ["-m0=ppmd", "-ms=off"], "PPMd", []),
        ("7z/bzip2.7z", ["-m0=bzip2", "-ms=off"], "BZip2", []),
        ("7z/deflate.7z", ["-m0=deflate", "-ms=off"], "Deflate", []),
        ("7z/copy.7z", ["-m0=copy"], "Stored (copy)", []),
        ("7z/bcj.7z", ["-mf=BCJ", "-m0=lzma2"], "BCJ x86 filter + LZMA2", []),
    ]
    for rel, args, label, tags in variants:
        p = out(rel)
        run("7zz", "a", "-t7z", *args, "-mtc=off", "-mta=off", "-bd", "-y", p, *names, cwd=d)
        record(rel, "sevenZip", BASIC.manifest_entries(), mtime=MTIME, tags=tags, notes=label)

    d = stage_root / "7z-solid"
    names = SOLID.stage(d)
    p = out("7z/solid.7z")
    run("7zz", "a", "-t7z", "-m0=lzma2", "-ms=on", "-mtc=off", "-mta=off", "-bd", "-y", p, *names, cwd=d)
    record("7z/solid.7z", "sevenZip", SOLID.manifest_entries(), mtime=MTIME, tags=["solid"],
           notes="Solid block: extracting one file decodes its predecessors.")

    d = stage_root / "7z-unicode"
    names = UNICODE.stage(d)
    p = out("7z/unicode.7z")
    run("7zz", "a", "-t7z", "-mtc=off", "-mta=off", "-bd", "-y", p, *names, cwd=d)
    record("7z/unicode.7z", "sevenZip", UNICODE.manifest_entries(), mtime=MTIME, tags=["unicode"])

    empties = Tree({"empty.txt": b"", "also-empty.txt": b""}, dirs={"empty-dir"})
    d = stage_root / "7z-empty"
    names = empties.stage(d)
    p = out("7z/only-empty.7z")
    run("7zz", "a", "-t7z", "-mtc=off", "-mta=off", "-bd", "-y", p, *names, cwd=d)
    record("7z/only-empty.7z", "sevenZip", empties.manifest_entries(), mtime=MTIME,
           notes="No packed streams at all: only empty files and an empty dir (7z 'empty stream' bits).")

    d = stage_root / "7z-basic"
    base = names_of(d)
    sevenzip_encrypted("7z/encrypted-data.7z", BASIC, d, base, PASSWORD, headers=False)
    sevenzip_encrypted("7z/encrypted-headers.7z", BASIC, d, base, PASSWORD, headers=True)
    # Short password, header-encrypted twin, non-ASCII password, solid multi-file.
    sevenzip_encrypted("7z/aes-pw.7z", BASIC, d, base, "pw", headers=False)
    sevenzip_encrypted("7z/aes-he-pw.7z", BASIC, d, base, "pw", headers=True)
    sevenzip_encrypted("7z/aes-cyrillic-password.7z", BASIC, d, base, "пароль", headers=False,
                       tags=["password-unicode"], notes="Password 'пароль' (7z derives the key from UTF-16LE).")
    d = stage_root / "7z-solid"
    sevenzip_encrypted("7z/aes-solid.7z", SOLID, d, names_of(d), "pw", headers=False, solid=True,
                       tags=["solid"], notes="Solid LZMA2 block of 13 files, AES-256.")


# KernirCore's 7z AES read (libarchive patch 0004): expectations moved from unsupportedEncryption to
# passwordRequired / wrongPassword / ok. A wrong password is caught at open for both forms.
SEVENZIP_AES = True


def sevenzip_encrypted(rel, tree, d, names, password, *, headers, solid=False, tags=(), notes=""):
    p = out(rel)
    args = ["-m0=lzma2", "-ms=on" if solid else "-ms=off", f"-mhe={'on' if headers else 'off'}"]
    run("7zz", "a", "-t7z", f"-p{password}", *args, "-mtc=off", "-mta=off", "-bd", "-y", p, *names, cwd=d)
    tags = ["encrypted"] + (["encrypted-headers"] if headers else []) + list(tags)
    kind = "Header encryption (-mhe=on): names hidden without the password." if headers else \
        "AES-256 data, plain headers: lists without a password (isEncrypted true)."
    if SEVENZIP_AES:
        record(rel, "sevenZip", tree.manifest_entries(), mtime=MTIME, password=password, encrypted=True,
               open_="passwordRequired" if headers else "ok",
               extract_without_password="passwordRequired", wrong_password="wrongPassword",
               extract_with_wrong_password="wrongPassword", tags=tags + ["patched-libarchive"],
               notes=f"{kind} {notes}".strip())
    elif headers:
        record(rel, "sevenZip", tree.manifest_entries(), open_="unsupportedEncryption", extract="any",
               password=password, encrypted=True, complete=False, wrong_password="unsupportedEncryption",
               tags=tags + ["libarchive-gap"],
               notes=f"{kind} {notes} Until 7z AES lands, open() throws unsupportedEncryption(.sevenZip); "
                     "entries = what the archive really contains.".strip())
    else:
        record(rel, "sevenZip", tree.manifest_entries(), mtime=MTIME, password=password, encrypted=True,
               extract="unsupportedEncryption", extract_without_password="unsupportedEncryption",
               extract_with_wrong_password="unsupportedEncryption", tags=tags + ["libarchive-gap"],
               notes=f"{kind} {notes} Until 7z AES lands, extract throws unsupportedEncryption(.sevenZip).")


def names_of(d):
    return sorted(os.listdir(d))


# MARK: - TAR family and single-stream compressors


def tar_bytes(tree, fmt=tarfile.PAX_FORMAT, hardlink=None, encoding="utf-8"):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=fmt, encoding=encoding) as tf:
        for p, kind in tree.ordered():
            ti = tarfile.TarInfo(p)
            ti.mtime, ti.uid, ti.gid, ti.uname, ti.gname = MTIME, 0, 0, "", ""
            if kind == "dir":
                ti.type, ti.mode = tarfile.DIRTYPE, 0o755
                tf.addfile(ti)
            elif kind == "file":
                data = tree.files[p]
                ti.mode, ti.size = 0o644, len(data)
                tf.addfile(ti, io.BytesIO(data))
            else:
                ti.type, ti.mode, ti.linkname = tarfile.SYMTYPE, 0o777, tree.symlinks[p]
                tf.addfile(ti)
        if hardlink:
            name, target = hardlink
            ti = tarfile.TarInfo(name)
            ti.type, ti.linkname, ti.mode, ti.mtime = tarfile.LNKTYPE, target, 0o644, MTIME
            tf.addfile(ti)
    return buf.getvalue()


def zstd_compress(data):
    return subprocess.run(["zstd", "-q", "-19", "-c"], input=data, check=True,
                          stdout=subprocess.PIPE).stdout


def gzip_compress(data, filename=""):
    buf = io.BytesIO()
    with gzip.GzipFile(filename=filename, mode="wb", fileobj=buf, mtime=MTIME) as g:
        g.write(data)
    return buf.getvalue()


def build_tar():
    plain = tar_bytes(BASIC)
    out("tar/basic.tar").write_bytes(plain)
    record("tar/basic.tar", "tar", BASIC.manifest_entries(), mtime=MTIME, tags=["baseline"], notes="POSIX pax")

    out("tar/ustar.tar").write_bytes(tar_bytes(BASIC, tarfile.USTAR_FORMAT))
    record("tar/ustar.tar", "tar", BASIC.manifest_entries(), mtime=MTIME, notes="Plain ustar")
    out("tar/legacy-cp1251.tar").write_bytes(tar_bytes(LEGACY_TREES["cp1251"], tarfile.USTAR_FORMAT, encoding="cp1251"))
    record("tar/legacy-cp1251.tar", "tar", LEGACY_TREES["cp1251"].manifest_entries(), mtime=MTIME,
           tags=["charset-heuristic", "legacy-encoding", "cp1251"],
           notes="ustar with CP1251 name bytes (no pax header to declare UTF-8). A tar save keeps the kept "
                 "entries' raw name bytes.")

    out("tar/gnu-long-names.tar").write_bytes(tar_bytes(LONG_NAMES, tarfile.GNU_FORMAT))
    record("tar/gnu-long-names.tar", "tar", LONG_NAMES.manifest_entries(), mtime=MTIME,
           tags=["long-names"], notes="GNU ././@LongLink headers for names over 100 bytes.")

    out("tar/pax-long-names.tar").write_bytes(tar_bytes(LONG_NAMES))
    record("tar/pax-long-names.tar", "tar", LONG_NAMES.manifest_entries(), mtime=MTIME,
           tags=["long-names"], notes="pax 'path' records for names over 100 bytes.")

    no_dirs = Tree(dict(BASIC.files))
    data = tar_bytes(no_dirs)
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as tf:
        for name, content in no_dirs.files.items():
            ti = tarfile.TarInfo(name)
            ti.mtime, ti.mode, ti.size = MTIME, 0o644, len(content)
            tf.addfile(ti, io.BytesIO(content))
    out("tar/no-dir-entries.tar").write_bytes(buf.getvalue())
    record("tar/no-dir-entries.tar", "tar", no_dirs.manifest_entries(), mtime=MTIME, tags=["synthesized-dirs"],
           notes="Only file members (tar of explicit file paths). Directories must be synthesized.")

    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as tf:
        for name, content in (("dup.txt", b"first version\n"), ("other.txt", b"other\n"),
                              ("dup.txt", b"second, final version\n")):
            ti = tarfile.TarInfo(name)
            ti.mtime, ti.mode, ti.size = MTIME, 0o644, len(content)
            tf.addfile(ti, io.BytesIO(content))
    out("tar/duplicates.tar").write_bytes(buf.getvalue())
    final = b"second, final version\n"
    record("tar/duplicates.tar", "tar",
           [{"path": "dup.txt", "dir": False, "size": len(final), "sha256": hashlib.sha256(final).hexdigest()},
            {"path": "other.txt", "dir": False, "size": 6, "sha256": hashlib.sha256(b"other\n").hexdigest()}],
           mtime=MTIME, tags=["duplicates"],
           notes="dup.txt appended twice (tar -r). Last member wins, one row.")

    nfc, nfd = "café.txt", "café.txt"
    final = b"nfd copy, last\n"
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as tf:
        for name, content in ((nfc, b"nfc copy\n"), (nfd, final)):
            ti = tarfile.TarInfo(name)
            ti.mtime, ti.mode, ti.size = MTIME, 0o644, len(content)
            tf.addfile(ti, io.BytesIO(content))
    out("tar/nfc-nfd-twins.tar").write_bytes(buf.getvalue())
    record("tar/nfc-nfd-twins.tar", "tar",
           [{"path": nfc, "dir": False, "size": len(final), "sha256": hashlib.sha256(final).hexdigest()}],
           mtime=MTIME, tags=["duplicates", "unicode", "nfd"],
           notes="café.txt stored NFC, then NFD. Both normalize to the NFC path: last member wins, one row "
                 "(compare unicodeScalars).")

    out("tar/nfd.tar").write_bytes(tar_bytes(NFD))
    record("tar/nfd.tar", "tar", NFD.manifest_entries(), mtime=MTIME, tags=["unicode", "nfd"],
           notes="Stored as decomposed (NFD) names, as HFS+ and Archive Utility produce. The manifest lists NFC: "
                 "KernirCore normalizes every name to NFC (compare unicodeScalars, String == hides the difference).")

    out("tar/unicode.tar").write_bytes(tar_bytes(UNICODE))
    record("tar/unicode.tar", "tar", UNICODE.manifest_entries(), mtime=MTIME, tags=["unicode"])

    # No "size": a tar hard-link member stores size 0, so the listed size is engine-defined.
    entries = SYMLINKS.manifest_entries() + [{"path": "hardlink-to-hello", "dir": False,
                                               "sha256": hashlib.sha256(b"Hello, Kernir!\n").hexdigest(),
                                               "hardlink": "hello.txt"}]
    out("tar/links.tar").write_bytes(tar_bytes(SYMLINKS, hardlink=("hardlink-to-hello", "hello.txt")))
    record("tar/links.tar", "tar", entries, mtime=MTIME, tags=["symlink", "hardlink"],
           notes="Symlinks (one dangling) and a hard link. Hard link extracts with the target's content.")

    for rel, fmt, data in (
        ("tar/basic.tar.gz", "tarGzip", gzip_compress(plain)),
        ("tar/basic.tgz", "tarGzip", gzip_compress(plain)),
        ("tar/basic.tar.bz2", "tarBzip2", bz2.compress(plain, 9)),
        ("tar/basic.tar.xz", "tarXz", lzma.compress(plain, format=lzma.FORMAT_XZ, check=lzma.CHECK_CRC64)),
        ("tar/basic.tar.zst", "tarZstd", zstd_compress(plain)),
    ):
        out(rel).write_bytes(data)
        record(rel, fmt, BASIC.manifest_entries(), mtime=MTIME)

    # Same bytes, misleading extension: detection must go by content.
    out("tar/gzip-named.zip").write_bytes(gzip_compress(plain))
    record("tar/gzip-named.zip", "tarGzip", BASIC.manifest_entries(), mtime=MTIME, tags=["wrong-extension"],
           notes="A .tar.gz saved with a .zip extension. detectFormat must read content.")

    build_macos_tar()


def apple_double(entries):
    """AppleDouble v2 (the ._ companion format): header, entry table, then each entry's data."""
    header = struct.pack(">II16sH", 0x00051607, 0x00020000, b"Mac OS X".ljust(16), len(entries))
    offset, table, data = len(header) + 12 * len(entries), b"", b""
    for entry_id, payload in entries:
        table += struct.pack(">III", entry_id, offset + len(data), len(payload))
        data += payload
    return header + table + data


def build_macos_tar():
    """Apple bsdtar's layout without --no-mac-metadata: a ._name AppleDouble member right before each member
    that has Finder info or a resource fork. Composed here because real bsdtar output also packs
    com.apple.provenance, which cannot be removed and differs per machine. Like copyfile, every companion
    has a Finder info entry followed by a resource fork entry, empty when there is no fork."""
    finder_info, resource_fork = 9, 2
    members = [
        ("._hello.txt", apple_double([(finder_info, b"TEXTKRNR" + bytes(24)), (resource_fork, b"KERNIR-RSRC" * 8)])),
        ("hello.txt", b"Hello, Kernir!\n"),
        ("plain.txt", b"plain\n"),
        ("._docs", apple_double([(finder_info, bytes(8) + b"\x00\x0c" + bytes(22)), (resource_fork, b"")])),
        ("docs", None),
        ("docs/._readme.md", apple_double([(finder_info, b"TEXTttxt" + bytes(24)), (resource_fork, b"")])),
        ("docs/readme.md", b"readme\n"),
    ]
    buf, entries = io.BytesIO(), []
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as tf:
        for name, data in members:
            ti = tarfile.TarInfo(name)
            ti.mtime, ti.uid, ti.gid, ti.uname, ti.gname = MTIME, 0, 0, "", ""
            if data is None:
                ti.type, ti.mode = tarfile.DIRTYPE, 0o755
                tf.addfile(ti)
                entries.append({"path": name, "dir": True})
            else:
                ti.mode, ti.size = 0o644, len(data)
                tf.addfile(ti, io.BytesIO(data))
                entries.append({"path": name, "dir": False, "size": len(data),
                                "sha256": hashlib.sha256(data).hexdigest()})
    out("tar/macos-bsdtar.tar").write_bytes(buf.getvalue())
    entries.sort(key=lambda e: e["path"].split("/"))
    record("tar/macos-bsdtar.tar", "tar", entries, mtime=MTIME, tags=["macosx", "resource-fork"],
           mac_metadata=["._docs", "._hello.txt", "docs/._readme.md"],
           notes="Laid out like Apple bsdtar without --no-mac-metadata: ._ AppleDouble members before hello.txt, "
                 "docs and docs/readme.md (plain.txt has none). Listed raw (tar:!mac-ext, like zip:!mac-ext); "
                 "stock libarchive on Apple merges each ._ member into the next member and hides it.")


def build_single():
    hello = b"Hello, Kernir!\n"
    notes = text_blob(20_000)
    # Single-stream entries report size nil; the sha256 is checked after extraction.
    one = lambda name, data: [{"path": name, "dir": False, "size": None,
                               "sha256": hashlib.sha256(data).hexdigest()}]
    out("single/hello.txt.gz").write_bytes(gzip_compress(hello, filename="hello.txt"))
    record("single/hello.txt.gz", "gzip", one("hello.txt", hello), tags=["single-stream"],
           notes="gzip with FNAME=hello.txt in the header.")
    out("single/no-name.gz").write_bytes(gzip_compress(notes))
    record("single/no-name.gz", "gzip", one("no-name", notes), tags=["single-stream"],
           notes="gzip without FNAME: entry name derived from the file name minus .gz.")
    out("single/notes.txt.bz2").write_bytes(bz2.compress(notes, 9))
    record("single/notes.txt.bz2", "bzip2", one("notes.txt", notes), tags=["single-stream", "size-unknown"],
           notes="No stored name or size: entry name is the file name minus .bz2; size may be nil before extract.")
    out("single/notes.txt.xz").write_bytes(lzma.compress(notes, format=lzma.FORMAT_XZ))
    record("single/notes.txt.xz", "xz", one("notes.txt", notes), tags=["single-stream", "size-unknown"])
    out("single/notes.txt.zst").write_bytes(zstd_compress(notes))
    record("single/notes.txt.zst", "zstd", one("notes.txt", notes), tags=["single-stream", "size-unknown"])


# MARK: - ISO, CPIO, XAR, CAB


def neutralize_xar_owner(path):
    """Rewrites <user> in the compressed TOC of a xar to "user", so the committed bytes do not carry the login of
    the account that built them. The TOC checksum at the start of the heap is recomputed; the heap is untouched.
    A deflate level that keeps the compressed TOC length is preferred, so the heap stays at the same offset."""
    data = Path(path).read_bytes()
    magic, header_size, version, clen, ulen, cksum_alg = struct.unpack(">4sHHQQI", data[:28])
    if magic != b"xar!":
        raise ValueError(f"neutralize_xar_owner: {path} is not a xar (magic {magic!r})")
    if header_size != 28 or cksum_alg != 1:
        raise ValueError(
            f"neutralize_xar_owner: unsupported xar header (header_size={header_size}, cksum_alg={cksum_alg}); "
            "only the 28-byte header with a SHA-1 TOC checksum (cksum_alg 1) is handled")
    toc = zlib.decompress(data[header_size:header_size + clen])
    toc = re.sub(rb"<user>[^<]*</user>", b"<user>user</user>", toc)
    packed = [zlib.compress(toc, level) for level in (5, 6, 4, 7, 3, 8, 2, 9, 1)]
    packed = next((c for c in packed if len(c) == clen), packed[1])
    heap = data[header_size + clen + 20:]  # skips the old SHA-1 of the compressed TOC
    header = struct.pack(">4sHHQQI", magic, header_size, version, len(packed), len(toc), cksum_alg)
    Path(path).write_bytes(header + packed + hashlib.sha1(packed).digest() + heap)


def build_misc(stage_root):
    d = stage_root / "misc-basic"
    names = BASIC.stage(d)

    p = out("iso/basic.iso")
    run("hdiutil", "makehybrid", "-quiet", "-iso", "-joliet", "-default-volume-name", "KERNIR",
        "-o", p, d)
    record("iso/basic.iso", "iso", BASIC.manifest_entries(), tags=["joliet"],
           notes="hdiutil makehybrid -iso -joliet (no Rock Ridge): names come from Joliet.")

    for rel, fmt, label in (("cpio/newc.cpio", "newc", "SVR4 newc"), ("cpio/odc.cpio", "odc", "POSIX odc")):
        p = out(rel)
        run("bsdtar", "-c", "--no-mac-metadata", "--format", fmt, "-f", p, *names, cwd=d)
        record(rel, "cpio", BASIC.manifest_entries(), mtime=MTIME, notes=label)

    p = out("xar/basic.xar")
    run("xar", "-c", "-f", p, *names, cwd=d)
    neutralize_xar_owner(p)
    record("xar/basic.xar", "xar", BASIC.manifest_entries(), mtime=MTIME,
           notes="Apple xar(1), gzip-compressed heap (the .pkg container format).")

    cab_tree = Tree({k: v for k, v in BASIC.files.items()})
    d = stage_root / "cab"
    cab_tree.stage(d)
    files = sorted(cab_tree.files)
    for rel, args, label in (("cab/mszip.cab", ["-z"], "MSZIP"), ("cab/none.cab", [], "uncompressed")):
        p = out(rel)
        run("gcab", "-c", *args, p, *files, cwd=d)
        record(rel, "cab", cab_tree.manifest_entries(),
               tags=["synthesized-dirs"] + (["libarchive-bug"] if not args else []),
               notes=f"gcab {label}. CAB stores backslash paths and no directory entries."
                     + ("" if args else " libarchive 3.7.4 reports a CFDATA checksum error on empty.txt; "
                        "7-Zip reads it fine."))


# MARK: - Showcase (App Store screenshots)


def png(width, height, pixel, noise_seed=None, noise_bits=0):
    """RGB PNG. pixel(x, y) -> (r, g, b). Optional deterministic noise in the low bits, so the
    file is about as large as a real photo-like image."""
    noise = blob(width * height * 3, noise_seed) if noise_seed else None
    mask = (1 << noise_bits) - 1
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        for x in range(width):
            r, g, b = pixel(x, y)
            if noise:
                i = (y * width + x) * 3
                r, g, b = r ^ (noise[i] & mask), g ^ (noise[i + 1] & mask), b ^ (noise[i + 2] & mask)
            raw += bytes((r, g, b))

    def chunk(kind, data):
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF))

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + chunk(b"IEND", b""))


def pdf(title, lines):
    """One-page PDF with Helvetica text and a valid xref table."""
    text = "BT /F1 24 Tf 72 720 Td (" + title + ") Tj /F1 12 Tf 0 -36 Td"
    for line in lines:
        text += " (" + line + ") Tj 0 -18 Td"
    text += " ET"
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R "
        b"/Resources << /Font << /F1 5 0 R >> >> >>",
        b"<< /Length " + str(len(text)).encode() + b" >>\nstream\n" + text.encode() + b"\nendstream",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    data = bytearray(b"%PDF-1.4\n")
    offsets = []
    for i, body in enumerate(objects, 1):
        offsets.append(len(data))
        data += f"{i} 0 obj\n".encode() + body + b"\nendobj\n"
    xref = len(data)
    data += f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n".encode()
    for off in offsets:
        data += f"{off:010} 00000 n \n".encode()
    data += f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
    return bytes(data)


SHOWCASE_MAIN = '''import SwiftUI

/// Field Notes: a small app for keeping notes while you are out walking.
@main
struct FieldNotesApp: App {
    @State private var store = NoteStore()

    var body: some Scene {
        WindowGroup {
            NoteList()
                .environment(store)
        }
    }
}

@Observable
final class NoteStore {
    private(set) var notes: [Note] = []

    func add(_ text: String, at place: String?) {
        let note = Note(text: text, place: place, created: .now)
        notes.insert(note, at: 0)
        save()
    }

    func remove(_ note: Note) {
        notes.removeAll { $0.id == note.id }
        save()
    }

    func notes(matching query: String) -> [Note] {
        guard !query.isEmpty else { return notes }
        return notes.filter { $0.text.localizedStandardContains(query) }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(notes)
            try data.write(to: .notesFile, options: .atomic)
        } catch {
            print("Could not save notes: \\(error.localizedDescription)")
        }
    }
}

struct Note: Identifiable, Codable, Hashable {
    var id = UUID()
    var text: String
    var place: String?
    var created: Date
}

struct NoteList: View {
    @Environment(NoteStore.self) private var store
    @State private var query = ""
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("New note", text: $draft)
                        .onSubmit(addDraft)
                }
                Section("Notes") {
                    ForEach(store.notes(matching: query)) { note in
                        NoteRow(note: note)
                            .swipeActions {
                                Button("Delete", role: .destructive) { store.remove(note) }
                            }
                    }
                }
            }
            .navigationTitle("Field Notes")
            .searchable(text: $query)
        }
    }

    private func addDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.add(text, at: nil)
        draft = ""
    }
}

struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(note.text)
                .lineLimit(3)
            HStack {
                Text(note.created, format: .relative(presentation: .named))
                if let place = note.place {
                    Text("·")
                    Text(place)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
'''

SHOWCASE_UTILS = '''import Foundation

extension URL {
    /// notes.json in the app's Documents folder.
    static var notesFile: URL {
        URL.documentsDirectory.appending(path: "notes.json")
    }
}

extension String {
    /// The first line, for list titles and share sheets.
    var firstLine: String {
        split(separator: "\\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
    }

    /// Word count, as shown under a note.
    var wordCount: Int {
        var count = 0
        enumerateSubstrings(in: startIndex..., options: [.byWords, .localized]) { _, _, _, _ in
            count += 1
        }
        return count
    }
}

extension Date {
    /// "Morning", "Afternoon" or "Evening", used to group notes by time of day.
    var partOfDay: String {
        switch Calendar.current.component(.hour, from: self) {
        case 5..<12: "Morning"
        case 12..<18: "Afternoon"
        default: "Evening"
        }
    }
}
'''

SHOWCASE_README = b"""# Field Notes

A small SwiftUI app for keeping notes while you are out walking.

## Build

Open the folder in Xcode 26 and run the FieldNotes scheme. No packages, no setup.

## Layout

- `src/` the app's Swift code
- `assets/` the app icon and logo
- `cover.png` the cover image for the project page
- `brief.pdf` the one-page project brief

Released under the MIT License, see LICENSE.
"""

SHOWCASE_LICENSE = b"""MIT License

Copyright (c) 2026 Field Notes contributors

Permission is hereby granted, free of charge, to any person obtaining a copy of this software
and associated documentation files (the "Software"), to deal in the Software without
restriction, including without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or
substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
"""

SHOWCASE_LOGO = b"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 120">
  <rect width="120" height="120" rx="27" fill="#2f7d5b"/>
  <path d="M34 30h40l14 14v46H34z" fill="#f4f1e8"/>
  <path d="M74 30v14h14" fill="#d9d3c2"/>
  <path d="M44 58h34M44 68h34M44 78h22" stroke="#2f7d5b" stroke-width="5" stroke-linecap="round"/>
</svg>
"""


def lerp(a, b, t):
    return int(a + (b - a) * t)


def build_showcase():
    """showcase/project.zip: a realistic small project for the App Store screenshots
    (Tests/KernirMacUITests/ScreenshotUITests.swift)."""
    cover = png(1600, 900, lambda x, y: (lerp(28, 244, x / 1600), lerp(92, 196, y / 900), lerp(140, 110, x / 1600)),
                noise_seed="showcase-cover", noise_bits=1)
    icon = png(512, 512, lambda x, y: (lerp(47, 90, y / 512), lerp(125, 170, y / 512), lerp(91, 120, x / 512)))
    tree = Tree(files={
        "src/main.swift": SHOWCASE_MAIN.encode(),
        "src/utils.swift": SHOWCASE_UTILS.encode(),
        "assets/icon.png": icon,
        "assets/logo.svg": SHOWCASE_LOGO,
        "cover.png": cover,
        "brief.pdf": pdf("Field Notes: project brief", [
            "Goal: a calm notes app for walks, one hand, no account.",
            "Scope: notes list, search, place names, export as text.",
            "Out of scope: sync, photos, sharing.",
            "Milestone 1: list and search, end of November 2026.",
        ]),
        "README.md": SHOWCASE_README,
        "LICENSE": SHOWCASE_LICENSE,
    })
    # Dates as in the mockup (DOS local time, even seconds).
    times = {
        "src/": (2026, 11, 8, 14, 2, 0), "src/main.swift": (2026, 11, 8, 14, 2, 0),
        "src/utils.swift": (2026, 11, 7, 19, 40, 0),
        "assets/": (2026, 11, 6, 11, 15, 0), "assets/icon.png": (2026, 11, 6, 11, 15, 0),
        "assets/logo.svg": (2026, 11, 6, 11, 10, 0),
        "cover.png": (2026, 11, 5, 9, 30, 0), "brief.pdf": (2026, 11, 4, 17, 12, 0),
        "README.md": (2026, 11, 5, 9, 31, 0), "LICENSE": (2026, 11, 1, 10, 0, 0),
    }
    rel = "showcase/project.zip"
    with zipfile.ZipFile(out(rel), "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for p, kind in tree.ordered():
            name = p + "/" if kind == "dir" else p
            zi = zipfile.ZipInfo(name, times[name])
            zi.create_system = 3
            if kind == "dir":
                zi.external_attr = (0o40755 << 16) | 0x10
                zf.writestr(zi, b"")
            else:
                zi.external_attr = 0o100644 << 16
                zi.compress_type = zipfile.ZIP_DEFLATED
                zf.writestr(zi, tree.files[p])
    record(rel, "zip", tree.manifest_entries(), tags=["showcase"],
           notes="App Store screenshot project, used by ScreenshotUITests.")


# MARK: - Corrupted and hostile


def build_hostile():
    deflate = (OUT / "zip/deflate.zip").read_bytes()
    out("corrupt/truncated.zip").write_bytes(deflate[: len(deflate) * 6 // 10])
    record("corrupt/truncated.zip", "zip", [], open_="any", extract="any", complete=False,
           tags=["corrupt"], notes="zip/deflate.zip cut at 60%: central directory gone. Must not crash or hang; "
                                   "an error or a partial (streamed) listing are both acceptable.")

    store = bytearray((OUT / "zip/store.zip").read_bytes())
    idx = store.index(b"The quick brown fox")
    store[idx] ^= 0xFF
    out("corrupt/bad-crc.zip").write_bytes(bytes(store))
    entries = [e for e in BASIC.manifest_entries() if e["path"] != "docs/notes.txt"]
    entries.append({"path": "docs/notes.txt", "dir": False, "size": 20_000, "corruptData": True})
    record("corrupt/bad-crc.zip", "zip", entries, extract="corrupted", tags=["corrupt"],
           notes="One flipped byte in stored docs/notes.txt: listing is fine, extracting it must fail "
                 "with corrupted (CRC mismatch), never silently write bad data.")

    for src, rel, fmt in (("7z/lzma2.7z", "corrupt/truncated.7z", "sevenZip"),
                          ("tar/basic.tar.gz", "corrupt/truncated.tar.gz", "tarGzip"),
                          ("tar/basic.tar.xz", "corrupt/truncated.tar.xz", "tarXz")):
        data = (OUT / src).read_bytes()
        out(rel).write_bytes(data[: len(data) // 2])
        record(rel, fmt, [], open_="any", extract="any", complete=False, tags=["corrupt"],
               notes=f"{src} cut in half. Must not crash or hang.")

    out("corrupt/zero-bytes.zip").write_bytes(b"")
    record("corrupt/zero-bytes.zip", None, [], open_="unsupportedFormat", extract="any", detect=None,
           tags=["corrupt"], notes="Empty file with .zip extension.")
    out("corrupt/random.zip").write_bytes(blob(4096, "garbage"))
    record("corrupt/random.zip", None, [], open_="unsupportedFormat", extract="any", detect=None,
           tags=["corrupt"], notes="Random bytes with a .zip extension.")
    out("corrupt/text.zip").write_bytes(b"This is not an archive.\n" * 10)
    record("corrupt/text.zip", None, [], open_="unsupportedFormat", extract="any", detect=None,
           tags=["corrupt"], notes="Plain text with a .zip extension.")

    sha = lambda b: hashlib.sha256(b).hexdigest()
    evil = b"pwned\n"
    zip_raw("traversal/zip-dotdot.zip",
            [(b"ok.txt", b"ok\n"), (b"../evil.txt", evil), (b"a/../../evil2.txt", evil),
             (b"/abs-evil.txt", evil), (b"..\\win-evil.txt", evil)], utf8_flag=True)
    f = lambda p, d: {"path": p, "dir": False, "size": len(d), "sha256": sha(d)}
    record("traversal/zip-dotdot.zip", "zip",
           [f("ok.txt", b"ok\n"), f("evil.txt", evil), {"path": "a", "dir": True}, f("a/evil2.txt", evil),
            f("abs-evil.txt", evil)],
           complete=False, extract="any", extract_expect="confined", tags=["traversal"],
           notes="Raw names ../evil.txt, a/../../evil2.txt, /abs-evil.txt, ..\\win-evil.txt. KernirCore normalizes by "
                 "dropping '..' and leading '/'; the backslash name is not asserted. extract(nil) must write "
                 "nothing outside the destination.")

    def tar_member(tf, name, data=None, link=None, kind=tarfile.REGTYPE):
        ti = tarfile.TarInfo(name)
        ti.mtime, ti.mode, ti.type = MTIME, 0o644, kind
        if link is not None:
            ti.linkname = link
        if data is not None:
            ti.size = len(data)
        tf.addfile(ti, io.BytesIO(data) if data is not None else None)

    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as tf:
        tar_member(tf, "ok.txt", b"ok\n")
        tar_member(tf, "../evil.txt", evil)
        tar_member(tf, "/abs-evil.txt", evil)
    out("traversal/tar-dotdot.tar").write_bytes(buf.getvalue())
    record("traversal/tar-dotdot.tar", "tar",
           [{"path": "ok.txt", "dir": False, "size": 3, "sha256": sha(b"ok\n")},
            {"path": "evil.txt", "dir": False, "size": len(evil), "sha256": sha(evil)},
            {"path": "abs-evil.txt", "dir": False, "size": len(evil), "sha256": sha(evil)}],
           extract="any", extract_expect="confined", tags=["traversal"],
           notes="../ and absolute members. Nothing may land outside the destination.")

    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as tf:
        tar_member(tf, "escape", link="../..", kind=tarfile.SYMTYPE)
        tar_member(tf, "escape/pwned.txt", evil)
        tar_member(tf, "abs-link", link="/tmp", kind=tarfile.SYMTYPE)
        tar_member(tf, "abs-link/pwned.txt", evil)
        tar_member(tf, "ok.txt", b"ok\n")
    out("traversal/tar-symlink-escape.tar").write_bytes(buf.getvalue())
    record("traversal/tar-symlink-escape.tar", "tar",
           [{"path": "ok.txt", "dir": False, "size": 3, "sha256": sha(b"ok\n")}],
           extract="any", extract_expect="confined", complete=False, tags=["traversal", "symlink"],
           notes="Symlink to ../.. (and /tmp), then a file written through it. extract must not follow it out "
                 "(libarchive ARCHIVE_EXTRACT_SECURE_SYMLINKS | _SECURE_NODOTDOT | _SECURE_NOABSOLUTEPATHS).")

    # 10 MiB of zeros in ~10 KiB: entry size is real, so the UI should show 10 MB, not choke.
    zeros = bytes(10 * 1024 * 1024)
    p = out("hostile/ratio-1000.zip")
    with zipfile.ZipFile(p, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        zi = zipfile.ZipInfo("zeros.bin", DOS_TIME)
        zi.compress_type = zipfile.ZIP_DEFLATED
        zf.writestr(zi, zeros)
    record("hostile/ratio-1000.zip", "zip",
           [{"path": "zeros.bin", "dir": False, "size": len(zeros), "sha256": sha(zeros)}],
           tags=["ratio"], notes="1000:1 compression ratio; harmless, but checks size display and streaming.")


# MARK: - Third-party samples (libarchive test suite, BSD-2-Clause)


THIRD_PARTY = [
    # (libarchive .uu name, fixture path, format, open, encrypted, extract, entries, notes)
    ("test_read_format_rar.rar.uu", "rar/rar4-basic.rar", "rar", "ok", False, "ok",
     [("test.txt", False), ("testlink", False), ("testdir/test.txt", False), ("testdir", True),
      ("testemptydir", True)], "RAR4: file, symlink, dir, empty dir"),
    ("test_read_format_rar_compress_best.rar.uu", "rar/rar4-best.rar", "rar", "ok", False, "ok",
     [("LibarchiveAddingTest.html", False), ("testlink", False), ("testdir/test.txt", False),
      ("testdir/LibarchiveAddingTest.html", False), ("testdir", True), ("testemptydir", True)],
     "RAR4 -m5 (best)"),
    ("test_read_format_rar_unicode.rar.uu", "rar/rar4-unicode.rar", "rar", "ok", False, "ok", None,
     "RAR4 Unicode names"),
    ("test_read_format_rar4_encrypted.rar.uu", "rar/rar4-encrypted-mixed.rar", "rar", "ok", True,
     "unsupportedEncryption", None, "RAR4 non-solid: a.txt, c.txt plain; b.txt encrypted with 'password', "
     "d.txt with 'password2'. libarchive cannot decrypt RAR: plain entries extract, encrypted ones throw."),
    ("test_read_format_rar4_solid_encrypted.rar.uu", "rar/rar4-solid-encrypted.rar", "rar", "unsupportedEncryption",
     True, "any", None, "RAR4 solid, all four entries encrypted with 'password'. libarchive 3.8.10 fails on the "
     "second header with encrypted entries, so open() throws unsupportedEncryption(.rar)."),
    ("test_read_format_rar4_encrypted_filenames.rar.uu", "rar/rar4-encrypted-headers.rar", "rar",
     "unsupportedEncryption", True, "any", [], "RAR4 encrypted headers (-hp)."),
    ("test_read_format_rar5_compressed.rar.uu", "rar/rar5-compressed.rar", "rar", "ok", False, "ok",
     [("test.bin", False)], "RAR5 compressed"),
    ("test_read_format_rar5_solid.rar.uu", "rar/rar5-solid.rar", "rar", "ok", False, "ok", None, "RAR5 solid"),
    ("test_read_format_rar5_stored.rar.uu", "rar/rar5-stored.rar", "rar", "ok", False, "ok",
     [("helloworld.txt", False)], "RAR5 stored"),
    ("test_read_format_rar5_symlink.rar.uu", "rar/rar5-symlink.rar", "rar", "ok", False, "ok", None,
     "RAR5 symlinks"),
    ("test_read_format_rar5_encrypted.rar.uu", "rar/rar5-encrypted-mixed.rar", "rar", "ok", True,
     "unsupportedEncryption", None, "RAR5 non-solid: a.txt, c.txt plain; b.txt encrypted with 'password', "
     "d.txt with 'password2'."),
    ("test_read_format_rar5_solid_encrypted.rar.uu", "rar/rar5-solid-encrypted.rar", "rar", "ok", True,
     "unsupportedEncryption", None, "RAR5 solid, all four entries encrypted with 'password'."),
    ("test_read_format_rar5_encrypted_filenames.rar.uu", "rar/rar5-encrypted-headers.rar", "rar",
     "unsupportedEncryption", True, "any", [], "RAR5 encrypted headers."),
    ("test_read_format_lha_lh0.lzh.uu", "lha/lh0.lzh", "lha", "ok", False, "ok", None, "LHA -lh0- (stored)"),
    ("test_read_format_lha_lh6.lzh.uu", "lha/lh6.lzh", "lha", "ok", False, "ok", None, "LHA -lh6-"),
    ("test_read_format_lha_lh7.lzh.uu", "lha/lh7.lzh", "lha", "ok", False, "ok", None, "LHA -lh7-"),
    ("test_read_format_lha_header0.lzh.uu", "lha/header0.lzh", "lha", "ok", False, "ok", None, "LHA level 0 header"),
    ("test_read_format_lha_header3.lzh.uu", "lha/header3.lzh", "lha", "ok", False, "ok", None, "LHA level 3 header"),
    ("test_read_format_lha_filename_cp932.lzh.uu", "lha/cp932-names.lzh", "lha", "ok", False, "ok", None,
     "LHA with Shift-JIS (CP932) names"),
    ("test_read_format_cab_1.cab.uu", "cab/libarchive-1.cab", "cab", "ok", False, "ok", None, "CAB MSZIP"),
    ("test_read_format_cab_2.cab.uu", "cab/libarchive-2.cab", "cab", "ok", False, "ok", None, "CAB LZX"),
    ("test_read_format_cab_filename_cp932.cab.uu", "cab/cp932-names.cab", "cab", "ok", False, "ok", None,
     "CAB with CP932 (Shift-JIS) names. Expected names are decoded; KernirCore decodes CP932 names "
     "(Russian is tried first)."),
]
# From libarchive's test_read_format_rar_encryption.c: every file holds "This is from <name>".
RAR_PASSWORD = "password"


def rar_encrypted_entries(rel):
    out = []
    for name in ("a.txt", "b.txt", "c.txt", "d.txt"):
        data = f"This is from {name}".encode()
        e = {"path": name, "dir": False, "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
        if "solid" in rel or "headers" in rel:
            e["encrypted"] = True
        else:
            e["encrypted"] = name in ("b.txt", "d.txt")
            if name == "d.txt":
                e["password"] = "password2"
        out.append(e)
    return out


THIRD_PARTY_SOURCE = "libarchive 3.7.7 test suite (libarchive/test/*.uu), BSD-2-Clause, see Fixtures/third-party/LICENSE"


def uudecode(text: str) -> bytes:
    data = bytearray()
    for line in text.splitlines()[1:]:
        if line.startswith("end") or not line.strip():
            break
        try:
            data += binascii.a2b_uu(line)
        except binascii.Error:
            # Some encoders pad short final lines differently.
            n = (ord(line[0]) - 32) & 63
            data += binascii.a2b_uu(line[: ((n + 2) // 3) * 4 + 1])
    return bytes(data)


# CP932 names in CAB need an explicit charset; the expected names are the decoded ones
# (the product ideal), even though KernirCore's heuristic only covers ZIP CP866/CP437.
BSDTAR_OPTIONS = {"cab/cp932-names.cab": ["--options", "hdrcharset=CP932"]}
UTF8_ENV = dict(os.environ, LC_ALL="en_US.UTF-8")


def bsdtar_entries(path: Path, rel: str):
    """Listing + content hashes via bsdtar; only used for third-party samples."""
    opts = BSDTAR_OPTIONS.get(rel, [])
    listing = subprocess.run(["bsdtar", *opts, "-tf", path], capture_output=True, text=True,
                             encoding="utf-8", env=UTF8_ENV)
    if listing.returncode != 0:
        return None
    names = [n.rstrip("/") for n in listing.stdout.splitlines() if n and n != "."]
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["bsdtar", *opts, "-xf", path, "-C", tmp], capture_output=True, env=UTF8_ENV)
        entries, dirs = [], set()
        for name in names:
            parts = name.split("/")
            for i in range(1, len(parts)):
                dirs.add("/".join(parts[:i]))
            fp = Path(tmp) / name
            if fp.is_symlink():
                entries.append({"path": name, "dir": False, "symlink": os.readlink(fp)})
            elif fp.is_dir():
                dirs.add(name)
            elif fp.is_file():
                data = fp.read_bytes()
                entries.append({"path": name, "dir": False, "size": len(data),
                                "sha256": hashlib.sha256(data).hexdigest()})
            else:
                entries.append({"path": name, "dir": False})
        entries += [{"path": d, "dir": True} for d in dirs if d not in {e["path"] for e in entries}]
        return sorted(entries, key=lambda e: e["path"].split("/"))


def build_third_party(src: Path | None):
    for uu, rel, fmt, open_, encrypted, extract, expected, notes in THIRD_PARTY:
        dest = OUT / "third-party" / rel
        if src is not None:
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(uudecode((src / "libarchive/test" / uu).read_text()))
        if not dest.exists():
            sys.exit(f"missing {dest}; pass --libarchive-src")
        if fmt == "rar" and encrypted:
            entries = rar_encrypted_entries(rel)
            extra = dict(password=RAR_PASSWORD, extract_without_password="unsupportedEncryption",
                         extract_with_wrong_password="unsupportedEncryption",
                         wrong_password="unsupportedEncryption" if open_ != "ok" else None)
            record("third-party/" + rel, fmt, entries, open_=open_, extract=extract, encrypted=True,
                   tags=["third-party", "encrypted", "libarchive-gap"]
                   + (["mixed-encryption"] if "mixed" in rel else []), notes=notes,
                   source=f"{THIRD_PARTY_SOURCE} ({uu})", complete=open_ == "ok", **extra)
            continue
        entries = bsdtar_entries(dest, rel) if open_ == "ok" else []
        if entries is None:
            sys.exit(f"bsdtar cannot list {dest}")
        if expected is not None and open_ == "ok":
            got = {(e["path"], e["dir"]) for e in entries}
            if got != set(expected):
                sys.exit(f"{rel}: bsdtar listing {sorted(got)} != libarchive test expectation {sorted(expected)}")
        record("third-party/" + rel, fmt, entries, open_=open_, extract=extract, encrypted=encrypted,
               tags=["third-party"] + (["encrypted", "libarchive-gap"] if encrypted else [])
               + (["cp932"] if rel in BSDTAR_OPTIONS else []), notes=notes,
               source=f"{THIRD_PARTY_SOURCE} ({uu})", complete=open_ == "ok")


# MARK: - Damage that only a checksum catches


def build_damaged():
    """One flipped byte that leaves every header intact, so only a CRC check notices (2026-11-10 finding:
    libarchive reports these as ARCHIVE_WARN or not at all, and KernirCore extracted the bad bytes; fixed by
    libarchive patch 0006, which fails 7z/LHA CRC and the gzip trailer CRC-32 and ISIZE).
    Runs after build_third_party: the LHA case is derived from a third-party sample."""
    recorded = {f["file"]: f for f in FIXTURES}

    def damage(src, rel, at, fmt, *, open_="ok", detect="same", corrupt_entry=None, notes):
        data = bytearray((OUT / src).read_bytes())
        data[at(bytes(data))] ^= 0xFF
        out(rel).write_bytes(bytes(data))
        entries = [dict(e) for e in recorded[src]["entries"]]
        for e in entries:
            # A single stream without a gzip FNAME is named after the file.
            if e["path"] == Path(src).stem and "single-stream" in recorded[src]["tags"]:
                e["path"] = Path(rel).stem
            if e["path"] == corrupt_entry:
                e.pop("sha256", None)
                e["corruptData"] = True
        record(rel, fmt, entries, open_=open_, extract="corrupted", detect=detect,
               tags=["corrupt"], notes=notes, source=f"derived from {src}")

    damage("7z/copy.7z", "corrupt/bad-crc.7z", lambda d: d.index(b"The quick brown fox"), "sevenZip",
           corrupt_entry="docs/notes.txt",
           notes="7z/copy.7z (stored) with one flipped byte in docs/notes.txt: the listing is fine, extracting "
                 "it must fail with corrupted (7z CRC mismatch), never write the bad bytes or launder them "
                 "into a repack with a fresh CRC.")
    damage("third-party/lha/cp932-names.lzh", "corrupt/bad-crc.lzh",
           lambda d: d.index(b"K\x00-lh0-") - 8, "lha", corrupt_entry="漢字.txt",
           notes="third-party/lha/cp932-names.lzh (-lh0-, stored) with the first data byte of 漢字.txt flipped: "
                 "the listing is fine, extracting it must fail with corrupted (LHA CRC-16 mismatch).")
    damage("tar/basic.tar.gz", "corrupt/bad-trailer.tar.gz", lambda d: len(d) - 8, "tarGzip", open_="corrupted",
           notes="tar/basic.tar.gz with the gzip trailer's CRC-32 flipped: every tar entry decodes, only the "
                 "trailer check fails (gzip -t: crc error). Open fails with corrupted (listing drains the stream "
                 "to its end), so nothing is extracted.")
    damage("single/hello.txt.gz", "corrupt/bad-trailer.txt.gz", lambda d: len(d) - 8, "gzip", open_="corrupted",
           detect=None,
           notes="single/hello.txt.gz with the gzip trailer's CRC-32 flipped. Open fails with corrupted, so nothing "
                 "is extracted; detectFormat is nil (the stream decodes completely during open, see below).")
    damage("single/hello.txt.gz", "corrupt/bad-isize.txt.gz", lambda d: len(d) - 1, "gzip", open_="corrupted",
           detect=None,
           notes="single/hello.txt.gz with the top byte of the gzip trailer's ISIZE flipped (CRC-32 intact, so "
                 "only the length check catches it; gzip -t: length error). Open fails with corrupted, so nothing "
                 "is extracted; detectFormat is nil.")
    # libarchive checks these already: the small streams decode completely during
    # archive_read_open (the uudecode bidder reads up to 128 KiB ahead), so open fails with corrupted, and
    # before any format bids, so detectFormat is nil except for bad-check.tar.xz.
    for src, rel, fmt, detect in (("tar/basic.tar.bz2", "corrupt/bad-trailer.tar.bz2", "tarBzip2", None),
                                  ("single/notes.txt.bz2", "corrupt/bad-trailer.txt.bz2", "bzip2", None)):
        damage(src, rel, bzip2_stream_crc_byte, fmt, open_="corrupted", detect=detect,
               notes=f"{src} with a byte of the bzip2 end-of-stream combined CRC flipped (block data and block "
                     "CRCs intact). Open fails with corrupted (the stream is read to its end during open), so "
                     "nothing is extracted; detectFormat is nil for the same reason.")
    for src, rel, fmt, detect in (("tar/basic.tar.xz", "corrupt/bad-check.tar.xz", "tarXz", "same"),
                                  ("single/notes.txt.xz", "corrupt/bad-check.txt.xz", "xz", None)):
        damage(src, rel, xz_last_block_check_byte, fmt, open_="corrupted", detect=detect,
               notes=f"{src} with the last byte of the last block's integrity check flipped (index and footer "
                     "intact). Open fails with corrupted (the stream is read to its end during open), so "
                     "nothing is extracted.")


def bzip2_stream_crc_byte(data: bytes) -> int:
    """Index of a byte holding only combined-CRC bits: the CRC is the 32 bits after the last 48-bit
    end-of-stream magic 0x177245385090, which is not byte aligned."""
    bits = int.from_bytes(data, "big")
    total = len(data) * 8
    magic = 0x177245385090
    for end in range(total - 32, 47, -1):  # end = bit index right after the magic
        if (bits >> (total - end)) & ((1 << 48) - 1) == magic:
            first, last = end // 8 + (end % 8 != 0), (end + 32) // 8 - 1
            assert first <= last
            return first
    sys.exit("no bzip2 end-of-stream marker")


def xz_last_block_check_byte(data: bytes) -> int:
    """Index of the last byte before the index: the last block's check (CRC-64 for xz's default)."""
    footer = data[-12:]
    assert footer[-2:] == b"YZ"
    index_size = (struct.unpack("<I", footer[4:8])[0] + 1) * 4
    return len(data) - 12 - index_size - 1


# MARK: - Multi-volume

# ~60 KB incompressible tree, split into 24 KB volumes (3 volumes per set).
MULTIVOLUME = Tree(files={
    "data/alpha.bin": blob(26_000, "mv-alpha"),
    "data/beta.bin": blob(20_000, "mv-beta"),
    "gamma.bin": blob(14_000, "mv-gamma"),
})
MV_VOLUME = 24 * 1024
# Info-ZIP `zip -s` refuses volumes under 64 KB, so the spanned sets (span, spane) use a bigger
# tree (the one above plus delta.bin, ~160 KB) with 64 KB volumes: still 3 volumes.
MULTIVOLUME_ZIP = Tree(files=dict(MULTIVOLUME.files, **{"data/delta.bin": blob(100_000, "mv-delta")}))
MV_ZIP_VOLUME = 64 * 1024
MV_DIR = "multivolume"
# Archive comment of sz-comment.zip.NNN (ASCII, two lines). It sits in the end-of-central-directory
# record, so in the last part: the engine must read it from the joined set, not from .001.
SZ_COMMENT = "Kernir split-volume fixture.\nThis comment lives in the last part."
MV_RAR_DIR = "third-party/rar-multivolume"

# Third-party RAR sets (libarchive v3.8.1 tests, BSD-2-Clause), decoded from .uu into
# Fixtures/third-party/rar-multivolume. Expectations come from `7zz l -slt` plus a 7zz extract
# of rar4-files. 7zz cannot decode the RAR5 sets (method v6), so those carry crc32 and no sha256.
_HTML_SHA = "ee16390e87152d7dec632ae2b37566da6135966e46b5166e6f40a1c827fa61ad"
_HTML_ENTRIES = [
    {"path": "LibarchiveAddingTest2.html", "dir": False, "size": 20111, "sha256": _HTML_SHA},
    {"path": "LibarchiveAddingTest.html", "dir": False, "size": 20111, "sha256": _HTML_SHA},
]
MV_RAR_SETS = {
    "rar5-multi": dict(
        format="rar5", first="rar5-multi.part01.rar",
        volumes=[f"rar5-multi.part{n:02d}.rar" for n in range(1, 9)],
        source="test_read_format_rar5_multiarchive.partNN.rar.uu",
        entries=[
            {"path": "home/antek/temp/build/unrar5/libarchive/bin/bsdcat_test", "dir": False,
             "size": 144608, "crc32": "35277473"},
            {"path": "home/antek/temp/build/unrar5/libarchive/bin/bsdtar_test", "dir": False,
             "size": 365672, "crc32": "E59665F8"},
        ]),
    "rar4-multi": dict(
        format="rar4", first="rar4-multi.part0001.rar",
        volumes=[f"rar4-multi.part{n:04d}.rar" for n in range(1, 5)],
        source="test_read_format_rar_multivolume.part000N.rar.uu",
        listingOnly=True,
        notes="First file inflates to 241 MB: list only, never extract in tests.",
        entries=[
            {"path": "ppmd_lzss_conversion_test.txt", "dir": False, "size": 241647978},
            {"path": "LibarchiveAddingTest.html", "dir": False, "size": 20111},
            {"path": "testlink", "dir": False, "size": 25, "symlink": True},
            {"path": "testdir/test.txt", "dir": False, "size": 20},
            {"path": "testdir/LibarchiveAddingTest.html", "dir": False, "size": 20111},
            {"path": "testdir", "dir": True},
            {"path": "testemptydir", "dir": True},
        ]),
    "rar4-files": dict(
        format="rar4", first="rar4-files.part1.rar",
        volumes=[f"rar4-files.part{n}.rar" for n in range(1, 7)],
        source="test_rar_multivolume_multiple_files.partN.rar.uu",
        entries=_HTML_ENTRIES),
    "rar4-old": dict(
        format="rar4", first="rar4-old.rar",
        volumes=["rar4-old.rar"] + [f"rar4-old.r{n:02d}" for n in range(5)],
        source="rar4-files set renamed to old-style .rar/.r00..r04 naming",
        notes="Same bytes as rar4-files. The headers carry the new-numbering flag, so 7zz reports "
              "'Missing volume' for this naming; the engine must pick the next name from the file name.",
        entries=_HTML_ENTRIES),
}


def build_multivolume():
    dest = OUT / MV_DIR
    enc_sets = {"s7e": [f"s7e.7z.{i:03d}" for i in (1, 2, 3)],
                "spane": ["spane.z01", "spane.z02", "spane.zip"]}
    previous = {n: (dest / n).read_bytes() for parts in enc_sets.values() for n in parts
                if (dest / n).exists()}
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)
    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp) / "src"
        names = MULTIVOLUME.stage(d)
        vol = f"{MV_VOLUME}b"
        z7 = ["7zz", "a", "-t7z", f"-v{vol}", "-m0=lzma2", "-ms=off", "-mtc=off", "-mta=off", "-bd", "-y"]
        run(*z7, dest / "s7.7z", *names, cwd=d)
        run(*z7, f"-p{PASSWORD}", "-mhe=on", dest / "s7e.7z", *names, cwd=d)
        run("7zz", "a", "-tzip", f"-v{vol}", "-mtc=off", "-mta=off", "-bd", "-y", dest / "sz.zip", *names, cwd=d)
        d = Path(tmp) / "src-zip"
        names = MULTIVOLUME_ZIP.stage(d)
        zvol = f"{MV_ZIP_VOLUME // 1024}k"
        run("zip", "-r", "-X", "-q", "-s", zvol, dest / "span.zip", *names, cwd=d)
        run("zip", "-r", "-X", "-q", "-s", zvol, "-P", PASSWORD, dest / "spane.zip", *names, cwd=d)
    # sz-comment: the MULTIVOLUME tree as one zip from Python zipfile (stored, fixed DOS times, tree order,
    # so the bytes are the same on every run) with SZ_COMMENT, then cut into MV_VOLUME-byte parts
    # .001, .002, ... like 7-Zip's -v raw split (sz above).
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", compression=zipfile.ZIP_STORED) as zf:
        for p, kind in MULTIVOLUME.ordered():
            is_dir = kind == "dir"
            zi = zipfile.ZipInfo(p + "/" if is_dir else p, DOS_TIME)
            zi.create_system = 3
            zi.external_attr = (0o40755 << 16) | 0x10 if is_dir else 0o100644 << 16
            zf.writestr(zi, b"" if is_dir else MULTIVOLUME.files[p])
        zf.comment = SZ_COMMENT.encode("ascii")
    data = buf.getvalue()
    sz_comment = [f"sz-comment.zip.{i // MV_VOLUME + 1:03d}" for i in range(0, len(data), MV_VOLUME)]
    for i, n in enumerate(sz_comment):
        (dest / n).write_bytes(data[i * MV_VOLUME:(i + 1) * MV_VOLUME])
    # Encrypted output differs on every run (random salt / header bytes): reuse committed bytes.
    for parts in enc_sets.values():
        if all(n in previous for n in parts):
            for n in parts:
                (dest / n).write_bytes(previous[n])
    missing = dest / "missing"
    missing.mkdir()
    for n in ("s7.7z.001", "s7.7z.003", "span.z02", "span.zip"):
        shutil.copy(dest / n, missing / n)

    entries = MULTIVOLUME.manifest_entries()
    sets = {}

    zip_entries = MULTIVOLUME_ZIP.manifest_entries()

    def gen(name, fmt, parts, **extra):
        spanned = fmt == "zip-spanned"
        sets[name] = dict(format=fmt, directory=MV_DIR, first=parts[-1] if spanned else parts[0],
                          volumes=parts, volumeSize=MV_ZIP_VOLUME if spanned else MV_VOLUME,
                          entries=zip_entries if spanned else entries, **extra)

    gen("s7", "7z", [f"s7.7z.{i:03d}" for i in (1, 2, 3)], password=None)
    gen("s7e", "7z", enc_sets["s7e"], password=PASSWORD, headersEncrypted=True)
    gen("sz", "zip-split", [f"sz.zip.{i:03d}" for i in (1, 2, 3)], password=None)
    gen("sz-comment", "zip-split", sz_comment, password=None, comment=SZ_COMMENT,
        notes="Python zipfile output with an archive comment, split by bytes; the comment is in the last part.")
    gen("span", "zip-spanned", ["span.z01", "span.z02", "span.zip"], password=None)
    gen("spane", "zip-spanned", enc_sets["spane"], password=PASSWORD, encryption="ZipCrypto")
    for name, spec in MV_RAR_SETS.items():
        sets[name] = dict(spec, directory=MV_RAR_DIR, password=None)
    sets["missing"] = {
        "directory": f"{MV_DIR}/missing",
        "notes": "s7 without .002 and span without span.z01, for app tests of the missing-volume path.",
        "files": sorted(os.listdir(missing)),
    }
    (dest / "EXPECTED.json").write_text(json.dumps(
        {"version": 1, "generatedBy": "scripts/fixtures/build_corpus.py", "password": PASSWORD,
         "sets": sets}, indent=2, ensure_ascii=False) + "\n")

    # SHA256SUMS: paths relative to Fixtures/ (cd Fixtures && shasum -a 256 -c multivolume/SHA256SUMS).
    files = [p for p in sorted(dest.rglob("*")) if p.is_file() and p.name not in ("SHA256SUMS", "EXPECTED.json")]
    files += sorted(p for p in (OUT / MV_RAR_DIR).iterdir() if p.is_file())
    lines = [f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(OUT)}" for p in files]
    (dest / "SHA256SUMS").write_text("\n".join(lines) + "\n")
    print(f"multivolume: {len(files)} files")
    return sets


# Rows in manifest.json for the sets above, on the part a person opens; "volumes" lists the other parts
# (paths relative to Fixtures/) so verify_corpus.py counts them as listed. Not in the manifest: rar4-multi
# (its first file inflates to 241 MB) and missing/ (the missing-part error is ArchiveVolumeError,
# not an ArchiveError case); the multi-volume tests cover both. KernirCore reads whole sets, so
# the rows carry no gap tag and FixtureTests checks them strictly. Stock bsdtar reads only the part it is
# given: verify_corpus.py reports a row with "volumes" as a known gap.
MV_FORMATS = {"7z": "sevenZip", "zip-split": "zip", "zip-spanned": "zip", "rar4": "rar", "rar5": "rar"}


def record_multivolume(sets):
    for name, spec in sets.items():
        if "format" not in spec or spec.get("listingOnly"):
            continue
        rel = f"{spec['directory']}/{spec['first']}"
        others = [f"{spec['directory']}/{v}" for v in spec["volumes"] if v != spec["first"]]
        entries = [{k: v for k, v in e.items() if k != "crc32"} for e in spec["entries"]]
        tags, kw = [], {}
        # KernirCore lists the parent folders an archive leaves out (rar5-multi has file entries only).
        have = {e["path"] for e in entries}
        parents = sorted({"/".join(e["path"].split("/")[:i]) for e in entries
                          for i in range(1, e["path"].count("/") + 1)} - have)
        if parents:
            entries = [{"path": d, "dir": True} for d in parents] + entries
            tags.append("synthesized-dirs")
        if spec.get("comment"):
            tags.append("comment")
        if spec["password"]:
            entries = [dict(e, encrypted=not e["dir"]) for e in entries]
            kw = dict(password=spec["password"], encrypted=True, extract_without_password="passwordRequired",
                      wrong_password="wrongPassword", extract_with_wrong_password="wrongPassword")
            tags.append("encrypted")
            if spec.get("headersEncrypted"):
                kw["open_"] = "passwordRequired"
                tags += ["encrypted-headers", "patched-libarchive"]
        notes = (f"{len(spec['volumes'])}-part {spec['format']} set ({name}), opened from {spec['first']}; "
                 "the engine must find the other parts by name. " + spec.get("notes", "")).strip()
        record(rel, MV_FORMATS[spec["format"]], entries, tags=tags, notes=notes, volumes=others,
               source=spec.get("source", "generated") if spec["directory"] == MV_RAR_DIR
               else "generated (build_multivolume)", comment=spec.get("comment"), **kw)


# MARK: - Comments


def build_comments(stage_root):
    """Archive and per-entry comment fixtures, recorded with comment=/entry_comments=. The oracle is
    the decoded text: an EOCD comment has no charset flag, so valid UTF-8 is read as UTF-8 (a UTF-8 BOM
    stripped), anything else as CP437 (names here are ASCII, so no detected legacy encoding applies).
    No RAR comments (no rar tool); 7z and tar have none."""
    tree = Tree({"readme.txt": b"Archive with a comment.\n",
                 "docs/plain.txt": b"Plain entry, no comment.\n",
                 "docs/ru.txt": "Файл с комментарием в UTF-8.\n".encode()})
    dos_time = (DOS_TIME[3] << 11) | (DOS_TIME[4] << 5) | (DOS_TIME[5] // 2)
    dos_date = ((DOS_TIME[0] - 1980) << 9) | (DOS_TIME[1] << 5) | DOS_TIME[2]

    def zip_commented(rel, comment=b"", entry_comments=None, tree=tree):
        """Deflate zip of `tree`, made by Unix, with an EOCD comment and central directory entry comments
        ({path: (bytes, utf8_flag)}). Bit 11 is set where an entry comment is UTF-8 or the name is not ASCII."""
        entry_comments = entry_comments or {}
        body, central = bytearray(), bytearray()
        members = tree.ordered()
        for p, kind in members:
            name = (p + "/" if kind == "dir" else p).encode()
            data = tree.files.get(p, b"")
            text, utf8 = entry_comments.get(p, (b"", False))
            flags = 0x800 if utf8 or not name.isascii() else 0
            crc = zlib.crc32(data)
            comp = zlib.compressobj(9, zlib.DEFLATED, -15)
            cdata = comp.compress(data) + comp.flush() if data else b""
            method = 8 if data else 0
            mode = (0o40755 << 16) | 0x10 if kind == "dir" else 0o100644 << 16
            offset = len(body)
            body += struct.pack("<IHHHHHIIIHH", 0x04034B50, 20, flags, method, dos_time, dos_date,
                                crc, len(cdata), len(data), len(name), 0) + name + cdata
            central += struct.pack("<IHHHHHHIIIHHHHHII", 0x02014B50, (3 << 8) | 20, 20, flags, method,
                                   dos_time, dos_date, crc, len(cdata), len(data), len(name), 0, len(text),
                                   0, 0, mode, offset) + name + text
        eocd = struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, len(members), len(members), len(central),
                           len(body), len(comment))
        out(rel).write_bytes(bytes(body + central + eocd + comment))

    def set_eocd_comment(path, comment):
        """Writes `comment` into a zip whose file ends in a 22-byte EOCD with comment length 0 (7zz, Info-ZIP)."""
        data = path.read_bytes()
        tail = data[-22:]
        assert tail[:4] == b"PK\x05\x06" and tail[20:22] == b"\0\0", path
        path.write_bytes(data[:-2] + struct.pack("<H", len(comment)) + comment)

    def pattern(n):
        """n bytes of 80-byte ASCII lines (79 + LF), each numbered, so a cut or a shift is easy to spot."""
        fill = "0123456789abcdefghijklmnopqrstuvwxyz"
        lines = [(f"Kernir comment line {i:04d} " + fill * 3)[:79] + "\n" for i in range(n // 80)]
        return "".join(lines)

    entries = tree.manifest_entries()

    cp437 = ("╔══════════════════════════════╗\n"
             "║   Kernir fixture  ░▒▓█▓▒░    ║\n"
             "╟──────────────────────────────╢\n"
             "║  ZIP comment in CP437 (DOS)  ║\n"
             "╚══════════════════════════════╝\n")
    raw = cp437.encode("cp437")
    try:
        raw.decode("utf-8")
        raise AssertionError("cp437 comment must not be valid UTF-8")
    except UnicodeDecodeError:
        pass
    zip_commented("zip/comment-cp437.zip", raw)
    record("zip/comment-cp437.zip", "zip", entries, comment=cp437, tags=["comment", "cp437"],
           notes="Archive comment in CP437 with box-drawing art (bytes are not valid UTF-8; an EOCD comment "
                 "has no UTF-8 flag). Names are ASCII, so no detected encoding: decoded as CP437. The box and "
                 "shade characters sit at the same bytes in CP866; CP1252 would give 'ÉÍÍ»'.")

    utf8 = "Привет из Kernir 🎉\nКомментарий архива в UTF-8, без BOM.\n"
    zip_commented("zip/comment-utf8.zip", utf8.encode())
    record("zip/comment-utf8.zip", "zip", entries, comment=utf8, tags=["comment", "unicode"],
           notes="UTF-8 archive comment (Cyrillic + emoji), no BOM. Valid UTF-8, so read as UTF-8.")

    zip_commented("zip/comment-utf8-bom.zip", b"\xef\xbb\xbf" + utf8.encode())
    record("zip/comment-utf8-bom.zip", "zip", entries, comment=utf8, tags=["comment", "unicode"],
           notes="Same comment as comment-utf8.zip after a UTF-8 BOM (EF BB BF). The reported text has the BOM "
                 "stripped; a save without an edit keeps the original bytes, BOM included.")

    for n in (16_000, 40_000):
        text = pattern(n)
        assert len(text) == n
        zip_commented(f"zip/comment-{n}.zip", text.encode())
        notes = (f"{n:,}-byte ASCII archive comment, 80-byte numbered lines. " +
                 ("The size Kernir caps writes at: the EOCD plus comment still fits libarchive's 16 KiB "
                  "seekable EOCD search, so the seekable reader opens it." if n == 16_000 else
                  "Longer than upstream libarchive's 16 KiB seekable EOCD search, under the 65,535 limit. "
                  "With libarchive patch 0012, KernirCore's libarchive searches the last 20 + 22 + 65,535 bytes "
                  "and takes an end record whose comment reaches EOF, so the seekable reader opens it "
                  "(stock bsdtar still falls back to streaming). Kernir must not write a comment this long "
                  "(cap 16,000)."))
        record(f"zip/comment-{n}.zip", "zip", entries, comment=text, tags=["comment"], notes=notes)

    readme_c = b"Read me first (ASCII entry comment)"
    ru_c = "Комментарий к файлу 📄"
    zip_commented("zip/entry-comments.zip", entry_comments={
        "readme.txt": (readme_c, False), "docs": (b"Folder comment", False), "docs/ru.txt": (ru_c.encode(), True)})
    record("zip/entry-comments.zip", "zip", entries,
           entry_comments={"readme.txt": readme_c.decode(), "docs": "Folder comment", "docs/ru.txt": ru_c},
           tags=["comment"],
           notes="Central directory entry comments, no archive comment: ASCII on readme.txt and the docs/ "
                 "directory (bit 11 clear), UTF-8 on docs/ru.txt (bit 11 set, name ASCII). docs/plain.txt has "
                 "none. 0.1.0 only keeps them on a zip save; they are not shown.")

    # A long UTF-8 archive comment past libarchive's old 16 KiB EOCD search, plus entry comments, so
    # the listing must come from the central directory.
    long_tree = Tree({"readme.txt": b"Long UTF-8 archive comment, entries with their own comments.\n",
                      "docs/отчёт.txt": "Отчёт: комментарий к записи в UTF-8.\n".encode(),
                      "docs/plain.txt": b"No entry comment here.\n",
                      "日本語/メモ.txt": "メモ: エントリのコメント。\n".encode(),
                      "emoji-🎉.txt": "Party 🎉\n".encode()})
    rows = ["Привет из Kernir! Длинный комментарий архива в UTF-8.",
            "日本語のコメント：アーカイブの説明はとても長いです。",
            "中文注释：这是一个很长的压缩包注释。",
            "한국어 주석: 아주 긴 압축 파일 설명입니다.",
            "Emoji 🎉📦🗜️✅🚀 и ещё ü ö ä ß é ñ."]
    lines, size, i = [], 0, 0
    while True:
        line = f"{i:04d} {rows[i % len(rows)]}\n"
        if size + len(line.encode()) > 48_000 - 16:
            break
        lines.append(line)
        size += len(line.encode())
        i += 1
    lines.append(f"{i:04d} " + "." * (48_000 - size - 6) + "\n")
    long_c = "".join(lines)
    assert len(long_c.encode()) == 48_000 and not long_c.isascii()
    long_ec = {"readme.txt": "ASCII entry comment on readme.txt",
               "docs": "Папка docs: комментарий к каталогу",
               "docs/отчёт.txt": "Комментарий к отчёту 📄",
               "日本語/メモ.txt": "Plain ASCII comment on a UTF-8 name",
               "emoji-🎉.txt": "絵文字のファイル 🎉"}
    zip_commented("zip/comment-long-utf8-entries.zip", long_c.encode(), tree=long_tree,
                  entry_comments={p: (t.encode(), not t.isascii()) for p, t in long_ec.items()})
    record("zip/comment-long-utf8-entries.zip", "zip", long_tree.manifest_entries(), comment=long_c,
           entry_comments=long_ec, tags=["comment", "unicode"],
           notes="48,000-byte UTF-8 archive comment (numbered Cyrillic, Japanese, Chinese, Korean and emoji "
                 "lines, no BOM) plus central directory entry comments on 5 of 7 entries: ASCII on readme.txt "
                 "(bit 11 clear) and on 日本語/メモ.txt (bit 11 set for the name), UTF-8 on the docs/ directory, "
                 "docs/отчёт.txt and emoji-🎉.txt (bit 11 set). docs/plain.txt and the 日本語/ directory have "
                 "none. The comment is longer than libarchive's old 16 KiB seekable EOCD search (KernirCore "
                 "widens it so the listing comes from the central directory); stock libarchive falls back to "
                 "its streaming reader. Every comment must survive a zip save.")

    d = stage_root / "comment-zip64"
    names = tree.stage(d)
    p = out("zip/zip64-comment.zip")
    run("zip", "-q", "-X", "-fz", "-r", p, *names, cwd=d)
    zip64_c = "Zip64 archive comment: the zip64 end of central directory record and locator come first.\n"
    set_eocd_comment(p, zip64_c.encode())
    record("zip/zip64-comment.zip", "zip", entries, comment=zip64_c, tags=["comment", "zip64"],
           notes="Info-ZIP -fz (zip64 extra fields, zip64 EOCD + locator) with the comment written into the "
                 "classic EOCD afterwards. Same comment on a Kernir save keeps the zip64 records valid.")

    d = stage_root / "comment-enc"
    names = tree.stage(d)
    for rel, method, label in (("zip/aes256-comment.zip", "AES256", "WinZip AES-256"),
                               ("zip/zipcrypto-comment.zip", "ZipCrypto", "traditional PKWARE ZipCrypto")):
        p = out(rel)
        run("7zz", "a", "-tzip", f"-mem={method}", f"-p{PASSWORD}", "-bd", "-y", p, *names, cwd=d)
        text = f"{label} archive. The comment itself is never encrypted: it reads without the password.\n"
        set_eocd_comment(p, text.encode())
        record(rel, "zip", zip_encryption_flags(p, entries), password=PASSWORD, encrypted=True,
               extract_without_password="passwordRequired", wrong_password="wrongPassword",
               extract_with_wrong_password="wrongPassword", comment=text, tags=["comment", "encrypted"],
               notes=f"{label} (7zz), data encrypted, names visible; EOCD comment added afterwards. The comment "
                     "is reported after open() with no password, with the right one and with the wrong one.")

    # gzip FCOMMENT, built by hand (gzip.GzipFile writes FNAME only). ISO-8859-1 per RFC 1952; the é and ° bytes
    # are not valid UTF-8, so a UTF-8-first decoder still lands on Latin-1.
    payload = b"gzip member with FNAME and FCOMMENT.\n"
    gz_c = "Kernir gzip comment: café, 25°C, ISO-8859-1.\n"
    comp = zlib.compressobj(9, zlib.DEFLATED, -15)
    gz = (struct.pack("<BBBBIBB", 0x1F, 0x8B, 8, 0x08 | 0x10, MTIME, 2, 255) + b"comment.txt\0"
          + gz_c.encode("latin-1") + b"\0" + comp.compress(payload) + comp.flush()
          + struct.pack("<II", zlib.crc32(payload), len(payload)))
    out("single/comment.txt.gz").write_bytes(gz)
    record("single/comment.txt.gz", "gzip",
           [{"path": "comment.txt", "dir": False, "size": None, "sha256": hashlib.sha256(payload).hexdigest()}],
           comment=gz_c, tags=["single-stream", "comment", "comment-deferred"],
           notes="gzip with FNAME=comment.txt and FCOMMENT (ISO-8859-1). Out of scope for 0.1.0 (ZIP comments "
                 "only): read side only, not kept on save. comment-deferred: until gzip comments are read, a "
                 "nil comment here is a known gap, not a failure.")


# MARK: - Rename names


def build_rename_names(stage_root):
    """Names that a rename or an extraction must handle with care: a legacy CP932 tar, and
    zip/tar pairs whose README and Readme differ only in case (allowed in 0.1.0)."""
    tree = LEGACY_TREES["cp932"]
    out("tar/legacy-cp932.tar").write_bytes(tar_bytes(tree, tarfile.USTAR_FORMAT, encoding="cp932"))
    record("tar/legacy-cp932.tar", "tar", tree.manifest_entries(), mtime=MTIME,
           tags=["charset-heuristic", "legacy-encoding", "cp932"],
           notes="ustar with CP932 (Shift-JIS) name bytes, no pax header to declare UTF-8. 表 ends in byte "
                 "0x5C, so 表/ and 表/一覧表.txt check the trail-byte fix-up next to a real separator. A tar "
                 "save or rename keeps the kept entries' raw name bytes.")

    twins = Tree(files={"README": b"README, upper case\n", "Readme": b"Readme, mixed case, longer\n",
                        "other.txt": b"other\n"})
    notes = ("README and Readme differ only in case and in content. Both are listed. Extracting onto a "
             "case-insensitive volume is a name conflict: extraction asks (Keep Both gives "
             "'Readme 2', or Replace), never a silent loss.")
    zip_with_python("zip/case-twins.zip", twins)
    record("zip/case-twins.zip", "zip", twins.manifest_entries(), tags=["case-twins"], notes=notes)
    out("tar/case-twins.tar").write_bytes(tar_bytes(twins))
    record("tar/case-twins.tar", "tar", twins.manifest_entries(), mtime=MTIME, tags=["case-twins"],
           notes="POSIX pax. " + notes)


# MARK: - macOS metadata


def build_macmeta(stage_root):
    """A user's folder full of Mac junk, zipped with Info-ZIP and packed with 7zz: .DS_Store at three levels,
    a loose ._a AppleDouble next to a, a __MACOSX/ tree like ditto / Archive Utility leave behind, plus
    Icon\\r (custom folder icon) and .localized. Recorded with mac_metadata=. zip/macos-nested-junk.zip adds
    __MACOSX folders below the root."""

    def is_mac_metadata(path):
        # .DS_Store at any level, ._* AppleDouble, __MACOSX/ and everything in it;
        # a __MACOSX folder at any depth, not just the root one.
        # Icon\r and .localized are NOT metadata for now; they stay in the tree as kept rows, pending
        # a decision. Either choice is a one-line change here. .fseventsd,
        # .Spotlight-V100 and .Trashes are left out of the corpus entirely.
        name = path.rsplit("/", 1)[-1]
        return name == ".DS_Store" or name.startswith("._") or "__MACOSX" in path.split("/")

    # Minimal .DS_Store: the "\0\0\0\1Bud1" buddy-allocator header, then fixed filler.
    ds_store = lambda seed: b"\x00\x00\x00\x01Bud1" + blob(512, f"ds-store-{seed}")
    finder_info, resource_fork = 9, 2
    tree = Tree({
        "a": b"a\n",
        "._a": apple_double([(finder_info, b"TEXTKRNR" + bytes(24)), (resource_fork, b"")]),
        ".DS_Store": ds_store("root"),
        ".localized": b"",
        "Icon\r": b"",
        "readme.txt": b"Mac junk fixture.\n",
        "sub/file": b"file\n",
        "sub/.DS_Store": ds_store("sub"),
        "sub/nested/deep.txt": b"deep\n",
        "sub/nested/.DS_Store": ds_store("nested"),
        "__MACOSX/._a": apple_double([(finder_info, b"TEXTKRNR" + bytes(24)), (resource_fork, b"")]),
        "__MACOSX/sub/._file": apple_double([(finder_info, bytes(32)), (resource_fork, b"KERNIR-RSRC" * 4)]),
    })
    entries = tree.manifest_entries()
    mac = [e["path"] for e in entries if is_mac_metadata(e["path"])]
    kept = ("Icon\\r and .localized are kept rows (not macMetadata), pending a decision on whether they "
            "count as Mac metadata.")

    d = stage_root / "macmeta"
    names = tree.stage(d)
    p = out("zip/macos-junk.zip")
    run("zip", "-q", "-X", "-r", p, *names, cwd=d)
    record("zip/macos-junk.zip", "zip", entries, tags=["macosx"], mac_metadata=mac,
           notes="Info-ZIP zip -r of a folder with Mac junk: .DS_Store at 3 levels, a loose ._a next to a, "
                 "__MACOSX/._a and __MACOSX/sub/._file. Listed raw (zip:!mac-ext). " + kept)

    p = out("7z/macos-junk.7z")
    run("7zz", "a", "-t7z", "-m0=lzma2", "-ms=off", "-mtc=off", "-mta=off", "-bd", "-y", p, *names, cwd=d)
    record("7z/macos-junk.7z", "sevenZip", entries, mtime=MTIME, tags=["macosx"], mac_metadata=mac,
           notes="The macos-junk.zip tree packed with 7zz (LZMA2, non-solid). " + kept)

    # A __MACOSX folder below the root is metadata too, with everything in it. It comes from a
    # Finder zip extracted by a tool that keeps __MACOSX/, then zipped again from a parent folder. stray.txt is
    # metadata only because of its folder; photos/__MACOSX.txt is a look-alike that is kept.
    nested = Tree({
        "readme.txt": b"Nested __MACOSX fixture.\n",
        "photos/img.jpg": b"\xff\xd8\xff\xe0" + blob(2_000, "nested-img"),
        "photos/__MACOSX/._img.jpg": apple_double([(finder_info, b"JPEGKRNR" + bytes(24)), (resource_fork, b"")]),
        "photos/__MACOSX/stray.txt": b"stray\n",
        "photos/__MACOSX.txt": b"a file, not the folder\n",
        "albums/trip/cover.jpg": b"\xff\xd8\xff\xe0" + blob(1_000, "nested-cover"),
        "albums/trip/__MACOSX/._cover.jpg": apple_double([(finder_info, bytes(32)),
                                                          (resource_fork, b"KERNIR-RSRC" * 2)]),
    })
    entries = nested.manifest_entries()
    d = stage_root / "macmeta-nested"
    names = nested.stage(d)
    p = out("zip/macos-nested-junk.zip")
    run("zip", "-q", "-X", "-r", p, *names, cwd=d)
    record("zip/macos-nested-junk.zip", "zip", entries, tags=["macosx"],
           mac_metadata=[e["path"] for e in entries if is_mac_metadata(e["path"])],
           notes="Info-ZIP zip -r of a folder holding nested __MACOSX folders (metadata at any depth): "
                 "photos/__MACOSX/ with ._img.jpg and stray.txt (metadata only by its folder) beside "
                 "photos/img.jpg, and albums/trip/__MACOSX/._cover.jpg two levels down. photos/__MACOSX.txt "
                 "is a kept look-alike. Listed raw (zip:!mac-ext).")


# MARK: - Preview types


def build_preview_types(stage_root):
    """showcase/preview-types.zip: one file per type the Space preview must render (CSV, HTML and Office
    previews spun forever), plus .txt/.pdf/.png controls that always worked.
    The .docx and .xlsx are minimal OOXML packages written here (no python-docx/openpyxl), with fixed
    member order and DOS times. page.html is self-contained: no URLs, no external CSS, JS or images.
    zip/android.apk: an APK-shaped zip (no signature), so an .apk opens as a zip."""

    def ooxml(parts):
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w", compression=zipfile.ZIP_DEFLATED) as zf:
            for name, text in parts:
                zi = zipfile.ZipInfo(name, DOS_TIME)
                zi.create_system = 0
                zi.compress_type = zipfile.ZIP_DEFLATED
                zf.writestr(zi, ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n' + text).encode())
        return buf.getvalue()

    pkg = "http://schemas.openxmlformats.org/package/2006/"
    rel_ns = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    office = "application/vnd.openxmlformats-officedocument."

    def content_types(overrides):
        return (f'<Types xmlns="{pkg}content-types">'
                f'<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
                '<Default Extension="xml" ContentType="application/xml"/>'
                + "".join(f'<Override PartName="/{p}" ContentType="{office}{t}"/>' for p, t in overrides)
                + "</Types>")

    def rels(rid, kind, target):
        return (f'<Relationships xmlns="{pkg}relationships">'
                f'<Relationship Id="{rid}" Type="{rel_ns}/{kind}" Target="{target}"/></Relationships>')

    paragraphs = ["Dear Kernir tester,",
                  "This letter is a minimal Word document inside a zip archive.",
                  "Press Space on it: the preview should show this text, not a spinner.",
                  "Café, naïve, Привет: non-ASCII text survives the round trip.",
                  "Regards, the QA team"]
    w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    letter = ooxml([
        ("[Content_Types].xml", content_types([("word/document.xml",
                                                "wordprocessingml.document.main+xml")])),
        ("_rels/.rels", rels("rId1", "officeDocument", "word/document.xml")),
        ("word/document.xml", f'<w:document xmlns:w="{w}"><w:body>'
                              + "".join(f"<w:p><w:r><w:t>{p}</w:t></w:r></w:p>" for p in paragraphs)
                              + "<w:sectPr/></w:body></w:document>"),
    ])

    budget_rows = [("Item", "Amount"), ("Rent", 1200), ("Groceries", 340), ("Transport", 95)]
    s = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    cells = []
    for r, row in enumerate(budget_rows, 1):
        cs = []
        for col, v in zip("AB", row):
            if isinstance(v, str):
                cs.append(f'<c r="{col}{r}" t="inlineStr"><is><t>{v}</t></is></c>')
            else:
                cs.append(f'<c r="{col}{r}"><v>{v}</v></c>')
        cells.append(f'<row r="{r}">' + "".join(cs) + "</row>")
    total_row = len(budget_rows) + 1
    total = sum(v for _, v in budget_rows[1:])
    cells.append(f'<row r="{total_row}"><c r="A{total_row}" t="inlineStr"><is><t>Total</t></is></c>'
                 f'<c r="B{total_row}"><f>SUM(B2:B{total_row - 1})</f><v>{total}</v></c></row>')
    budget = ooxml([
        ("[Content_Types].xml", content_types([("xl/workbook.xml", "spreadsheetml.sheet.main+xml"),
                                               ("xl/worksheets/sheet1.xml", "spreadsheetml.worksheet+xml")])),
        ("_rels/.rels", rels("rId1", "officeDocument", "xl/workbook.xml")),
        ("xl/workbook.xml", f'<workbook xmlns="{s}" xmlns:r="{rel_ns}"><sheets>'
                            '<sheet name="Budget" sheetId="1" r:id="rId1"/></sheets></workbook>'),
        ("xl/_rels/workbook.xml.rels", rels("rId1", "worksheet", "worksheets/sheet1.xml")),
        ("xl/worksheets/sheet1.xml", f'<worksheet xmlns="{s}"><sheetData>' + "".join(cells)
                                     + "</sheetData></worksheet>"),
    ])

    report_csv = ("date,city,temperature,note\r\n"
                  "2026-11-01,Baku,14.5,clear\r\n"
                  "2026-11-02,Tbilisi,9.0,\"rain, then sun\"\r\n"
                  "2026-11-03,Zürich,4.2,\"quoted \"\"word\"\"\"\r\n"
                  "2026-11-04,Москва,-1.0,snow\r\n").encode()
    data_tsv = ("id\tname\tqty\tprice\n"
                "1\tnotebook\t3\t2.50\n"
                "2\tpencil\t12\t0.40\n"
                "3\téraser\t1\t0.99\n").encode()
    page_html = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Kernir preview test page</title>
<style>
  body { font: 15px/1.5 -apple-system, sans-serif; margin: 2em; color: #222; background: #fafaf7; }
  h1 { color: #2f7d5b; }
  table { border-collapse: collapse; }
  td, th { border: 1px solid #ccc; padding: 4px 10px; }
  .box { width: 120px; height: 40px; background: linear-gradient(90deg, #2f7d5b, #5aa9e6); }
</style>
</head>
<body>
<h1>Preview test page</h1>
<p>A self-contained HTML file inside a zip. It loads nothing from the network: no links,
no external styles, scripts or images. Pressing Space on it should show this page.</p>
<table>
<tr><th>Type</th><th>Expected preview</th></tr>
<tr><td>CSV</td><td>table</td></tr>
<tr><td>HTML</td><td>this page</td></tr>
<tr><td>DOCX / XLSX</td><td>document text / sheet</td></tr>
</table>
<p>Inline styled box:</p>
<div class="box"></div>
</body>
</html>
""".encode()
    tree = Tree(files={
        "report.csv": report_csv,
        "data.tsv": data_tsv,
        "page.html": page_html,
        "letter.docx": letter,
        "budget.xlsx": budget,
        "notes.txt": b"Plain text control: this preview always worked.\n",
        "control.pdf": pdf("Kernir preview control", ["A one-page PDF control for the Space preview."]),
        "control.png": png(64, 48, lambda x, y: (lerp(47, 90, y / 48), lerp(125, 170, x / 64), 120)),
    })
    rel = "showcase/preview-types.zip"
    zip_with_python(rel, tree)
    record(rel, "zip", tree.manifest_entries(), tags=["preview-types"],
           notes="Space preview per file type (CSV, HTML and Office previews once spun forever): "
                 "report.csv, data.tsv, page.html (self-contained), minimal OOXML letter.docx and "
                 "budget.xlsx, and .txt/.pdf/.png controls.")

    # Placeholder bytes: the AXML magic (0x00080003) and a dex header magic, padded. Never parsed.
    apk = Tree(files={
        "AndroidManifest.xml": struct.pack("<HHI", 0x0003, 0x0008, 64) + bytes(56),
        "classes.dex": b"dex\n035\x00" + bytes(104),
        "META-INF/MANIFEST.MF": b"Manifest-Version: 1.0\r\nCreated-By: Kernir build_corpus.py\r\n\r\n",
    })
    rel = "zip/android.apk"
    zip_with_python(rel, apk, dir_entries=False)
    record(rel, "zip", apk.manifest_entries(), tags=["synthesized-dirs"],
           notes="APK-shaped zip (AndroidManifest.xml and classes.dex placeholders, META-INF/, unsigned): "
                 "an .apk extension opens as a zip. No directory entries, as in real APKs.")


# MARK: - Extract here


def build_extract_here(stage_root):
    """Extract Here, Finder's rule: a single top-level item extracts as-is, several items go
    into a folder named after the archive. The top-level names (report.txt, Project/) differ from the
    archive base names, so a test can tell "kept as-is" from "wrapped in a folder named after the archive".
    zip/deflate.zip and the other BASIC fixtures cover the several-items case; name clashes with the
    destination are set up by the test (pre-create report.txt or Project/), not by a fixture."""
    one_file = Tree(files={"report.txt": b"Quarterly report\n\nOne file at the top of the archive.\n"})
    zip_with_python("zip/one-file.zip", one_file)
    record("zip/one-file.zip", "zip", one_file.manifest_entries(), tags=["extract-here"],
           notes="Exactly one top-level file (report.txt): Extract Here writes report.txt next to the "
                 "archive, no one-file/ folder.")

    # Explicit directory entries for Project/ and Project/src/ in every format.
    one_folder = Tree(files={
        "Project/README.md": b"# Project\n\nThe only top-level item in the archive.\n",
        "Project/notes.txt": text_blob(4_000),
        "Project/src/main.swift": b"print(\"Hello, Kernir!\")\n",
        "Project/src/data.bin": blob(5_000, "extract-here"),
    }, dirs={"Project", "Project/src"})
    note = ("Exactly one top-level folder (Project/, with its own directory entry) holding files and a "
            "subfolder: Extract Here writes Project/ next to the archive, no one-folder/ wrapper.")

    zip_with_python("zip/one-folder.zip", one_folder)
    record("zip/one-folder.zip", "zip", one_folder.manifest_entries(), tags=["extract-here"], notes=note)

    d = stage_root / "extract-here-one-folder"
    names = one_folder.stage(d)
    p = out("7z/one-folder.7z")
    run("7zz", "a", "-t7z", "-m0=lzma2", "-ms=off", "-mtc=off", "-mta=off", "-bd", "-y", p, *names, cwd=d)
    record("7z/one-folder.7z", "sevenZip", one_folder.manifest_entries(), mtime=MTIME, tags=["extract-here"],
           notes=note)

    out("tar/one-folder.tar.gz").write_bytes(gzip_compress(tar_bytes(one_folder)))
    record("tar/one-folder.tar.gz", "tarGzip", one_folder.manifest_entries(), mtime=MTIME,
           tags=["extract-here"], notes=note)


def zip_tree_bytes(tree):
    """A deterministic deflate zip of `tree` (files and explicit directories) as bytes."""
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for p, kind in tree.ordered():
            zi = zipfile.ZipInfo(p + "/" if kind == "dir" else p, DOS_TIME)
            zi.create_system = 3
            if kind == "dir":
                zi.external_attr = (0o40755 << 16) | 0x10
                zf.writestr(zi, b"")
            else:
                zi.external_attr = 0o100644 << 16
                zi.compress_type = zipfile.ZIP_DEFLATED
                zf.writestr(zi, tree.files[p])
    return buf.getvalue()


def encrypted_zip_matches(data, tree, work):
    """Whether the AES zip `data` (password PASSWORD) holds exactly `tree`'s files: the same names, and each
    file's bytes. 7-Zip prints no CRC for AES entries, so the bytes are extracted (`7zz x -so`) and compared."""
    work.mkdir(parents=True, exist_ok=True)
    path = work / "check.zip"
    path.write_bytes(data)
    r = subprocess.run(["7zz", "l", "-slt", "-bd", f"-p{PASSWORD}", str(path)], capture_output=True, text=True)
    if r.returncode != 0:
        return False
    listed = set()
    for block in r.stdout.split("\n\n"):
        f = dict(line.split(" = ", 1) for line in block.splitlines() if " = " in line)
        if f.get("Folder") == "-" and "Path" in f:
            listed.add(f["Path"])
    if listed != set(tree.files):
        return False
    for name, want in tree.files.items():
        x = subprocess.run(["7zz", "x", "-so", "-spd", "-bd", f"-p{PASSWORD}", str(path), name],
                           capture_output=True)
        if x.returncode != 0 or x.stdout != want:
            return False
    return True


def build_nested(stage_root, previous):
    """Archives inside archives (issue 6, open nested archives). The inner archives are ordinary files of
    the outer tree, so a test finds them as entries named like an archive (inner.zip, src.tgz, inner.zip.gz
    -> inner.zip) and `docx-in-zip.zip` holds a .docx that is a ZIP by content but must not count as one."""
    level3 = Tree(files={"deepest.txt": b"Third level.\n"})
    inner = Tree(files={
        "hello.txt": b"Hello from the inner archive.\n",
        "docs/readme.md": b"# Inner\n\nOne archive inside another.\n",
        "docs/notes.txt": text_blob(3_000),
        "deeper/level3.zip": zip_tree_bytes(level3),
    })
    inner_zip = zip_tree_bytes(inner)

    outer = Tree(files={"readme.txt": b"The release archive.\n", "archives/inner.zip": inner_zip},
                 dirs={"archives"})
    zip_with_python("nested/zip-in-zip.zip", outer)
    record("nested/zip-in-zip.zip", "zip", outer.manifest_entries(), tags=["nested"],
           notes="archives/inner.zip is a plain zip (hello.txt, docs/readme.md, docs/notes.txt, "
                 "deeper/level3.zip), and deeper/level3.zip holds deepest.txt: three levels to click through.")

    src = Tree(files={"src/main.swift": b"print(\"Hello, Kernir!\")\n", "src/data.txt": text_blob(4_000)},
               dirs={"src"})
    d = stage_root / "nested-tgz-in-7z"
    d.mkdir()
    (d / "src.tgz").write_bytes(gzip_compress(tar_bytes(src)))
    (d / "readme.txt").write_bytes(b"Backup with a tar.gz inside.\n")
    os.utime(d / "src.tgz", (MTIME, MTIME))
    os.utime(d / "readme.txt", (MTIME, MTIME))
    p = out("nested/tgz-in-7z.7z")
    run("7zz", "a", "-t7z", "-m0=lzma2", "-ms=off", "-mtc=off", "-mta=off", "-bd", "-y", p, "readme.txt", "src.tgz", cwd=d)
    tgz = (d / "src.tgz").read_bytes()
    record("nested/tgz-in-7z.7z", "sevenZip", [
        {"path": "readme.txt", "dir": False, "size": 29, "sha256": hashlib.sha256(b"Backup with a tar.gz inside.\n").hexdigest()},
        {"path": "src.tgz", "dir": False, "size": len(tgz), "sha256": hashlib.sha256(tgz).hexdigest()},
    ], mtime=MTIME, tags=["nested"],
        notes="src.tgz is a tar.gz of src/main.swift and src/data.txt: the inner one is a compressed tar.")

    # Raw gzip of a zip, no FNAME: the entry is the file name minus .gz, so the file is named inner.zip.gz
    # and opens as the one entry inner.zip, which counts as an archive name (a name "zip.gz" would open as "zip").
    out("nested/inner.zip.gz").write_bytes(gzip_compress(inner_zip))
    record("nested/inner.zip.gz", "gzip",
           [{"path": "inner.zip", "dir": False, "size": None, "sha256": hashlib.sha256(inner_zip).hexdigest()}],
           tags=["nested", "single-stream"],
           notes="gzip of inner.zip without FNAME (as a mail gateway writes a.zip.gz): one entry inner.zip, "
                 "the same zip as in zip-in-zip.zip.")

    # AES-256 inner zip. 7-Zip salts it at random, so a rerun reuses the committed bytes (the entry's sha256
    # would change on every run otherwise), but only while they still hold the current `inner` tree.
    enc_bytes = None
    old = previous.get("nested/encrypted-inner.zip")
    if old:
        with zipfile.ZipFile(io.BytesIO(old[1])) as zf:
            candidate = zf.read("secret/inner.zip")
        if encrypted_zip_matches(candidate, inner, stage_root / "nested-encrypted-check"):
            enc_bytes = candidate
        else:
            print("nested/encrypted-inner.zip: committed inner zip no longer matches the tree, rebuilding")
    if enc_bytes is None:
        d = stage_root / "nested-encrypted"
        names = inner.stage(d)
        enc = stage_root / "nested-encrypted-inner.zip"
        run("7zz", "a", "-tzip", "-mem=AES256", f"-p{PASSWORD}", "-bd", "-y", enc, *names, cwd=d)
        enc_bytes = enc.read_bytes()
    outer = Tree(files={"readme.txt": b"The inner archive has a password.\n", "secret/inner.zip": enc_bytes},
                 dirs={"secret"})
    zip_with_python("nested/encrypted-inner.zip", outer)
    record("nested/encrypted-inner.zip", "zip", outer.manifest_entries(), tags=["nested", "encrypted-inner"],
           notes=f"Plain outer zip, no password. secret/inner.zip is a WinZip AES-256 zip with the same content as "
                 f"zip-in-zip.zip's inner.zip, password '{PASSWORD}' (nothing in the outer manifest row is encrypted).")

    docx = Tree(files={
        "[Content_Types].xml": b'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            b'<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
            b'<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
            b'<Default Extension="xml" ContentType="application/xml"/>'
            b'<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.'
            b'wordprocessingml.document.main+xml"/></Types>',
        "_rels/.rels": b'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            b'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            b'<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/'
            b'officeDocument" Target="word/document.xml"/></Relationships>',
        "word/document.xml": b'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            b'<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>'
            b'<w:p><w:r><w:t>Hello, Kernir!</w:t></w:r></w:p></w:body></w:document>',
    })
    outer = Tree(files={"report.docx": zip_tree_bytes(docx), "readme.txt": b"A .docx is a zip, but not an archive.\n"})
    zip_with_python("nested/docx-in-zip.zip", outer)
    record("nested/docx-in-zip.zip", "zip", outer.manifest_entries(), tags=["nested"],
           notes="report.docx is a minimal Word file: a ZIP by content, so detectFormat says zip, but "
                 "NestedArchive.isArchiveEntry says no and it opens in its own app.")


# MARK: - Main


def load_previous():
    """Old manifest records and bytes, so fixtures whose expectations did not change keep their exact bytes.
    Encrypted zip/7z (random salts), iso, xar, cpio and ditto output differ on every run otherwise."""
    try:
        old = json.loads((OUT / "manifest.json").read_text())["fixtures"]
    except (OSError, ValueError, KeyError):
        return {}
    out = {}
    for f in old:
        path = OUT / f["file"]
        if path.exists():
            record_only = {k: v for k, v in f.items() if k not in ("bytes", "fileSha256")}
            out[f["file"]] = (record_only, path.read_bytes())
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--libarchive-src", type=Path)
    ap.add_argument("--only", choices=["multivolume"],
                    help="rebuild just that group; leaves manifest.json and the other fixtures alone")
    args = ap.parse_args()
    if args.only == "multivolume":
        build_multivolume()
        return
    for tool in ("zip", "ditto", "7zz", "gcab", "zstd", "xar", "bsdtar", "hdiutil", "xattr"):
        if shutil.which(tool) is None:
            sys.exit(f"missing tool: {tool}")
    os.umask(0o022)
    previous = load_previous()
    for sub in OUT.iterdir() if OUT.exists() else []:
        if sub.is_dir() and sub.name not in ("third-party", MV_DIR):
            shutil.rmtree(sub)
    with tempfile.TemporaryDirectory() as tmp:
        stage = Path(tmp)
        build_zip(stage)
        build_7z(stage)
        build_tar()
        build_single()
        build_misc(stage)
        build_showcase()
        build_hostile()
        build_comments(stage)
        build_rename_names(stage)
        build_macmeta(stage)
        build_preview_types(stage)
        build_extract_here(stage)
        build_nested(stage, previous)
    build_third_party(args.libarchive_src)
    build_damaged()
    record_multivolume(build_multivolume())
    kept = 0
    for f in FIXTURES:
        old = previous.get(f["file"])
        if old and old[0] == f:
            (OUT / f["file"]).write_bytes(old[1])
            kept += 1
        data = (OUT / f["file"]).read_bytes()
        f["bytes"], f["fileSha256"] = len(data), hashlib.sha256(data).hexdigest()
    manifest = {
        "version": 1,
        "generatedBy": "scripts/fixtures/build_corpus.py",
        "schema": "docs/qa/fixtures.md",
        "password": PASSWORD,
        "wrongPassword": WRONG_PASSWORD,
        "fixtures": FIXTURES,
    }
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    total = sum(f["bytes"] for f in FIXTURES)
    print(f"{len(FIXTURES)} fixtures, {total / 1024:.0f} KiB ({kept} kept byte-identical)")


if __name__ == "__main__":
    main()
