#!/bin/bash
# F3 (the score follows the commit): git-notes score attachment + isukit pick.
# Sources ../isukit (ISUKIT_SOURCED=1 skips main), stubs gh/rsh/say/warn, and
# drives run_note_score + cmd_pick against a real throwaway git repo.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERBOSE=0
for a in "$@"; do [ "$a" = "-v" ] && VERBOSE=1; done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/isukit-notes.XXXXXX")"
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

setup_repo() { # fresh, ISOLATED git repo with one committed file
  local d
  d="$(mktemp -d "$WORK/repo.XXXXXX")"
  cd "$d" || exit 2
  git init -q
  git config user.email t@test.local
  git config user.name test
  printf 'base\n' > base.txt
  git add base.txt
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

t_note_attached_clean_sha() {
  setup_repo
  local sha
  sha=$(git rev-parse --short HEAD)
  run_note_score "$sha" "1234" "2026-01-01T00:00:00Z" "first run" "tester"
  local note
  note=$(git notes --ref=isukit show HEAD 2>/dev/null)
  check -n "$(printf '%s' "$note" | grep -F '1234')"
  check -n "$(printf '%s' "$note" | grep -F 'first run')"
}

t_dirty_sha_skipped() {
  setup_repo
  local rc
  run_note_score "1234567-dirty" "999" "when" "note" "who"; rc=$?
  check "$rc" = 0
  check -z "$(git notes --ref=isukit list 2>/dev/null)"
}

t_missing_sha_skipped() {
  setup_repo
  local rc
  run_note_score "deadbeefcafe" "999" "when" "note" "who"; rc=$?
  check "$rc" = 0
  check -z "$(git notes --ref=isukit list 2>/dev/null)"
}

t_pick_carries_note() {
  setup_repo
  git switch -c feature -q
  printf 'feature line\n' >> base.txt
  git commit -q -am "feature commit"
  local feat_sha
  feat_sha=$(git rev-parse --short HEAD)
  run_note_score "$feat_sha" "555" "when" "feature note" "tester"
  git switch - -q
  local rc
  ( cmd_pick "$feat_sha" ) >/dev/null 2>&1; rc=$?
  check "$rc" = 0
  check -n "$(git notes --ref=isukit show HEAD 2>/dev/null | grep -F '555')"
}

t_pick_no_note_succeeds() {
  setup_repo
  git switch -c feature2 -q
  printf 'no note line\n' >> base.txt
  git commit -q -am "no-note commit"
  local feat_sha
  feat_sha=$(git rev-parse --short HEAD)
  git switch - -q
  local rc
  ( cmd_pick "$feat_sha" ) >/dev/null 2>&1; rc=$?
  check "$rc" = 0
  check -z "$(git notes --ref=isukit show HEAD 2>/dev/null)"
}

case_ notes-clean-sha-attached      t_note_attached_clean_sha
case_ notes-dirty-sha-skipped       t_dirty_sha_skipped
case_ notes-missing-sha-skipped     t_missing_sha_skipped
case_ pick-carries-note             t_pick_carries_note
case_ pick-no-note-succeeds         t_pick_no_note_succeeds

echo "$TOTAL fixtures, $PASSED passed, $((TOTAL-PASSED)) failed"
[ -z "$FAILED" ]
