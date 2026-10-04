#!/bin/bash
# Runs ON A WEB OR APP HOST, sent by `isukit finalize` over `ssh host bash -s`.
#
# "The unit is active" is not "it answers": an app that came back without its
# DB, or nginx with no upstream left, is active and returns 502 / 500. Asks
# over HTTP, from the host itself, and retries while the box is still starting.
#   web: http://localhost<PATH>            — through nginx, so the upstream too
#   app: http://127.0.0.1:<port><PATH>    — the app directly; the port is the
#        one its unit's main process listens on (or APP_PORT if given)
# 2xx-4xx is an answer (an API root may well 404); no answer or 5xx is not.
# Prints one line:  OK|<url>|<code>   or   FAIL|<url>|<code or reason>
#
# Inputs (isukit prepends them as VAR=value lines):
#   MODE      web | app
#   PATH_     the path to request (default /)
#   APP_UNIT  app mode: the unit whose listening port to use
#   APP_PORT  app mode: use this port instead of discovering it
#   WAIT      seconds to keep retrying (default 60)

set -u
P="${PATH_:-/}"
case "$P" in /*) ;; *) P="/$P" ;; esac

if [ "${MODE:-web}" = app ]; then
  port="${APP_PORT:-}"
  if [ -z "$port" ]; then
    pid=$(systemctl show -p MainPID --value "${APP_UNIT:-}" 2>/dev/null)
    if [ -n "$pid" ] && [ "$pid" != 0 ] && command -v ss >/dev/null 2>&1; then
      # the main process or one of its children (a wrapper script execs the app)
      pids=" $pid $(pgrep -P "$pid" 2>/dev/null | tr '\n' ' ')"
      port=$(sudo -n ss -ltnpH 2>/dev/null | awk -v pids="$pids" '{
               if (match($0, /pid=[0-9]+/)) { p = substr($0, RSTART + 4, RLENGTH - 4)
                 if (index(pids, " " p " ")) { n = split($4, a, ":"); print a[n]; exit } } }')
    fi
  fi
  [ -n "$port" ] || { echo "FAIL|${APP_UNIT:-app}|no listening port found for the unit (set FINAL_APP_PORT)"; exit 0; }
  url="http://127.0.0.1:$port$P"
else
  url="http://localhost$P"
fi

end=$(( $(date +%s) + ${WAIT:-60} ))
code=000
while :; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null) || true
  case "$code" in
    2??|3??|4??) echo "OK|$url|$code"; exit 0 ;;
  esac
  [ "$(date +%s)" -ge "$end" ] && break
  sleep 2
done
[ "$code" = 000 ] && code="no answer"
echo "FAIL|$url|$code"
exit 0
