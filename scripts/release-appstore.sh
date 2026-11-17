#!/bin/bash
# Archive and export the Mac or iOS app for the App Store; optionally upload to App Store Connect.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<USAGE
Usage: $SCRIPT_NAME <mac|ios> [--version X.Y.Z] [--upload | --offline]

  mac|ios           Platform to build (Universal Purchase: both share one bundle ID)
  --version X.Y.Z   Marketing version (default: the git tag at HEAD without 'v';
                    with no tag the script refuses to run, so tag HEAD vX.Y.Z or pass --version)
  --upload          Upload to App Store Connect (TestFlight) instead of exporting locally.
                    Requires KERNIR_ALLOW_UPLOAD=1 in the environment.
  --offline         Archive with ad-hoc signing and check the bundle for App Store upload
                    problems. Contacts no Apple service. Cannot be combined with --upload.
  --help            Show this help

Signing is automatic via the App Store Connect API key (ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH).
Without --upload: dist/appstore-<platform>/Lutik.pkg (mac) or Lutik.ipa (ios); the path is the
last stdout line. With --upload the export goes to a temp dir, dist/ is not touched and the
build is sent to Apple. BUILD_NUMBER in the environment overrides the build number (commit count).
USAGE
}

PLATFORM=""
VERSION=""
UPLOAD=0
OFFLINE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --version)
      [ "$#" -ge 2 ] && [ -n "$2" ] && [ "${2#-}" = "$2" ] || die "--version needs a value (X.Y.Z)"
      VERSION="$2"; shift 2 ;;
    --upload) UPLOAD=1; shift ;;
    --offline) OFFLINE=1; shift ;;
    mac|ios)
      [ -z "$PLATFORM" ] || die "platform given twice"
      PLATFORM="$1"; shift ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done
[ -n "$PLATFORM" ] || { usage >&2; die "platform (mac|ios) is required"; }

case "$PLATFORM" in
  mac) SCHEME="$SCHEME_MAC"; DESTINATION='generic/platform=macOS'; PLIST="$SCRIPT_DIR/export/AppStoreMac.plist"; ARTIFACT="$APP_NAME.pkg" ;;
  ios) SCHEME="$SCHEME_IOS"; DESTINATION='generic/platform=iOS'; PLIST="$SCRIPT_DIR/export/AppStoreIOS.plist"; ARTIFACT="$APP_NAME.ipa" ;;
esac

[ "$OFFLINE" -eq 0 ] || [ "$UPLOAD" -eq 0 ] || die "--offline and --upload cannot be combined (offline contacts no Apple service)"

# Safety latch and credentials come first: no xcodebuild call, no outputs touched before them.
if [ "$UPLOAD" -eq 1 ] && [ "${KERNIR_ALLOW_UPLOAD:-}" != 1 ]; then
  die "--upload sends the build to App Store Connect; set KERNIR_ALLOW_UPLOAD=1 to allow it"
fi
# Placeholder guard: App Review opens the metadata URLs, so a placeholder must never ship.
METADATA_DIR="${KERNIR_METADATA_DIR:-$REPO_ROOT/docs/release/appstore/metadata}"
if [ "$UPLOAD" -eq 1 ] && [ ! -d "$METADATA_DIR" ]; then
  die "--upload refused: metadata directory not found: $METADATA_DIR"
fi
if [ "$UPLOAD" -eq 1 ]; then
  # grep exit: 0 = placeholder found, 1 = clean, anything else = scan failed (never fail open).
  rc=0
  grep -rlF 'kernir.example' "$METADATA_DIR" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) die "--upload refused: placeholder 'kernir.example' still in $METADATA_DIR (replace it with the real URL)" ;;
    1) ;;
    *) die "--upload refused: cannot scan metadata in $METADATA_DIR (grep exit $rc)" ;;
  esac
fi
AUTH=""
if [ "$OFFLINE" -eq 0 ]; then
  AUTH="$(xcb_auth_args)" || exit 1
  [ -f "$PLIST" ] || die "export options plist not found: $PLIST"
fi

cd "$REPO_ROOT"
[ -n "$VERSION" ] || VERSION="$(version_from_git)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || die "App Store version must be X.Y.Z (got $VERSION); tag HEAD vX.Y.Z or pass --version"
BUILD_NUMBER="$(build_number)"

BUILD="$REPO_ROOT/build"
ARCHIVE="$BUILD/$APP_NAME-$PLATFORM.xcarchive"
OUT_DIR="$REPO_ROOT/dist/appstore-$PLATFORM"
TMP_DIR=""
cleanup() {
  [ -z "$TMP_DIR" ] || rm -rf "$TMP_DIR"
  # Built copies must never stay registered with Launch Services, also when archive failed.
  unregister_apps_under "$BUILD"
  # Offline builds are throwaway: delete them once unregistered.
  if [ "$OFFLINE" -eq 1 ]; then rm -rf "$ARCHIVE" "$BUILD/DerivedData"; fi
}
trap cleanup EXIT

require_cmd xcodegen
log "generating project"
xcodegen generate >&2
rm -rf "$ARCHIVE"
mkdir -p "$BUILD"

EXPORT_PLIST="$PLIST"
EXPORT_DIR="$OUT_DIR"
if [ "$UPLOAD" -eq 1 ]; then
  # Upload mode never touches dist/ or the committed plist.
  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kernir-export.XXXXXX")"
  cp "$PLIST" "$TMP_DIR/ExportOptions.plist"
  /usr/libexec/PlistBuddy -c "Set :destination upload" "$TMP_DIR/ExportOptions.plist"
  EXPORT_PLIST="$TMP_DIR/ExportOptions.plist"
  EXPORT_DIR="$TMP_DIR/export"
elif [ "$OFFLINE" -eq 0 ]; then
  rm -rf "$OUT_DIR"
fi

if [ "$OFFLINE" -eq 1 ]; then
  log "archiving $SCHEME $VERSION ($BUILD_NUMBER) offline (ad-hoc signing)"
  $XCODEBUILD archive -quiet \
    -project "$PROJECT_NAME.xcodeproj" \
    -scheme "$SCHEME" -configuration Release \
    -destination "$DESTINATION" \
    -archivePath "$ARCHIVE" \
    -derivedDataPath "$BUILD/DerivedData" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= >&2
  CHECKER="${KERNIR_BUNDLE_CHECKER:-$SCRIPT_DIR/check-appstore-bundle.sh}"
  rc=0
  "$CHECKER" --platform "$PLATFORM" "$ARCHIVE/Products/Applications/$APP_NAME.app" || rc=$?
  exit "$rc"
fi

log "archiving $SCHEME $VERSION ($BUILD_NUMBER)"
# shellcheck disable=SC2086
$XCODEBUILD archive -quiet \
  -project "$PROJECT_NAME.xcodeproj" \
  -scheme "$SCHEME" -configuration Release \
  -destination "$DESTINATION" \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$BUILD/DerivedData" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  DEVELOPMENT_TEAM="$TEAM_ID" $AUTH >&2

if [ "$UPLOAD" -eq 1 ]; then
  log "exporting and uploading $PLATFORM build to App Store Connect"
else
  log "exporting $PLATFORM build"
fi
# shellcheck disable=SC2086
# Xcode's IPA/pkg copy step runs rsync from PATH; Homebrew rsync 3.5.2 breaks it ("exportArchive Copy failed"), so system tools go first.
PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH" $XCODEBUILD -exportArchive -quiet \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_PLIST" $AUTH >&2

if [ "$UPLOAD" -eq 1 ]; then
  log "upload submitted; check TestFlight in App Store Connect"
else
  [ -f "$OUT_DIR/$ARTIFACT" ] || die "export did not produce $OUT_DIR/$ARTIFACT"
  printf '%s\n' "$OUT_DIR/$ARTIFACT"
fi
