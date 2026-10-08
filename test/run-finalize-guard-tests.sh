#!/bin/bash
# F4a (the precondition that actually matters): finalize must refuse to score
# a tree nobody benched. Sources ../isukit (ISUKIT_SOURCED=1 skips main),
# stubs gh/rsh/say/warn, and drives finalize_bench_guard directly against a
# real throwaway git repo + .isukit/scores.tsv — faster and more isolated
# than driving all of cmd_finalize (reboot/HTTP-check plumbing) through it,
# and cmd_finalize calls this guard unconditionally first, so the coverage
# is equivalent.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERBOSE=0
for a in "$@"; do [ "$a" = "-v" ] && VERBOSE=1; done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/isukit-finalize.XXXXXX")"
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
say()  { :; }
warn() { printf 'warn: %s\n' "$*" >> "$CALLS"; }
gh()   { return 1; } # no real gh here: repo-visibility always warns, never fails

setup_repo() { # fresh, ISOLATED git repo + the isukit state the guard needs
  local d
  d="$(mktemp -d "$WORK/repo.XXXXXX")"
  cd "$d" || exit 2
  git init -q
  git config user.email t@test.local
  git config user.name test
  mkdir -p .isukit
  printf 'APP=local\n' > .isukit/config
  printf '.isukit/\n' > .gitignore
  printf 'base\n' > base.txt
  git add .gitignore base.txt
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

t_dies_on_absent_bench() {
  setup_repo
  local out rc
  out=$( ( finalize_bench_guard ) 2>&1 ); rc=$?
  check "$rc" != 0
  check -n "$(printf '%s' "$out" | grep -F 'no recorded bench')"
}

t_dies_on_dirty_tree() {
  setup_repo
  printf 'uncommitted\n' >> base.txt
  local out rc
  out=$( ( finalize_bench_guard ) 2>&1 ); rc=$?
  check "$rc" != 0
  check -n "$(printf '%s' "$out" | grep -F 'uncommitted tree')"
}

t_proceeds_when_benched() {
  setup_repo
  local sha
  sha=$(git rev-parse --short HEAD)
  printf 'when\t%s\t1234\tnote\trundir\tmain\twho\n' "$sha" > .isukit/scores.tsv
  local rc
  ( finalize_bench_guard ) >/dev/null 2>&1; rc=$?
  check "$rc" = 0
}

t_override_bypasses_absent_bench() {
  setup_repo
  local rc
  ( ISUKIT_OVERRIDE='contest day' finalize_bench_guard ) >/dev/null 2>&1; rc=$?
  check "$rc" = 0
  check -f .isukit/overrides.log
  check -n "$(grep -F 'finalize-unbenched' .isukit/overrides.log | grep -F 'contest day')"
}

case_ finalize-dies-on-absent-bench       t_dies_on_absent_bench
case_ finalize-dies-on-dirty-tree         t_dies_on_dirty_tree
case_ finalize-proceeds-when-benched      t_proceeds_when_benched
case_ finalize-override-bypasses-absent   t_override_bypasses_absent_bench

echo "$TOTAL fixtures, $PASSED passed, $((TOTAL-PASSED)) failed"
[ -z "$FAILED" ]
