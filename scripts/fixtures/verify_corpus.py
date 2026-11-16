#!/usr/bin/env python3
"""Cross-checks Fixtures/manifest.json against stock libarchive (bsdtar) before KernirCore exists.

For each fixture: file hash matches, bsdtar's listing (normalized like KernirCore: no leading
"/" or "./", no "..", no trailing "/", parent dirs synthesized) matches the manifest, and every
file's extracted bytes hash to the manifest sha256. Mismatches are either generator bugs or
places where KernirCore must do better than plain libarchive (charset heuristics, 7z/RAR
encryption); the latter are listed as EXPECTED with the tag that explains them.

Usage: python3 -I scripts/fixtures/verify_corpus.py
"""

import hashlib
import json
import os
import subprocess
import sys
import unicodedata
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
FIX = REPO / "Fixtures"
ENV = dict(os.environ, LC_ALL="en_US.UTF-8")
# Mismatches with these tags are known gaps between bsdtar and KernirCore's intended behavior.
EXPECTED_GAP_TAGS = {"charset-heuristic", "libarchive-gap", "libarchive-bug", "single-stream", "duplicates",
                     "macosx", "patched-libarchive"}
# A multi-volume row ("volumes"): bsdtar reads only the part it is given, KernirCore the whole set.
VOLUMES_GAP = "multivolume"
OPTIONS = {"third-party/cab/cp932-names.cab": ["--options", "hdrcharset=CP932"]}


def normalize(path):
    """KernirCore's path rules, plus NFC: Apple's libarchive returns NFD names."""
    parts = [p for p in path.split("/") if p not in ("", ".", "..")]
    return unicodedata.normalize("NFC", "/".join(parts))


def pattern(name):
    """bsdtar treats member names as globs; escape the metacharacters."""
    return "".join("\\" + c if c in "[]*?\\" else c for c in name)


def bsdtar(*args):
    return subprocess.run(["bsdtar", *args], capture_output=True, env=ENV)


def check(f):
    path = FIX / f["file"]
    problems = []
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != f["fileSha256"]:
        problems.append("file sha256 differs from manifest (regenerate)")
    if f["open"] != "ok" or not f["entries"]:
        return problems
    opts = OPTIONS.get(f["file"], [])
    if f["password"]:
        opts = opts + ["--passphrase", f["password"]]
    res = bsdtar(*opts, "-tf", path)
    if res.returncode != 0:
        return problems + [f"bsdtar -t failed: {res.stderr.decode(errors='replace').strip()[:200]}"]
    raw = [n for n in res.stdout.decode("utf-8", errors="replace").splitlines() if n]
    listed = set()
    for n in raw:
        n = normalize(n)
        if not n:
            continue
        parts = n.split("/")
        for i in range(1, len(parts) + 1):
            listed.add("/".join(parts[:i]))
    expected = {unicodedata.normalize("NFC", e["path"]) for e in f["entries"]}
    if f["entriesComplete"]:
        if listed != expected:
            problems.append(f"listing: missing {sorted(expected - listed)[:5]} extra {sorted(listed - expected)[:5]}")
        if f["entryCount"] is not None and len(listed) != f["entryCount"]:
            problems.append(f"entryCount {f['entryCount']} but bsdtar gives {len(listed)}")
    elif not expected <= listed:
        problems.append(f"listing lacks {sorted(expected - listed)[:5]}")
    by_norm = {}
    for n in raw:
        by_norm.setdefault(normalize(n), n)
    for e in f["entries"]:
        key = unicodedata.normalize("NFC", e["path"])
        if e["dir"] or "sha256" not in e or "hardlink" in e or key not in by_norm:
            continue
        entry_opts = opts
        if e.get("password"):
            entry_opts = OPTIONS.get(f["file"], []) + ["--passphrase", e["password"]]
        out = bsdtar(*entry_opts, "-xOf", path, pattern(by_norm[key]))
        if out.returncode != 0 and not e.get("corruptData"):
            problems.append(f"extract {e['path']}: {out.stderr.decode(errors='replace').strip()[:120]}")
        elif out.returncode == 0 and hashlib.sha256(out.stdout).hexdigest() != e["sha256"]:
            problems.append(f"sha256 mismatch for {e['path']}")
    return problems


def main():
    manifest = json.loads((FIX / "manifest.json").read_text())
    files_on_disk = {str(p.relative_to(FIX)) for p in FIX.rglob("*")
                     if p.is_file() and p.name not in ("manifest.json", "LICENSE", "README.md", ".DS_Store")}
    listed = {f["file"] for f in manifest["fixtures"]} | {v for f in manifest["fixtures"] for v in f.get("volumes", [])}
    # Multi-volume extras: checksums, per-set expectations, missing-part sets, the 241 MB RAR4 set.
    listed |= {p for p in files_on_disk if p in ("multivolume/SHA256SUMS", "multivolume/EXPECTED.json")
               or p.startswith(("multivolume/missing/", "third-party/rar-multivolume/rar4-multi."))}
    hard, gaps = 0, 0
    for orphan in sorted(files_on_disk - listed):
        print(f"FAIL  {orphan}: not in manifest")
        hard += 1
    for f in manifest["fixtures"]:
        problems = check(f)
        if not problems:
            print(f"ok    {f['file']}")
            continue
        gap = EXPECTED_GAP_TAGS & set(f["tags"]) | ({VOLUMES_GAP} if f.get("volumes") else set())
        label = f"GAP   ({','.join(sorted(gap))})" if gap else "FAIL "
        hard += 0 if gap else 1
        gaps += 1 if gap else 0
        for p in problems:
            print(f"{label} {f['file']}: {p}")
    print(f"\n{len(manifest['fixtures'])} fixtures, {hard} failures, {gaps} known gaps vs stock bsdtar")
    sys.exit(1 if hard else 0)


if __name__ == "__main__":
    main()
