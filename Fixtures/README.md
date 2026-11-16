# Fixtures

These are test archives for KernirCore and the apps. `manifest.json` says what each one must produce. The schema, the tags, the rebuild commands and the libarchive findings are in [docs/qa/fixtures.md](../docs/qa/fixtures.md).

All generated encrypted fixtures use the password `kernir`. The RAR samples under `third-party/rar/` use `password` (and `password2` for `d.txt`), as documented in libarchive's tests.

Don't edit these files by hand. Change `scripts/fixtures/build_corpus.py` and rebuild. Files under `third-party/` come from libarchive 3.7.7's test suite (BSD-2-Clause, see `third-party/LICENSE`).

## Multi-volume sets

Not listed in `manifest.json`. `multivolume/EXPECTED.json` holds every set (volumes, entries with size and sha256, passwords) and `multivolume/SHA256SUMS` the checksum of every part (`cd Fixtures && shasum -a 256 -c multivolume/SHA256SUMS`). Rebuild with `python3 -I scripts/fixtures/build_corpus.py --only multivolume`. Generated sets come from one deterministic incompressible tree (60 KB, 24 KB volumes). Encrypted sets (`s7e`, `spane`) have random salts, so the script keeps the committed bytes.

- `multivolume/s7.7z.001`-`.003`: 7z split, plain.
- `multivolume/s7e.7z.001`-`.003`: 7z split, AES-256 with encrypted headers (`kernir`).
- `multivolume/sz.zip.001`-`.003`: zip split by 7zz (`-v`).
- `multivolume/span.z01`, `span.z02`, `span.zip`: Info-ZIP spanned zip. `zip -s` needs volumes of at least 64 KB, so this one uses a 160 KB tree (adds `data/delta.bin`) with 64 KB volumes.
- `multivolume/spane.z01`, `spane.z02`, `spane.zip`: the same, ZipCrypto with `kernir`.
- `multivolume/missing/`: `s7` without `.002`, `span` without `span.z01`, for missing-volume tests.
- `third-party/rar-multivolume/rar5-multi.part01.rar`-`part08.rar`, `rar4-multi.part0001.rar`-`part0004.rar` (first entry inflates to 241 MB: list only), `rar4-files.part1.rar`-`part6.rar`: libarchive v3.8.1 tests (BSD-2-Clause), decoded from `.uu`.
- `third-party/rar-multivolume/rar4-old.rar`, `.r00`-`.r04`: the `rar4-files` bytes renamed to old-style naming. The headers still carry the new-numbering flag.
