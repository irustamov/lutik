#!/bin/bash
# Tests for the build stamp: scripts/build/stamp-version.sh (xcodegen's preGenCommand) writes
# App/Version.generated.xcconfig, which App/Version.xcconfig (project-level config, project.yml
# configFiles) includes. Runs the script in throwaway git repos; static checks on project.yml.
# Sourced by run.sh.

SV_SCRIPT="$REPO_ROOT/scripts/build/stamp-version.sh"

# A throwaway repo with the script at scripts/build/ and $1 commits. Prints its path.
sv_repo() {
  local r i
  r="$(mktemp -d "${TMPDIR:-/tmp}/stamp-version-test.XXXXXX")"
  mkdir -p "$r/repo/scripts/build" "$r/repo/App"
  cp "$SV_SCRIPT" "$r/repo/scripts/build/"
  : > "$r/repo/App/.keep"
  git -C "$r/repo" init --quiet && git -C "$r/repo" add scripts App   # in the first commit (clones get them)
  for ((i = 1; i <= $1; i++)); do
    git -C "$r/repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit --quiet --allow-empty -m "c$i"
  done
  printf '%s\n' "$r/repo"
}

sv_value() { sed -n "s/^$1 = //p" "$2/App/Version.generated.xcconfig"; }

test_stamp_version_writes_count_and_sha() {
  local r; r="$(sv_repo 3)"; trap "rm -rf '${r%/repo}'" EXIT
  bash "$r/scripts/build/stamp-version.sh" 2>/dev/null
  [ "$(sv_value CURRENT_PROJECT_VERSION "$r")" = 3 ]
  [ "$(sv_value KERNIR_GIT_COMMIT "$r")" = "$(git -C "$r" rev-parse --short=7 HEAD)" ]
  git -C "$r" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit --quiet --allow-empty -m c4
  bash "$r/scripts/build/stamp-version.sh" 2>/dev/null
  [ "$(sv_value CURRENT_PROJECT_VERSION "$r")" = 4 ]
  [ "$(sv_value KERNIR_GIT_COMMIT "$r")" = "$(git -C "$r" rev-parse --short=7 HEAD)" ]
}

test_stamp_version_runs_from_any_directory() {
  local r; r="$(sv_repo 2)"; trap "rm -rf '${r%/repo}'" EXIT
  ( cd / && bash "$r/scripts/build/stamp-version.sh" 2>/dev/null )
  [ "$(sv_value CURRENT_PROJECT_VERSION "$r")" = 2 ]
}

# A shallow clone's count is wrong: no build number (the default 1 applies), the SHA still goes in.
test_stamp_version_shallow_clone_keeps_default_build() {
  local r s err
  r="$(sv_repo 3)"; trap "rm -rf '${r%/repo}'" EXIT; s="$(dirname "$r")/shallow"
  git clone --quiet --depth 1 "file://$r" "$s"
  err="$(bash "$s/scripts/build/stamp-version.sh" 2>&1 >/dev/null)"
  grep -q 'shallow' <<<"$err"
  if grep -q '^CURRENT_PROJECT_VERSION' "$s/App/Version.generated.xcconfig"; then echo "shallow: count stamped" >&2; return 1; fi
  [ "$(sv_value KERNIR_GIT_COMMIT "$s")" = "$(git -C "$r" rev-parse --short=7 HEAD)" ]
}

# Outside git (a source archive): no generated file, so the committed defaults (1, dev) apply.
test_stamp_version_without_git_removes_stale_stamp() {
  local d err
  d="$(mktemp -d "${TMPDIR:-/tmp}/stamp-version-test.XXXXXX")"; trap "rm -rf '$d'" EXIT; mkdir -p "$d/src/scripts/build" "$d/src/App"
  cp "$SV_SCRIPT" "$d/src/scripts/build/"
  echo 'CURRENT_PROJECT_VERSION = 99' > "$d/src/App/Version.generated.xcconfig"
  err="$(GIT_CEILING_DIRECTORIES="$d" bash "$d/src/scripts/build/stamp-version.sh" 2>&1 >/dev/null)"
  grep -q 'not a git' <<<"$err"
  [ ! -e "$d/src/App/Version.generated.xcconfig" ]
}

test_stamp_version_project_wiring() {
  local yml="$REPO_ROOT/project.yml" cfg="$REPO_ROOT/App/Version.xcconfig"
  grep -q '^  preGenCommand: /bin/bash scripts/build/stamp-version.sh$' "$yml"
  # Project-level settings would override the project xcconfig: the build number lives only there.
  if grep -q 'CURRENT_PROJECT_VERSION:' "$yml"; then echo "project.yml sets CURRENT_PROJECT_VERSION" >&2; return 1; fi
  [ "$(grep -c '^        CFBundleVersion: \$(CURRENT_PROJECT_VERSION)$' "$yml")" -eq 6 ]
  [ "$(grep -c '^        KernirGitCommit: \$(KERNIR_GIT_COMMIT)' "$yml")" -eq 2 ]
  grep -q '^  Debug: App/Version.xcconfig$' "$yml"
  grep -q '^  Release: App/Version.xcconfig$' "$yml"
  grep -q '^CURRENT_PROJECT_VERSION = 1$' "$cfg"
  grep -q '^KERNIR_GIT_COMMIT = dev$' "$cfg"
  [ "$(tail -n 1 "$cfg")" = '#include? "Version.generated.xcconfig"' ]
  git -C "$REPO_ROOT" check-ignore -q App/Version.generated.xcconfig
}
