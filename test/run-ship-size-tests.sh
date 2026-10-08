#!/bin/bash
# F2 (最小単位 commits): isukit ship's size gate. Sources ../isukit
# (ISUKIT_SOURCED=1 skips main), stubs gh/rsh/say/warn, and drives cmd_ship
# against a real throwaway git repo to assert the SHIP_MAX_FILES/
# SHIP_MAX_LINES gate, the rules_override hatch, and --only staging.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERBOSE=0
for a in "$@"; do [ "$a" = "-v" ] && VERBOSE=1; done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/isukit-shipsize.XXXXXX")"
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

setup_repo() { # fresh, ISOLATED git repo with one committed file, and the isukit state ship's load() needs
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
  [ "$#" -gt 0 ] && printf '%s\n' "$@" >> isukit.conf
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

t_small_change_ships() {
  setup_repo
  printf 'one more line\n' >> base.txt
  local rc
  ( cmd_ship --no-check "small change" ) >/dev/null 2>&1; rc=$?
  check "$rc" = 0
  check -n "$(git log --oneline -1 --grep='small change' 2>/dev/null)"
  check -n "$(git rev-parse --abbrev-ref HEAD 2>/dev/null | grep -F 'isukit/small-change')"
}

t_over_max_files_dies() {
  setup_repo SHIP_MAX_FILES=2 SHIP_MAX_LINES=300
  printf 'a\n' > a.txt; printf 'b\n' > b.txt; printf 'c\n' > c.txt
  local out rc
  out=$( ( cmd_ship --no-check "three new files" ) 2>&1 ); rc=$?
  check "$rc" != 0
  check -n "$(printf '%s' "$out" | grep -F '3 files')"
  check -n "$(printf '%s' "$out" | grep -F 'SHIP_MAX_FILES=2')"
  check -z "$(git log --oneline | grep -F 'three new files')"
}

t_over_max_lines_dies() {
  setup_repo SHIP_MAX_FILES=10 SHIP_MAX_LINES=5
  seq 1 20 > big.txt
  local out rc
  out=$( ( cmd_ship --no-check "one big file" ) 2>&1 ); rc=$?
  check "$rc" != 0
  check -n "$(printf '%s' "$out" | grep -F 'SHIP_MAX_LINES=5')"
}

t_override_proceeds_and_logs() {
  setup_repo SHIP_MAX_FILES=1 SHIP_MAX_LINES=300
  printf 'a\n' > a.txt; printf 'b\n' > b.txt
  local rc
  ( ISUKIT_OVERRIDE='contest day, deadline' cmd_ship --no-check "two files, overridden" ) >/dev/null 2>&1; rc=$?
  check "$rc" = 0
  check -n "$(git log --oneline -1 --grep='two files, overridden' 2>/dev/null)"
  check -f .isukit/overrides.log
  check -n "$(grep -F 'ship-size' .isukit/overrides.log | grep -F 'contest day, deadline')"
}

t_only_stages_named_paths() {
  setup_repo
  printf 'keep\n' > keep.txt
  printf 'skip\n' > skip.txt
  local out rc
  out=$( ( cmd_ship --no-check --only keep.txt "only keep.txt" ) 2>&1 ); rc=$?
  check "$rc" = 0
  check -n "$(git show --stat HEAD 2>/dev/null | grep -F 'keep.txt')"
  check -z "$(git show --stat HEAD 2>/dev/null | grep -F 'skip.txt')"
  check -n "$(git status --short -- skip.txt 2>/dev/null | grep -F '??')"
}

case_ ship-small-change-ok          t_small_change_ships
case_ ship-over-max-files-dies      t_over_max_files_dies
case_ ship-over-max-lines-dies      t_over_max_lines_dies
case_ ship-override-proceeds-logs   t_override_proceeds_and_logs
case_ ship-only-stages-named-paths  t_only_stages_named_paths

echo "$TOTAL fixtures, $PASSED passed, $((TOTAL-PASSED)) failed"
[ -z "$FAILED" ]
