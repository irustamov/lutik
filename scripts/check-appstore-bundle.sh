#!/bin/bash
# Offline check for problems App Store Connect rejects at upload. Never contacts Apple.
# Also checks that every app document type has a CFBundleTypeName (and, on macOS, that its
# CFBundleTypeIconFile exists in Contents/Resources as .icns), and that every content type
# the app (CFBundleDocumentTypes LSItemContentTypes) and each appex (QLSupportedContentTypes)
# lists is declared in that bundle's UTImported/UTExported
# TypeDeclarations or is a system type on a clean macOS / iOS (rar, lha and zst are not: the dev
# Mac resolves them only because other apps declare them).
# Usage: check-appstore-bundle.sh [--platform mac|ios] APP_PATH
# Prints "FAIL: <bundle relative path>: <reason>" to stderr per finding, "OK: APP_PATH" on stdout
# when clean. Exit 0 clean, 1 findings, 2 usage error.
set -uo pipefail

usage() { echo "Usage: $0 [--platform mac|ios] APP_PATH" >&2; exit 2; }

PLATFORM=""
APP=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --platform) [ "$#" -ge 2 ] || usage; PLATFORM="$2"; shift 2 ;;
    -h|--help) echo "Usage: $0 [--platform mac|ios] APP_PATH"; exit 0 ;;
    -*) usage ;;
    *) [ -z "$APP" ] || usage; APP="$1"; shift ;;
  esac
done
[ -n "$APP" ] && [ -d "$APP" ] || usage
APP="${APP%/}"
if [ -z "$PLATFORM" ]; then
  if [ -f "$APP/Contents/Info.plist" ]; then PLATFORM=mac; else PLATFORM=ios; fi
fi
case "$PLATFORM" in mac|ios) ;; *) usage ;; esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FINDINGS=0
fail() { # REL REASON
  FINDINGS=$((FINDINGS + 1))
  echo "FAIL: $1: $2" >&2
}

plist_get() { plutil -extract "$2" raw -o - "$1" 2>/dev/null; }

# Release bundle IDs (KERNIR_BUNDLE_ID_SUFFIX is empty in Release). Every appex must use one of
# EXT_IDS, and no two appexes may share one.
APP_ID=com.kernir.app
EXT_IDS="$APP_ID.quicklook $APP_ID.thumbnail"
SEEN_EXT_IDS=""  # "ID REL" per line, for the appexes checked so far

if [ "$PLATFORM" = mac ]; then
  CONTENTS="Contents/"; PLUGINS="Contents/PlugIns"
else
  CONTENTS=""; PLUGINS="PlugIns"
fi

# Content types a bundle may list without declaring them: exactly what the Info.plists use
# undeclared today, which CI's clean runners accept. Extend only with evidence from a clean
# runner (CI), never from the dev Mac: it resolves extra types that other apps declare there.
SYSTEM_TYPES_MAC="com.apple.xar-archive com.microsoft.cab com.sun.java-archive com.sun.web-application-archive
  org.7-zip.7-zip-archive org.gnu.gnu-tar-archive org.gnu.gnu-zip-archive org.gnu.gnu-zip-tar-archive
  org.tukaani.tar-xz-archive org.tukaani.xz-archive public.bzip2-archive public.cpio-archive public.iso-image
  public.tar-archive public.tar-bzip2-archive public.zip-archive"
# public.item is exempt from the CI-evidence rule above, in the Mac app's LSItemContentTypes only
# (check_content_types): the "File or Folder" document type, a rank-None Viewer with no
# document class, which makes the Dock icon a drop target and claims no file. It is the root type
# CoreTypes.bundle exports on every macOS. Nowhere else (an extension's QLSupportedContentTypes, iOS).
# iOS: the same minus public.iso-image (the iOS bundles import it).
SYSTEM_TYPES_IOS="com.apple.xar-archive com.microsoft.cab com.sun.java-archive com.sun.web-application-archive
  org.7-zip.7-zip-archive org.gnu.gnu-tar-archive org.gnu.gnu-zip-archive org.gnu.gnu-zip-tar-archive
  org.tukaani.tar-xz-archive org.tukaani.xz-archive public.bzip2-archive public.cpio-archive
  public.tar-archive public.tar-bzip2-archive public.zip-archive"
if [ "$PLATFORM" = mac ]; then
  SYSTEM_TYPES="$SYSTEM_TYPES_MAC"; PLATFORM_NAME=macOS
else
  SYSTEM_TYPES="$SYSTEM_TYPES_IOS"; PLATFORM_NAME=iOS
fi

is_system_type() {
  local s
  for s in $SYSTEM_TYPES; do [ "$s" != "$1" ] || return 0; done
  return 1
}

# Print the string items of the array at KEYPATH, one per line. Args: PLIST KEYPATH
plist_array() {
  local n i
  n="$(plist_get "$1" "$2")"
  [[ "$n" =~ ^[0-9]+$ ]] || return 0
  for ((i = 0; i < n; i++)); do plist_get "$1" "$2.$i"; echo; done
}

# Every listed content type must be declared in the same Info.plist or be a system type.
# Args: INFO REL KIND
check_content_types() {
  local info="$1" rel="$2" kind="$3" key declared="" t n i
  for key in UTImportedTypeDeclarations UTExportedTypeDeclarations; do
    n="$(plist_get "$info" "$key")"
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    for ((i = 0; i < n; i++)); do declared="$declared $(plist_get "$info" "$key.$i.UTTypeIdentifier")"; done
  done
  local refs=()  # "KEY TYPE"
  if [ "$kind" = app ]; then
    n="$(plist_get "$info" CFBundleDocumentTypes)"
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    for ((i = 0; i < n; i++)); do
      # ITMS-90243: every document type needs a CFBundleTypeName.
      [ -n "$(plist_get "$info" "CFBundleDocumentTypes.$i.CFBundleTypeName")" ] \
        || fail "$rel" "CFBundleDocumentTypes.$i has no CFBundleTypeName (ITMS-90243)"
      while IFS= read -r t; do [ -z "$t" ] || refs+=("LSItemContentTypes $t"); done \
        < <(plist_array "$info" "CFBundleDocumentTypes.$i.LSItemContentTypes")
    done
  else
    while IFS= read -r t; do [ -z "$t" ] || refs+=("QLSupportedContentTypes $t"); done \
      < <(plist_array "$info" NSExtension.NSExtensionAttributes.QLSupportedContentTypes)
  fi
  local ref reported=""
  for ref in ${refs[@]+"${refs[@]}"}; do
    key="${ref%% *}"; t="${ref#* }"
    case " $declared $reported " in *" $t "*) continue ;; esac
    is_system_type "$t" && continue
    [ "$PLATFORM" = mac ] && [ "$key $t" = "LSItemContentTypes public.item" ] && continue
    reported="$reported $t"
    fail "$rel" "$t is listed in $key but not declared in UTImportedTypeDeclarations (not a system type on a clean $PLATFORM_NAME)"
  done
}

# Required-reason symbols -> category.
category_for_symbol() {
  case "$1" in
    _stat|_fstat|_lstat|_fstatat|_getattrlist|_fgetattrlist|_getattrlistbulk) echo NSPrivacyAccessedAPICategoryFileTimestamp ;;
    _statfs|_fstatfs|_statvfs|_fstatvfs) echo NSPrivacyAccessedAPICategoryDiskSpace ;;
    '_OBJC_CLASS_$_NSUserDefaults') echo NSPrivacyAccessedAPICategoryUserDefaults ;;
    _mach_absolute_time) echo NSPrivacyAccessedAPICategorySystemBootTime ;;
  esac
}

# check_bundle ROOT REL KIND(app|ext) ; ROOT is the bundle dir, REL its path relative to APP.
check_bundle() {
  local root="$1" rel="$2" kind="$3"
  local info="$root/${CONTENTS}Info.plist" v exe
  if [ ! -f "$info" ]; then fail "$rel" "missing ${CONTENTS}Info.plist"; return; fi

  v="$(plist_get "$info" CFBundleIdentifier)"
  if [ "$kind" = app ]; then
    [ "$v" = "$APP_ID" ] || fail "$rel" "CFBundleIdentifier is '${v}', expected $APP_ID"
  else
    case " $EXT_IDS " in
      *" $v "*) ;;
      *) fail "$rel" "CFBundleIdentifier is '${v}', expected one of: $EXT_IDS" ;;
    esac
    local seen_id seen_rel
    if [ -n "$v" ]; then
      while read -r seen_id seen_rel; do
        [ "$seen_id" != "$v" ] || fail "$rel" "CFBundleIdentifier '${v}' is already used by $seen_rel"
      done <<< "$SEEN_EXT_IDS"
      SEEN_EXT_IDS="$SEEN_EXT_IDS$v $rel"$'\n'
    fi
  fi

  local short build
  short="$(plist_get "$info" CFBundleShortVersionString)"
  build="$(plist_get "$info" CFBundleVersion)"
  if [ "$kind" = app ]; then
    APP_SHORT="$short"; APP_BUILD="$build"
    [[ "$short" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "$rel" "CFBundleShortVersionString '${short}' is not major.minor.patch"
    [[ "$build" =~ ^[0-9]+$ ]] || fail "$rel" "CFBundleVersion '${build}' is not an integer"
  else
    [ "$short" = "$APP_SHORT" ] || fail "$rel" "CFBundleShortVersionString '${short}' differs from the app's '${APP_SHORT}'"
    [ "$build" = "$APP_BUILD" ] || fail "$rel" "CFBundleVersion '${build}' differs from the app's '${APP_BUILD}'"
  fi

  if [ "$kind" = app ]; then
    v="$(plist_get "$info" ITSAppUsesNonExemptEncryption)"
    [ "$v" = false ] || fail "$rel" "ITSAppUsesNonExemptEncryption must be present and false (found '${v:-missing}')"
    if [ "$PLATFORM" = mac ]; then
      v="$(plist_get "$info" LSApplicationCategoryType)"
      [ "$v" = public.app-category.utilities ] || fail "$rel" "LSApplicationCategoryType is '${v:-missing}', expected public.app-category.utilities"
      # Every document type icon (CFBundleTypeIconFile, .icns optional) ships in Contents/Resources.
      local n i icon
      n="$(plist_get "$info" CFBundleDocumentTypes)"
      [[ "$n" =~ ^[0-9]+$ ]] || n=0
      for ((i = 0; i < n; i++)); do
        icon="$(plist_get "$info" "CFBundleDocumentTypes.$i.CFBundleTypeIconFile")"
        [ -n "$icon" ] || continue
        case "$icon" in *.icns) ;; *) icon="$icon.icns" ;; esac
        if [ ! -e "$root/Contents/Resources/$icon" ]; then
          fail "$rel" "CFBundleDocumentTypes.$i CFBundleTypeIconFile: Contents/Resources/$icon not found"
        elif [ ! -s "$root/Contents/Resources/$icon" ] || [ ! -f "$root/Contents/Resources/$icon" ]; then
          fail "$rel" "CFBundleDocumentTypes.$i CFBundleTypeIconFile: Contents/Resources/$icon is empty or not a file"
        fi
      done
    fi
    v="$(plist_get "$info" CFBundleIconName)"
    # iOS: actool puts the icon name under CFBundleIcons, not at the top level.
    [ -n "$v" ] || [ "$PLATFORM" = mac ] || v="$(plist_get "$info" CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName)"
    [ "$v" = AppIcon ] || fail "$rel" "CFBundleIconName is '${v:-missing}', expected AppIcon"
    local assets="$root/Assets.car"; [ "$PLATFORM" = mac ] && assets="$root/Contents/Resources/Assets.car"
    [ -f "$assets" ] || fail "$rel" "Assets.car not found in bundle"
  fi

  if [ "$PLATFORM" = mac ]; then
    local ents="$TMP/ents.plist"
    : > "$ents"
    codesign -d --entitlements - --xml "$root" >"$ents" 2>/dev/null
    v="$(plist_get "$ents" 'com\.apple\.security\.app-sandbox')"
    [ "$v" = true ] || fail "$rel" "com.apple.security.app-sandbox is not true in the signature entitlements"
  fi

  check_content_types "$info" "$rel" "$kind"

  # Privacy manifest vs imported required-reason symbols.
  exe="$(plist_get "$info" CFBundleExecutable)"
  local exe_path="$root/${CONTENTS}$([ "$PLATFORM" = mac ] && echo MacOS/)$exe"
  if [ -z "$exe" ] || [ ! -f "$exe_path" ]; then
    fail "$rel" "executable '${exe}' not found"
    return
  fi
  local needed="" sym cat nm_paths=("$exe_path")
  # Debug builds move the code into <exe>.debug.dylib; the stub executable imports nothing.
  [ ! -f "${exe_path}.debug.dylib" ] || nm_paths+=("${exe_path}.debug.dylib")
  while IFS= read -r sym; do
    sym="${sym%\$INODE64}"
    cat="$(category_for_symbol "$sym")"
    case " $needed " in *" $cat "*) ;; *) [ -z "$cat" ] || needed="$needed $cat" ;; esac
  done < <(nm -u -j -arch all "${nm_paths[@]}" 2>/dev/null | sort -u)

  local manifest="$root/${CONTENTS}$([ "$PLATFORM" = mac ] && echo Resources/)PrivacyInfo.xcprivacy"
  local mrel="${rel}/${manifest#"$root"/}"
  if [ ! -f "$manifest" ]; then
    [ -z "$needed" ] || fail "$rel" "executable imports required-reason APIs but ${manifest#"$root"/} (PrivacyInfo.xcprivacy) is missing; needs:$needed"
    return
  fi
  if ! plutil -lint "$manifest" >/dev/null 2>&1; then fail "$mrel" "PrivacyInfo.xcprivacy is not a valid plist"; return; fi
  v="$(plist_get "$manifest" NSPrivacyTracking)"
  [ "$v" = false ] || fail "$mrel" "NSPrivacyTracking must be false (found '${v:-missing}')"
  v="$(plist_get "$manifest" NSPrivacyCollectedDataTypes)"
  [ -z "$v" ] || [ "$v" = 0 ] || fail "$mrel" "NSPrivacyCollectedDataTypes must be empty"

  local have="" n i t r
  n="$(plist_get "$manifest" NSPrivacyAccessedAPITypes)"; n="${n:-0}"
  for ((i = 0; i < n; i++)); do
    t="$(plist_get "$manifest" "NSPrivacyAccessedAPITypes.$i.NSPrivacyAccessedAPIType")"
    r="$(plist_get "$manifest" "NSPrivacyAccessedAPITypes.$i.NSPrivacyAccessedAPITypeReasons")"
    [ -z "$t" ] || [ "${r:-0}" = 0 ] || have="$have $t"
  done
  for cat in $needed; do
    case " $have " in *" $cat "*) ;; *) fail "$mrel" "missing $cat (with at least one reason code) in NSPrivacyAccessedAPITypes" ;; esac
  done
}

APP_SHORT=""; APP_BUILD=""
check_bundle "$APP" "$(basename "$APP")" app
if [ -d "$APP/$PLUGINS" ]; then
  for appex in "$APP/$PLUGINS"/*.appex; do
    [ -d "$appex" ] || continue
    check_bundle "$appex" "$PLUGINS/$(basename "$appex")" ext
  done
fi

if [ "$FINDINGS" -gt 0 ]; then exit 1; fi
echo "OK: $APP"
