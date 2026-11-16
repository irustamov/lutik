#!/bin/bash
# Prepare signing credentials on a CI runner.
#   import-signing.sh import    create temp keychain, import Developer ID p12, write the .p8
#   import-signing.sh cleanup   delete the keychain, restore the search list, remove the .p8
# Env (import): DEVELOPER_ID_P12_BASE64, DEVELOPER_ID_P12_PASSWORD, ASC_KEY_P8_BASE64, ASC_KEY_ID
# Env (both): RUNNER_TEMP (default: a mktemp dir), GITHUB_ENV (optional)
# No tracing is enabled and no secret is printed.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: import-signing.sh import|cleanup

import   Needs DEVELOPER_ID_P12_BASE64, DEVELOPER_ID_P12_PASSWORD, ASC_KEY_P8_BASE64, ASC_KEY_ID.
cleanup  Removes the temporary keychain and the .p8, and restores the keychain search list.
USAGE
}

die() { printf '[import-signing] error: %s\n' "$*" >&2; exit 1; }

: "${RUNNER_TEMP:=$(mktemp -d)}"
KEYCHAIN="$RUNNER_TEMP/signing.keychain-db"
ORIG_LIST="$RUNNER_TEMP/keychains.orig"

# Print the user keychain search list, one unquoted path per line.
current_list() {
  security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//'
}

do_import() {
  local v
  for v in DEVELOPER_ID_P12_BASE64 DEVELOPER_ID_P12_PASSWORD ASC_KEY_P8_BASE64 ASC_KEY_ID; do
    [ -n "${!v:-}" ] || die "$v is not set"
  done
  case "$ASC_KEY_ID" in
    *[!A-Za-z0-9]*) die "ASC_KEY_ID must be alphanumeric" ;;
  esac

  local pw
  pw="$(openssl rand -base64 24)"
  echo "::add-mask::$pw"

  # Remember the search list so cleanup can restore it exactly.
  current_list > "$ORIG_LIST"

  local p12="$RUNNER_TEMP/developer-id.p12"
  ( umask 077; printf '%s' "$DEVELOPER_ID_P12_BASE64" | base64 -D > "$p12" )

  security create-keychain -p "$pw" "$KEYCHAIN"
  security set-keychain-settings -lut 21600 "$KEYCHAIN"
  security unlock-keychain -p "$pw" "$KEYCHAIN"
  security import "$p12" -k "$KEYCHAIN" -f pkcs12 -P "$DEVELOPER_ID_P12_PASSWORD" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null
  rm -f "$p12"
  security set-key-partition-list -S apple-tool:,apple: -s -k "$pw" "$KEYCHAIN" >/dev/null

  local existing=()
  local line
  while IFS= read -r line; do
    [ -n "$line" ] && existing+=("$line")
  done < "$ORIG_LIST"
  if [ "${#existing[@]}" -gt 0 ]; then
    security list-keychains -d user -s "$KEYCHAIN" "${existing[@]}"
  else
    security list-keychains -d user -s "$KEYCHAIN"
  fi

  local p8="$RUNNER_TEMP/AuthKey_${ASC_KEY_ID}.p8"
  ( umask 077; printf '%s' "$ASC_KEY_P8_BASE64" | base64 -D > "$p8" )
  chmod 600 "$p8"
  if [ -n "${GITHUB_ENV:-}" ]; then
    echo "ASC_KEY_PATH=$p8" >> "$GITHUB_ENV"
  fi
  echo "[import-signing] signing keychain ready"
}

do_cleanup() {
  local lines=() line
  if [ -f "$ORIG_LIST" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && lines+=("$line")
    done < "$ORIG_LIST"
  else
    # No saved list: drop only our keychain from the current one.
    while IFS= read -r line; do
      [ -n "$line" ] && [ "$line" != "$KEYCHAIN" ] && lines+=("$line")
    done < <(current_list)
  fi
  if [ "${#lines[@]}" -gt 0 ]; then
    security list-keychains -d user -s "${lines[@]}" >/dev/null 2>&1 || true
  fi
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  rm -f "$KEYCHAIN" "$ORIG_LIST" "$RUNNER_TEMP/developer-id.p12"
  if [ -n "${ASC_KEY_ID:-}" ]; then
    rm -f "$RUNNER_TEMP/AuthKey_${ASC_KEY_ID}.p8"
  fi
  rm -f "$RUNNER_TEMP"/AuthKey_*.p8
  echo "[import-signing] cleaned up"
}

case "${1:-}" in
  import) do_import ;;
  cleanup) do_cleanup ;;
  --help|-h) usage ;;
  *) usage >&2; exit 2 ;;
esac
