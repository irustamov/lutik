#!/bin/bash
# Minimal bash test runner. Each test_* function runs in its own subshell.
# Usage: scripts/tests/run.sh [--help] (--all | test_name ...)
set -euo pipefail

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'USAGE'
Usage: scripts/tests/run.sh test_name ...
       scripts/tests/run.sh --all

Runs the named test_* functions from scripts/tests/test_*.sh, or with --all every one
(the full suite, including the KernirMac archive). An empty list (no args, or only blank
args such as a failed "$(...)" expansion) is refused with exit 2; --all cannot be
combined with names.
Each test runs in a subshell and prints PASS/FAIL. Exits non-zero on any FAIL.
Tests listed in KNOWN_FAIL print XFAIL (or XPASS when fixed) and do not fail the suite.
USAGE
  exit 0
fi

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
cd "$REPO_ROOT"
export REPO_ROOT

# Select what to run. The full suite (it archives KernirMac) only runs with an explicit --all; an empty
# list (no args, or only blank args from a failed "$(...)" expansion) is refused. Blank args are dropped.
# Test seam: RUN_SH_DRY_RUN=1 prints the selection and exits 3 before sourcing or running anything.
if [ "${1:-}" != "--one" ]; then
  all=0; names=()
  for a in "$@"; do
    if [ "$a" = "--all" ]; then all=1
    elif [[ "$a" =~ ^[[:space:]]*$ ]]; then :
    else names+=("$a"); fi
  done
  if [ "$all" = 1 ] && [ "${#names[@]}" -gt 0 ]; then
    echo "run.sh: --all cannot be combined with test names (${names[*]}). Use --all alone, or name the tests." >&2
    exit 2
  fi
  if [ "$all" = 0 ] && [ "${#names[@]}" -eq 0 ]; then
    echo "run.sh: no test names given (empty list refused). Name the tests, or pass --all to run the full suite (including the KernirMac archive)." >&2
    exit 2
  fi
  if [ "${RUN_SH_DRY_RUN:-}" = 1 ]; then
    if [ "$all" = 1 ]; then echo "DRY-RUN all"; else echo "DRY-RUN names: ${names[*]}"; fi
    exit 3   # distinct non-zero code: a dry run must never look like a passing run
  fi
fi

# KNOWN_FAIL entries: "test_name|reason"
KNOWN_FAIL=(
)

known_fail_reason() {
  local entry
  for entry in ${KNOWN_FAIL[@]+"${KNOWN_FAIL[@]}"}; do
    if [ "${entry%%|*}" = "$1" ]; then
      printf '%s' "${entry#*|}"
      return 0
    fi
  done
  return 1
}

# Child mode: run one test in a fresh process so errexit is fully effective
# (bash disables errexit inside any command on the left of ||, &&, if).
if [ "${1:-}" = "--one" ]; then
  LSREGISTER="${LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
  export LSREGISTER
  for f in "$TESTS_DIR"/test_*.sh; do
    # shellcheck source=/dev/null
    . "$f"
  done
  set -euo pipefail
  "$2"
  exit 0
fi

# LSREGISTER from the environment is a test seam (test_run_sh_cleanup_unregisters_both_app_names).
LSREGISTER="${LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
cleanup_build() {
  local app
  while IFS= read -r app; do
    [ -n "$app" ] && "$LSREGISTER" -u "$app" >/dev/null 2>&1 || true
  # Lutik.app since the rename; Kernir.app in build folders from before it.
  done < <(find "$REPO_ROOT/build" -type d \( -name 'Lutik.app' -o -name 'Kernir.app' \) 2>/dev/null)
  rm -rf "$REPO_ROOT/build"
}
export LSREGISTER
trap cleanup_build EXIT

for f in "$TESTS_DIR"/test_*.sh; do
  # shellcheck source=/dev/null
  . "$f"
done

if [ "$all" = 1 ]; then
  while IFS= read -r n; do names+=("$n"); done < <(sed -n 's/^\(test_[A-Za-z0-9_]*\)().*/\1/p' "$TESTS_DIR"/test_*.sh)
fi

pass=0; fail=0; xfail=0; xpass=0
for t in "${names[@]}"; do
  rc=0
  bash "$TESTS_DIR/run.sh" --one "$t" || rc=$?
  if reason="$(known_fail_reason "$t")"; then
    if [ "$rc" -eq 0 ]; then
      echo "XPASS $t — remove from KNOWN_FAIL"; xpass=$((xpass + 1))
    else
      echo "XFAIL $t: $reason"; xfail=$((xfail + 1))
    fi
  elif [ "$rc" -eq 0 ]; then
    echo "PASS $t"; pass=$((pass + 1))
  else
    echo "FAIL $t"; fail=$((fail + 1))
  fi
done

echo "passed=$pass failed=$fail xfail=$xfail xpass=$xpass"
[ "$fail" -eq 0 ]
