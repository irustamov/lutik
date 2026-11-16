#!/bin/bash
# Tests for scripts/tests/run.sh argument handling (empty list refused, --all explicit). Sourced by run.sh.
# Each call runs a COPY of run.sh in a fresh temp dir (no test_*.sh beside it, no build tree) with
# RUN_SH_DRY_RUN=1: run.sh prints its selection and exits 3 before running anything (no suite, no archive,
# no xcodegen/xcodebuild). If the dry-run seam regressed, the copy has no tests to source and fails harmlessly.

# rs_run <args...>: sets RS_RC, RS_OUT, RS_ERR. Callers pass literal args, or deliberately none (safe: dry run).
rs_run() {
  local d; d=$(mktemp -d)
  trap "rm -rf $(printf %q "$d")" EXIT   # fallback; the explicit rm below is the normal path
  mkdir -p "$d/scripts/tests"
  cp "$REPO_ROOT/scripts/tests/run.sh" "$d/scripts/tests/run.sh"
  RS_RC=0
  RS_OUT=$(RUN_SH_DRY_RUN=1 bash "$d/scripts/tests/run.sh" "$@" 2>"$d/err") || RS_RC=$?
  RS_ERR=$(cat "$d/err")
  rm -rf "$d"
}

rs_refused() {
  [ "$RS_RC" -eq 2 ] || { echo "rc=$RS_RC, want 2 ($RS_ERR)" >&2; return 1; }
  [ -z "$RS_OUT" ] || { echo "selected tests despite refusal: $RS_OUT" >&2; return 1; }
  grep -q -- '--all' <<<"$RS_ERR" || { echo "stderr does not name --all: $RS_ERR" >&2; return 1; }
}

# rs_selected <want stdout>: dry-run selection (exit 3).
rs_selected() {
  [ "$RS_RC" -eq 3 ] && [ "$RS_OUT" = "$1" ] || { echo "rc=$RS_RC out=[$RS_OUT] err=[$RS_ERR], want rc=3 out=[$1]" >&2; return 1; }
}

test_run_sh_refuses_no_args() {
  rs_run
  rs_refused || return 1
  grep -q 'KernirMac archive' <<<"$RS_ERR"
}

test_run_sh_refuses_blank_args() {
  rs_run ""; rs_refused || return 1
  rs_run " "; rs_refused || return 1
  rs_run "" " " $'\t'; rs_refused || return 1
  rs_run "$(true)"; rs_refused   # failed/empty "$(...)" expansion
}

test_run_sh_drops_blank_args_runs_real_names() {
  rs_run "" test_alpha " " test_beta
  rs_selected "DRY-RUN names: test_alpha test_beta" || return 1
  rs_run test_alpha
  rs_selected "DRY-RUN names: test_alpha"
}

test_run_sh_all_selects_full_suite() {
  rs_run --all
  rs_selected "DRY-RUN all" || return 1
  rs_run --all ""
  rs_selected "DRY-RUN all"
}

test_run_sh_all_with_names_is_an_error() {
  rs_run --all test_alpha
  [ "$RS_RC" -eq 2 ] && [ -z "$RS_OUT" ] || { echo "rc=$RS_RC out=[$RS_OUT]" >&2; return 1; }
  grep -q -- '--all' <<<"$RS_ERR" || return 1
  rs_run test_alpha --all
  [ "$RS_RC" -eq 2 ] && [ -z "$RS_OUT" ] || { echo "rc=$RS_RC out=[$RS_OUT]" >&2; return 1; }
}

test_run_sh_cleanup_unregisters_both_app_names() {
  # run.sh's exit cleanup unregisters Lutik.app and the pre-rename Kernir.app under build/ (run.sh:85).
  # Runs a COPY of run.sh in a temp tree with one trivial test and a fake lsregister (LSREGISTER seam).
  local d; d=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$d'; trap - RETURN" RETURN
  mkdir -p "$d/scripts/tests" "$d/build/x/Lutik.app" "$d/build/y/Kernir.app" "$d/build/z/Other.app"
  cp "$REPO_ROOT/scripts/tests/run.sh" "$d/scripts/tests/run.sh"
  printf 'test_noop() { true; }\n' > "$d/scripts/tests/test_noop.sh"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$d/log" > "$d/lsregister"
  chmod +x "$d/lsregister"
  LSREGISTER="$d/lsregister" bash "$d/scripts/tests/run.sh" test_noop >/dev/null
  # The scripts dir is physically under $d; resolve symlinks (macOS /var -> /private/var) like run.sh does.
  local real; real=$(cd "$d" && pwd)
  grep -qxF -- "-u $real/build/x/Lutik.app" "$d/log" || { cat "$d/log" >&2; return 1; }
  grep -qxF -- "-u $real/build/y/Kernir.app" "$d/log" || { cat "$d/log" >&2; return 1; }
  [ "$(wc -l < "$d/log" | tr -d ' ')" -eq 2 ] || { cat "$d/log" >&2; return 1; }
  [ ! -e "$d/build" ]
}
