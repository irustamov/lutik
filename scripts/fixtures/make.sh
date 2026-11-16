#!/bin/sh
# Builds large fixtures that are too big to commit into build/fixtures-big/.
#   zip64-5gib.zip     one 5 GiB file of zeros (zip64 sizes and offsets, about 5 MB on disk)
#   entries-70k.zip    70,000 entries (more than the 65,535 a non-zip64 central directory can hold)
#   entries-200k.zip   200,000 empty files: Quick Look timing (< 2 s in Release)
#   big-tree.tar.xz    2,000 files x 256 KiB of random data (about 500 MB): repack and progress timing
# Writes build/fixtures-big/manifest.json in the same schema as Fixtures/manifest.json.
# Usage: scripts/fixtures/make.sh [only-name ...]
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT="$ROOT/build/fixtures-big"
mkdir -p "$OUT"
exec python3 -I - "$OUT" "$@" <<'PY'
import hashlib, io, json, lzma, os, sys, tarfile, zipfile
out, only = sys.argv[1], set(sys.argv[2:])
MTIME = 1767323045
fixtures = []

def want(name):
    return not only or name in only

if want("zip64-5gib.zip"):
    size, chunk = 5 * 1024**3, bytes(16 * 1024**2)
    h = hashlib.sha256()
    with zipfile.ZipFile(os.path.join(out, "zip64-5gib.zip"), "w", zipfile.ZIP_DEFLATED, compresslevel=1) as zf:
        with zf.open(zipfile.ZipInfo("zeros-5gib.bin", (2026, 1, 2, 3, 4, 4)), "w", force_zip64=True) as f:
            for _ in range(size // len(chunk)):
                f.write(chunk); h.update(chunk)
    fixtures.append({"file": "zip64-5gib.zip", "format": "zip", "detect": "zip", "open": "ok", "extract": "ok",
                     "entriesComplete": True, "entryCount": 1, "tags": ["zip64", "big"],
                     "entries": [{"path": "zeros-5gib.bin", "dir": False, "size": size, "sha256": h.hexdigest()}]})

if want("entries-70k.zip"):
    n = 70_000
    with zipfile.ZipFile(os.path.join(out, "entries-70k.zip"), "w", zipfile.ZIP_STORED) as zf:
        for i in range(n):
            zf.writestr(zipfile.ZipInfo(f"d{i // 1000:02}/f{i % 1000:03}.txt", (2026, 1, 2, 3, 4, 4)), f"{i}\n")
    fixtures.append({"file": "entries-70k.zip", "format": "zip", "detect": "zip", "open": "ok", "extract": "ok",
                     "entriesComplete": False, "entryCount": n + 70, "tags": ["zip64", "many-entries", "big"],
                     "entries": [{"path": "d69/f999.txt", "dir": False, "size": 6,
                                  "sha256": hashlib.sha256(b"69999\n").hexdigest()}]})

if want("entries-200k.zip"):
    n = 200_000
    with zipfile.ZipFile(os.path.join(out, "entries-200k.zip"), "w", zipfile.ZIP_STORED) as zf:
        for i in range(n):
            zf.writestr(zipfile.ZipInfo(f"d{i // 1000:03}/f{i % 1000:03}.txt", (2026, 1, 2, 3, 4, 4)), b"")
    fixtures.append({"file": "entries-200k.zip", "format": "zip", "detect": "zip", "open": "ok", "extract": "ok",
                     "entriesComplete": False, "entryCount": n + 200, "tags": ["zip64", "many-entries", "big"],
                     "entries": [{"path": "d199/f999.txt", "dir": False, "size": 0,
                                  "sha256": hashlib.sha256(b"").hexdigest()}]})

if want("big-tree.tar.xz"):
    entries = []
    with lzma.open(os.path.join(out, "big-tree.tar.xz"), "wb", preset=1) as xz:
        with tarfile.open(fileobj=xz, mode="w|", format=tarfile.PAX_FORMAT) as tf:
            for i in range(2000):
                data = b"".join(hashlib.sha256(f"{i}:{j}".encode()).digest() for j in range(8192))
                ti = tarfile.TarInfo(f"dir{i // 100:02}/file{i:04}.bin")
                ti.size, ti.mtime, ti.mode = len(data), MTIME, 0o644
                tf.addfile(ti, io.BytesIO(data))
                entries.append({"path": ti.name, "dir": False, "size": len(data),
                                "sha256": hashlib.sha256(data).hexdigest()})
    fixtures.append({"file": "big-tree.tar.xz", "format": "tarXz", "detect": "tarXz", "open": "ok", "extract": "ok",
                     "entriesComplete": False, "entryCount": 2020, "mtime": MTIME, "tags": ["big"],
                     "entries": entries[:: 100]})

def file_sha256(name):
    h = hashlib.sha256()
    with open(os.path.join(out, name), "rb") as f:
        for block in iter(lambda: f.read(16 * 1024**2), b""):
            h.update(block)
    return h.hexdigest()

# fileSha256 is required by FixtureTests' decoder; without it the "Big fixtures" suite skips.
for f in fixtures:
    f["fileSha256"] = file_sha256(f["file"])

path = os.path.join(out, "manifest.json")
old = json.load(open(path))["fixtures"] if os.path.exists(path) else []
merged = {f["file"]: f for f in old if os.path.exists(os.path.join(out, f["file"]))} | {f["file"]: f for f in fixtures}
for f in merged.values():
    f.setdefault("password", None); f.setdefault("encrypted", False); f.setdefault("mtime", None)
    if "fileSha256" not in f:
        f["fileSha256"] = file_sha256(f["file"])
json.dump({"version": 1, "generatedBy": "scripts/fixtures/make.sh", "fixtures": list(merged.values())},
          open(path, "w"), indent=2)
print(f"{len(fixtures)} big fixtures in {out}")
PY
