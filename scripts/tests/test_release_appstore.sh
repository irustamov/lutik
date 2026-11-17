#!/bin/bash
# Tests for scripts/release-appstore.sh (fake xcodebuild only; nothing reaches Apple).
# Sourced by run.sh.

AS_SCRIPT="$REPO_ROOT/scripts/release-appstore.sh"
AS_FAKES="$REPO_ROOT/scripts/tests/fakes"

# Run release-appstore.sh against the fake xcodebuild.
# Args: [VAR=value ...] -- script args. Sets AS_TMP, AS_LOG, AS_ERR, AS_RC.
run_fake_appstore() {
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  AS_TMP="$(mktemp -d)"
  : > "$AS_TMP/AuthKey_FAKEKEY.p8"
  mkdir -p "$AS_TMP/bin" "$AS_TMP/tmp"
  ln -s "$AS_FAKES/xcodegen" "$AS_TMP/bin/xcodegen"
  # A broken rsync first in PATH, like Homebrew's 3.5.2 ahead of /usr/bin/rsync.
  printf '#!/bin/sh\necho "fake broken rsync" >&2\nexit 1\n' > "$AS_TMP/bin/rsync"
  chmod +x "$AS_TMP/bin/rsync"
  AS_LOG="$AS_TMP/fake.log"; AS_ERR="$AS_TMP/err.txt"; AS_GEN_LOG="$AS_TMP/xcodegen.log"
  : > "$AS_LOG"; : > "$AS_GEN_LOG"
  AS_CHECKER_LOG="$AS_TMP/checker.log"; : > "$AS_CHECKER_LOG"
  # Fake bundle checker: logs its args, exits $FAKE_CHECKER_RC (default 0).
  cat > "$AS_TMP/fake-checker" <<'CHK'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_CHECKER_LOG"
exit "${FAKE_CHECKER_RC:-0}"
CHK
  chmod +x "$AS_TMP/fake-checker"
  AS_RC=0
  # Default ASC_* are set by the outer env, so an inner "-u ASC_*" in envs really unsets them.
  env ASC_KEY_ID=FAKEKEY ASC_ISSUER_ID=fake-issuer ASC_KEY_PATH="$AS_TMP/AuthKey_FAKEKEY.p8" \
    env ${envs[@]+"${envs[@]}"} FAKE_LOG="$AS_LOG" FAKE_XCODEGEN_LOG="$AS_GEN_LOG" \
    KERNIR_BUNDLE_CHECKER="$AS_TMP/fake-checker" FAKE_CHECKER_LOG="$AS_CHECKER_LOG" \
    PATH="$AS_TMP/bin:$PATH" TMPDIR="$AS_TMP/tmp" XCODEBUILD="$AS_FAKES/xcodebuild" \
    "$AS_SCRIPT" "$@" >"$AS_TMP/out.txt" 2>"$AS_ERR" || AS_RC=$?
}

assert_no_temp_leftovers() {
  if [ -n "$(find "$AS_TMP/tmp" -mindepth 1 2>/dev/null)" ]; then
    echo "temp files left behind in TMPDIR:" >&2; find "$AS_TMP/tmp" -mindepth 1 >&2; return 1
  fi
}

test_appstore_help() {
  local out
  out="$("$AS_SCRIPT" --help)"
  grep -qi usage <<<"$out"
}

test_export_uses_system_rsync() {
  # Homebrew rsync ahead of /usr/bin broke Xcode's IPA copy ("exportArchive Copy failed").
  local plat
  for plat in ios mac; do
    run_fake_appstore -- "$plat" --version 1.2.3
    [ "$AS_RC" -eq 0 ] || { echo "rc=$AS_RC" >&2; cat "$AS_ERR" >&2; return 1; }
    grep -qx 'export-rsync: /usr/bin/rsync' "$AS_LOG" || { echo "export saw: $(grep '^export-rsync' "$AS_LOG")" >&2; return 1; }
    rm -rf "$AS_TMP"
  done
}

test_upload_requires_latch() {
  run_fake_appstore -u KERNIR_ALLOW_UPLOAD -- mac --upload
  [ "$AS_RC" -ne 0 ]
  grep -q KERNIR_ALLOW_UPLOAD "$AS_ERR"
  if [ -s "$AS_LOG" ]; then echo "xcodebuild was called before the latch check" >&2; return 1; fi
  if [ -s "$AS_GEN_LOG" ]; then echo "xcodegen was called before the latch check" >&2; return 1; fi
  rm -rf "$AS_TMP"
}

test_upload_latch_must_be_exactly_one() {
  run_fake_appstore KERNIR_ALLOW_UPLOAD=yes -- ios --upload
  [ "$AS_RC" -ne 0 ]
  if [ -s "$AS_LOG" ] || [ -s "$AS_GEN_LOG" ]; then echo "tools were called with a bad latch" >&2; return 1; fi
  rm -rf "$AS_TMP"
}

test_appstore_missing_credentials_fails_fast() {
  local tmp rc=0
  tmp="$(mktemp -d)"
  : > "$tmp/log"; mkdir -p "$tmp/bin"; ln -s "$AS_FAKES/xcodegen" "$tmp/bin/xcodegen"
  env -u ASC_KEY_ID -u ASC_ISSUER_ID -u ASC_KEY_PATH FAKE_LOG="$tmp/log" FAKE_XCODEGEN_LOG="$tmp/log" \
    PATH="$tmp/bin:$PATH" XCODEBUILD="$AS_FAKES/xcodebuild" "$AS_SCRIPT" mac >/dev/null 2>"$tmp/err" || rc=$?
  [ "$rc" -ne 0 ]
  grep -q ASC_KEY_ID "$tmp/err"
  if [ -s "$tmp/log" ]; then echo "xcodebuild/xcodegen ran without credentials" >&2; return 1; fi
  rm -rf "$tmp"
}

test_upload_missing_credentials_fails_before_xcodebuild() {
  local tmp rc=0
  tmp="$(mktemp -d)"
  : > "$tmp/log"; mkdir -p "$tmp/bin"; ln -s "$AS_FAKES/xcodegen" "$tmp/bin/xcodegen"
  env -u ASC_KEY_ID -u ASC_ISSUER_ID -u ASC_KEY_PATH KERNIR_ALLOW_UPLOAD=1 FAKE_LOG="$tmp/log" \
    FAKE_XCODEGEN_LOG="$tmp/log" PATH="$tmp/bin:$PATH" XCODEBUILD="$AS_FAKES/xcodebuild" "$AS_SCRIPT" ios --upload >/dev/null 2>"$tmp/err" || rc=$?
  [ "$rc" -ne 0 ]
  if [ -s "$tmp/log" ]; then echo "xcodebuild/xcodegen ran without credentials" >&2; return 1; fi
  rm -rf "$tmp"
}

test_invalid_platform_rejected() {
  run_fake_appstore -- tvos
  [ "$AS_RC" -ne 0 ]
  if [ -s "$AS_LOG" ] || [ -s "$AS_GEN_LOG" ]; then echo "tools ran for an invalid platform" >&2; return 1; fi
  rm -rf "$AS_TMP"
}

test_platform_args_ios() {
  run_fake_appstore -- ios --version 1.2.3
  [ "$AS_RC" -eq 0 ]
  grep '^xcodebuild archive' "$AS_LOG" | grep -q -- '-scheme KernirIOS'
  grep '^xcodebuild archive' "$AS_LOG" | grep -q -- '-destination generic/platform=iOS'
  grep '^xcodebuild archive' "$AS_LOG" | grep -q -- 'MARKETING_VERSION=1.2.3'
  grep '^xcodebuild archive' "$AS_LOG" | grep -q -- 'DEVELOPMENT_TEAM=Q42GSJXJKF'
  grep '^xcodebuild archive' "$AS_LOG" | grep -q -- '-allowProvisioningUpdates'
  grep '^xcodebuild archive' "$AS_LOG" | grep -q -- '-authenticationKeyID FAKEKEY'
  grep '^xcodebuild archive' "$AS_LOG" | grep -q -- '-derivedDataPath .*build/DerivedData'
  grep '^xcodebuild archive' "$AS_LOG" | grep -q -- 'build/Lutik-ios.xcarchive'
  grep '^xcodebuild -exportArchive' "$AS_LOG" | grep -q -- '-allowProvisioningUpdates'
  grep '^xcodebuild -exportArchive' "$AS_LOG" | grep -q -- '-authenticationKeyIssuerID fake-issuer'
  grep '^xcodebuild -exportArchive' "$AS_LOG" | grep -q -- 'AppStoreIOS.plist'
  grep -q '^plist-destination: export' "$AS_LOG"
  grep '^xcodebuild archive' "$AS_LOG" | grep -q -- "CURRENT_PROJECT_VERSION=$(git -C "$REPO_ROOT" rev-list --count HEAD)"
  grep -q '^xcodegen generate' "$AS_GEN_LOG"
  assert_no_temp_leftovers
  grep -q 'dist/appstore-ios/Lutik.ipa$' "$AS_TMP/out.txt"
  [ -f "$REPO_ROOT/dist/appstore-ios/Lutik.ipa" ]
  rm -rf "$AS_TMP"
}

test_platform_args_mac() {
  run_fake_appstore -- mac --version 1.2.3
  [ "$AS_RC" -eq 0 ]
  grep '^xcodebuild archive' "$AS_LOG" | grep -q -- '-scheme KernirMac'
  grep '^xcodebuild archive' "$AS_LOG" | grep -q -- '-destination generic/platform=macOS'
  grep '^xcodebuild archive' "$AS_LOG" | grep -q -- 'build/Lutik-mac.xcarchive'
  grep '^xcodebuild -exportArchive' "$AS_LOG" | grep -q -- 'AppStoreMac.plist'
  grep -q 'dist/appstore-mac/Lutik.pkg$' "$AS_TMP/out.txt"
  [ -f "$REPO_ROOT/dist/appstore-mac/Lutik.pkg" ]
  rm -rf "$AS_TMP"
}

test_upload_rewrites_temp_plist_only() {
  local before after
  before="$(shasum "$REPO_ROOT/scripts/export/AppStoreMac.plist")"
  run_fake_appstore KERNIR_ALLOW_UPLOAD=1 -- mac --version 1.2.3 --upload
  [ "$AS_RC" -eq 0 ]
  grep -q '^plist-destination: upload' "$AS_LOG"
  if grep '^xcodebuild -exportArchive' "$AS_LOG" | grep -q 'scripts/export/AppStoreMac.plist'; then
    echo "upload used the committed plist" >&2; return 1
  fi
  after="$(shasum "$REPO_ROOT/scripts/export/AppStoreMac.plist")"
  [ "$before" = "$after" ]
  assert_no_temp_leftovers
  [ "$(/usr/libexec/PlistBuddy -c 'Print :destination' "$REPO_ROOT/scripts/export/AppStoreMac.plist")" = export ]
  rm -rf "$AS_TMP"
}

test_export_plists_valid() {
  local p v
  for p in AppStoreMac AppStoreIOS; do
    plutil -lint "$REPO_ROOT/scripts/export/$p.plist" >/dev/null
    for v in "method:app-store-connect" "teamID:Q42GSJXJKF" "signingStyle:automatic" \
             "destination:export" "uploadSymbols:true" "manageAppVersionAndBuildNumber:false"; do
      [ "$(/usr/libexec/PlistBuddy -c "Print :${v%%:*}" "$REPO_ROOT/scripts/export/$p.plist")" = "${v#*:}" ]
    done
  done
}

test_version_must_be_strict_semver() {
  run_fake_appstore -- mac --version 0.0.0-dev
  [ "$AS_RC" -ne 0 ]
  grep -q 'X.Y.Z' "$AS_ERR"
  if [ -s "$AS_LOG" ] || [ -s "$AS_GEN_LOG" ]; then echo "tools ran with a bad version" >&2; return 1; fi
  rm -rf "$AS_TMP"
}

test_version_flag_rejects_flag_value() {
  run_fake_appstore -- mac --version --upload
  [ "$AS_RC" -ne 0 ]
  if [ -s "$AS_LOG" ] || [ -s "$AS_GEN_LOG" ]; then echo "tools ran with a bad --version" >&2; return 1; fi
  rm -rf "$AS_TMP"
  run_fake_appstore -- mac --version
  [ "$AS_RC" -ne 0 ]
  rm -rf "$AS_TMP"
}

test_upload_leaves_dist_untouched() {
  local d="$REPO_ROOT/dist/appstore-mac"
  rm -rf "$d"
  mkdir -p "$d"
  echo keep > "$d/keep.txt"
  run_fake_appstore KERNIR_ALLOW_UPLOAD=1 -- mac --version 1.2.3 --upload
  [ "$AS_RC" -eq 0 ]
  [ -f "$d/keep.txt" ]
  if [ -e "$d/Lutik.pkg" ]; then echo "upload wrote into dist/" >&2; return 1; fi
  grep '^xcodebuild -exportArchive' "$AS_LOG" | grep -q -- 'ExportOptions.plist'
  assert_no_temp_leftovers
  rm -rf "$AS_TMP" "$d"
}

test_export_without_artifact_dies() {
  run_fake_appstore FAKE_EXPORT_EMPTY=1 -- ios --version 1.2.3
  [ "$AS_RC" -ne 0 ]
  grep -q 'export did not produce' "$AS_ERR"
  rm -rf "$AS_TMP"
}

test_export_emits_only_platform_artifact() {
  run_fake_appstore -- mac --version 1.2.3
  [ "$AS_RC" -eq 0 ]
  [ -f "$REPO_ROOT/dist/appstore-mac/Lutik.pkg" ]
  if [ -e "$REPO_ROOT/dist/appstore-mac/Lutik.ipa" ] || [ -e "$REPO_ROOT/dist/appstore-mac/Lutik.app" ]; then
    echo "fake emitted extra artifacts" >&2; return 1
  fi
  rm -rf "$AS_TMP"
}

test_build_number_override() {
  run_fake_appstore BUILD_NUMBER=777 -- mac --version 1.2.3
  [ "$AS_RC" -eq 0 ]
  grep '^xcodebuild archive' "$AS_LOG" | grep -q -- 'CURRENT_PROJECT_VERSION=777'
  rm -rf "$AS_TMP"
}

test_build_number_override_validated() {
  local bn
  for bn in abc 0 -5 12x; do
    run_fake_appstore BUILD_NUMBER="$bn" -- mac --version 1.2.3
    [ "$AS_RC" -ne 0 ]
    grep -q BUILD_NUMBER "$AS_ERR"
    if [ -s "$AS_LOG" ]; then echo "xcodebuild ran with BUILD_NUMBER=$bn" >&2; return 1; fi
    rm -rf "$AS_TMP"
  done
}

# ---- --offline ----

test_offline_needs_no_credentials() {
  run_fake_appstore -u ASC_KEY_ID -u ASC_ISSUER_ID -u ASC_KEY_PATH -- mac --offline --version 0.1.0
  [ "$AS_RC" -eq 0 ]
  rm -rf "$AS_TMP"
  # Control: the same environment without --offline must fail for lack of credentials.
  run_fake_appstore -u ASC_KEY_ID -u ASC_ISSUER_ID -u ASC_KEY_PATH -- mac --version 0.1.0
  [ "$AS_RC" -ne 0 ]
  grep -q ASC_KEY_ID "$AS_ERR"
  rm -rf "$AS_TMP"
}

test_offline_never_contacts_apple() {
  run_fake_appstore -- mac --offline --version 0.1.0
  [ "$AS_RC" -eq 0 ]
  local flag
  for flag in -allowProvisioningUpdates -authenticationKey -exportArchive; do
    if grep -q -- "$flag" "$AS_LOG"; then echo "offline passed $flag" >&2; return 1; fi
  done
  grep '^xcodebuild archive' "$AS_LOG" | grep -q -- 'CODE_SIGN_IDENTITY=-'
  grep '^xcodebuild archive' "$AS_LOG" | grep -q -- 'CODE_SIGN_STYLE=Manual'
  rm -rf "$AS_TMP"
}

test_offline_runs_checker_on_archived_app() {
  run_fake_appstore -- mac --offline --version 0.1.0
  [ "$AS_RC" -eq 0 ]
  grep -q -- '--platform mac .*Products/Applications/Lutik.app$' "$AS_CHECKER_LOG"
  rm -rf "$AS_TMP"
  run_fake_appstore FAKE_CHECKER_RC=1 -- ios --offline --version 0.1.0
  [ "$AS_RC" -eq 1 ]
  grep -q -- '--platform ios ' "$AS_CHECKER_LOG"
  rm -rf "$AS_TMP"
}

test_offline_leaves_dist_untouched() {
  rm -rf "$REPO_ROOT/dist/appstore-mac"
  run_fake_appstore -- mac --offline --version 0.1.0
  [ "$AS_RC" -eq 0 ]
  if [ -e "$REPO_ROOT/dist/appstore-mac" ]; then echo "offline wrote dist/appstore-mac" >&2; return 1; fi
  rm -rf "$AS_TMP"
}

test_offline_and_upload_conflict() {
  run_fake_appstore KERNIR_ALLOW_UPLOAD=1 -- mac --offline --upload
  [ "$AS_RC" -eq 1 ]
  grep -q -- '--offline' "$AS_ERR"
  grep -q -- '--upload' "$AS_ERR"
  if [ -s "$AS_LOG" ] || [ -s "$AS_GEN_LOG" ]; then echo "tools ran for --offline --upload" >&2; return 1; fi
  rm -rf "$AS_TMP"
}

test_cleanup_unregisters_everything_under_build() {
  # The exit cleanup must unregister every built app under $BUILD (also an old Kernir-<platform>.xcarchive),
  # not only the new Lutik archive and DerivedData. Static check: the real run would touch the repo's build/.
  grep -qE '^  unregister_apps_under "\$BUILD"$' "$AS_SCRIPT"
}
