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

# --- #40: final apply changes what the hosts run without a deploy. The deploy
# record (on the lock host, /var/tmp/isukit.deployed) stands in a file here.
deployed_on_file() { # rsh that reads / writes $WORK/deployed for the deploy record, records the rest
  rsh() {
    printf '%s %s\n' "$1" "${*:2}" >> "$CALLS"
    local c="${*:2}"
    case "$c" in
      *"cat $DEPLOYED_FILE"*) cat "$WORK/deployed" 2>/dev/null ;;
      *"> $DEPLOYED_FILE"*) c="${c#sudo -n }"; bash -c "${c//$DEPLOYED_FILE/$WORK/deployed}" ;;
    esac
    return 0
  }
}

final_apply_stubbed() { # cmd_final_apply with every host-side step a no-op; only the etc/ edit + record are real
  lock_guard() { :; }; cmd_logs() { :; }; cmd_etc_push() { :; }; cmd_final_check() { :; }
  final_host_findings() { :; }; final_code_findings() { :; }; notify() { cat >/dev/null; }
  cmd_final_apply
}

t_final_apply_marks_the_deploy_dirty() {
  setup_repo
  deployed_on_file
  mkdir -p etc/nginx
  printf 'http {\n    access_log /var/log/nginx/access.log;\n}\n' > etc/nginx/nginx.conf
  git add etc && git commit -q -m etc
  local sha
  sha=$(git rev-parse --short HEAD)
  printf '%s|main|alice|1\n' "$sha" > "$WORK/deployed"
  printf 'when\t%s\t1234\tnote\trundir\tmain\twho\n' "$sha" > .isukit/scores.tsv   # benched as deployed
  ( final_apply_stubbed ) >/dev/null 2>&1
  check -n "$(grep -F 'access_log off' etc/nginx/nginx.conf)"
  check "$(cut -d'|' -f1,2 "$WORK/deployed")" = "$sha-dirty|main"
  # what bench would now record, and finalize refuses it: the old sha's bench is not this config's
  check "$(deployed)" = "$sha-dirty main"
  local out rc
  out=$( ( finalize_bench_guard ) 2>&1 ); rc=$?
  check "$rc" != 0
  check -n "$(printf '%s' "$out" | grep -F 'uncommitted tree')"
  # applying again does not stack the mark
  ( deploy_record_dirty ) >/dev/null
  check "$(cut -d'|' -f1 "$WORK/deployed")" = "$sha-dirty"
  # ship + deploy writes a clean record again
  git add etc && git commit -q -m "final: logging off"
  deploy_record
  check "$(cut -d'|' -f1 "$WORK/deployed")" = "$(git rev-parse --short HEAD)"
}

t_final_apply_leaves_a_clean_record_alone() {
  setup_repo
  deployed_on_file
  mkdir -p etc/nginx
  printf 'http {\n    access_log off;\n}\n' > etc/nginx/nginx.conf     # nothing left to turn off
  git add etc && git commit -q -m etc
  local sha
  sha=$(git rev-parse --short HEAD)
  printf '%s|main|alice|1\n' "$sha" > "$WORK/deployed"
  ( final_apply_stubbed ) >/dev/null 2>&1
  check "$(cut -d'|' -f1 "$WORK/deployed")" = "$sha"
}

case_ final-apply-marks-deploy-dirty      t_final_apply_marks_the_deploy_dirty
case_ final-apply-clean-record-kept       t_final_apply_leaves_a_clean_record_alone
case_ finalize-dies-on-absent-bench       t_dies_on_absent_bench
case_ finalize-dies-on-dirty-tree         t_dies_on_dirty_tree
case_ finalize-proceeds-when-benched      t_proceeds_when_benched
case_ finalize-override-bypasses-absent   t_override_bypasses_absent_bench

echo "$TOTAL fixtures, $PASSED passed, $((TOTAL-PASSED)) failed"
[ -z "$FAILED" ]
