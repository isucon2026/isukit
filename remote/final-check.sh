#!/bin/bash
# Runs ON EVERY HOST, sent by `isukit final check` over `ssh host bash -s`.
#
# Before the last scoring run, every byte a request writes that nobody will
# read costs score. Lists what this host still logs or runs for measurement,
# by its roles, without changing anything. One line per finding:
#   FIX|<what>|<how>
#
# Inputs (isukit prepends them as VAR=value lines):
#   WANT_NGINX  1 = web host     WANT_MYSQL  1 = db host
#   APP_UNIT    the app unit, checked for how much it logs (app hosts; may be empty)
#   ETC_ROOT    default /etc (tests point it elsewhere)
#   SUDO        default "sudo -n"

set -u
SUDO="${SUDO-sudo -n}"
E="${ETC_ROOT:-/etc}"
fix() { printf 'FIX|%s|%s\n' "$1" "$2"; }

# --- isukit's own measurement
[ -f "$E/nginx/conf.d/00-isukit.conf" ] && fix "isukit measurement logging is still on" "isukit logs off"
if [ -f /tmp/isukit-run/pids ]; then
  # shellcheck disable=SC2046  # one pid per word
  if kill -0 $(cat /tmp/isukit-run/pids) 2>/dev/null; then
    fix "isukit samplers (vmstat/pidstat) still running" "isukit final apply"
  fi
fi
left=""
for f in /var/log/nginx/isukit.log /tmp/isukit-slow.log /tmp/isukit-alp.log /tmp/isukit-cpu.pprof /tmp/isukit-run; do
  $SUDO test -e "$f" && left="$left $f"
done
[ -n "$left" ] && fix "measurement files left:$left" "isukit final apply"
for t in sysstat-collect.timer sysstat-summary.timer sysstat.service; do
  systemctl is-active --quiet "$t" 2>/dev/null && fix "$t is active (collects stats in the background)" "isukit final apply"
done

# --- nginx: every request appends a line unless access_log is off
if [ "${WANT_NGINX:-0}" = 1 ] && [ -d "$E/nginx" ]; then
  on=$($SUDO find -L "$E/nginx" -type f \( -name '*.conf' -o -path "$E/nginx/sites-enabled/*" \) \
         -exec grep -HnE '^[[:space:]]*access_log[[:space:]]+[^o;][^;]*;' {} + 2>/dev/null \
         | grep -vE 'access_log[[:space:]]+off[[:space:]]*;' | sed "s|^$E/||")
  if [ -n "$on" ]; then
    printf '%s\n' "$on" | while IFS= read -r l; do fix "nginx access_log on: ${l%%:*}:$(printf '%s' "$l" | cut -d: -f2)" "isukit final apply (access_log off;)"; done
  elif ! $SUDO grep -RqsE '^[[:space:]]*access_log[[:space:]]+off[[:space:]]*;' "$E/nginx"; then
    fix "nginx has no access_log directive, so it logs to the compiled-in default" "isukit final apply (access_log off; in http {})"
  fi
fi

# --- mysql: the slow / general log, live and in the config that a restart reads
if [ "${WANT_MYSQL:-0}" = 1 ]; then
  if $SUDO mysql -e "SELECT 1" >/dev/null 2>&1; then
    for v in slow_query_log general_log; do
      [ "$($SUDO mysql -N -B -e "SELECT @@GLOBAL.$v" 2>/dev/null)" = 1 ] && fix "mysql $v is ON (live)" "isukit final apply"
    done
  fi
  if [ -d "$E/mysql" ]; then
    $SUDO find -L "$E/mysql" -type f -name '*.cnf' -exec grep -HniE '^[[:space:]]*(slow_query_log|slow-query-log|general_log|general-log)[[:space:]]*=[[:space:]]*(1|on)\b' {} + 2>/dev/null \
      | sed "s|^$E/||" | while IFS= read -r l; do
          fix "mysql config turns a log on: $(printf '%s' "$l" | cut -d: -f1,2)" "isukit final apply (set to 0 in etc/)"
        done
  fi
fi

# --- the app's own logging, by volume: the journal sees its stdout/stderr
if [ -n "${APP_UNIT:-}" ] && command -v journalctl >/dev/null 2>&1; then
  n=$($SUDO journalctl -u "$APP_UNIT" --since "-10min" --no-pager -q 2>/dev/null | wc -l | tr -d ' ')
  [ "${n:-0}" -gt 1000 ] 2>/dev/null && fix "$APP_UNIT wrote $n log lines in the last 10 minutes" "drop per-request logging in the app (see the code findings)"
fi
exit 0
