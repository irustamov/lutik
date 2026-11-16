# Fixture corpus

`Fixtures/` holds about 5 MB of small archives, committed. `Fixtures/manifest.json` records what each one must produce through KernirCore. Large archives are not committed: `scripts/fixtures/make.sh` builds them into `build/fixtures-big/`.

## Commands

```sh
# Rebuild the committed corpus (needs: brew install sevenzip gcab zstd; macOS ditto/xar/hdiutil/bsdtar)
python3 -I scripts/fixtures/build_corpus.py --libarchive-src <unpacked libarchive-3.7.7>
#   Without --libarchive-src, the samples already in Fixtures/third-party/ are kept.

# Cross-check the manifest against stock libarchive (bsdtar) and the file hashes
python3 -I scripts/fixtures/verify_corpus.py

# Big fixtures (zip64 > 4 GiB, 70k and 200k entries), not committed
scripts/fixtures/make.sh
```

Some fixtures come out different on every run: random salts in the encrypted zip/7z fixtures, and timestamps or inode numbers in ditto, iso, xar and cpio output. The builder keeps the committed bytes of every row whose manifest record did not change (`load_previous`). When a record changes without the archive changing (a new manifest key such as `macMetadata`), restore the committed file with `git checkout` and run the builder again, so it is kept as well. Commit a rebuild only when a fixture really changed.

## Tests

`Packages/KernirCore/Tests/KernirCoreTests/FixtureTests.swift` runs every assertion in the manifest through the public API. Run it with `swift test` in `Packages/KernirCore`.

- The "Fixture corpus" suite always runs and checks that every file matches its `fileSha256`.
- The engine suites skip themselves until the reader lands (when `detectFormat(zip/deflate.zip)` returns non-nil). Each test has a 1-minute limit, so a hang fails instead of blocking CI.
- On fixtures tagged `libarchive-bug`, failures are recorded as known issues. Set `KERNIR_STRICT_FIXTURES=1` to make them fail. Everything else is strict: `libarchive-gap` rows already expect `unsupportedEncryption`, and `charset-heuristic` rows have been checked strictly since the per-archive name encoding landed.
- Every `extractAll` run, known gap or not, checks that nothing landed outside the destination.
- When `open` fails, `extractAll` takes that as the extraction's result: it must match both `open` and `extract` (so a damaged stream that fails at open still has to fail with the `extract` the manifest names).
- `KERNIR_FIXTURES=<dir>` points the suite at another corpus. The "Big fixtures" suite runs when `build/fixtures-big/manifest.json` exists.

## How the manifest is built

Expected entries come from the file trees defined in `build_corpus.py`, not from reading the archives back, so the manifest is an independent check of KernirCore. Two exceptions:

- `zip/macos-finder.zip` (ditto output) is listed with Python's `zipfile`.
- `third-party/**` (rar, lha, cab samples from libarchive's BSD-licensed test suite) are listed with bsdtar. Each listing is checked against libarchive's own test expectations, and the RAR encryption contents and passwords come from `test_read_format_rar_encryption.c`.

`showcase/project.zip` (tag `showcase`) is not a test case but the project shown in the App Store screenshots (`ScreenshotUITests`). It is shaped like a small design project: `src/`, `assets/`, `cover.png`, `brief.pdf`, `README.md` and `LICENSE`, with dates in November 2026. Every file is real, generated in `build_showcase()`, and opens in its own app. It runs through the same manifest tests as every other fixture. Change its look only together with `ScreenshotUITests`.

`verify_corpus.py` compares every fixture with stock bsdtar (libarchive 3.7.4 on macOS). Where KernirCore is meant to differ from bsdtar, the fixture carries a tag that explains why, and the script reports it as `GAP`. Anything else is reported as `FAIL`.

## Manifest schema (version 1)

Top level: `password` (`"kernir"`, used by every generated encrypted fixture), `wrongPassword`, and `fixtures[]`.

| Field | Meaning |
|---|---|
| `file` | Path relative to `Fixtures/`. |
| `volumes` | Multi-volume sets only: the set's other parts, relative to `Fixtures/`, in order. `file` is the part a person opens (`.001`, `.zip`, `.part1.rar`, `.rar`), and every expectation applies to opening that part. Other rows leave the key out. |
| `comment` | Archive comment: the decoded text the engine should report. Rows without an archive comment leave the key out. |
| `entryComments` | Map of entry path to that entry's comment (decoded text). Rows without entry comments leave the key out. |
| `macMetadata` | Entry paths that are macOS metadata (`.DS_Store`, `._*`, `__MACOSX/` at any depth). `Icon\r` and `.localized` are not listed yet, see the notes below. Rows that don't set it leave the key out. |
| `format` | `ArchiveFormat` raw value, or `null` for non-archives. |
| `detect` | Expected `Archive.detectFormat` result (`null` means not an archive). |
| `open` | Expected result of `Archive.open(at:password: nil)`. |
| `password` | Password that unlocks the fixture, or `null`. |
| `encrypted` | Expected `ArchiveReading.isEncrypted`. |
| `extract` | Expected result of `extract(nil, to:)` after opening with `password`. |
| `extractWithoutPassword` | Expected result of `extract(nil, to:)` after opening without a password. |
| `openWithWrongPassword`, `extractWithWrongPassword` | The same calls made with `wrongPassword`. |
| `extractExpect` | `"confined"`: after extraction (whether it throws or not), nothing exists outside the destination. |
| `mtime` | Unix time every entry carries, for formats that store it exactly (tar, 7z, cpio, xar). `null` means don't assert dates. ZIP DOS times are local-time, so they are never asserted. |
| `entriesComplete` | `true`: the listing must equal `entries` exactly. `false`: `entries` must be a subset of the listing. |
| `entryCount` | Exact number of entries, including synthesized directories. Set even when `entries` is a sample (`zip/many-entries.zip`). |
| `entries[]` | `path` (normalized), `dir`, `size` (`null` means the engine reports nil; missing means don't assert), `sha256` of the extracted bytes, and optional `symlink`, `hardlink`, `encrypted`, `password` (when one entry uses a different password), `corruptData` (extracting it must fail). |
| `tags` | See below. |
| `bytes`, `fileSha256` | Size and hash of the fixture file itself. |

Result values: `"ok"`, an `ArchiveError` case name (`passwordRequired`, `wrongPassword`, `unsupportedEncryption`, `corrupted`, `unsupportedFormat`), `"error"` (any `ArchiveError`), or `"any"` (must return or throw, never crash or hang).

### Path rules

- Paths are normalized: no leading `/` or `./`, no trailing `/`, and empty, `.` and `..` components are dropped. So `../evil.txt` lists as `evil.txt`.
- Missing parent directories are synthesized, with size and date nil.
- For duplicate paths, the last entry wins.
- A single-stream file (`.gz`, `.bz2`, `.xz`, `.zst`) is one entry named after the file without its compression extension, with size nil. A gzip `FNAME` header takes precedence over that.
- Names may come back from libarchive in NFD on Apple platforms. Swift's `String ==` treats NFC and NFD as equal, so tests compare with `==`.

### Tags

`baseline`, `encrypted`, `mixed-encryption`, `encrypted-headers`, `unicode`, `nfd`, `charset-heuristic` (names without a UTF-8 flag that KernirCore decodes by detecting the archive's encoding; strict in FixtureTests, a known gap for verify_corpus.py only, since stock bsdtar does not decode them), `synthesized-dirs`, `symlink`, `hardlink`, `duplicates`, `long-names`, `zip64`, `many-entries`, `single-stream`, `size-unknown`, `macosx`, `resource-fork`, `wrong-extension`, `corrupt`, `traversal`, `ratio`, `third-party`, `libarchive-gap` (libarchive cannot do it at all yet: RAR decryption), `patched-libarchive` (KernirCore's patched libarchive does it, stock bsdtar does not: 7z AES-256 decryption, patch 0004; a known gap for verify_corpus.py only, strict in FixtureTests), `libarchive-bug` (valid archive that 7-Zip reads but libarchive 3.7.4 does not), `multivolume` (retired: it marked the split and multi-volume sets as a known gap until KernirCore learned to read whole sets; their rows, the ones with `volumes`, carry no gap tag now and FixtureTests checks them strictly. verify_corpus.py still reports a row with `volumes` as a known gap, since stock bsdtar reads only the part it is given. `multivolume/missing/` and the 241 MB `rar4-multi` set have no rows, see `multivolume/EXPECTED.json`), `damage-unchecked` (retired: it marked the Fixtures/corrupt/ cases that only a CRC catches, 7z and LHA entry CRCs and the gzip trailer, until libarchive patch 0006 made them fail with corrupted; no fixture carries it now), `comment` (the row has an archive `comment` or `entryComments`), `comment-deferred` (a comment the engine does not read yet: `single/comment.txt.gz`, a gzip `FCOMMENT`; a nil comment there is a known gap, not a failure), `case-twins` (names that differ only in case, `README` and `Readme`: both are listed; FixtureTests checks the twins' contents only on a case-sensitive volume until N1's conflict handling lands), `extract-here` (exactly one top-level file or folder, for Extract Here's no-extra-folder rule), `preview-types` (`showcase/preview-types.zip`, one file per type the Space preview must render), `legacy-encoding`, `cp437`, `cp932` (which legacy name or comment encoding a row exercises; they assert nothing on their own).

### Notes on the 0.1.0 fixtures

- `zip/comment-utf8-bom.zip`: the comment bytes start with a UTF-8 BOM. The manifest's `comment` has the BOM stripped, so the engine must report the text without it; a save without an edit keeps the original bytes.
- `zip/comment-40000.zip`: 40,000 bytes is longer than upstream libarchive's 16 KiB seekable end-of-central-directory search, where stock bsdtar falls back to its streaming reader. KernirCore's patched libarchive (patch 0012) searches the last 20 + 22 + 65,535 bytes and takes an end record whose comment reaches EOF, so the zip opens with the seekable reader and its central directory. `zip/comment-16000.zip` is the size KernirCore caps writes at.
- `zip/comment-long-utf8-entries.zip`: a 48,000-byte UTF-8 archive comment (Cyrillic, CJK, emoji lines), also past libarchive's old 16 KiB EOCD search, plus entry comments on 5 of 7 entries (ASCII and UTF-8, bit 11 set where a name or comment is UTF-8). With KernirCore's widened search the listing comes from the central directory; every comment must survive a zip save.
- `Icon\r` and `.localized` in `zip/macos-junk.zip` and `7z/macos-junk.7z` are deliberately not in `macMetadata`: they are ordinary rows until it is decided whether they count as Mac metadata.
- `zip/macos-nested-junk.zip`: `__MACOSX` folders below the root, `photos/__MACOSX/` (an AppleDouble `._img.jpg` and a plain `stray.txt` that is metadata only because of its folder) and `albums/trip/__MACOSX/`. They are metadata like the root one, with everything in them. `photos/__MACOSX.txt` is a look-alike and is kept.
- `single/comment.txt.gz` (`comment-deferred`) is out of scope for 0.1.0, which handles ZIP comments only: read side only, and a gzip comment is not kept on save.

## Findings while building the corpus (libarchive 3.7.4 on macOS)

1. **`__MACOSX` disappears on Apple platforms.** In `archive_read_support_format_zip.c`, when `HAVE_COPYFILE_H` is defined the seekable ZIP reader merges `__MACOSX/._*` AppleDouble entries into their files and hides them. If the vendored build defines it, `zip/macos-finder.zip` lists 4 entries instead of 10, and a repack built from that listing would silently drop resource forks and extended attributes. The streaming reader doesn't do this, so macOS and iOS may also behave differently. The tar reader does the same with `._name` members (`tar:mac-ext` is on by default): `tar/macos-bsdtar.tar` lists 4 entries instead of 7. KernirCore reads with `zip:!mac-ext` and `tar:!mac-ext`, so both list raw.
2. **Encrypted RAR entries are reported as corrupt data**, not as encrypted. bsdtar says "Invalid PPMd sequence" for `b.txt` in `rar4-encrypted-mixed.rar`. KernirCore must check `archive_entry_is_data_encrypted` before reading, so it throws `unsupportedEncryption` rather than `corrupted`.
3. **Solid encrypted RAR (v4 and v5) won't list** with Apple's 3.7.4. libarchive 3.7.7's own test expects the headers to read, so this depends on the vendored version.
4. **A zero-length entry with ZIP method 14 (LZMA)** fails with "lzma unknown error 10" (`zip/lzma-method.zip`, `empty.txt`).
5. **An uncompressed CAB from gcab** fails with a CFDATA checksum error on the empty file (`cab/none.cab`). 7-Zip reads it. This may be a gcab checksum quirk, but real-world CABs come from many tools.
6. **Password tooling for interop tests:** `bsdtar --passphrase` reads ZipCrypto and WinZip AES. `unzip -P` reads only ZipCrypto. `ditto` cannot take a password at all ("No password was provided and the client did not provide a callback"). 7-Zip (`7zz`) reads everything.
