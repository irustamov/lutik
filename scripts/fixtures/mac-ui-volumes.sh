#!/bin/sh
# Disk images for OwnerChecksUITests' full-disk and read-only tests. Xcode signs the macOS UI
# test runner with app-sandbox (whatever ENABLE_APP_SANDBOX says), so the runner can't run
# hdiutil or write outside its container; this script does that part outside the runner.
#   attach DIR   creates and attaches two images with -nobrowse (Finder never shows them):
#                DIR/full      20 MB HFS+ volume holding deflate.zip, filled to the last byte
#                DIR/readonly  read-only volume holding deflate.zip
#   detach DIR   detaches both images and removes DIR
# Pass DIR to the tests as TEST_RUNNER_KERNIR_MAC_UI_VOLUMES=DIR; without it those two tests
# skip. Run detach after the tests, also when they fail. Neither command drives the desktop.
# Usage: scripts/fixtures/mac-ui-volumes.sh attach|detach DIR
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
command=${1:-}
dir=${2:-}
if [ -z "$command" ] || [ -z "$dir" ]; then
    echo "usage: $0 attach|detach DIR" >&2
    exit 2
fi

detach_all() {
    [ -d "$dir" ] || return 0
    real=$(cd "$dir" && pwd -P)
    for mountPoint in "$real/full" "$real/readonly"; do
        if mount | grep -qF " on $mountPoint ("; then
            hdiutil detach "$mountPoint" -force -quiet
        fi
    done
}

case "$command" in
attach)
    detach_all # leftovers from an earlier run
    rm -rf "$dir"
    mkdir -p "$dir/full" "$dir/readonly" "$dir/source"
    dir=$(cd "$dir" && pwd -P)

    hdiutil create -size 20m -fs HFS+ -volname KernirFull -quiet "$dir/full.dmg"
    hdiutil attach "$dir/full.dmg" -nobrowse -noautoopen -mountpoint "$dir/full" -quiet
    cp "$ROOT/Fixtures/zip/deflate.zip" "$dir/full/"
    # dd stops with "No space left on device", which is the point. bs=1m leaves up to 1 MiB
    # free, enough for a small save, so a second pass fills the rest 512 bytes at a time.
    dd if=/dev/zero of="$dir/full/filler" bs=1m 2>/dev/null || true
    dd if=/dev/zero bs=512 2>/dev/null >>"$dir/full/filler" || true
    free=$(df -k "$dir/full" | awk 'NR == 2 { print $4 }')
    if [ "$free" -gt 0 ]; then
        echo "mac-ui-volumes: $dir/full still has $free KiB free" >&2
        exit 1
    fi

    cp "$ROOT/Fixtures/zip/deflate.zip" "$dir/source/"
    hdiutil create -srcfolder "$dir/source" -format UDZO -fs HFS+ -volname KernirReadOnly -quiet \
        "$dir/readonly.dmg"
    hdiutil attach "$dir/readonly.dmg" -readonly -nobrowse -noautoopen -mountpoint "$dir/readonly" -quiet
    echo "$dir"
    ;;
detach)
    detach_all
    rm -rf "$dir"
    ;;
*)
    echo "usage: $0 attach|detach DIR" >&2
    exit 2
    ;;
esac
