#!/bin/bash
# shellcheck disable=SC2034
# Shared config and helpers for release scripts. Source this file; do not execute.

# ---- App config: the only place a future app changes ----
# APP_NAME: the product's file name (Lutik.app, Lutik.dmg, Lutik.pkg, Lutik.ipa; PRODUCT_NAME in project.yml).
# PROJECT_NAME: the code name the Xcode project and schemes keep (Kernir.xcodeproj).
APP_NAME=Lutik
PROJECT_NAME=Kernir
SCHEME_MAC=KernirMac
SCHEME_IOS=KernirIOS
TEAM_ID=Q42GSJXJKF
BUNDLE_ID=com.kernir.app

# ---- Tools (overridable for tests) ----
XCODEBUILD="${XCODEBUILD:-xcodebuild}"
NOTARYTOOL="${NOTARYTOOL:-xcrun notarytool}"
STAPLER="${STAPLER:-xcrun stapler}"
HDIUTIL="${HDIUTIL:-hdiutil}"
CODESIGN="${CODESIGN:-codesign}"
SPCTL="${SPCTL:-spctl}"
SECURITY="${SECURITY:-security}"
LSREGISTER="${LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"

SCRIPT_NAME="$(basename "$0")"

log() { printf '[%s] %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "error: $*"; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# Version from an exact git tag (v0.2.0 -> 0.2.0), else 0.0.0-dev.
version_from_git() {
  local tag
  if tag="$(git describe --tags --exact-match 2>/dev/null)"; then
    printf '%s\n' "${tag#v}"
  else
    printf '0.0.0-dev\n'
  fi
}

# Monotonic build number: commit count. BUILD_NUMBER in the environment overrides it
# (e.g. when App Store Connect rejects a duplicate build number on re-upload).
build_number() {
  if [ -n "${BUILD_NUMBER:-}" ]; then
    [[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || die "BUILD_NUMBER must be a positive integer (got $BUILD_NUMBER)"
    printf '%s\n' "$BUILD_NUMBER"
  else
    git rev-list --count HEAD
  fi
}

# Unregister an app bundle from Launch Services (no-op if absent).
unregister_app() {
  [ -e "$1" ] && "$LSREGISTER" -u "$1" >/dev/null 2>&1 || true
}

# Unregister every $APP_NAME.app found under the given directories (no-op for missing ones), and
# every $PROJECT_NAME.app: the product's file name before the Lutik rename, still in old build folders.
unregister_apps_under() {
  local d built
  for d in "$@"; do
    [ -d "$d" ] || continue
    while IFS= read -r built; do unregister_app "$built"; done < <(find "$d" -type d \( -name "$APP_NAME.app" -o -name "$PROJECT_NAME.app" \) 2>/dev/null)
  done
}

# ---- App Store Connect API key credentials (env only; values are never logged) ----
# Validates ASC_KEY_ID, ASC_ISSUER_ID and the key file; exports ASC_KEY_PATH default.
require_asc_credentials() {
  [ -n "${ASC_KEY_ID:-}" ] || die "ASC_KEY_ID is not set"
  [ -n "${ASC_ISSUER_ID:-}" ] || die "ASC_ISSUER_ID is not set"
  ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
  [ -f "$ASC_KEY_PATH" ] || die "App Store Connect key file not found (ASC_KEY_PATH, default ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8)"
  case "$ASC_KEY_PATH$ASC_KEY_ID$ASC_ISSUER_ID" in
    *[[:space:]]*) die "ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID must not contain whitespace" ;;
  esac
}

# Arguments for notarytool (word-split by callers; values contain no whitespace).
asc_auth_args() {
  require_asc_credentials
  printf '%s\n' "--key $ASC_KEY_PATH --key-id $ASC_KEY_ID --issuer $ASC_ISSUER_ID"
}

# Arguments for xcodebuild archive/export with API-key provisioning.
xcb_auth_args() {
  require_asc_credentials
  printf '%s\n' "-allowProvisioningUpdates -authenticationKeyPath $ASC_KEY_PATH -authenticationKeyID $ASC_KEY_ID -authenticationKeyIssuerID $ASC_ISSUER_ID"
}

# Extract a top-level string key from JSON on stdin.
json_field() {
  local input
  input="$(cat)"
  printf '%s' "$input" | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null \
    || printf '%s' "$input" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1" 2>/dev/null
}

# Resolve the Developer ID Application identity (SHA-1 of the keychain entry) for TEAM_ID.
# DEVELOPER_ID_IDENTITY in the environment overrides the lookup (any codesign identity string).
resolve_developer_id_identity() {
  local found
  if [ -n "${DEVELOPER_ID_IDENTITY:-}" ]; then
    printf '%s\n' "$DEVELOPER_ID_IDENTITY"
    return 0
  fi
  found="$($SECURITY find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application:" | grep "($TEAM_ID)" | awk '{print $2}' | head -n 1 || true)"
  [ -n "$found" ] || die "no valid 'Developer ID Application' identity for team $TEAM_ID found in the keychain (security find-identity -v -p codesigning)"
  printf '%s\n' "$found"
}

# Submit a file to the notary service and wait; on anything but Accepted print the log and die.
# Whether `submit --wait` exits non-zero for Invalid is undocumented, so parse the output first.
notarize_submit() {
  local file="$1" auth out id status rc=0
  auth="$(asc_auth_args)" || exit 1
  log "notarizing $(basename "$file") (this can take minutes)"
  # shellcheck disable=SC2086
  out="$($NOTARYTOOL submit "$file" --wait --timeout "${NOTARY_TIMEOUT:-60m}" --output-format json $auth)" || rc=$?
  id="$(printf '%s' "$out" | json_field id)" || id=""
  status="$(printf '%s' "$out" | json_field status)" || status=""
  if [ -z "$id" ]; then
    printf '%s\n' "$out" >&2
    die "notarytool submit failed for $(basename "$file") (exit $rc, no submission id)"
  fi
  if [ "$status" != "Accepted" ] || [ "$rc" -ne 0 ]; then
    log "notarization status: ${status:-unknown} (submission $id, exit $rc)"
    # shellcheck disable=SC2086
    $NOTARYTOOL log "$id" $auth >&2 || true
    die "notarization of $(basename "$file") was not accepted"
  fi
  log "notarization of $(basename "$file") accepted"
}

# Submit, wait, then staple the same file (use for DMGs; for an app submitted as a zip,
# call notarize_submit on the zip and staple the app yourself).
notarize() {
  notarize_submit "$1"
  $STAPLER staple "$1" >&2 || die "stapler failed for $(basename "$1")"
}
