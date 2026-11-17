# App Store metadata

Kernir is one Universal Purchase record with a Mac version and an iOS version. The only localization is English (U.S.), and it serves every storefront.

Some fields are shared by both platforms and live under App Information. Others belong to one platform's version page. Each per-platform field has its own `-mac` and `-ios` file.

| File | App Store Connect field | Where it lives in ASC | Scope | Limit | Needs a new version to change |
|------|-------------------------|-----------------------|-------|-------|-------------------------------|
| `en-US/name.txt` | Name | App Information | shared | 30 characters | yes |
| `en-US/subtitle.txt` | Subtitle | App Information | shared | 30 characters | yes |
| `en-US/privacy_url.txt` | Privacy Policy URL | App Information | shared | URL | yes |
| `en-US/keywords-mac.txt` | Keywords | macOS version page | Mac | 100 bytes | yes |
| `en-US/keywords-ios.txt` | Keywords | iOS version page | iOS | 100 bytes | yes |
| `en-US/promotional_text-mac.txt` | Promotional Text | macOS version page | Mac | 170 characters | no |
| `en-US/promotional_text-ios.txt` | Promotional Text | iOS version page | iOS | 170 characters | no |
| `en-US/description-mac.txt` | Description | macOS version page | Mac | 4000 characters | yes |
| `en-US/description-ios.txt` | Description | iOS version page | iOS | 4000 characters | yes |
| `en-US/release_notes.txt` | What's New | each version page (paste into both) | both | 4000 characters | yes |
| `en-US/support_url.txt` | Support URL | each version page (paste into both) | both | URL | yes |
| `en-US/marketing_url.txt` | Marketing URL | each version page (paste into both) | both | URL | yes |
| `primary_category.txt` | Primary Category | App Information | shared | one category | yes |

## Rules

- Name and subtitle are shared, so they must be true on both platforms. Never put a feature that exists on only one platform there. Quick Look and Finder are Mac-only.
- A platform-only feature goes only in that platform's keywords, promotional text and description.
- Password claims must match `ArchiveFormat.supportedEncryptions` in `API.swift`. ZIP and 7z passwords work, for opening and saving: ZIP with AES-256, AES-128 or ZipCrypto, 7z with AES-256 and encrypted file names. Never claim support for encrypted RAR or PKWARE Strong Encryption ZIPs.
- Every claim in `description-ios.txt` must be backed by iOS code before the iOS version is submitted.

## Upload

The per-platform files are pasted into App Store Connect by hand, or sent through the App Store Connect API to each platform's version localization. fastlane `deliver`'s plain layout (`<locale>/keywords.txt` and so on) has one file per field, so it does not cover this split.

"Needs a new version" is the safe reading. Promotional text is the only field that changes on a live version without a new submission.
