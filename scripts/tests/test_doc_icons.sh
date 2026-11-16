#!/bin/bash
# Tests for the Mac document icons: the "Document icons" Run Script phase
# (scripts/brand/make-doc-icons.sh) and its xcfilelists, the 1024 masters in
# Extensions/ThumbnailAssets, and the KernirMac CFBundleTypeIconFile names must agree.
# Static checks only (no build). Sourced by run.sh.

DI_BRAND="$REPO_ROOT/scripts/brand"
DI_ASSETS="Extensions/ThumbnailAssets/Thumbnails.xcassets"
# Overridable so a test can be pointed at a mutated copy.
DI_PROJECT_YML="${DI_PROJECT_YML:-$REPO_ROOT/project.yml}"
DI_THUMBNAIL_ART="${DI_THUMBNAIL_ART:-$REPO_ROOT/Extensions/ThumbnailShared/ThumbnailArt.swift}"
DI_INFO_PLIST="${DI_INFO_PLIST:-$REPO_ROOT/App/macOS/Info.plist}"
# The one non-archive document type,
# for files and folders dropped on the Dock icon. Rank None, no class, no icon: exempt from the
# icon checks, checked by test_doc_icons_mac_drop_type_is_rank_none instead.
DI_DROP_TYPE="File or Folder"

# Arts with a 1024 master on disk, one per line, sorted.
di_master_arts() {
  local f
  for f in "$REPO_ROOT/$DI_ASSETS"/*.imageset/*-1024.png; do
    [ -f "$f" ] && basename "$f" -1024.png
  done | sort
}

# The KernirMac target block of project.yml (up to the next target).
di_mac_target() {
  awk '/^  KernirMac:$/ { on = 1; next } on && /^  [A-Za-z]/ { exit } on' "$DI_PROJECT_YML"
}

test_doc_icons_filelists_match_masters() {
  local arts in_arts out_arts
  arts="$(di_master_arts)"
  [ "$(echo "$arts" | wc -l | tr -d ' ')" -eq 21 ] || { echo "expected 21 masters, got: $arts" >&2; return 1; }
  [ "$(head -1 "$DI_BRAND/doc-icons-inputs.xcfilelist")" = '$(SRCROOT)/scripts/brand/make-doc-icons.sh' ]
  in_arts="$(sed -n "s|^\$(SRCROOT)/$DI_ASSETS/\([^/]*\)\.imageset/\1-1024\.png\$|\1|p" \
    "$DI_BRAND/doc-icons-inputs.xcfilelist" | sort)"
  [ "$(grep -c . "$DI_BRAND/doc-icons-inputs.xcfilelist")" -eq 22 ] || { echo "inputs: unexpected lines" >&2; return 1; }
  [ "$in_arts" = "$arts" ] || { echo "inputs differ from masters" >&2; return 1; }
  out_arts="$(sed -n 's|^$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/DocIcon-\(.*\)\.icns$|\1|p' \
    "$DI_BRAND/doc-icons-outputs.xcfilelist" | sort)"
  [ "$(grep -c . "$DI_BRAND/doc-icons-outputs.xcfilelist")" -eq 21 ] || { echo "outputs: unexpected lines" >&2; return 1; }
  [ "$out_arts" = "$arts" ] || { echo "outputs differ from masters" >&2; return 1; }
}

test_doc_icons_mac_document_types_use_masters() {
  local block names arts n used
  block="$(di_mac_target)"
  grep -q 'make-doc-icons.sh' <<<"$block"
  grep -q 'inputFileLists: \[$(SRCROOT)/scripts/brand/doc-icons-inputs.xcfilelist\]' <<<"$block"
  grep -q 'outputFileLists: \[$(SRCROOT)/scripts/brand/doc-icons-outputs.xcfilelist\]' <<<"$block"
  # Only KernirMac runs the phase.
  [ "$(grep -c 'make-doc-icons.sh' "$DI_PROJECT_YML")" -eq 1 ]
  n="$(echo "$block" | grep '^          - CFBundleTypeName: ' | grep -cvx "          - CFBundleTypeName: $DI_DROP_TYPE")"
  [ "$n" -eq 27 ] || { echo "expected 27 Mac archive document types besides $DI_DROP_TYPE, got $n" >&2; return 1; }
  names="$(echo "$block" | sed -n 's/^            CFBundleTypeIconFile: DocIcon-\(.*\)$/\1/p')"
  [ "$(echo "$names" | wc -l | tr -d ' ')" -eq "$n" ] || { echo "not every document type has an icon" >&2; return 1; }
  arts="$(di_master_arts)"
  used="$(echo "$names" | sort -u)"
  [ "$used" = "$arts" ] || { echo "icon names differ from masters: $(diff <(echo "$used") <(echo "$arts"))" >&2; return 1; }
}

# "type=art" per ThumbnailArt.rows (the source of truth), sorted.
di_thumbnail_art_rows() {
  local vol
  vol="$(sed -n 's/^    static let volumeType = "\(.*\)"$/\1/p' "$DI_THUMBNAIL_ART")"
  [ -n "$vol" ] || return 1
  sed -n '/^    static let rows: \[Row\] = \[$/,/^    \]$/p' "$DI_THUMBNAIL_ART" | tr '\n' ' ' | awk -v vol="$vol" '{
    n = split($0, parts, "Row\\(")
    for (i = 2; i <= n; i++) {
      type = parts[i]; sub(/,.*/, "", type); gsub(/[" ]/, "", type)
      if (type == "volumeType") type = vol
      if (!match(parts[i], /art: "[^"]*"/)) { print "?" type "=?"; continue }
      art = substr(parts[i], RSTART + 6, RLENGTH - 7)
      print type "=" art
    }
  }' | sort
}

# "type=art" per KernirMac document type: each LSItemContentTypes entry with its
# CFBundleTypeIconFile minus "DocIcon-", sorted.
di_mac_document_type_arts() {
  di_mac_target | awk '
    /^          - CFBundleTypeName: / { types = ""; next }
    /^            LSItemContentTypes: \[/ { types = $0; sub(/^.*\[/, "", types); sub(/\].*$/, "", types); gsub(/ /, "", types); next }
    /^            CFBundleTypeIconFile: / {
      icon = $2; sub(/^DocIcon-/, "", icon)
      n = split(types, t, ",")
      for (i = 1; i <= n; i++) print t[i] "=" icon
      types = ""
    }' | sort
}

# Each Mac document type shows the same art as its Quick Look thumbnail (ThumbnailArt.rows), so a
# swapped DocIcon-zip / DocIcon-7z fails here even though the set of names still matches.
test_doc_icons_mac_document_types_match_thumbnail_art() {
  local from_yml from_swift
  from_swift="$(di_thumbnail_art_rows)"
  [ "$(echo "$from_swift" | grep -c '=')" -eq 27 ] || { echo "expected 27 ThumbnailArt rows, got: $from_swift" >&2; return 1; }
  from_yml="$(di_mac_document_type_arts)"
  [ "$(echo "$from_yml" | grep -c '=')" -eq 27 ] || { echo "expected 27 Mac document type icons, got: $from_yml" >&2; return 1; }
  [ "$from_yml" = "$from_swift" ] \
    || { echo "project.yml type -> icon vs ThumbnailArt type -> art: $(diff <(echo "$from_yml") <(echo "$from_swift"))" >&2; return 1; }
}

test_doc_icons_info_plist_matches_project_yml() {
  local info="$DI_INFO_PLIST" n i v from_plist from_yml
  n="$(plutil -extract CFBundleDocumentTypes raw -o - "$info")"
  [ "$n" -eq 28 ] || { echo "expected 27 archive document types + $DI_DROP_TYPE, got $n" >&2; return 1; }
  from_plist="$(for ((i = 0; i < n; i++)); do
    v="$(plutil -extract "CFBundleDocumentTypes.$i.CFBundleTypeName" raw -o - "$info")"
    echo "$v=$(plutil -extract "CFBundleDocumentTypes.$i.CFBundleTypeIconFile" raw -o - "$info" 2>/dev/null)"
  done)"
  from_yml="$(di_mac_target | awk '
    /^          - CFBundleTypeName: / { if (name != "") print name "=" icon; name = $0; sub(/^ *- CFBundleTypeName: /, "", name); icon = "" }
    /^            CFBundleTypeIconFile: / { icon = $2 }
    /^        UTImportedTypeDeclarations:/ { if (name != "") print name "=" icon; name = "" }')"
  [ "$from_plist" = "$from_yml" ] || { echo "Info.plist vs project.yml: $(diff <(echo "$from_plist") <(echo "$from_yml"))" >&2; return 1; }
}

# The drop type is the only one for non-archives: a Viewer of public.item, rank None (never
# any type's handler), no NSDocumentClass (the Open panel stays archives only), no icon; every
# other type is an ArchiveDocument one, ranked, and lists no generic type. Info.plist and
# project.yml both.
test_doc_icons_mac_drop_type_is_rank_none() {
  local info="$DI_INFO_PLIST" generic='"public\.(item|data|content|folder|directory)"' entry n i name drops=0
  entry="$(di_mac_target | awk -v name="          - CFBundleTypeName: $DI_DROP_TYPE" '
    $0 == name { on = 1; print; next }
    on && (/^          - / || /^        [A-Za-z]/) { exit }
    on')"
  [ "$entry" = "          - CFBundleTypeName: $DI_DROP_TYPE
            CFBundleTypeRole: Viewer
            LSHandlerRank: None
            LSItemContentTypes: [public.item]" ] || { echo "project.yml drop type: $entry" >&2; return 1; }
  [ "$(di_mac_target | grep -cE '^            LSItemContentTypes: .*public\.(item|data|content|folder|directory) *[],]')" -eq 1 ] \
    || { echo "project.yml: a type besides $DI_DROP_TYPE lists a generic type" >&2; return 1; }
  n="$(plutil -extract CFBundleDocumentTypes raw -o - "$info")"
  for ((i = 0; i < n; i++)); do
    name="$(plutil -extract "CFBundleDocumentTypes.$i.CFBundleTypeName" raw -o - "$info")"
    if [ "$name" = "$DI_DROP_TYPE" ]; then
      drops=$((drops + 1))
      # plutil's JSON key order varies: compare sorted.
      [ "$(plutil -extract "CFBundleDocumentTypes.$i" json -o - "$info" | python3 -I -c 'import json, sys; print(json.dumps(json.load(sys.stdin), sort_keys=True))')" \
        = '{"CFBundleTypeName": "File or Folder", "CFBundleTypeRole": "Viewer", "LSHandlerRank": "None", "LSItemContentTypes": ["public.item"]}' ] \
        || { echo "Info.plist drop type: $(plutil -extract "CFBundleDocumentTypes.$i" json -o - "$info")" >&2; return 1; }
    else
      [ "$(plutil -extract "CFBundleDocumentTypes.$i.NSDocumentClass" raw -o - "$info")" = '$(PRODUCT_MODULE_NAME).ArchiveDocument' ] \
        || { echo "Info.plist $name: not an ArchiveDocument type" >&2; return 1; }
      case "$(plutil -extract "CFBundleDocumentTypes.$i.LSHandlerRank" raw -o - "$info")" in
        Default|Alternate) ;; *) echo "Info.plist $name: rank is not Default or Alternate" >&2; return 1 ;;
      esac
      ! grep -Eq "$generic" <<<"$(plutil -extract "CFBundleDocumentTypes.$i.LSItemContentTypes" json -o - "$info")" \
        || { echo "Info.plist $name lists a generic type" >&2; return 1; }
    fi
  done
  [ "$drops" -eq 1 ] || { echo "Info.plist: $drops $DI_DROP_TYPE entries" >&2; return 1; }
}

# test_doc_icons_mac_drop_type_is_rank_none fails on a mutated copy of Info.plist: the drop type
# ranked Alternate (Kernir would become an Open With choice for every file), or given
# ArchiveDocument as its class (the Open panel would take every file). The unmutated copy passes,
# so each failure is the mutation's.
test_doc_icons_mac_drop_type_check_rejects_mutations() {
  local t n i drop="" mutation
  t="$(mktemp -d)" || return 1
  # Never rm -rf an empty path, / or the repo (run.sh sets cwd to REPO_ROOT).
  case "$t" in ""|/|"$REPO_ROOT"|"$PWD"|"$HOME") echo "refusing unsafe temp dir '$t'" >&2; return 1 ;; esac
  DI_MUTATION_TMP="$t"
  trap 'rm -rf "$DI_MUTATION_TMP"' EXIT   # each test runs in its own process (run.sh)
  n="$(plutil -extract CFBundleDocumentTypes raw -o - "$DI_INFO_PLIST")"
  for ((i = 0; i < n; i++)); do
    [ "$(plutil -extract "CFBundleDocumentTypes.$i.CFBundleTypeName" raw -o - "$DI_INFO_PLIST")" = "$DI_DROP_TYPE" ] && drop="$i"
  done
  [ -n "$drop" ] || { echo "Info.plist has no $DI_DROP_TYPE entry" >&2; return 1; }
  cp "$DI_INFO_PLIST" "$t/unmutated.plist"
  ( DI_INFO_PLIST="$t/unmutated.plist"; test_doc_icons_mac_drop_type_is_rank_none ) \
    || { echo "the unmutated copy fails" >&2; return 1; }
  cp "$DI_INFO_PLIST" "$t/alternate.plist"
  plutil -replace "CFBundleDocumentTypes.$drop.LSHandlerRank" -string Alternate "$t/alternate.plist"
  cp "$DI_INFO_PLIST" "$t/class.plist"
  plutil -insert "CFBundleDocumentTypes.$drop.NSDocumentClass" -string '$(PRODUCT_MODULE_NAME).ArchiveDocument' "$t/class.plist"
  for mutation in alternate class; do
    if ( DI_INFO_PLIST="$t/$mutation.plist"; test_doc_icons_mac_drop_type_is_rank_none ) 2>/dev/null; then
      echo "the drop type check accepts the $mutation mutation" >&2; return 1
    fi
  done
}

# Runs make-doc-icons.sh under a profile that mirrors the one Xcode generates for user
# script sandboxing (ENABLE_USER_SCRIPT_SANDBOXING; template strings identical in Xcode
# 26.6 and 27.2 SWBTaskConstruction): build dirs and SRCROOT denied, TEMP_DIR allowed,
# DERIVED_FILE_DIR denied again (Xcode 27.2 enforces this), declared inputs readable,
# declared outputs read+write as literals (the strict case). Two masters keep it fast.
# test_doc_icons_mac_document_types_use_masters fails on a mutated copy of project.yml: an archive
# type (7z) without its icon. The unmutated copy passes, so the failure is the mutation's.
test_doc_icons_project_yml_icon_check_rejects_a_missing_icon() {
  local t
  t="$(mktemp -d)" || return 1
  # Never rm -rf an empty path, / or the repo (run.sh sets cwd to REPO_ROOT).
  case "$t" in ""|/|"$REPO_ROOT"|"$PWD"|"$HOME") echo "refusing unsafe temp dir '$t'" >&2; return 1 ;; esac
  DI_MUTATION_TMP="$t"
  trap 'rm -rf "$DI_MUTATION_TMP"' EXIT   # each test runs in its own process (run.sh)
  cp "$DI_PROJECT_YML" "$t/unmutated.yml"
  ( DI_PROJECT_YML="$t/unmutated.yml"; test_doc_icons_mac_document_types_use_masters ) \
    || { echo "the unmutated copy fails" >&2; return 1; }
  grep -vx '            CFBundleTypeIconFile: DocIcon-7z' "$DI_PROJECT_YML" > "$t/no-icon.yml"
  [ "$(wc -l < "$t/no-icon.yml")" -lt "$(wc -l < "$DI_PROJECT_YML")" ] || { echo "no 7z icon line to remove" >&2; return 1; }
  if ( DI_PROJECT_YML="$t/no-icon.yml"; test_doc_icons_mac_document_types_use_masters ) 2>/dev/null; then
    echo "the icon check accepts an archive type without an icon" >&2; return 1
  fi
}

test_doc_icons_script_writes_only_sandbox_allowed_paths() {
  local t src obj tmp derived res sb a in_list out_list rc=0
  [ -x /usr/bin/sandbox-exec ] || { echo "/usr/bin/sandbox-exec missing or not executable" >&2; return 1; }
  t="$(mktemp -d)" || return 1
  t="$(cd "$t" && pwd -P)" || return 1   # real path: the sandbox matches /private/var, not /var
  # Never rm -rf an empty path, / or the repo (run.sh sets cwd to REPO_ROOT).
  case "$t" in ""|/|"$REPO_ROOT"|"$PWD"|"$HOME") echo "refusing unsafe temp dir '$t'" >&2; return 1 ;; esac
  DI_SANDBOX_TMP="$t"
  trap 'rm -rf "$DI_SANDBOX_TMP"' EXIT   # each test runs in its own process (run.sh); covers set -e exits
  src="$t/src" obj="$t/obj" tmp="$t/obj/KernirMac.build"
  derived="$tmp/DerivedSources" res="$t/products/Lutik.app/Contents/Resources"
  mkdir -p "$src/scripts/brand" "$derived" "$res"
  cp "$DI_BRAND/make-doc-icons.sh" "$src/scripts/brand/"
  in_list="$tmp/inputs.xcfilelist" out_list="$tmp/outputs.xcfilelist"
  echo "$src/scripts/brand/make-doc-icons.sh" > "$in_list"; : > "$out_list"
  for a in zip 7z; do
    cp "$REPO_ROOT/$DI_ASSETS/$a.imageset/$a-1024.png" "$src/$a-1024.png"
    echo "$src/$a-1024.png" >> "$in_list"; echo "$res/DocIcon-$a.icns" >> "$out_list"
  done
  sb="$t/script.sb"
  {
    echo '(version 1)(allow default)(disable-callouts)'
    echo '(import "/System/Library/Sandbox/Profiles/bsd.sb")'
    echo "(deny file-read* file-write* (subpath \"$src\") (subpath \"$obj\") (subpath \"$t/products\"))"
    echo "(allow file-read* file-write* (subpath \"$tmp\"))"
    echo "(deny file-read* file-write* (subpath \"$derived\"))"
    echo "(allow file-read* (literal \"$src\"))"
    for a in "$t" "$src" "$src/scripts" "$src/scripts/brand" "$t/products" "$t/products/Lutik.app" \
      "$t/products/Lutik.app/Contents" "$res"; do echo "(allow file-read* (literal \"$a\"))"; done
    while IFS= read -r a; do echo "(allow file-read* (literal \"$a\"))"; done < "$in_list"
    while IFS= read -r a; do echo "(allow file-read* file-write* (literal \"$a\"))"; done < "$out_list"
  } > "$sb"
  SCRIPT_INPUT_FILE_LIST_0="$in_list" SCRIPT_OUTPUT_FILE_LIST_0="$out_list" \
    DERIVED_FILE_DIR="$derived" TEMP_DIR="$tmp" \
    sandbox-exec -f "$sb" /bin/bash "$src/scripts/brand/make-doc-icons.sh" > "$t/out.log" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then echo "script failed in sandbox (rc=$rc): $(tail -5 "$t/out.log")" >&2
  elif [ "$(ls "$res")" != "$(printf 'DocIcon-7z.icns\nDocIcon-zip.icns')" ]; then
    echo "unexpected Resources contents: $(ls -A "$res")" >&2; rc=1
  elif [ -n "$(ls -A "$derived")" ]; then echo "DerivedSources not empty" >&2; rc=1
  elif [ -n "$(ls -A "$tmp" | grep -v -x -e DerivedSources -e '.*\.xcfilelist')" ]; then
    echo "work dir left: $(ls -A "$tmp")" >&2; rc=1
  fi
  rm -rf "$t"; trap - EXIT
  return "$rc"
}
