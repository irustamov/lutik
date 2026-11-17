<p align="center">
  <img src="docs/assets/readme-header.png" alt="Lutik: a Yorkshire terrier surrounded by archive and package file icons" width="860">
</p>

# Lutik

**Zip, 7z & RAR viewer for Mac, iPhone and iPad.** Look inside an archive, take out one file, add or remove files and save it back. Free, open source, built with SwiftUI.

**Lutik is named after our dog.**

In loving memory of Lutik, a loyal companion whose warmth, joy, and gentle presence brought light into every day. Though Lutik is no longer with us, the love we shared and the memories we made will stay in our hearts forever.

Run free across the rainbow bridge, sweet Lutik.

App Store name: *Lutik: Zip, 7z & RAR Viewer* · Website: [lutik.io](https://lutik.io)

Archive Utility unpacks everything at once. Lutik opens an archive like a folder instead: press Space in Finder to see what is inside, double-click to browse it, then take out just the file you need, or change the archive and save. It uses only stock Apple controls, so it looks and behaves like the rest of macOS and iOS. No account, no subscription, no "Pro" version, no ads, no tracking.

## At a glance

- **Platforms:** Mac (macOS 14 Sonoma or later), iPhone and iPad (iOS / iPadOS 17 or later).
- **Price and license:** free, [MIT](LICENSE) open source. No account, subscription, in-app purchases or ads.
- **Open and save:** ZIP, 7z, TAR, TAR.GZ, TAR.BZ2, TAR.XZ.
- **Open only:** RAR (v4, v5, multi-part), GZ, BZ2, XZ, ZST, TAR.ZST, ISO, CPIO, XAR, LHA, CAB.
- **Passwords:** opens ZipCrypto and AES ZIPs and AES-256 7z archives (encrypted file names included). Saves ZIP with AES-256, AES-128 or ZipCrypto, and 7z with AES-256, which also hides the file names. Encrypted RAR and ZIPs with PKWARE Strong Encryption cannot be opened.
- **Privacy:** no data collection, analytics or tracking, and no networking code. The Mac app runs in the App Sandbox without network access. A password is kept only if you choose to remember it, in your Keychain.
- **Download:** [Lutik.dmg](https://github.com/irustamov/lutik/releases/latest/download/Lutik.dmg) for Mac (signed and notarized), from [GitHub Releases](https://github.com/irustamov/lutik/releases). The App Store versions are not live yet. See [lutik.io](https://lutik.io).

## What it does

- **Browse.** Open an archive as a document: folders, sizes, kinds and dates, sorting and search. Press Space on a file to preview it without extracting.
- **Edit in place.** Add files with the plus button or by dragging them in, remove and rename files, make folders, and save the archive back with ⌘S (undo with ⌘Z).
- **Extract.** Take out the selection or everything, or drag files straight into Finder (Mac) or Files (iPad).
- **Create.** Make a new archive from files you pick, optionally protected with a password (ZIP: AES-256, AES-128 or ZipCrypto; 7z: AES-256 with encrypted file names). On the Mac, ZIP and 7z can also be split into parts when saved.
- **Quick Look and thumbnails.** On the Mac, select an archive in Finder and press Space to see its file tree. Quick Look and thumbnail extensions are also included for iOS and iPadOS.
- **Finder Services (Mac).** *Extract Here with Lutik* and *Compress with Lutik* in the right-click Services menu.
- **Safe saves.** The new archive is written to a temporary file and only then replaces the original, so a failed save does not damage it.

## Formats

| Format | Open | Create / save |
| --- | :---: | :---: |
| ZIP | ✓ | ✓ |
| 7z | ✓ | ✓ |
| TAR | ✓ | ✓ |
| TAR.GZ, TAR.BZ2, TAR.XZ | ✓ | ✓ |
| RAR (v4, v5, multi-part) | ✓ | |
| GZ, BZ2, XZ, ZST, TAR.ZST | ✓ | |
| ISO, CPIO, XAR, LHA, CAB | ✓ | |

ZIP-based packages such as JAR, APK, AAB, XPI, WHL and NuGet open as ZIP. RAR is read-only because the format is proprietary. Password-protected ZIP and 7z archives ask for the password when you open them; encrypted RAR archives and ZIPs with PKWARE Strong Encryption are not supported. Reading and writing is done by [libarchive](https://www.libarchive.org).

## Get Lutik

- **Mac, direct download:** Lutik 0.1.0 is out as a signed and notarized [`Lutik.dmg`](https://github.com/irustamov/lutik/releases/latest/download/Lutik.dmg) on [GitHub Releases](https://github.com/irustamov/lutik/releases).
- **Mac App Store** and **App Store for iPhone and iPad**, listed as *Lutik: Zip, 7z & RAR Viewer*: coming, not available yet.

Requires macOS 14 or later, or iOS / iPadOS 17 or later. Check [lutik.io](https://lutik.io) for availability.

## Build from source

You need a recent Xcode (26 or later) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
git clone https://github.com/irustamov/lutik.git
cd lutik
xcodegen generate
open Kernir.xcodeproj
```

`Kernir` is the code name: the repository, Xcode project, targets and Swift package keep that name, while the app is called Lutik. `Kernir.xcodeproj` is generated from `project.yml` and is not checked in. The archive engine is a Swift package (libarchive is vendored); to run its tests:

```sh
cd Packages/KernirCore && swift test
```

```
Packages/KernirCore   archive engine: vendored libarchive + Swift API
App/Shared            SwiftUI code shared by both apps
App/macOS, App/iOS    the two app targets
Extensions/           Quick Look and thumbnail extensions
```

## Contributing

Bug reports and pull requests are welcome. Please open an issue first for anything larger than a small fix, so we can agree on the approach.

Lutik has one design rule: it should feel like an app Apple shipped. That means stock SwiftUI, AppKit and UIKit controls, SF Symbols and the system accent color, with no custom styling. Pull requests that add custom UI chrome will be asked to use the system equivalent. If an archive opens incorrectly, a small sample file attached to the issue helps a lot.

## Support

Lutik is free. If it saves you time, you can [buy me a coffee](https://buymeacoffee.com/irustamov).

## License

[MIT](LICENSE) © 2026 Ilham Rustamov. Third-party code and its licenses are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
