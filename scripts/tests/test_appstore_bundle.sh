#!/bin/bash
# Tests for scripts/check-appstore-bundle.sh. Builds tiny fixture bundles with the real
# clang/codesign/plutil/nm (ad-hoc signing, nothing is launched, nothing reaches Apple).
# Sourced by run.sh.

AB_SCRIPT="$REPO_ROOT/scripts/check-appstore-bundle.sh"

# Compile a tiny executable that imports the named symbols. Args: OUT SYMBOLS...
# Env: AB_FAT=1 builds arm64 + x86_64. AB_DYLIB=1 builds a -dynamiclib instead of an executable.
ab_compile() {
  local out="$1"; shift
  local src="$out.c" sym refs="" archs=(-arch arm64)
  {
    echo '#include <sys/stat.h>'
    echo '#include <sys/statvfs.h>'
    echo '#include <sys/mount.h>'
    echo '#include <sys/attr.h>'
    echo '#include <mach/mach_time.h>'
    echo 'extern void *OBJC_CLASS_NSUD __asm__("_OBJC_CLASS_$_NSUserDefaults");'
  } > "$src"
  for sym in "$@"; do
    case "$sym" in
      NSUserDefaults) refs="$refs (void*)&OBJC_CLASS_NSUD," ;;
      *) refs="$refs (void*)$sym," ;;
    esac
  done
  echo "static void *volatile refs[] = { $refs 0 };" >> "$src"
  echo 'int main(void) { return refs[0] != 0; }' >> "$src"
  [ "${AB_FAT:-0}" = 1 ] && archs=(-arch arm64 -arch x86_64)
  [ "${AB_DYLIB:-0}" = 1 ] && archs+=(-dynamiclib)
  xcrun clang "${archs[@]}" -Wno-everything -framework Foundation -o "$out" "$src"
  rm -f "$src"
}

# Write a bundle Info.plist. Args: PLIST ID SHORT BUILD EXE [category]
ab_info() {
  local p="$1"
  plutil -create xml1 "$p"
  plutil -insert CFBundleIdentifier -string "$2" "$p"
  plutil -insert CFBundleShortVersionString -string "$3" "$p"
  plutil -insert CFBundleVersion -string "$4" "$p"
  plutil -insert CFBundleExecutable -string "$5" "$p"
}

# Write a privacy manifest. Args: PATH TRACKING(true|false) CATEGORIES...
ab_write_manifest() {
  local path="$1" tracking="$2" cat; shift 2
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo "<plist version=\"1.0\"><dict><key>NSPrivacyTracking</key><$tracking/>"
    echo '<key>NSPrivacyCollectedDataTypes</key><array/>'
    echo '<key>NSPrivacyAccessedAPITypes</key><array>'
    for cat in "$@"; do
      echo "<dict><key>NSPrivacyAccessedAPIType</key><string>NSPrivacyAccessedAPICategory$cat</string>"
      echo '<key>NSPrivacyAccessedAPITypeReasons</key><array><string>C617.1</string></array></dict>'
    done
    echo '</array></dict></plist>'
  } > "$path"
}

# Print a JSON string array. Args: "a b c"
ab_json_list() {
  local t out=""
  for t in $1; do out="$out${out:+,}\"$t\""; done
  printf '[%s]' "$out"
}

# Insert a type declaration array (UTTypeIdentifier + UTTypeConformsTo). Args: PLIST KEY "ids"
ab_type_decls() {
  local t out=""
  [ -n "$3" ] || return 0
  for t in $3; do out="$out${out:+,}{\"UTTypeIdentifier\":\"$t\",\"UTTypeConformsTo\":[\"public.data\",\"public.archive\"]}"; done
  plutil -insert "$2" -json "[$out]" "$1"
}

# Build a fixture app + Quick Look appex. Args: DIR PLATFORM(mac|ios) APP_SYMBOLS...
# Sets AB_APP. Knobs (env): AB_APP_ID AB_APP_VER AB_APP_BUILD AB_APPEX_BUILD AB_ENCRYPT(0 omits)
# AB_CATEGORY AB_APPEX_SANDBOX(0 omits) AB_APPEX_SYMBOLS AB_MANIFEST_CATS (space separated,
# empty = no manifest) AB_MANIFEST_TRACKING AB_MANIFEST_AT_ROOT(1) AB_FAT(1)
# AB_DEBUG_DYLIB_SYMBOLS (mac only: also builds Lutik.debug.dylib importing these symbols).
# AB_DOC_TYPE_NAME(0 omits the document type's CFBundleTypeName).
# AB_DOC_ICON (sets the document type's CFBundleTypeIconFile), AB_DOC_ICNS (creates this file in
# the app's Resources, non-empty), AB_DOC_ICNS_EMPTY(1 creates it empty).
# AB_QL_ID (the QL.appex CFBundleIdentifier, default com.kernir.app.quicklook).
# AB_THUMB_ID (non-empty adds a second appex, Thumb.appex, with this ID; same version, symbols,
# QLSupportedContentTypes and sandbox knobs as QL.appex).
# Content types (space separated, empty = key omitted): AB_DOC_TYPES (app LSItemContentTypes),
# AB_APP_IMPORTS AB_APP_EXPORTS (app UTImported/UTExportedTypeDeclarations), AB_QL_TYPES
# (appex QLSupportedContentTypes), AB_APPEX_IMPORTS.
ab_bundle() {
  local dir="$1" platform="$2"; shift 2
  local app="$dir/Lutik.app" root exe_dir res_dir appex aroot thumb="" troot="" ents sbx r
  ents="$dir/app.entitlements"; sbx="$dir/appex.entitlements"
  if [ "$platform" = mac ]; then
    root="$app/Contents"; exe_dir="$root/MacOS"; res_dir="$root/Resources"
    appex="$root/PlugIns/QL.appex"; aroot="$appex/Contents"
    mkdir -p "$exe_dir" "$res_dir" "$aroot/MacOS"
    [ -z "${AB_THUMB_ID:-}" ] || { thumb="$root/PlugIns/Thumb.appex"; troot="$thumb/Contents"; mkdir -p "$troot/MacOS"; }
  else
    root="$app"; exe_dir="$app"; res_dir="$app"
    appex="$app/PlugIns/QL.appex"; aroot="$appex"
    mkdir -p "$appex"
    [ -z "${AB_THUMB_ID:-}" ] || { thumb="$app/PlugIns/Thumb.appex"; troot="$thumb"; mkdir -p "$thumb"; }
  fi
  ab_info "$root/Info.plist" "${AB_APP_ID:-com.kernir.app}" "${AB_APP_VER:-1.0.0}" "${AB_APP_BUILD:-42}" Lutik
  if [ "$platform" = mac ]; then
    plutil -insert CFBundleIconName -string AppIcon "$root/Info.plist"
  else
    # actool writes the iOS icon name only under CFBundleIcons (Release-iphonesimulator, Xcode 26.6).
    plutil -insert CFBundleIcons -dictionary "$root/Info.plist"
    plutil -insert CFBundleIcons.CFBundlePrimaryIcon -dictionary "$root/Info.plist"
    plutil -insert CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName -string AppIcon "$root/Info.plist"
  fi
  [ "${AB_ENCRYPT:-1}" = 0 ] || plutil -insert ITSAppUsesNonExemptEncryption -bool false "$root/Info.plist"
  [ "$platform" != mac ] || plutil -insert LSApplicationCategoryType -string "${AB_CATEGORY:-public.app-category.utilities}" "$root/Info.plist"
  ab_info "$aroot/Info.plist" "${AB_QL_ID:-com.kernir.app.quicklook}" "${AB_APP_VER:-1.0.0}" "${AB_APPEX_BUILD:-${AB_APP_BUILD:-42}}" QL
  [ -z "$thumb" ] || ab_info "$troot/Info.plist" "$AB_THUMB_ID" "${AB_APP_VER:-1.0.0}" "${AB_APPEX_BUILD:-${AB_APP_BUILD:-42}}" Thumb
  [ -z "${AB_DOC_TYPES:-}" ] || plutil -insert CFBundleDocumentTypes -json "[{\"CFBundleTypeName\":\"Archive\",\"LSItemContentTypes\":$(ab_json_list "$AB_DOC_TYPES")}]" "$root/Info.plist"
  [ "${AB_DOC_TYPE_NAME:-1}" = 1 ] || [ -z "${AB_DOC_TYPES:-}" ] || plutil -remove CFBundleDocumentTypes.0.CFBundleTypeName "$root/Info.plist"
  [ -z "${AB_DOC_ICON:-}" ] || plutil -insert CFBundleDocumentTypes.0.CFBundleTypeIconFile -string "$AB_DOC_ICON" "$root/Info.plist"
  if [ -n "${AB_DOC_ICNS:-}" ]; then
    if [ "${AB_DOC_ICNS_EMPTY:-0}" = 1 ]; then : > "$res_dir/$AB_DOC_ICNS"; else printf 'icns' > "$res_dir/$AB_DOC_ICNS"; fi
  fi
  ab_type_decls "$root/Info.plist" UTImportedTypeDeclarations "${AB_APP_IMPORTS:-}"
  ab_type_decls "$root/Info.plist" UTExportedTypeDeclarations "${AB_APP_EXPORTS:-}"
  for r in "$aroot" ${troot:+"$troot"}; do
    [ -z "${AB_QL_TYPES:-}" ] || plutil -insert NSExtension -json "{\"NSExtensionAttributes\":{\"QLSupportedContentTypes\":$(ab_json_list "$AB_QL_TYPES")}}" "$r/Info.plist"
    ab_type_decls "$r/Info.plist" UTImportedTypeDeclarations "${AB_APPEX_IMPORTS:-}"
  done
  : > "$res_dir/Assets.car"
  ab_compile "$exe_dir/Lutik" "$@"
  # shellcheck disable=SC2086
  if [ "$platform" = mac ]; then ab_compile "$aroot/MacOS/QL" ${AB_APPEX_SYMBOLS:-}; else ab_compile "$aroot/QL" ${AB_APPEX_SYMBOLS:-}; fi
  # shellcheck disable=SC2086
  if [ -z "$thumb" ]; then :; elif [ "$platform" = mac ]; then ab_compile "$troot/MacOS/Thumb" ${AB_APPEX_SYMBOLS:-}; else ab_compile "$troot/Thumb" ${AB_APPEX_SYMBOLS:-}; fi
  # shellcheck disable=SC2086
  [ -z "${AB_DEBUG_DYLIB_SYMBOLS:-}" ] || AB_DYLIB=1 ab_compile "$exe_dir/Lutik.debug.dylib" $AB_DEBUG_DYLIB_SYMBOLS
  if [ -n "${AB_MANIFEST_CATS:-}" ]; then
    local mpath="$res_dir/PrivacyInfo.xcprivacy"
    # A root-level file would make codesign refuse the bundle, so that case is written after signing.
    [ "${AB_MANIFEST_AT_ROOT:-0}" = 1 ] && mpath="$dir/PrivacyInfo.xcprivacy"
    # shellcheck disable=SC2086
    ab_write_manifest "$mpath" "${AB_MANIFEST_TRACKING:-false}" $AB_MANIFEST_CATS
  fi
  cat > "$ents" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>
PL
  if [ "${AB_APPEX_SANDBOX:-1}" = 0 ]; then
    printf '%s' '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict/></plist>' > "$sbx"
  else
    cp "$ents" "$sbx"
  fi
  codesign -s - --entitlements "$sbx" -f "$appex" >/dev/null 2>&1
  [ -z "$thumb" ] || codesign -s - --entitlements "$sbx" -f "$thumb" >/dev/null 2>&1
  codesign -s - --entitlements "$ents" -f "$app" >/dev/null 2>&1
  [ "${AB_MANIFEST_AT_ROOT:-0}" != 1 ] || mv "$dir/PrivacyInfo.xcprivacy" "$app/PrivacyInfo.xcprivacy"
  AB_APP="$app"
}

# Run the checker. Args: [--platform X] APP. Sets AB_RC, AB_OUT, AB_ERR (in $AB_TMP).
ab_run() {
  AB_RC=0
  "$AB_SCRIPT" "$@" >"$AB_TMP/out.txt" 2>"$AB_TMP/err.txt" || AB_RC=$?
  AB_OUT="$(cat "$AB_TMP/out.txt")"; AB_ERR="$(cat "$AB_TMP/err.txt")"
}

ab_setup() { AB_TMP="$(mktemp -d)"; mkdir "$AB_TMP/b"; }
ab_teardown() { rm -rf "$AB_TMP"; }

ab_expect_fail() {  # fails the test, showing the checker output
  echo "unexpected checker result rc=$AB_RC" >&2; echo "stdout: $AB_OUT" >&2; echo "stderr: $AB_ERR" >&2; return 1
}

test_appstore_bundle_clean_mac_passes() {
  ab_setup
  AB_MANIFEST_CATS="FileTimestamp" ab_bundle "$AB_TMP/b" mac stat
  ab_run "$AB_APP"
  [ "$AB_RC" -eq 0 ] || ab_expect_fail
  case "$AB_OUT" in OK:*) ;; *) ab_expect_fail ;; esac
  ab_teardown
}

test_appstore_bundle_missing_manifest_fails() {
  ab_setup
  ab_bundle "$AB_TMP/b" mac stat
  ab_run "$AB_APP"
  [ "$AB_RC" -eq 1 ] || ab_expect_fail
  grep 'PrivacyInfo.xcprivacy' <<<"$AB_ERR" | grep -q FileTimestamp || ab_expect_fail
  ab_teardown
}

test_appstore_bundle_manifest_missing_category_fails() {
  ab_setup
  AB_MANIFEST_CATS="UserDefaults" ab_bundle "$AB_TMP/b" mac statfs NSUserDefaults
  ab_run "$AB_APP"
  [ "$AB_RC" -eq 1 ] || ab_expect_fail
  grep -q DiskSpace <<<"$AB_ERR" || ab_expect_fail
  ab_teardown
}

test_appstore_bundle_mac_manifest_at_root_fails() {
  ab_setup
  AB_MANIFEST_CATS="FileTimestamp" AB_MANIFEST_AT_ROOT=1 ab_bundle "$AB_TMP/b" mac stat
  ab_run "$AB_APP"
  [ "$AB_RC" -eq 1 ] || ab_expect_fail
  ab_teardown
}

test_appstore_bundle_fat_inode64_needs_manifest() {
  ab_setup
  AB_FAT=1 ab_bundle "$AB_TMP/b" mac stat
  ab_run "$AB_APP"
  [ "$AB_RC" -eq 1 ] || ab_expect_fail
  grep -q FileTimestamp <<<"$AB_ERR" || ab_expect_fail
  ab_teardown
}

test_appstore_bundle_debug_dylib_needs_manifest() {
  ab_setup
  AB_DEBUG_DYLIB_SYMBOLS="stat" ab_bundle "$AB_TMP/b" mac
  ab_run "$AB_APP"
  [ "$AB_RC" -eq 1 ] || ab_expect_fail
  grep 'PrivacyInfo.xcprivacy' <<<"$AB_ERR" | grep -q FileTimestamp || ab_expect_fail
  ab_teardown
}

test_appstore_bundle_extension_version_mismatch_fails() {
  ab_setup
  AB_APPEX_BUILD=41 ab_bundle "$AB_TMP/b" mac
  ab_run "$AB_APP"
  [ "$AB_RC" -eq 1 ] || ab_expect_fail
  grep -q 'QL.appex' <<<"$AB_ERR" || ab_expect_fail
  ab_teardown
}

test_appstore_bundle_wrong_ids_and_keys_fail() {
  ab_setup
  AB_APP_ID=com.example.x AB_ENCRYPT=0 AB_CATEGORY=public.app-category.productivity ab_bundle "$AB_TMP/b" mac
  ab_run "$AB_APP"
  [ "$AB_RC" -eq 1 ] || ab_expect_fail
  [ "$(echo "$AB_ERR" | grep -c '^FAIL:')" -ge 3 ] || ab_expect_fail
  grep -q 'com.example.x' <<<"$AB_ERR" || ab_expect_fail
  grep -q 'ITSAppUsesNonExemptEncryption' <<<"$AB_ERR" || ab_expect_fail
  grep -q 'public.app-category.productivity' <<<"$AB_ERR" || ab_expect_fail
  ab_teardown
}

# Quick Look preview + thumbnail extensions: both release IDs are accepted, on both platforms.
test_appstore_bundle_two_extensions_pass() {
  ab_setup
  AB_THUMB_ID=com.kernir.app.thumbnail AB_MANIFEST_CATS="FileTimestamp" ab_bundle "$AB_TMP/b" mac stat
  ab_run "$AB_APP"
  [ "$AB_RC" -eq 0 ] || ab_expect_fail
  case "$AB_OUT" in OK:*) ;; *) ab_expect_fail ;; esac
  rm -rf "$AB_TMP/b"; mkdir "$AB_TMP/b"
  AB_THUMB_ID=com.kernir.app.thumbnail AB_MANIFEST_CATS="FileTimestamp" ab_bundle "$AB_TMP/b" ios stat
  ab_run --platform ios "$AB_APP"
  [ "$AB_RC" -eq 0 ] || ab_expect_fail
  # The per-appex checks still run on every appex.
  rm -rf "$AB_TMP/b"; mkdir "$AB_TMP/b"
  AB_THUMB_ID=com.kernir.app.thumbnail AB_APPEX_BUILD=41 AB_MANIFEST_CATS="FileTimestamp" ab_bundle "$AB_TMP/b" mac stat
  ab_run "$AB_APP"
  [ "$AB_RC" -eq 1 ] || ab_expect_fail
  grep '^FAIL: Contents/PlugIns/QL.appex: ' <<<"$AB_ERR" | grep -q 'CFBundleVersion' || ab_expect_fail
  grep '^FAIL: Contents/PlugIns/Thumb.appex: ' <<<"$AB_ERR" | grep -q 'CFBundleVersion' || ab_expect_fail
  ab_teardown
}

test_appstore_bundle_unknown_extension_id_fails() {
  ab_setup
  AB_THUMB_ID=com.kernir.app.foo AB_MANIFEST_CATS="FileTimestamp" ab_bundle "$AB_TMP/b" mac stat
  ab_run "$AB_APP"
  [ "$AB_RC" -eq 1 ] || ab_expect_fail
  [ "$(echo "$AB_ERR" | grep -c '^FAIL:')" -eq 1 ] || ab_expect_fail
  grep '^FAIL: Contents/PlugIns/Thumb.appex: ' <<<"$AB_ERR" | grep "'com.kernir.app.foo'" \
    | grep 'com.kernir.app.quicklook' | grep -q 'com.kernir.app.thumbnail' || ab_expect_fail
  ab_teardown
}

test_appstore_bundle_duplicate_extension_id_fails() {
  ab_setup
  AB_QL_ID=com.kernir.app.thumbnail AB_THUMB_ID=com.kernir.app.thumbnail AB_MANIFEST_CATS="FileTimestamp" \
    ab_bundle "$AB_TMP/b" mac stat
  ab_run "$AB_APP"
  [ "$AB_RC" -eq 1 ] || ab_expect_fail
  [ "$(echo "$AB_ERR" | grep -c '^FAIL:')" -eq 1 ] || ab_expect_fail
  grep '^FAIL: Contents/PlugIns/Thumb.appex: ' <<<"$AB_ERR" | grep 'com.kernir.app.thumbnail' \
    | grep -q 'QL.appex' || ab_expect_fail
  ab_teardown
}

test_appstore_bundle_mac_unsandboxed_extension_fails() {
  ab_setup
  AB_APPEX_SANDBOX=0 ab_bundle "$AB_TMP/b" mac
  ab_run "$AB_APP"
  [ "$AB_RC" -eq 1 ] || ab_expect_fail
  grep 'QL.appex' <<<"$AB_ERR" | grep -q 'app-sandbox' || ab_expect_fail
  ab_teardown
}

test_appstore_bundle_ios_layout_passes() {
  ab_setup
  AB_MANIFEST_CATS="FileTimestamp" ab_bundle "$AB_TMP/b" ios stat
  ab_run "$AB_APP"
  [ "$AB_RC" -eq 0 ] || ab_expect_fail
  ab_run --platform ios "$AB_APP"
  [ "$AB_RC" -eq 0 ] || ab_expect_fail
  ab_teardown
}

test_appstore_bundle_tracking_or_collection_fails() {
  ab_setup
  AB_MANIFEST_CATS="FileTimestamp" AB_MANIFEST_TRACKING=true ab_bundle "$AB_TMP/b" mac stat
  ab_run "$AB_APP"
  [ "$AB_RC" -eq 1 ] || ab_expect_fail
  grep -q NSPrivacyTracking <<<"$AB_ERR" || ab_expect_fail
  ab_teardown
}

test_appstore_bundle_undeclared_document_type_fails() {
  ab_setup
  AB_DOC_TYPES="public.zip-archive com.rarlab.rar-archive" AB_MANIFEST_CATS="FileTimestamp" ab_bundle "$AB_TMP/b" mac stat
  ab_run "$AB_APP"
  [ "$AB_RC" -eq 1 ] || ab_expect_fail
  [ "$(echo "$AB_ERR" | grep -c '^FAIL:')" -eq 1 ] || ab_expect_fail
  grep '^FAIL: Lutik.app: ' <<<"$AB_ERR" | grep 'com.rarlab.rar-archive' | grep 'LSItemContentTypes' \
    | grep 'UTImportedTypeDeclarations' | grep -q 'clean macOS' || ab_expect_fail
  ab_teardown
}

test_appstore_bundle_declared_document_type_passes() {
  ab_setup
  AB_DOC_TYPES="public.zip-archive com.rarlab.rar-archive com.facebook.zst-archive" \
    AB_APP_IMPORTS="com.rarlab.rar-archive" AB_APP_EXPORTS="com.facebook.zst-archive" \
    AB_MANIFEST_CATS="FileTimestamp" ab_bundle "$AB_TMP/b" mac stat
  ab_run "$AB_APP"
  [ "$AB_RC" -eq 0 ] || ab_expect_fail
  case "$AB_OUT" in OK:*) ;; *) ab_expect_fail ;; esac
  ab_teardown
}

# ITMS-90243: App Store Connect rejects a document type without CFBundleTypeName (build 596).
test_appstore_bundle_document_type_without_name_fails() {
  ab_setup
  AB_DOC_TYPES="public.zip-archive" AB_DOC_TYPE_NAME=0 AB_MANIFEST_CATS="FileTimestamp" ab_bundle "$AB_TMP/b" mac stat
  ab_run "$AB_APP"
  [ "$AB_RC" -eq 1 ] || ab_expect_fail
  [ "$(echo "$AB_ERR" | grep -c '^FAIL:')" -eq 1 ] || ab_expect_fail
  grep '^FAIL: Lutik.app: ' <<<"$AB_ERR" | grep 'CFBundleDocumentTypes.0' | grep -q 'CFBundleTypeName' || ab_expect_fail
  ab_teardown
}

# A Mac document type icon must ship as Contents/Resources/<CFBundleTypeIconFile>.icns.
test_appstore_bundle_document_icon_present_passes() {
  ab_setup
  AB_DOC_TYPES="public.zip-archive" AB_DOC_ICON="DocIcon-zip" AB_DOC_ICNS="DocIcon-zip.icns" \
    AB_MANIFEST_CATS="FileTimestamp" ab_bundle "$AB_TMP/b" mac stat
  ab_run "$AB_APP"
  [ "$AB_RC" -eq 0 ] || ab_expect_fail
  ab_teardown
}

test_appstore_bundle_document_icon_missing_fails() {
  ab_setup
  AB_DOC_TYPES="public.zip-archive" AB_DOC_ICON="DocIcon-zip" AB_DOC_ICNS="DocIcon-7z.icns" \
    AB_MANIFEST_CATS="FileTimestamp" ab_bundle "$AB_TMP/b" mac stat
  ab_run "$AB_APP"
  [ "$AB_RC" -eq 1 ] || ab_expect_fail
  [ "$(echo "$AB_ERR" | grep -c '^FAIL:')" -eq 1 ] || ab_expect_fail
  grep '^FAIL: Lutik.app: ' <<<"$AB_ERR" | grep 'CFBundleDocumentTypes.0' \
    | grep -q 'Contents/Resources/DocIcon-zip.icns not found' || ab_expect_fail
  ab_teardown
}

test_appstore_bundle_document_icon_empty_fails() {
  ab_setup
  AB_DOC_TYPES="public.zip-archive" AB_DOC_ICON="DocIcon-zip" AB_DOC_ICNS="DocIcon-zip.icns" AB_DOC_ICNS_EMPTY=1 \
    AB_MANIFEST_CATS="FileTimestamp" ab_bundle "$AB_TMP/b" mac stat
  ab_run "$AB_APP"
  [ "$AB_RC" -eq 1 ] || ab_expect_fail
  [ "$(echo "$AB_ERR" | grep -c '^FAIL:')" -eq 1 ] || ab_expect_fail
  grep '^FAIL: Lutik.app: ' <<<"$AB_ERR" | grep 'CFBundleDocumentTypes.0' \
    | grep -q 'Contents/Resources/DocIcon-zip.icns is empty' || ab_expect_fail
  ab_teardown
}

test_appstore_bundle_appex_undeclared_ql_type_fails() {
  ab_setup
  AB_QL_TYPES="public.zip-archive cx.c3.lha-archive" AB_MANIFEST_CATS="FileTimestamp" ab_bundle "$AB_TMP/b" mac stat
  ab_run "$AB_APP"
  [ "$AB_RC" -eq 1 ] || ab_expect_fail
  [ "$(echo "$AB_ERR" | grep -c '^FAIL:')" -eq 1 ] || ab_expect_fail
  grep '^FAIL: Contents/PlugIns/QL.appex: ' <<<"$AB_ERR" | grep 'cx.c3.lha-archive' \
    | grep -q 'QLSupportedContentTypes' || ab_expect_fail
  # An import in the appex's own Info.plist fixes it (the app's imports don't count).
  rm -rf "$AB_TMP/b"; mkdir "$AB_TMP/b"
  AB_QL_TYPES="cx.c3.lha-archive" AB_APP_IMPORTS="cx.c3.lha-archive" AB_MANIFEST_CATS="FileTimestamp" ab_bundle "$AB_TMP/b" mac stat
  ab_run "$AB_APP"
  [ "$AB_RC" -eq 1 ] || ab_expect_fail
  rm -rf "$AB_TMP/b"; mkdir "$AB_TMP/b"
  AB_QL_TYPES="cx.c3.lha-archive" AB_APPEX_IMPORTS="cx.c3.lha-archive" AB_MANIFEST_CATS="FileTimestamp" ab_bundle "$AB_TMP/b" mac stat
  ab_run "$AB_APP"
  [ "$AB_RC" -eq 0 ] || ab_expect_fail
  ab_teardown
}

test_appstore_bundle_iso_image_system_type_per_platform() {
  ab_setup
  AB_DOC_TYPES="public.iso-image" AB_QL_TYPES="public.iso-image" AB_MANIFEST_CATS="FileTimestamp" ab_bundle "$AB_TMP/b" mac stat
  ab_run --platform mac "$AB_APP"
  [ "$AB_RC" -eq 0 ] || ab_expect_fail
  rm -rf "$AB_TMP/b"; mkdir "$AB_TMP/b"
  AB_DOC_TYPES="public.iso-image" AB_QL_TYPES="public.iso-image" AB_MANIFEST_CATS="FileTimestamp" ab_bundle "$AB_TMP/b" ios stat
  ab_run --platform ios "$AB_APP"
  [ "$AB_RC" -eq 1 ] || ab_expect_fail
  [ "$(echo "$AB_ERR" | grep -c '^FAIL:')" -eq 2 ] || ab_expect_fail
  grep '^FAIL: Lutik.app: ' <<<"$AB_ERR" | grep 'public.iso-image' | grep -q 'clean iOS' || ab_expect_fail
  grep '^FAIL: PlugIns/QL.appex: ' <<<"$AB_ERR" | grep -q 'public.iso-image' || ab_expect_fail
  ab_teardown
}

# The Dock drop type: public.item passes in the Mac app's document types only, never in an
# extension's QLSupportedContentTypes (nor on iOS).
test_appstore_bundle_public_item_app_doc_type_only() {
  ab_setup
  AB_DOC_TYPES="public.zip-archive public.item" AB_MANIFEST_CATS="FileTimestamp" ab_bundle "$AB_TMP/b" mac stat
  ab_run --platform mac "$AB_APP"
  [ "$AB_RC" -eq 0 ] || ab_expect_fail
  rm -rf "$AB_TMP/b"; mkdir "$AB_TMP/b"
  AB_QL_TYPES="public.zip-archive public.item" AB_MANIFEST_CATS="FileTimestamp" ab_bundle "$AB_TMP/b" mac stat
  ab_run --platform mac "$AB_APP"
  [ "$AB_RC" -eq 1 ] || ab_expect_fail
  [ "$(echo "$AB_ERR" | grep -c '^FAIL:')" -eq 1 ] || ab_expect_fail
  grep '^FAIL: Contents/PlugIns/QL.appex: ' <<<"$AB_ERR" | grep 'public.item' \
    | grep -q 'QLSupportedContentTypes' || ab_expect_fail
  rm -rf "$AB_TMP/b"; mkdir "$AB_TMP/b"
  AB_DOC_TYPES="public.item" AB_MANIFEST_CATS="FileTimestamp" ab_bundle "$AB_TMP/b" ios stat
  ab_run --platform ios "$AB_APP"
  [ "$AB_RC" -eq 1 ] || ab_expect_fail
  ab_teardown
}

test_appstore_bundle_usage() {
  local rc=0
  "$AB_SCRIPT" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ]
  rc=0
  "$AB_SCRIPT" /nonexistent/Lutik.app >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ]
  # --help is a request, not an error (test_playbook_commands_exist runs it).
  grep -q '^Usage:' <<<"$("$AB_SCRIPT" --help 2>/dev/null)"
}
