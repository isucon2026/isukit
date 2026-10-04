#!/bin/bash
# Host-role routing: sources ../isukit (ISUKIT_SOURCED=1 skips main), swaps the
# ssh transport (rsh / rsh_stdin) for a recorder, and asserts which host each
# command reaches — with a .isukit/hosts roles file, and without one (the
# pre-roles layout: $APP does everything, EXTRA_HOSTS are app instances).
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERBOSE=0
for a in "$@"; do [ "$a" = "-v" ] && VERBOSE=1; done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/isukit-hosts.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK" || exit 2

# shellcheck disable=SC2034  # read by the sourced isukit
ISUKIT_SOURCED=1
# shellcheck source=../isukit
. "$HERE/../isukit"
set +e +u +o pipefail   # isukit's own strict mode; the harness checks by hand

CALLS="$WORK/calls"
rsh() { # record "<host> <command>"; everything "succeeds" (LOGS_OFF=1: logging reads as off)
  printf '%s %s\n' "$1" "${*:2}" >> "$CALLS"
  case "$*" in *00-isukit.conf*) [ "${LOGS_OFF:-0}" = 1 ] && return 1 ;; esac
  case "$*" in *"df -P /tmp"*) echo "${DF_KB:-99999999}" ;; esac
  return 0
}
rsh_stdin() { # record "<host> stdin:" + the VAR= lines the caller prepended
  local body
  body=$(cat)
  local tag=""
  case "$body" in *"Closes the measurement window"*) tag="run-stop " ;; esac
  printf '%s stdin: %s%s\n' "$1" "$tag" "$(printf '%s\n' "$body" | grep -E '^(MODE|WANT_NGINX|WANT_MYSQL|REPO|RESET_NGINX|RESET_MYSQL|SAMPLE)=' | tr '\n' ' ')" >> "$CALLS"
  return 0
}
say()  { :; }
warn() { printf 'warn: %s\n' "$*" >> "$CALLS"; }

setup_state() { # setup_state <APP> <EXTRA_HOSTS> [hosts-file-content]
  rm -rf .isukit; mkdir -p .isukit
  cat > .isukit/config <<EOF
APP=$1
BENCH=bench
BENCH_MODE=manual
BENCH_CMD=''
SSH_OPTS=''
EXTRA_UNITS=''
EXTRA_HOSTS='$2'
EOF
  cat > .isukit/manifest <<'EOF'
APP_UNIT=isu-go.service
WEB_SERVER=nginx
DB_SERVER=mysql
APP_EXEC_RAW=''
SRC_DIR=/home/isucon/webapp
EOF
  [ -n "${3:-}" ] && printf '%s\n' "$3" > .isukit/hosts
  : > "$CALLS"
}
hosts_called() { # hosts_called <grep-pattern> -- distinct hosts whose recorded call matches
  grep -E "$1" "$CALLS" | awk '{print $1}' | awk '!s[$0]++' | tr '\n' ' ' | sed 's/ $//'
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

ROLES='# <ssh-target> <roles>
isu1 web,app
isu2 app
isu3 db'

t_legacy_layout() {
  setup_state isu1 "isu2 isu3"
  load
  check "$(hosts_with app | tr '\n' ' ')" = "isu1 isu2 isu3 "
  check "$(hosts_with web)" = "isu1"
  check "$(hosts_with db)" = "isu1"
  cmd_restart
  check "$(hosts_called 'systemctl restart')" = "isu1 isu2 isu3"
}

t_restart_app_hosts_only() {
  setup_state isu1 "" "$ROLES"
  load
  cmd_restart
  check "$(hosts_called 'systemctl restart isu-go.service')" = "isu1 isu2"
}

t_logs_split_by_role() {
  setup_state isu1 "" "$ROLES"
  load
  cmd_logs on
  check -n "$(grep '^isu1 stdin: MODE=on WANT_NGINX=1 WANT_MYSQL=0' "$CALLS")"
  check -n "$(grep '^isu3 stdin: MODE=on WANT_NGINX=0 WANT_MYSQL=1' "$CALLS")"
  check -z "$(grep '^isu2 stdin:' "$CALLS")"
  # the slow log only sees new sessions: every app host reconnects, once
  check "$(hosts_called 'systemctl restart')" = "isu1 isu2"
  check "$(grep -c 'systemctl restart' "$CALLS")" = 2
  : > "$CALLS"
  cmd_logs off
  check -z "$(grep 'systemctl restart' "$CALLS")"
}

t_alp_slow_route() {
  setup_state isu1 "" "$ROLES"
  load
  cmd_alp
  check "$(hosts_called 'alp ltsv')" = "isu1"
  : > "$CALLS"
  cmd_slow
  check "$(hosts_called 'pt-query-digest --limit')" = "isu3"
}

t_role_units() {
  setup_state isu1 "" "$ROLES"
  load
  check "$(role_units isu1)" = "nginx isu-go.service"
  check "$(role_units isu2)" = "isu-go.service"
  check "$(role_units isu3)" = "mysql"
}

t_host_role_seeds_file() {
  setup_state isu1 "isu2"
  load
  cmd_host role isu3 db >/dev/null 2>&1
  check -f .isukit/hosts
  check "$(awk '!/^#/' .isukit/hosts | tr '\n' ';')" = "isu1 web,app,db;isu2 app;isu3 db;"
  cmd_host role isu1 web,app >/dev/null 2>&1
  check "$(awk '$1=="isu1"{print $2}' .isukit/hosts)" = "web,app"
  check "$(grep -c '^isu1 ' .isukit/hosts)" = 1
  cmd_host add isu4 >/dev/null 2>&1
  check "$(awk '$1=="isu4"{print $2}' .isukit/hosts)" = "app"
  ( cmd_host role isu5 cache ) >/dev/null 2>&1
  check "$?" != 0
}

t_on_hosts_isolates_and_continues() {
  setup_state isu1 "" "$ROLES"
  load
  probe_one() { printf '%s %s\n' "$APP" "probe_one" >> "$CALLS"; [ "$APP" != isu1 ] || die "boom"; }
  on_hosts all probe_one; local rc=$?
  check "$rc" = 1
  check "$(hosts_called 'probe_one')" = "isu1 isu2 isu3"
  check -n "$(grep 'failed on: isu1' "$CALLS")"
  check "$APP" = isu1   # the loop never leaks its per-host $APP
}

t_deploy_builds_each_app_host_restarts_once() {
  setup_state isu1 "" "$ROLES"
  load
  deploy_one() { printf '%s deploy_one force=%s\n' "$APP" "$1" >> "$CALLS"; }
  cmd_deploy
  check "$(hosts_called 'deploy_one')" = "isu1 isu2"
  check "$(grep -c 'systemctl restart' "$CALLS")" = 2   # one per app host, not per build
  : > "$CALLS"
  deploy_one() { printf '%s deploy_one\n' "$APP" >> "$CALLS"; [ "$APP" != isu2 ] || die "build failed"; }
  ( cmd_deploy ) >/dev/null 2>&1
  check "$?" != 0
  check -z "$(grep 'systemctl restart' "$CALLS")"      # never restart a half-deployed fleet
}

t_etc_push_fleet_followups_once() {
  setup_state isu1 "" "$ROLES"
  load
  # every host reports "logging was on and I restarted mysql" / "app unit changed"
  etc_push_one() { etc_flag relog; etc_flag app-unit; printf '%s etc_push_one\n' "$APP" >> "$CALLS"; }
  cmd_etc_push
  check "$(hosts_called 'etc_push_one')" = "isu1 isu2 isu3"
  check "$(grep -c 'stdin: MODE=on' "$CALLS")" = 2      # logs on once: isu1 (web) + isu3 (db)
  check "$(grep -c 'systemctl restart' "$CALLS")" = 2   # and the app restarted once per app host
  check ! -d .isukit/.etc-flags
  : > "$CALLS"
  etc_push_one() { etc_flag app-unit; }
  cmd_etc_push --from-deploy
  check -z "$(grep 'systemctl restart' "$CALLS")"      # deploy restarts right after
}

t_bench_measures_run() {
  setup_state isu1 "" "$ROLES"
  sed -i.bak "s|^BENCH_MODE=manual|BENCH_MODE=auto|; s|^BENCH_CMD=''|BENCH_CMD='./bench'|" .isukit/config && rm -f .isukit/config.bak
  load
  cmd_bench "idx" >/dev/null 2>&1
  # window opened on every host, each emptying only the logs its roles write
  check -n "$(grep '^isu1 stdin: RESET_NGINX=1 RESET_MYSQL=0 SAMPLE=1' "$CALLS")"
  check -n "$(grep '^isu2 stdin: RESET_NGINX=0 RESET_MYSQL=0 SAMPLE=1' "$CALLS")"
  check -n "$(grep '^isu3 stdin: RESET_NGINX=0 RESET_MYSQL=1 SAMPLE=1' "$CALLS")"
  check "$(hosts_called 'stdin: run-stop')" = "isu1 isu2 isu3"
  check "$(hosts_called 'alp ltsv')" = "isu1"
  check "$(hosts_called 'pt-query-digest --limit')" = "isu3"
  # the bench ran between opening and closing the window
  local open bench close
  open=$(grep -n 'SAMPLE=1' "$CALLS" | tail -1 | cut -d: -f1)
  bench=$(grep -n '^bench ./bench' "$CALLS" | cut -d: -f1)
  close=$(grep -n 'run-stop' "$CALLS" | head -1 | cut -d: -f1)
  check -n "$bench"
  check "$open" -lt "${bench:-0}"
  check "${bench:-0}" -lt "$close"
  # and the logs are emptied again after collecting, for the next record
  check "$(grep 'SAMPLE=0' "$CALLS" | awk '{print $1}' | tr '\n' ' ')" = "isu1 isu2 isu3 "
  local run
  run=$(ls -1d .isukit/runs/* | tail -1)
  check -f "$run/meta"
  check -n "$(grep '^note=idx' "$run/meta")"
  check -n "$(awk -F'\t' -v r="$run" '$5 == r' .isukit/scores.tsv)"
}

t_bench_clean_when_logs_off() {
  setup_state isu1 "" "$ROLES"
  sed -i.bak "s|^BENCH_MODE=manual|BENCH_MODE=auto|; s|^BENCH_CMD=''|BENCH_CMD='./bench'|" .isukit/config && rm -f .isukit/config.bak
  load
  # logs_are_on also asks mysql; make that read "off" too
  rsh() { printf '%s %s\n' "$1" "${*:2}" >> "$CALLS"; case "$*" in *00-isukit.conf*) return 1 ;; esac; return 0; }
  cmd_bench "final" >/dev/null 2>&1
  check -z "$(grep -E 'SAMPLE=|run-stop|alp ltsv|pt-query-digest' "$CALLS")"
  check -n "$(grep '^bench ./bench' "$CALLS")"
}

t_manual_score_collects_run() {
  setup_state isu1 "" "$ROLES"
  load
  cmd_bench --score 1234 "portal run" </dev/null >/dev/null 2>&1
  # no window was opened (no prompt), but this run's logs are still collected
  check -z "$(grep 'SAMPLE=1' "$CALLS")"
  check "$(hosts_called 'alp ltsv')" = "isu1"
  check "$(hosts_called 'pt-query-digest --limit')" = "isu3"
  check "$(grep -c 'SAMPLE=0' "$CALLS")" = 3
  check -n "$(awk -F'\t' '$3 == 1234 && $4 == "portal run"' .isukit/scores.tsv)"
}

t_logs_space_guard_on_db_hosts() {
  setup_state isu1 "" "$ROLES"
  load
  DF_KB=1000 cmd_logs on
  check "$(hosts_called 'df -P /tmp')" = "isu3"          # only where the slow log is written
  check -n "$(grep 'warn: only 0MB free on /tmp on isu3' "$CALLS")"
}

t_etc_pull_leaves_out_disagreeing_files() {
  setup_state isu1 "" "$ROLES"
  load
  etc_sums() { # local: nothing yet; hosts: the db host tuned mysqld.cnf
    [ "$1" = local ] && return 0
    printf '111 10 ./nginx/nginx.conf\n'
    if [ "$APP" = isu3 ]; then printf '999 5 ./mysql/mysqld.cnf\n'; else printf '222 5 ./mysql/mysqld.cnf\n'; fi
  }
  etc_rsync() { printf '%s rsync %s\n' "$APP" "${*:3}" >> "$CALLS"; }
  cmd_etc_pull; local rc=$?
  check "$rc" = 1
  check "$(hosts_called ' rsync ')" = "isu1 isu2 isu3"
  check "$(grep -c 'rsync --exclude=/mysql/mysqld.cnf' "$CALLS")" = 3
  check -z "$(grep 'exclude=/nginx' "$CALLS")"           # agreed files still come down
  check -n "$(grep 'warn: etc pull: hosts disagree' "$CALLS")"
  : > "$CALLS"
  etc_sums() { [ "$1" = local ] && return 0; printf '111 10 ./nginx/nginx.conf\n'; }
  cmd_etc_pull; rc=$?
  check "$rc" = 0
  check -z "$(grep exclude "$CALLS")"
}

t_host_app_moves_hosts_line() {
  setup_state isu1 "" "$ROLES"
  cmd_host app isu9 >/dev/null 2>&1
  check "$(awk '$1=="isu9"{print $2}' .isukit/hosts)" = "web,app"
  check -z "$(awk '$1=="isu1"' .isukit/hosts)"
}

t_catchall_follows_app_key() {
  setup_state isukit-app "" "$ROLES"
  sed -i.bak "s|^SSH_OPTS=''|SSH_OPTS='-F .isukit/ssh_config'|" .isukit/config && rm -f .isukit/config.bak
  printf 'Host isukit-app\n  HostName 10.0.0.1\n  User ubuntu\n  IdentityFile /old.pem\n\nHost *\n  User ubuntu\n  IdentityFile /old.pem\n  StrictHostKeyChecking accept-new\n' > .isukit/ssh_config
  : > new.pem; chmod 600 new.pem
  cmd_host app ubuntu@10.0.0.1 -i new.pem >/dev/null 2>&1
  local star
  star=$(awk '/^Host \*$/{f=1;next} f&&/^Host /{exit} f' .isukit/ssh_config)
  check -n "$(printf '%s\n' "$star" | grep "IdentityFile /.*/new.pem$")"
  check -n "$(printf '%s\n' "$star" | grep 'User ubuntu')"
  check "$(grep -c '^Host \*$' .isukit/ssh_config)" = 1
}

t_bench_records_score_when_collection_fails() {
  setup_state isu1 "" "$ROLES"
  sed -i.bak "s|^BENCH_MODE=manual|BENCH_MODE=auto|; s|^BENCH_CMD=''|BENCH_CMD='./bench'|" .isukit/config && rm -f .isukit/config.bak
  # an empty log after a failed /initialize: alp_one dies, and a host is down for run-stop
  rsh() {
    printf '%s %s\n' "$1" "${*:2}" >> "$CALLS"
    case "$*" in *"test -s"*) return 1 ;; esac
    case "$1 $*" in bench*) echo "score: 777" ;; esac
    return 0
  }
  rsh_stdin() { cat >/dev/null; [ "$1" = isu2 ] && return 255; return 0; }
  # the real command runs under isukit's own strict mode
  ( set -euo pipefail; load; cmd_bench "empty run" ) >/dev/null 2>&1
  check -n "$(awk -F'\t' '$3 == 777 && $4 == "empty run"' .isukit/scores.tsv)"
  check -f "$(ls -1d .isukit/runs/* | tail -1)/meta"
}

t_stale_pprof_never_saved() {
  setup_state isu1 "" "$ROLES"
  sed -i.bak "s|^BENCH_MODE=manual|BENCH_MODE=auto|; s|^BENCH_CMD=''|BENCH_CMD='./bench'|" .isukit/config && rm -f .isukit/config.bak
  load
  rpull() { printf 'PULLED %s\n' "$2" >> "$CALLS"; }
  cmd_bench "no endpoint" >/dev/null 2>&1        # curl gets no 200: the profile is skipped
  check -n "$(grep 'rm -f /tmp/isukit-cpu.pprof' "$CALLS")"   # old files cleared regardless
  check -z "$(grep PULLED "$CALLS")"
  check ! -e "$(ls -1d .isukit/runs/* | tail -1)/cpu.pprof"
}

t_show_out_of_range() {
  setup_state isu1 "" "$ROLES"
  mkdir -p .isukit/runs/20260101-000000 .isukit/runs/20260102-000000
  ( cmd_show 3 ) >/dev/null 2>&1; check "$?" != 0
  ( cmd_show 0 ) >/dev/null 2>&1; check "$?" != 0
  check -n "$(cmd_show 2 2>/dev/null | grep 'runs/20260101-000000')"
}

case_ legacy-layout-without-hosts-file t_legacy_layout
case_ restart-hits-app-hosts-only     t_restart_app_hosts_only
case_ logs-split-nginx-web-mysql-db   t_logs_split_by_role
case_ alp-on-web-slow-on-db           t_alp_slow_route
case_ role-units-per-host             t_role_units
case_ host-role-seeds-hosts-file      t_host_role_seeds_file
case_ on-hosts-isolates-and-continues t_on_hosts_isolates_and_continues
case_ deploy-each-app-host-restart-once t_deploy_builds_each_app_host_restarts_once
case_ etc-push-followups-run-once     t_etc_push_fleet_followups_once
case_ bench-measures-one-run          t_bench_measures_run
case_ bench-clean-when-logs-off       t_bench_clean_when_logs_off
case_ manual-score-collects-its-run   t_manual_score_collects_run
case_ logs-space-guard-on-db-hosts    t_logs_space_guard_on_db_hosts
case_ etc-pull-leaves-out-disagreeing t_etc_pull_leaves_out_disagreeing_files
case_ host-app-moves-hosts-line       t_host_app_moves_hosts_line
case_ catchall-follows-app-key        t_catchall_follows_app_key
case_ bench-records-score-on-failure  t_bench_records_score_when_collection_fails
case_ stale-pprof-never-saved         t_stale_pprof_never_saved
case_ show-out-of-range-errors        t_show_out_of_range

echo "$TOTAL fixtures, $PASSED passed, $((TOTAL-PASSED)) failed"
[ -z "$FAILED" ]
