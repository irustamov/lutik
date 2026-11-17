# AGENTS.md

Instructions for coding agents working in this repository. Product facts for users are in
[README.md](README.md); product and design intent is in [PRODUCT.md](PRODUCT.md).

## What this is

Lutik is a free, MIT-licensed archive viewer and editor for macOS 14+ and iOS/iPadOS 17+, written in
Swift 6 (SwiftUI plus AppKit/UIKit) on a vendored, patched libarchive. **Kernir** is the code name:
the Xcode project, targets, schemes, Swift package, Swift module (`@testable import Kernir`) and bundle
IDs (`com.kernir.app...`) keep it. The shipped app, `.app`, `.dmg` and every user-facing string say
**Lutik**. Do not rename Kernir identifiers.

## Layout

```
project.yml                  XcodeGen spec: the source of truth for targets, Info.plists, entitlements
Packages/KernirCore/         Swift package, the archive engine (no UI)
  Sources/KernirCore/        public API in API.swift; libarchive wrappers in Engine/
  Sources/CLibArchive/       vendored libarchive 3.8.10 + zstd 1.5.7 decoder (C)
  Sources/CLZMA/             vendored xz-utils liblzma 5.8.4 (C), used on both platforms
  Tests/KernirCoreTests/     engine tests (Swift Testing); Support/ holds synthetic archive builders
App/Shared/                  code compiled into both apps (model, save settings, services, l10n "Shared" table)
App/macOS/, App/iOS/         the KernirMac and KernirIOS app targets
Extensions/                  Quick Look preview + thumbnail extensions, Mac and iOS (Shared/, ThumbnailShared/)
Tests/                       app, extension and UI test targets (see project.yml for which sources each compiles)
Fixtures/                    committed test archives + manifest.json (generated, see below)
scripts/                     release, CI, fixture, l10n and brand scripts; scripts/tests/ = bash test suite
docs/                        README images, QA fixture docs, App Store metadata texts
```

## Build and test

Everything that builds or runs the app needs macOS with Xcode 26 (CI pins Xcode 26.6 on `macos-26`)
and XcodeGen. Commands as CI runs them (`.github/workflows/ci.yml`), from the repo root:

```sh
brew install xcodegen
xcodegen generate            # writes Kernir.xcodeproj (gitignored); runs scripts/build/stamp-version.sh first

# Engine tests. CI sets KERNIR_REQUIRE_INTEROP=1 and installs `sevenzip`; without that variable,
# checks that need an external tool (7zz, zipinfo, bsdtar, unzip, hdiutil) skip when it is missing.
swift test --package-path Packages/KernirCore

# iOS build
xcodebuild build -project Kernir.xcodeproj -scheme KernirIOS \
  -destination 'generic/platform=iOS Simulator' CODE_SIGN_IDENTITY=-

# Release/App Store script tests (fake xcodebuild/codesign/notarytool in scripts/tests/fakes).
# --all also archives KernirMac in Release, which is CI's macOS build check.
scripts/tests/run.sh --all   # or: scripts/tests/run.sh test_name ...
```

Manual-dispatch CI jobs only (Actions > CI > Run workflow): hosted Mac unit tests
(`xcodebuild test -project Kernir.xcodeproj -scheme KernirMac -destination 'platform=macOS' CODE_SIGN_IDENTITY=-`),
Mac UI tests (scheme `KernirMacUITests`) and the iOS QA UI test classes on iPhone and iPad simulators.
CI runs neither `KernirIOSTests` (in the `KernirIOS` scheme; the iOS job uses `-only-testing` for the
QA classes) nor the `KernirQuickLookTests` and `KernirQuickLookIOSUITests` schemes.

Checks that need only Python 3 (stdlib, no Xcode, so they also run on Linux). CI does not run them;
run them when you touch strings, `.xcstrings`, or Info.plist content in `project.yml`:

```sh
python3 -I scripts/l10n/check-catalogs.py         # String Catalog gate (includes code_keys.py)
python3 -I scripts/l10n/infoplist_catalogs.py --check
```

There is no SwiftLint/SwiftFormat config in the repo.

## Conventions observed in the code

- Swift 6 language mode (`SWIFT_VERSION: "6.0"`, `swift-tools-version: 6.0`): strict concurrency,
  `Sendable` types, `OSAllocatedUnfairLock` for shared caches. 4-space indent, lines mostly under 120 chars.
- Unit tests use Swift Testing (`import Testing`, `@Test`, `#expect`/`#require`); UI tests use XCTest.
  Tests import with `@testable import Kernir` (apps) or `@testable import KernirCore`.
- Every user-visible string goes through String Catalogs, English only for now:
  `String(localized: "...", table: "Shared", comment: "...")` for `App/Shared`; every key needs a
  non-empty comment saying where it appears. Don't build plurals with `count == 1 ? ...` ternaries;
  `check-catalogs.py` flags them.
- Logging: `Logger(subsystem: "com.kernir.app", category: "...")`.
- Doc comments explain behavior and the reason for it (limits, failure modes, which test covers it).
  Keep that density when you change behavior, and update the comment with the code.
- UI rule (README, PRODUCT.md): stock SwiftUI/AppKit/UIKit controls, SF Symbols, system accent color.
  No custom colors, fonts or chrome.
- Engine safety: a save writes a temporary file and replaces the original only when complete; extraction
  never overwrites existing items and never applies setuid/setgid/sticky bits. Size, count and nesting
  limits guard against hostile archives (`NestingBudget.swift`, and the limit patches listed in
  `CLibArchive/VERSION`).
  Keep these guarantees and their tests when you change the engine.

## Do not touch, or touch only this way

- `Kernir.xcodeproj` is generated and gitignored: change `project.yml` and rerun `xcodegen generate`.
- `App/*/Info.plist`, `Extensions/*/Info.plist` and `App/macOS/KernirMac.entitlements` are written by
  XcodeGen from `project.yml` (`info.properties`, `entitlements.properties`). Edit `project.yml`,
  then regenerate the InfoPlist/ServicesMenu catalogs with `python3 -I scripts/l10n/infoplist_catalogs.py`.
- `App/Version.generated.xcconfig` is written by `stamp-version.sh` on every generate (gitignored).
- `Packages/KernirCore/Sources/CLibArchive/`: vendored C. Local changes to libarchive are recorded as
  numbered files in `CLibArchive/patches/` (already applied to the tree) and listed in
  `CLibArchive/VERSION`. Any change there needs a new patch file and a VERSION entry. The zstd sources
  are unmodified upstream and decompression only, so `.zst` cannot be written.
- `Fixtures/`: generated by `scripts/fixtures/build_corpus.py`; don't edit by hand
  (`Fixtures/README.md`, `docs/qa/fixtures.md`). Generated encrypted fixtures use the password `kernir`.
- Signing and release config: `scripts/lib/common.sh` (team ID, bundle ID), `scripts/export/*.plist`,
  `scripts/ci/import-signing.sh`, the entitlements in `project.yml`, `DEVELOPMENT_TEAM` (kept empty in
  `project.yml` for local ad-hoc builds). Change only when asked. Never commit certificates, `.p8` keys
  or passwords; CI reads them from GitHub secrets.
- Privacy: the apps have no networking code, and the Mac app's sandbox has no network entitlement.
  The privacy manifests (`*/PrivacyInfo.xcprivacy`) declare no tracking and no collected data. Don't add
  network access, analytics or SDKs. Using a new required-reason API means updating those manifests.
- Bundle IDs and the App Store record: `com.kernir.app` (Mac Debug builds use `com.kernir.app.dev`).

## Gotchas

- `KernirMacTests` must not depend on the `KernirCore` package: it uses the host app's copy through
  `BUNDLE_LOADER`. A second copy makes `ArchiveError` fail to match `ArchiveError`.
- `Tests/KernirMacTests/ArchiveNameEncodingTitleTests.swift` and `Tests/KernirMacTests/Support/TestDefaults.swift`
  are also compiled into `KernirIOSTests`; moving or renaming them breaks iOS project generation.
- Mac UI tests drive the real keyboard and mouse: never run them on a developer's Mac
  (build-for-testing only). Every test skips unless `KERNIR_MAC_UI_TESTS=1` (`MacAppLaunch.swift`).
- The app's `PRODUCT_NAME` is `Lutik` and its module is `Kernir`, so `TEST_HOST` paths say `Lutik.app`.
- CI runs on pull requests and pushes to `main` only (not feature-branch pushes), and ignores changes
  limited to `docs/**` and `**/*.md`. macOS runner minutes are metered.
- Read-only formats (RAR, ISO, CPIO, XAR, LHA, CAB, single-file GZ/BZ2/XZ/ZST, TAR.ZST) come from
  `ArchiveFormat.writable` in `API.swift`; encryption per format from `supportedEncryptions`. The UI
  reads these capabilities, so change them there, not in views.

## Release flow

- Status: Mac 0.1.0 is on GitHub Releases. The Mac and iPhone/iPad App Store versions are submitted
  to Apple and awaiting release.
- Mac direct download: pushing a tag `vX.Y.Z` runs `.github/workflows/release.yml`. It runs
  `scripts/release-mac.sh --version X.Y.Z --sign developer-id` (archive, sign, notarize),
  `scripts/verify-dmg.sh dist/Lutik.dmg`, and creates a **draft** GitHub release with `Lutik.dmg` and
  `Lutik.dmg.sha256`. A manual dispatch is an ad-hoc signed dry run (draft prerelease).
- App Store: `scripts/release-appstore.sh <mac|ios> [--version X.Y.Z] [--upload | --offline]`;
  `--upload` requires `KERNIR_ALLOW_UPLOAD=1` and App Store Connect API key variables. Store texts are
  in `docs/release/appstore/metadata/`.
- The version comes from the tag (scripts pass `MARKETING_VERSION`); the build number is the commit count.

## Before you finish

Run what applies on your platform: `swift test --package-path Packages/KernirCore` for engine changes,
the Python l10n checks for strings or `project.yml`, and `scripts/tests/run.sh <test_name>` for
script changes. If you can't build (no macOS/Xcode), say which checks you could not run.
