#!/bin/bash
# Verify a release DMG: image integrity, signatures, versions, sandbox entitlements.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<USAGE
Usage: $SCRIPT_NAME <dmg> [--adhoc]

Checks: hdiutil verify, codesign --deep --strict, extension version equals app version,
app-sandbox entitlement on app and extension. Without --adhoc also checks the Developer ID
authority ($TEAM_ID), Gatekeeper (spctl) on app and DMG, and stapled tickets.
USAGE
}

DMG=""
ADHOC=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --adhoc) ADHOC=1; shift ;;
    -*) usage >&2; die "unknown option: $1" ;;
    *) [ -z "$DMG" ] || die "multiple DMG paths given"; DMG="$1"; shift ;;
  esac
done
[ -n "$DMG" ] || { usage >&2; die "missing <dmg>"; }
[ -f "$DMG" ] || die "DMG not found: $DMG"

MNT=""
cleanup() {
  if [ -n "$MNT" ]; then
    $HDIUTIL detach "$MNT" >/dev/null 2>&1 || $HDIUTIL detach -force "$MNT" >/dev/null 2>&1 || true
    rmdir "$MNT" 2>/dev/null || true
  fi
}
trap cleanup EXIT

FAILED=0
fail() { log "FAIL: $*"; FAILED=1; }
ok() { log "ok: $*"; }

plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null; }

has_sandbox() {
  local out
  out="$($CODESIGN -d --entitlements - "$1" 2>&1 || true)"
  case "$out" in *com.apple.security.app-sandbox*) return 0 ;; *) return 1 ;; esac
}

if $HDIUTIL verify "$DMG" >/dev/null 2>&1; then ok "hdiutil verify"; else fail "hdiutil verify"; exit 1; fi

MNT="$(mktemp -d)"
$HDIUTIL attach -nobrowse -readonly -mountpoint "$MNT" "$DMG" >/dev/null || die "cannot mount $DMG"

APP="$MNT/$APP_NAME.app"
[ -d "$APP" ] || die "$APP_NAME.app not found in DMG"

if $CODESIGN --verify --deep --strict "$APP" 2>/dev/null; then ok "codesign --deep --strict"; else fail "codesign --deep --strict"; fi

APP_VER="$(plist_value "$APP" CFBundleShortVersionString || true)"
APPEX_COUNT=0
for appex in "$APP"/Contents/PlugIns/*.appex; do
  [ -d "$appex" ] || continue
  APPEX_COUNT=$((APPEX_COUNT + 1))
  EXT_VER="$(plist_value "$appex" CFBundleShortVersionString || true)"
  if [ -n "$APP_VER" ] && [ "$EXT_VER" = "$APP_VER" ]; then
    ok "$(basename "$appex") version $EXT_VER matches app"
  else
    fail "$(basename "$appex") CFBundleShortVersionString '$EXT_VER' != app '$APP_VER'"
  fi
  if has_sandbox "$appex"; then ok "$(basename "$appex") app-sandbox"; else fail "$(basename "$appex") missing com.apple.security.app-sandbox"; fi
done
[ "$APPEX_COUNT" -gt 0 ] || fail "no .appex in Contents/PlugIns"
if has_sandbox "$APP"; then ok "app app-sandbox"; else fail "app missing com.apple.security.app-sandbox"; fi

if [ "$ADHOC" -eq 0 ]; then
  # -dvv: Authority= lines only appear at verbosity 2 and up; plain -dv prints none.
  SIGN_INFO="$($CODESIGN -dvv "$APP" 2>&1 || true)"
  if printf '%s\n' "$SIGN_INFO" | grep -q "Authority=Developer ID Application: .*($TEAM_ID)"; then
    ok "Developer ID authority"
  else
    fail "app not signed by Developer ID Application ($TEAM_ID)"
  fi
  if $SPCTL -a -vvv -t exec "$APP" >/dev/null 2>&1; then ok "spctl exec"; else fail "spctl -t exec rejected app"; fi
  if $SPCTL -a -t open --context context:primary-signature "$DMG" >/dev/null 2>&1; then ok "spctl open"; else fail "spctl -t open rejected DMG"; fi
  if $STAPLER validate "$APP" >/dev/null 2>&1; then ok "stapler app"; else fail "stapler validate app"; fi
  if $STAPLER validate "$DMG" >/dev/null 2>&1; then ok "stapler dmg"; else fail "stapler validate dmg"; fi
fi

[ "$FAILED" -eq 0 ] || exit 1
log "all checks passed"
