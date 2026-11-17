#!/bin/bash
# Build the macOS app and package it as dist/Lutik.dmg (+ .sha256).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<USAGE
Usage: $SCRIPT_NAME [--version X.Y.Z] [--sign adhoc|developer-id] [--no-notarize] [--notarize] [--app <Lutik.app>]

  --version X.Y.Z   Marketing version (default: git tag without 'v', else 0.0.0-dev)
  --sign MODE       adhoc (default) or developer-id
  --no-notarize     Skip notarization (developer-id only)
  --notarize        Test only: force notarization on an adhoc build (use with fake tools)
  --app PATH        Package an already built Lutik.app; skips xcodegen and archive
  --help            Show this help

Output: dist/Lutik.dmg and dist/Lutik.dmg.sha256. The DMG path is the last stdout line.
USAGE
}

VERSION=""
SIGN=adhoc
NOTARIZE=""
APP_PATH=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --version) [ "$#" -ge 2 ] || die "--version needs a value"; VERSION="$2"; shift 2 ;;
    --sign) [ "$#" -ge 2 ] || die "--sign needs a value"; SIGN="$2"; shift 2 ;;
    --no-notarize) NOTARIZE=0; shift ;;
    --notarize) NOTARIZE=1; shift ;;
    --app) [ "$#" -ge 2 ] || die "--app needs a path"; APP_PATH="$2"; shift 2 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

case "$SIGN" in
  adhoc) [ -n "$NOTARIZE" ] || NOTARIZE=0 ;;
  developer-id) [ -n "$NOTARIZE" ] || NOTARIZE=1 ;;
  *) die "invalid --sign value: $SIGN (adhoc|developer-id)" ;;
esac

# Validate inputs and credentials before touching outputs or starting a long archive.
if [ "$SIGN" = developer-id ] || [ "$NOTARIZE" -eq 1 ]; then
  require_asc_credentials
fi
SIGN_IDENTITY=-
if [ "$SIGN" = developer-id ]; then
  SIGN_IDENTITY="$(resolve_developer_id_identity)"
fi
if [ -n "$APP_PATH" ]; then
  [ -d "$APP_PATH" ] || die "--app path is not a directory: $APP_PATH"
fi

cd "$REPO_ROOT"
[ -n "$VERSION" ] || VERSION="$(version_from_git)"

DIST="$REPO_ROOT/dist"
BUILD="$REPO_ROOT/build"
DMG="$DIST/$APP_NAME.dmg"
STAGE=""
ZIP_DIR=""
SUCCESS=0
cleanup() {
  # A failed run must not leave a partial or unnotarized DMG behind.
  if [ "$SUCCESS" -ne 1 ]; then rm -f "$DMG" "$DMG.sha256"; fi
  [ -z "$ZIP_DIR" ] || rm -rf "$ZIP_DIR"
  if [ -n "$STAGE" ]; then
    unregister_app "$STAGE/$APP_NAME.app"
    rm -rf "$STAGE"
  fi
  # Staged/archived/intermediate copies must never stay registered with Launch Services,
  # also when archive or hdiutil failed.
  unregister_apps_under "$BUILD"
}
trap cleanup EXIT

mkdir -p "$DIST"
rm -f "$DMG" "$DMG.sha256"

if [ -n "$APP_PATH" ]; then
  SRC_APP="$APP_PATH"
else
  require_cmd xcodegen
  rm -rf "$BUILD"
  log "generating project"
  xcodegen generate >&2
  BUILD_NUMBER="$(build_number)"
  log "archiving $SCHEME_MAC $VERSION ($BUILD_NUMBER)"
  if [ "$SIGN" = developer-id ]; then
    # Manual signing with the Developer ID identity only (CI has no Apple Development cert).
    $XCODEBUILD archive -quiet \
      -project "$PROJECT_NAME.xcodeproj" \
      -scheme "$SCHEME_MAC" -configuration Release \
      -destination 'generic/platform=macOS' \
      -archivePath "$BUILD/$APP_NAME.xcarchive" \
      -derivedDataPath "$BUILD/DerivedData" \
      MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
      CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" \
      DEVELOPMENT_TEAM="$TEAM_ID" >&2
    log "exporting Developer ID build"
    # Xcode's export copy step runs rsync from PATH; Homebrew rsync 3.5.2 breaks it ("exportArchive Copy failed"), so system tools go first.
    PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH" $XCODEBUILD -exportArchive -quiet \
      -archivePath "$BUILD/$APP_NAME.xcarchive" \
      -exportPath "$BUILD/export" \
      -exportOptionsPlist "$SCRIPT_DIR/export/DeveloperID.plist" >&2
    SRC_APP="$BUILD/export/$APP_NAME.app"
  else
    # Ad hoc ('-') signing still applies entitlements, including the extension sandbox.
    $XCODEBUILD archive -quiet \
      -project "$PROJECT_NAME.xcodeproj" \
      -scheme "$SCHEME_MAC" -configuration Release \
      -destination 'generic/platform=macOS' \
      -archivePath "$BUILD/$APP_NAME.xcarchive" \
      -derivedDataPath "$BUILD/DerivedData" \
      MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
      CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= >&2
    SRC_APP="$BUILD/$APP_NAME.xcarchive/Products/Applications/$APP_NAME.app"
  fi
  [ -d "$SRC_APP" ] || die "build did not produce $SRC_APP"
fi

STAGE="$(mktemp -d)"
ditto "$SRC_APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

if [ "$NOTARIZE" -eq 1 ]; then
  ZIP_DIR="$(mktemp -d)"
  ditto -c -k --keepParent "$STAGE/$APP_NAME.app" "$ZIP_DIR/$APP_NAME.zip"
  notarize_submit "$ZIP_DIR/$APP_NAME.zip"
  $STAPLER staple "$STAGE/$APP_NAME.app" >&2 || die "stapler failed for $APP_NAME.app"
fi

log "creating DMG"
$HDIUTIL create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -format UDZO -ov "$DMG" >&2

if [ "$SIGN" = developer-id ]; then
  log "signing DMG"
  $CODESIGN --force --sign "$SIGN_IDENTITY" --timestamp "$DMG" >&2
else
  $CODESIGN --force --sign - "$DMG" >&2
fi
if [ "$NOTARIZE" -eq 1 ]; then
  notarize "$DMG"
fi

( cd "$DIST" && shasum -a 256 "$APP_NAME.dmg" > "$APP_NAME.dmg.sha256" )
SUCCESS=1
printf '%s\n' "$DMG"
