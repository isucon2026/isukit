#!/bin/bash
# Regulation guards: sources ../isukit (ISUKIT_SOURCED=1 skips main), stubs gh
# and the ssh transport, and asserts rules_epoch/rules_in_contest/
# rules_after_contest across the contest clock, rules_allow_host across the
# registered/unregistered/bench-role/bench-var cases, the rules_override
# hatch, and the CHK-REPRO cold-rerun floor inside `isukit rules check`.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERBOSE=0
for a in "$@"; do [ "$a" = "-v" ] && VERBOSE=1; done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/isukit-rules.XXXXXX")"
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
iso_at() { # iso_at <offset-seconds-from-now> -> ISO8601 rules_epoch can parse on GNU or BSD date
  local secs
  secs=$(( $(date +%s) + $1 ))
  date -u -d "@$secs" +%Y-%m-%dT%H:%M:%S+0000 2>/dev/null || date -u -r "$secs" +%Y-%m-%dT%H:%M:%S+0000
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

t_rules_epoch() {
  local e1 e2
  e1=$(rules_epoch '2026-11-08T10:00:00+0900')
  e2=$(rules_epoch '2026-11-08T11:00:00+0900')
  check -n "$e1"
  check "$e1" != "$e2"
  check "$((e2 - e1))" = 3600
  check -z "$(rules_epoch 'definitely-not-a-date' 2>/dev/null)"
}

t_contest_window_states() {
  setup_state
  load
  check "$(rules_in_contest >/dev/null 2>&1; echo $?)" = 1     # unset
  check "$(rules_after_contest >/dev/null 2>&1; echo $?)" = 1

  setup_state isu1 bench1 manual "CONTEST_START='$(iso_at 3600)'" "CONTEST_END='$(iso_at 7200)'"
  load
  check "$(rules_in_contest >/dev/null 2>&1; echo $?)" = 1     # before
  check "$(rules_after_contest >/dev/null 2>&1; echo $?)" = 1

  setup_state isu1 bench1 manual "CONTEST_START='$(iso_at -3600)'" "CONTEST_END='$(iso_at 3600)'"
  load
  check "$(rules_in_contest >/dev/null 2>&1; echo $?)" = 0     # during
  check "$(rules_after_contest >/dev/null 2>&1; echo $?)" = 1

  setup_state isu1 bench1 manual "CONTEST_START='$(iso_at -7200)'" "CONTEST_END='$(iso_at -3600)'"
  load
  check "$(rules_in_contest >/dev/null 2>&1; echo $?)" = 1     # after
  check "$(rules_after_contest >/dev/null 2>&1; echo $?)" = 0
}

t_allow_host_registered() {
  setup_state   # no isukit.hosts -> pre-roles layout, APP=isu1 is hosts_all
  load
  ( rules_allow_host isu1 ) >/dev/null 2>&1
  check "$?" = 0
}

t_allow_host_unregistered_dies() {
  setup_state
  load
  local out rc
  out=$( ( rules_allow_host totally-unknown-host ) 2>&1 ); rc=$?
  check "$rc" != 0
  check -n "$(printf '%s' "$out" | grep -F "refusing to connect to 'totally-unknown-host'")"
}

t_allow_host_bench_role_during_contest() {
  # 'bench' is not in KNOWN_ROLES (app web db) so no UI path (isukit host role)
  # can produce it, but rules_allow_host's bench-role branch is still live
  # code against whatever isukit.hosts actually says -- test it directly.
  setup_state isu1 bench1 manual "CONTEST_START='$(iso_at -60)'" "CONTEST_END='$(iso_at 60)'"
  printf '# <ssh-target> <roles>\nbenchbox bench\n' > isukit.hosts
  load
  local out rc
  out=$( ( rules_allow_host benchbox ) 2>&1 ); rc=$?
  check "$rc" != 0
  check -n "$(printf '%s' "$out" | grep -F "registered with the 'bench' role")"
}

t_allow_host_bench_var_auto_mode() {
  # the OTHER bench path: $BENCH itself, not listed anywhere, allowed only
  # with BENCH_MODE=auto and only outside the contest window.
  setup_state isu1 benchtarget auto
  load
  ( rules_allow_host benchtarget ) >/dev/null 2>&1
  check "$?" = 0    # window unset (not in contest) + BENCH_MODE=auto

  setup_state isu1 benchtarget auto "CONTEST_START='$(iso_at -60)'" "CONTEST_END='$(iso_at 60)'"
  load
  ( rules_allow_host benchtarget ) >/dev/null 2>&1
  check "$?" != 0   # in contest -> the auto-mode exemption doesn't apply
}

t_allow_host_bench_role_outside_contest_auto_mode() {
  # same bench-role host as t_allow_host_bench_role_during_contest, but with
  # the contest window unset (= outside it) and BENCH_MODE=auto: the
  # bench-role branch only rejects while rules_in_contest is true, so here
  # it falls through to the unconditional return 0 for a registered host.
  setup_state isu1 bench1 auto
  printf '# <ssh-target> <roles>\nbenchbox bench\n' > isukit.hosts
  load
  ( rules_allow_host benchbox ) >/dev/null 2>&1
  check "$?" = 0
}

t_override_hatch() {
  setup_state
  load
  local rc
  : > "$CALLS"
  ( ISUKIT_OVERRIDE='day-of manual says so' rules_override test-guard "doing the risky thing" ) >/dev/null 2>&1; rc=$?
  check "$rc" = 0
  check -n "$(grep -F 'OVERRIDE [test-guard]' "$CALLS")"
  check -n "$(grep -F 'day-of manual says so' "$CALLS")"
  check -f "$STATE/overrides.log"
  check -n "$(grep -F 'test-guard' "$STATE/overrides.log" | grep -F 'day-of manual says so')"
  ( rules_override test-guard "no override set this time" ) >/dev/null 2>&1
  check "$?" != 0
}

t_host_findings_two_impls_one_fix() {
  # R2 through rules_host_findings(): two enabled reference-implementation
  # units sharing one app host collapse to exactly one FIX line, not two.
  setup_state isu1 bench1 manual
  load
  rsh_stdin() {
    cat >/dev/null
    printf 'IMPL|isu-go.service|enabled|active\n'
    printf 'IMPL|isu-ruby.service|enabled|inactive\n'
    printf 'FIX|2 implementation units are enabled at once (isu-go.service isu-ruby.service)|sudo systemctl disable --now <the ones you are not using>\n'
  }
  local out
  out=$(rules_host_findings)
  check "$(printf '%s\n' "$out" | grep -c .)" = 1
  check -n "$(printf '%s' "$out" | grep -F 'isu1' | grep -F '2 implementation units are enabled')"
}

t_host_findings_one_impl_no_fix() {
  setup_state isu1 bench1 manual
  load
  rsh_stdin() { cat >/dev/null; printf 'IMPL|isu-go.service|enabled|active\n'; }
  check -z "$(rules_host_findings)"
}

t_chk_impl_lang_drift_fail() {
  # half-finished language switch: IMPL_LANG says go but the enabled unit is
  # the ruby reference implementation -> cmd_rules_check must FAIL on it.
  setup_state local bench1 manual "IMPL_LANG='go'"
  load
  rsh_stdin() { cat >/dev/null; printf 'IMPL|isu-ruby.service|enabled|active\n'; }
  local out rc
  out=$( ( cmd_rules_check ) 2>&1 ); rc=$?
  check "$rc" != 0
  check -n "$(printf '%s' "$out" | grep -F "IMPL_LANG='go' but the enabled implementation is isu-ruby.service (ruby)")"
}

t_chk_repro_no_cold_row() {
  setup_state local bench1 manual
  load
  write_scores $'2026-10-01T00:00:00Z\tsha1\t1000\tnormal-run\trundir1\tmain\talice'
  local out rc
  out=$( ( cmd_rules_check ) 2>&1 ); rc=$?
  check "$rc" != 0
  check -n "$(printf '%s' "$out" | grep -F 'no cold re-run recorded')"
}

t_chk_repro_cold_passes_floor() {
  setup_state local bench1 manual "REPRO_MIN='0.9'"
  load
  write_scores \
    $'2026-10-01T00:00:00Z\tsha1\t1000\tnormal-run\trundir1\tmain\talice' \
    $'2026-10-01T01:00:00Z\tsha1\t950\tcold:post-reboot\trundir2\tmain\talice'
  local out rc
  out=$( ( cmd_rules_check ) 2>&1 ); rc=$?
  check "$rc" = 0
  check -n "$(printf '%s' "$out" | grep -F 'ratio=0.950')"
}

t_chk_repro_cold_below_floor() {
  setup_state local bench1 manual "REPRO_MIN='0.9'"
  load
  write_scores \
    $'2026-10-01T00:00:00Z\tsha1\t1000\tnormal-run\trundir1\tmain\talice' \
    $'2026-10-01T01:00:00Z\tsha1\t800\tcold:post-reboot\trundir2\tmain\talice'
  local out rc
  out=$( ( cmd_rules_check ) 2>&1 ); rc=$?
  check "$rc" != 0
  check -n "$(printf '%s' "$out" | grep -F 'ratio=0.800')"
  check -n "$(printf '%s' "$out" | grep -F '登録スコアに近い結果が再現されなければ')"
}

case_ rules-epoch-parses                t_rules_epoch
case_ contest-window-states             t_contest_window_states
case_ allow-host-registered             t_allow_host_registered
case_ allow-host-unregistered-dies      t_allow_host_unregistered_dies
case_ allow-host-bench-role-in-contest  t_allow_host_bench_role_during_contest
case_ allow-host-bench-var-auto-mode    t_allow_host_bench_var_auto_mode
case_ allow-host-bench-role-outside     t_allow_host_bench_role_outside_contest_auto_mode
case_ override-hatch-logs-and-passes    t_override_hatch
case_ host-findings-two-impls-one-fix   t_host_findings_two_impls_one_fix
case_ host-findings-one-impl-no-fix     t_host_findings_one_impl_no_fix
case_ chk-impl-lang-drift-fail          t_chk_impl_lang_drift_fail
case_ chk-repro-no-cold-row             t_chk_repro_no_cold_row
case_ chk-repro-cold-passes-floor       t_chk_repro_cold_passes_floor
case_ chk-repro-cold-below-floor        t_chk_repro_cold_below_floor

echo "$TOTAL fixtures, $PASSED passed, $((TOTAL-PASSED)) failed"
[ -z "$FAILED" ]
