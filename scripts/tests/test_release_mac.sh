#!/bin/bash
# Tests for scripts/release-mac.sh and scripts/verify-dmg.sh.
# Sourced by run.sh. Tests run in definition order; the first one performs the
# suite's only real archive and later tests reuse dist/ and build/.

DMG="$REPO_ROOT/dist/Lutik.dmg"
BUILT_APP="$REPO_ROOT/build/Lutik.xcarchive/Products/Applications/Lutik.app"

# Attach DMG read-only, echo mountpoint via global MNT; caller must call detach_dmg.
attach_dmg() {
  MNT="$(mktemp -d)"
  hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$DMG" >/dev/null
}
detach_dmg() {
  hdiutil detach "$MNT" >/dev/null 2>&1 || hdiutil detach -force "$MNT" >/dev/null 2>&1 || true
  rmdir "$MNT" 2>/dev/null || true
}

test_scripts_help() {
  local s
  for s in release-mac.sh verify-dmg.sh; do
    "$REPO_ROOT/scripts/$s" --help | grep -qi usage
  done
}

test_adhoc_dmg_builds() {
  # The suite's only real archive: version and build number are asserted on it too.
  local build_no short bundle
  "$REPO_ROOT/scripts/release-mac.sh" --version 1.2.3 --sign adhoc >/dev/null
  [ -f "$DMG" ]
  [ -f "$DMG.sha256" ]
  ( cd "$REPO_ROOT/dist" && shasum -a 256 -c Lutik.dmg.sha256 )
  build_no="$(git -C "$REPO_ROOT" rev-list --count HEAD)"
  attach_dmg
  short="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MNT/Lutik.app/Contents/Info.plist")"
  bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$MNT/Lutik.app/Contents/Info.plist")"
  detach_dmg
  [ "$short" = "1.2.3" ]
  [ "$bundle" = "$build_no" ]
}

test_dmg_layout() {
  attach_dmg
  trap detach_dmg EXIT
  [ -d "$MNT/Lutik.app" ]
  [ -L "$MNT/Applications" ]
  [ "$(readlink "$MNT/Applications")" = "/Applications" ]
  [ "$(diskutil info "$MNT" | awk -F': *' '/Volume Name/ {print $2}')" = "Lutik 1.2.3" ]
}

test_app_flag_repackages() {
  # --app packages an already built app without archiving.
  local tmp rc=0
  tmp="$(mktemp -d)"
  cp -R "$BUILT_APP" "$tmp/Lutik.app"
  "$REPO_ROOT/scripts/release-mac.sh" --version 0.0.1 --sign adhoc --app "$tmp/Lutik.app" \
    | tail -n 1 | grep -q 'dist/Lutik.dmg$' || rc=1
  "$LSREGISTER" -u "$tmp/Lutik.app" >/dev/null 2>&1 || true
  rm -rf "$tmp"
  [ "$rc" -eq 0 ]
  ( cd "$REPO_ROOT/dist" && shasum -a 256 -c Lutik.dmg.sha256 )
}

test_verify_dmg_adhoc() {
  "$REPO_ROOT/scripts/verify-dmg.sh" "$DMG" --adhoc
}

test_verify_dmg_rejects_corrupt() {
  local tmp
  tmp="$(mktemp -d)"
  head -c 4096 /dev/urandom > "$tmp/bad.dmg"
  if "$REPO_ROOT/scripts/verify-dmg.sh" "$tmp/bad.dmg" --adhoc >/dev/null 2>&1; then
    rm -rf "$tmp"; return 1
  fi
  rm -rf "$tmp"
}

# ---- notarization / credentials / versions (fakes only, never Apple) ----
FAKES="$REPO_ROOT/scripts/tests/fakes"

# Run release-mac.sh against the fakes on a copy of the prebuilt app.
# Args: status [extra release-mac.sh args...]. Sets FAKE_LOG_FILE, ERR_FILE, FAKE_TMP, RC.
run_fake_release() {
  local status="$1" tmp key
  shift
  tmp="$(mktemp -d)"
  key="$tmp/AuthKey_FAKEKEY.p8"
  : > "$key"
  cp -R "$BUILT_APP" "$tmp/Lutik.app"
  FAKE_LOG_FILE="$tmp/fake.log"; ERR_FILE="$tmp/err.txt"
  : > "$FAKE_LOG_FILE"
  RC=0
  FAKE_NOTARY_STATUS="$status" FAKE_LOG="$FAKE_LOG_FILE" \
    NOTARYTOOL="$FAKES/notarytool" STAPLER="$FAKES/stapler" \
    ASC_KEY_ID=FAKEKEY ASC_ISSUER_ID=fake-issuer ASC_KEY_PATH="$key" \
    "$REPO_ROOT/scripts/release-mac.sh" --version 0.0.1 --sign adhoc --notarize \
    --app "$tmp/Lutik.app" "$@" >/dev/null 2>"$ERR_FILE" || RC=$?
  "$LSREGISTER" -u "$tmp/Lutik.app" >/dev/null 2>&1 || true
  rm -rf "$tmp/Lutik.app"
  FAKE_TMP="$tmp"
}

test_missing_credentials_fails_fast() {
  local start rc=0 err
  err="$(mktemp)"
  start=$SECONDS
  env -u ASC_KEY_ID -u ASC_ISSUER_ID -u ASC_KEY_PATH \
    "$REPO_ROOT/scripts/release-mac.sh" --version 0.0.1 --sign developer-id >/dev/null 2>"$err" || rc=$?
  [ "$rc" -ne 0 ]
  [ $((SECONDS - start)) -lt 5 ]
  grep -q ASC_KEY_ID "$err"
  rm -f "$err"
}

test_missing_key_file_fails_fast() {
  local rc=0 err
  err="$(mktemp)"
  ASC_KEY_ID=FAKEKEY ASC_ISSUER_ID=fake-issuer ASC_KEY_PATH=/nonexistent/AuthKey.p8 \
    "$REPO_ROOT/scripts/release-mac.sh" --version 0.0.1 --sign developer-id >/dev/null 2>"$err" || rc=$?
  [ "$rc" -ne 0 ]
  grep -qi 'key file' "$err"
  rm -f "$err"
}

test_bad_app_keeps_previous_dmg() {
  # Input validation must happen before outputs are cleaned.
  local before rc=0
  [ -f "$DMG" ]
  before="$(shasum -a 256 "$DMG")"
  "$REPO_ROOT/scripts/release-mac.sh" --version 0.0.1 --app /nonexistent/Lutik.app >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ]
  [ "$(shasum -a 256 "$DMG")" = "$before" ]
}

test_notarize_invalid_fails() {
  run_fake_release Invalid
  [ "$RC" -ne 0 ]
  grep -q 'FAKE NOTARY LOG' "$ERR_FILE"
  [ ! -e "$DMG" ]
  [ ! -e "$DMG.sha256" ]
  rm -rf "$FAKE_TMP"
}

test_notarize_accepted_staples_twice() {
  run_fake_release Accepted
  [ "$RC" -eq 0 ]
  [ "$(grep -c '^notarytool submit ' "$FAKE_LOG_FILE")" -eq 2 ]
  [ "$(grep -c '^stapler staple ' "$FAKE_LOG_FILE")" -eq 2 ]
  grep '^notarytool submit ' "$FAKE_LOG_FILE" | sed -n 1p | grep -q '\.zip '
  grep '^notarytool submit ' "$FAKE_LOG_FILE" | sed -n 2p | grep -q 'Lutik\.dmg '
  grep -q -- '--wait' "$FAKE_LOG_FILE"
  grep -q -- '--timeout 60m' "$FAKE_LOG_FILE"
  [ -f "$DMG" ]
  rm -rf "$FAKE_TMP"
}

test_rerun_overwrites() {
  run_fake_release Accepted
  [ "$RC" -eq 0 ]
  rm -rf "$FAKE_TMP"
  run_fake_release Accepted
  [ "$RC" -eq 0 ]
  rm -rf "$FAKE_TMP"
}

test_notarize_invalid_nonzero_exit_prints_log() {
  # submit --wait may exit non-zero for Invalid; the log must still be fetched.
  FAKE_NOTARY_EXIT_NONZERO=1 run_fake_release Invalid
  [ "$RC" -ne 0 ]
  grep -q 'FAKE NOTARY LOG' "$ERR_FILE"
  grep -q '^notarytool log fake-submission-id' "$FAKE_LOG_FILE"
  rm -rf "$FAKE_TMP"
}

test_notarize_dmg_invalid_removes_partial_dmg() {
  # The zip is accepted; only the DMG is Invalid. The built DMG must be cleaned up.
  FAKE_NOTARY_FAIL_ON=dmg run_fake_release Accepted
  [ "$RC" -ne 0 ]
  [ "$(grep -c '^notarytool submit ' "$FAKE_LOG_FILE")" -eq 2 ]
  grep -q 'FAKE NOTARY LOG' "$ERR_FILE"
  [ ! -e "$DMG" ]
  [ ! -e "$DMG.sha256" ]
  rm -rf "$FAKE_TMP"
}

test_developer_id_no_identity_fails_fast() {
  local tmp rc=0 start
  tmp="$(mktemp -d)"; : > "$tmp/key.p8"
  start=$SECONDS
  FAKE_SECURITY_IDENTITY=none SECURITY="$FAKES/security" \
    ASC_KEY_ID=FAKEKEY ASC_ISSUER_ID=fake-issuer ASC_KEY_PATH="$tmp/key.p8" \
    "$REPO_ROOT/scripts/release-mac.sh" --version 0.0.1 --sign developer-id >/dev/null 2>"$tmp/err" || rc=$?
  [ "$rc" -ne 0 ]
  [ $((SECONDS - start)) -lt 5 ]
  grep -q 'Developer ID Application' "$tmp/err"
  rm -rf "$tmp"
}

test_export_plist_manual_signing() {
  local plist="$REPO_ROOT/scripts/export/DeveloperID.plist" v
  plutil -lint "$plist" >/dev/null
  for v in "method:developer-id" "teamID:Q42GSJXJKF" "signingStyle:manual" \
           "signingCertificate:Developer ID Application" "destination:export"; do
    [ "$(/usr/libexec/PlistBuddy -c "Print :${v%%:*}" "$plist")" = "${v#*:}" ]
  done
}

test_developer_id_uses_manual_signing() {
  # Fake xcodebuild/codesign/notarytool: nothing real is signed or sent.
  local tmp log
  tmp="$(mktemp -d)"; : > "$tmp/key.p8"; log="$tmp/fake.log"; : > "$log"
  FAKE_LOG="$log" XCODEBUILD="$FAKES/xcodebuild" CODESIGN="$FAKES/codesign" \
    SECURITY="$FAKES/security" NOTARYTOOL="$FAKES/notarytool" STAPLER="$FAKES/stapler" \
    ASC_KEY_ID=FAKEKEY ASC_ISSUER_ID=fake-issuer ASC_KEY_PATH="$tmp/key.p8" \
    "$REPO_ROOT/scripts/release-mac.sh" --version 0.0.1 --sign developer-id >/dev/null 2>"$tmp/err"
  grep '^xcodebuild archive' "$log" | grep -q 'CODE_SIGN_STYLE=Manual'
  grep '^xcodebuild archive' "$log" | grep -q 'CODE_SIGN_IDENTITY=Developer ID Application'
  grep '^xcodebuild archive' "$log" | grep -q 'DEVELOPMENT_TEAM=Q42GSJXJKF'
  grep -q '^xcodebuild -exportArchive' "$log"
  if grep '^xcodebuild' "$log" | grep -q -- '-allowProvisioningUpdates'; then
    echo "unexpected -allowProvisioningUpdates in xcodebuild argv" >&2; return 1
  fi
  if grep '^xcodebuild' "$log" | grep -q -- '-authenticationKey'; then
    echo "unexpected -authenticationKey in xcodebuild argv" >&2; return 1
  fi
  # DMG is signed with the resolved SHA-1 and a timestamp.
  grep '^codesign' "$log" | grep -q -- '--sign 0123456789ABCDEF0123456789ABCDEF01234567 --timestamp'
  [ "$(grep -c '^stapler staple ' "$log")" -eq 2 ]
  rm -rf "$tmp"
}

# Count registered Launch Services paths under build/ or dist/ in a dump file.
count_registered() {
  grep -c -E "path:[[:space:]]+($REPO_ROOT/(build|dist))(/|[[:space:]])" "$1" || true
}

test_registered_pattern_matches() {
  # Guard against a vacuous pattern: it must match a known registered path line.
  local f; f="$(mktemp)"
  printf 'path:                       %s/build/Lutik.xcarchive/Products/Applications/Lutik.app (0xe8cc)\n' "$REPO_ROOT" > "$f"
  [ "$(count_registered "$f")" -eq 1 ]
  printf 'path:                       /elsewhere/Lutik.app (0x1)\n' > "$f"
  [ "$(count_registered "$f")" -eq 0 ]
  rm -f "$f"
}

test_unregister_apps_under_covers_both_app_names() {
  # scripts/lib/common.sh unregisters $APP_NAME.app (Lutik) and $PROJECT_NAME.app (Kernir, the pre-rename
  # file name, still in old build folders) under the given dirs; other names and missing dirs are ignored.
  local tmp log
  tmp="$(mktemp -d)"; log="$tmp/log"
  mkdir -p "$tmp/build/a/Lutik.app" "$tmp/build/b/c/Kernir.app" "$tmp/build/Other.app" "$tmp/dist/Lutik.app"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$log" > "$tmp/lsregister"
  chmod +x "$tmp/lsregister"
  (
    # shellcheck source=/dev/null
    . "$REPO_ROOT/scripts/lib/common.sh"
    LSREGISTER="$tmp/lsregister"
    unregister_apps_under "$tmp/build" "$tmp/dist" "$tmp/missing"
  )
  grep -qxF -- "-u $tmp/build/a/Lutik.app" "$log"
  grep -qxF -- "-u $tmp/build/b/c/Kernir.app" "$log"
  grep -qxF -- "-u $tmp/dist/Lutik.app" "$log"
  [ "$(wc -l < "$log" | tr -d ' ')" -eq 3 ]
  rm -rf "$tmp"
}

test_no_registered_leftovers() {
  # Assert first (scripts must have unregistered everything), then clean up.
  local dump app n
  dump="$(mktemp)"
  "$LSREGISTER" -dump > "$dump"
  [ -s "$dump" ]
  n="$(count_registered "$dump")"
  rm -f "$dump"
  [ "$n" -eq 0 ]
  while IFS= read -r app; do
    "$LSREGISTER" -u "$app" >/dev/null 2>&1 || true
  done < <(find "$REPO_ROOT/build" -name 'Lutik.app' -type d 2>/dev/null)
  rm -rf "$REPO_ROOT/build"
  [ -z "$(find "$REPO_ROOT/build" -name 'Lutik.app' 2>/dev/null)" ]
}
