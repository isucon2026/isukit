#!/bin/bash
# Dirty-tree provenance (F1): repo_dirty() true/false, deploy/deployed recording
# a -dirty suffix, and isukit attribute refusing KEEP/REVERT when either
# compared run's sha carries that suffix.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERBOSE=0
for a in "$@"; do [ "$a" = "-v" ] && VERBOSE=1; done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/isukit-provenance.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK" || exit 2

# shellcheck disable=SC2034  # read by the sourced isukit
ISUKIT_SOURCED=1
# shellcheck source=../isukit
. "$HERE/../isukit"
set +e +u +o pipefail   # isukit's own strict mode; the harness checks by hand

CALLS="$WORK/calls"
: > "$CALLS"
rsh() { printf '%s %s\n' "$1" "${*:2}" >> "$CALLS"; return 0; }
rsh_stdin() { cat >/dev/null; printf '%s stdin\n' "$1" >> "$CALLS"; return 0; }
say()  { :; }
warn() { printf 'warn: %s\n' "$*" >> "$CALLS"; }
gh()   { return 1; }

setup_state() { # setup_state [APP] [BENCH] [BENCH_MODE] -- then: extra isukit.conf lines...
  local app="${1:-isu1}" bench="${2:-bench1}" mode="${3:-manual}"
  [ "$#" -ge 3 ] && shift 3 || shift "$#"
  rm -rf .isukit isukit.hosts isukit.conf
  mkdir -p .isukit
  cat > .isukit/config <<EOF
APP=$app
BENCH=$bench
BENCH_MODE=$mode
BENCH_CMD=''
SSH_OPTS=''
EXTRA_UNITS=''
EXTRA_HOSTS=''
EOF
  cat > .isukit/manifest <<'EOF'
APP_UNIT=isu-go.service
WEB_SERVER=nginx
DB_SERVER=mysql
APP_EXEC_RAW=''
SRC_DIR=/home/isucon/webapp
EOF
  : > isukit.conf
  [ "$#" -gt 0 ] && printf '%s\n' "$@" >> isukit.conf
  : > "$CALLS"
}
write_scores() { mkdir -p "$STATE"; printf '%s\n' "$@" > "$STATE/scores.tsv"; }

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

t_repo_dirty_clean() {
  local gitdir="$WORK/clean-repo"
  mkdir -p "$gitdir" && ( cd "$gitdir" && git init -q )
  ( cd "$gitdir" && repo_dirty ) >/dev/null 2>&1
  check "$?" != 0   # clean tree -> repo_dirty is false
}

t_repo_dirty_untracked() {
  local gitdir="$WORK/dirty-repo"
  mkdir -p "$gitdir" && ( cd "$gitdir" && git init -q )
  : > "$gitdir/untracked-file"
  ( cd "$gitdir" && repo_dirty ) >/dev/null 2>&1
  check "$?" = 0    # untracked file -> repo_dirty is true
}

t_attribute_base_dirty_inconclusive() {
  setup_state local bench1 manual
  load
  write_scores \
    $'2026-10-01T00:00:00Z\tsha1-dirty\t1000\tnormal-run\trundir1\tmain\talice' \
    $'2026-10-01T01:00:00Z\tsha2\t1200\tnormal-run\trundir2\tfeat\talice'
  local out rc
  out=$( ( cmd_attribute ) 2>&1 ); rc=$?
  check "$rc" = 0
  check -n "$(printf '%s' "$out" | grep -F 'INCONCLUSIVE')"
  check -n "$(printf '%s' "$out" | grep -F 'dirty tree')"
  check -n "$(printf '%s' "$out" | grep -F 'earlier (base)')"
  check -z "$(printf '%s' "$out" | grep -F 'KEEP')"
  check -z "$(printf '%s' "$out" | grep -F 'REVERT')"
}

t_attribute_cur_dirty_inconclusive() {
  setup_state local bench1 manual
  load
  write_scores \
    $'2026-10-01T00:00:00Z\tsha1\t1000\tnormal-run\trundir1\tmain\talice' \
    $'2026-10-01T01:00:00Z\tsha2-dirty\t1200\tnormal-run\trundir2\tfeat\talice'
  local out rc
  out=$( ( cmd_attribute ) 2>&1 ); rc=$?
  check "$rc" = 0
  check -n "$(printf '%s' "$out" | grep -F 'INCONCLUSIVE')"
  check -n "$(printf '%s' "$out" | grep -F 'dirty tree')"
  check -n "$(printf '%s' "$out" | grep -F 'the current')"
}

t_attribute_clean_rows_keep_unchanged() {
  # regression guard: two clean shas still get the existing KEEP/REVERT path,
  # not swallowed by the new dirty check.
  setup_state local bench1 manual
  load
  write_scores \
    $'2026-10-01T00:00:00Z\tsha1\t1000\tnormal-run\trundir1\tmain\talice' \
    $'2026-10-01T01:00:00Z\tsha2\t1200\tnormal-run\trundir2\tfeat\talice'
  local out rc
  out=$( ( cmd_attribute ) 2>&1 ); rc=$?
  check "$rc" = 0
  check -n "$(printf '%s' "$out" | grep -F 'KEEP')"
  check -z "$(printf '%s' "$out" | grep -F 'INCONCLUSIVE')"
}

case_ repo-dirty-clean-is-false          t_repo_dirty_clean
case_ repo-dirty-untracked-is-true       t_repo_dirty_untracked
case_ attribute-base-dirty-inconclusive  t_attribute_base_dirty_inconclusive
case_ attribute-cur-dirty-inconclusive   t_attribute_cur_dirty_inconclusive
case_ attribute-clean-rows-keep-unchanged t_attribute_clean_rows_keep_unchanged

echo "$TOTAL fixtures, $PASSED passed, $((TOTAL-PASSED)) failed"
[ -z "$FAILED" ]
