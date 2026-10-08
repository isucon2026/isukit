#!/bin/bash
# F6 (labelled measurement commits): ship --measure's git trailer, the retroactive
# `isukit measure` note, measure_commits() (the union-minus-reverted the rest of F6
# is built on), and its two call sites — finalize_measure_guard and final strip's
# new first section. Sources ../isukit (ISUKIT_SOURCED=1 skips main), stubs
# gh/rsh/say/warn, and drives cmd_ship / cmd_measure / cmd_measures /
# finalize_measure_guard / cmd_final_strip against a real throwaway git repo —
# notes and reverts need real git plumbing, a mock cannot stand in for it.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERBOSE=0
for a in "$@"; do [ "$a" = "-v" ] && VERBOSE=1; done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/isukit-measure.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK" || exit 2

# shellcheck disable=SC2034  # read by the sourced isukit
ISUKIT_SOURCED=1
# shellcheck source=../isukit
. "$HERE/../isukit"
set +e +u +o pipefail   # isukit's own strict mode; the harness checks by hand

CALLS="$WORK/calls"
rsh() { printf '%s %s\n' "$1" "${*:2}" >> "$CALLS"; return 0; }
rsh_stdin() { cat >/dev/null; printf '%s stdin\n' "$1" >> "$CALLS"; return 0; }
say()  { printf '%s\n' "$*" >&2; }
warn() { printf 'warn: %s\n' "$*" >> "$CALLS"; }
gh()   { return 1; } # no real gh here: repo-visibility always warns, never fails

setup_repo() { # fresh, ISOLATED git repo with one committed file, and the isukit state ship/finalize/final-strip need
  local d
  d="$(mktemp -d "$WORK/repo.XXXXXX")"
  cd "$d" || exit 2
  git init -q
  git config user.email t@test.local
  git config user.name test
  mkdir -p .isukit
  cat > .isukit/config <<'EOF'
APP=local
BENCH=local
BENCH_MODE=manual
BENCH_CMD=''
SSH_OPTS=''
EXTRA_UNITS=''
EXTRA_HOSTS=''
EOF
  : > isukit.conf
  printf '.isukit/\n' > .gitignore
  printf 'base\n' > base.txt
  git add .gitignore isukit.conf base.txt
  git commit -q -m base
  : > "$CALLS"
}

TOTAL=0; PASSED=0; FAILED=""; ERR=""
check() { [ "$@" ] || ERR="$ERR
    failed: [ $* ]"; }
case_() {
  TOTAL=$((TOTAL+1)); ERR=""
  ( "$2" ; printf '%s' "$ERR" > "$WORK/err" )
  ERR="$(cat "$WORK/err" 2>/dev/null)"
  if [ -z "$ERR" ]; then PASSED=$((PASSED+1)); echo "PASS  $1"
  else FAILED="$FAILED $1"; echo "FAIL  $1$ERR"; fi
  [ "$VERBOSE" = 1 ] && sed 's/^/      | /' "$CALLS"
  return 0
}

t_ship_measure_trailer_found() {
  setup_repo
  printf 'instrumentation\n' >> base.txt
  local rc
  ( cmd_ship --no-check --measure "add instrumentation" ) >/dev/null 2>&1; rc=$?
  check "$rc" = 0
  local body
  body="$(git log -1 --format=%B HEAD)"
  check -n "$(git interpret-trailers --parse <<< "$body" | grep -F 'Isukit-Measure: true')"
  check -n "$(cmd_measures 2>&1 | grep -F 'add instrumentation')"
}

t_measure_sha_and_measures_listing() {
  setup_repo
  printf 'plain\n' >> base.txt
  ( cmd_ship --no-check "plain change" ) >/dev/null 2>&1
  local sha rc
  sha=$(git rev-parse HEAD)
  ( cmd_measure "$sha" ) >/dev/null 2>&1; rc=$?
  check "$rc" = 0
  check -n "$(git notes --ref=isukit-measure show "$sha" 2>/dev/null | grep -x true)"
  check -n "$(cmd_measures 2>&1 | grep -F "${sha:0:7}" | grep -F 'plain change')"
}

t_reverted_labelled_commit_excluded() {
  setup_repo
  printf 'measured\n' >> base.txt
  ( cmd_ship --no-check --measure "measured change" ) >/dev/null 2>&1
  local sha
  sha=$(git rev-parse HEAD)
  ( git revert --no-edit "$sha" ) >/dev/null 2>&1
  check -z "$(measure_commits)"
  check -n "$(cmd_measures 2>&1 | grep -F 'no measurement commits live in HEAD')"
}

t_commit_on_other_branch_excluded() {
  setup_repo
  local main_branch
  main_branch=$(git branch --show-current)
  ( git switch -q -c other-line ) >/dev/null 2>&1
  printf 'off-branch\n' >> base.txt
  ( cmd_ship --no-check --measure "off branch measure" ) >/dev/null 2>&1
  local off_sha
  off_sha=$(git rev-parse HEAD)
  git switch -q "$main_branch"
  check -z "$(measure_commits | grep -F "$off_sha")"
  check -n "$(cmd_measures 2>&1 | grep -F 'no measurement commits live in HEAD')"
}

t_finalize_dies_naming_live_commit() {
  setup_repo
  printf 'measured\n' >> base.txt
  ( cmd_ship --no-check --measure "measured change" ) >/dev/null 2>&1
  local out rc
  out=$( ( finalize_measure_guard ) 2>&1 ); rc=$?
  check "$rc" != 0
  check -n "$(printf '%s' "$out" | grep -F 'measurement commits are still live')"
  check -n "$(printf '%s' "$out" | grep -F 'measured change')"
}

t_finalize_proceeds_once_reverted() {
  setup_repo
  printf 'measured\n' >> base.txt
  ( cmd_ship --no-check --measure "measured change" ) >/dev/null 2>&1
  local sha
  sha=$(git rev-parse HEAD)
  ( git revert --no-edit "$sha" ) >/dev/null 2>&1
  local rc
  ( finalize_measure_guard ) >/dev/null 2>&1; rc=$?
  check "$rc" = 0
}

t_final_strip_apply_conflict_stops() {
  setup_repo
  printf 'v0\n' > conflict.txt
  git add conflict.txt
  git commit -q -m 'conflict base'
  printf 'v1\n' > conflict.txt
  ( cmd_ship --no-check --measure "measure A" ) >/dev/null 2>&1
  printf 'v2\n' > conflict.txt
  ( cmd_ship --no-check "intermediate" ) >/dev/null 2>&1
  printf 'unrelated\n' > unrelated.txt
  ( cmd_ship --no-check --measure "measure B" ) >/dev/null 2>&1

  local rowcount
  rowcount=$(measure_commits | grep -c .)
  check "$rowcount" = 2

  local out rc
  out=$( ( cmd_final_strip --apply ) 2>&1 ); rc=$?
  check "$rc" != 0
  check -n "$(printf '%s' "$out" | grep -F 'conflicts')"
  check -n "$(printf '%s' "$out" | grep -F 'conflicted paths')"
  check -z "$([ -f unrelated.txt ] && echo yes)"
  check -n "$(grep -F '<<<<<<<' conflict.txt 2>/dev/null)"
  git revert --abort >/dev/null 2>&1
}

case_ measure-ship-trailer-found           t_ship_measure_trailer_found
case_ measure-sha-and-measures-listing     t_measure_sha_and_measures_listing
case_ measure-reverted-commit-excluded     t_reverted_labelled_commit_excluded
case_ measure-other-branch-excluded        t_commit_on_other_branch_excluded
case_ measure-finalize-dies-naming-live    t_finalize_dies_naming_live_commit
case_ measure-finalize-proceeds-reverted   t_finalize_proceeds_once_reverted
case_ measure-final-strip-conflict-stops   t_final_strip_apply_conflict_stops

echo "$TOTAL fixtures, $PASSED passed, $((TOTAL-PASSED)) failed"
[ -z "$FAILED" ]
