#!/bin/bash
# Xcode Run Script phase "Document icons" (KernirMac only). Builds one Mac document icon
# (.icns, 10 representations 16-512 @1x/@2x) per 1024 px master, straight into the app's
# Resources. The .icns files are build products only, never committed.
# Inputs / outputs are declared in doc-icons-inputs.xcfilelist / doc-icons-outputs.xcfilelist;
# output DocIcon-<art>.icns pairs with master <art>-1024.png. Uses only sips and iconutil.
set -euo pipefail

: "${SCRIPT_INPUT_FILE_LIST_0:?run from Xcode}" "${SCRIPT_OUTPUT_FILE_LIST_0:?run from Xcode}"
: "${TEMP_DIR:?run from Xcode}"
die() { echo "error: make-doc-icons: $*" >&2; exit 1; }

masters=() outputs=()
while IFS= read -r f; do case "$f" in *-1024.png) masters+=("$f") ;; esac; done < "$SCRIPT_INPUT_FILE_LIST_0"
while IFS= read -r f; do [ -n "$f" ] && outputs+=("$f"); done < "$SCRIPT_OUTPUT_FILE_LIST_0"
[ "${#masters[@]}" -gt 0 ] || die "no masters in the input file list"
[ "${#masters[@]}" -eq "${#outputs[@]}" ] || die "${#masters[@]} masters but ${#outputs[@]} outputs"

# Scratch under TEMP_DIR (the target's temp dir): Xcode's user-script sandbox allows writes
# below TEMP_DIR but denies DERIVED_FILE_DIR and every other undeclared build path.
work="$TEMP_DIR/doc-icons"
rm -rf "$work"; mkdir -p "$work/src"
for m in "${masters[@]}"; do
  [ -f "$m" ] || die "master missing: $m"
  art="$(basename "$m" -1024.png)"
  w="$(sips -g pixelWidth "$m" | awk '/pixelWidth/ {print $2}')"
  h="$(sips -g pixelHeight "$m" | awk '/pixelHeight/ {print $2}')"
  [ "$w" = 1024 ] && [ "$h" = 1024 ] || die "$m is ${w}x${h}, expected 1024x1024"
  cp "$m" "$work/src/$art.png"
done

# One sips process per pixel size, all masters at once.
for px in 16 32 64 128 256 512; do
  mkdir -p "$work/$px"
  sips -z "$px" "$px" "$work"/src/*.png --out "$work/$px" >/dev/null
done

for o in "${outputs[@]}"; do
  art="$(basename "$o" .icns)"; art="${art#DocIcon-}"
  [ -f "$work/src/$art.png" ] || die "no master for output $o"
  set="$work/$art.iconset"; mkdir -p "$set"
  for pt in 16 32 128 256 512; do
    cp "$work/$pt/$art.png" "$set/icon_${pt}x${pt}.png"
    if [ "$pt" = 512 ]; then cp "$work/src/$art.png" "$set/icon_512x512@2x.png"
    else cp "$work/$((pt * 2))/$art.png" "$set/icon_${pt}x${pt}@2x.png"; fi
  done
  mkdir -p "$(dirname "$o")"
  iconutil -c icns -o "$o" "$set" || die "iconutil failed for $art"
done
rm -rf "$work"
