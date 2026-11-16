# Product

## Register

product

## Users
Mac and iPhone/iPad users who receive and send archives (ZIP, 7z, RAR, TAR and friends) in everyday work. On macOS the built-in Archive Utility only unpacks everything blindly; there is no free way to look inside an archive, take one file out, drop one file in, or remove one file and save the archive back. Windows has had this in Explorer forever. The user wants to glance (space in Finder), act (double-click, add, remove, extract) and leave.

## Product Purpose
Lutik (code name Kernir) is a free, open-source (MIT) archive viewer and editor built natively in SwiftUI for macOS and iOS. Core jobs:
- Quick Look: select an archive in Finder, press Space, see its contents.
- Open an archive (double-click), browse the tree, preview any file with Space.
- Add files (＋ or drag in), remove files (－), extract selected or all, save the repacked archive (⌘S).
- Read all common formats via libarchive (ZIP, 7z, TAR, GZ, BZ2, XZ, ISO, RAR read-only); write ZIP, 7z, TAR family.

Distributed via GitHub Releases (signed, notarized DMG), a simple landing page (lutik.io), Mac App Store and iOS App Store. A secondary goal is walking the whole App Store publishing path once to reuse for future apps.

Success: it feels like an app Apple forgot to ship. Lighter than anything paid.

## Brand Personality
Invisible, native, fast. The app has no visual identity of its own beyond its icon and name; it is Finder's missing feature. Copy is short, plain, system-like.

## Anti-references
- Any custom-styled UI: custom colors, custom fonts, custom buttons, branded chrome. A hand-drawn non-native mockup was rejected outright.
- Cross-platform-looking archivers (Electron/Qt feel, WinRAR/7-Zip toolbars full of big icons).
- Paywalls, "Pro" upsells, nag screens.
- Inventing new interaction patterns where Apple already has one.

## Design Principles
1. Apple already designed it: use only stock SwiftUI/AppKit/UIKit components in the macOS 26 / iOS 26 style (Liquid Glass toolbars, system Table/List, SF Symbols, system accent). Nothing new to invent.
2. Glance first: Quick Look and Space-to-preview are the main entry points, the window is secondary.
3. Minimal surface: ＋, －, Extract, Search. Everything else lives in menus, context menus and drag and drop.
4. Behave like a document: edits mark the window as edited, ⌘S saves, ⌘Z undoes, closing asks to save.

## Accessibility & Inclusion
Inherit everything the system provides: VoiceOver labels on every control, full keyboard navigation, Dynamic Type on iOS, Reduce Transparency / Increase Contrast respected automatically by stock components, light and dark appearance follow the system.
