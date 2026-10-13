#!/bin/bash
# Runs ON A WEB OR APP HOST, sent by `isukit finalize` over `ssh host bash -s`.
#
# "The unit is active" is not "it answers": an app that came back without its
# DB, or nginx with no upstream left, is active and returns 502 / 500. Asks
# over HTTP, from the host itself, and retries while the box is still starting.
#   web: through nginx, to the server block that proxies to the app — its listen
#        port and scheme, its server_name as the Host (curl --resolve to this
#        host, -k for a self-signed cert), all read off `nginx -T`. A site on
#        443 with a server_name never sees http://localhost/: that lands on the
#        default server, which answers 404 itself and never reaches the app.
#        WEB_URL (scheme://name[:port]) names the site instead; with no
#        proxying server block found, http://localhost.
#   app: http://127.0.0.1:<port><PATH> — the app directly; the port is the
#        one its unit's main process listens on (or APP_PORT if given)
# 2xx-4xx from the app is an answer (an API root may well 404); no answer or
# 5xx is not, and neither is a 4xx nginx wrote itself (its own error page: the
# default server, a deny, a location with no proxy) — that one never reached it.
# Prints one line:  OK|<url>|<code>   or   FAIL|<url>|<code or reason>
#
# Inputs (isukit prepends them as VAR=value lines):
#   MODE      web | app
#   PATH_     the path to request (default /)
#   WEB_URL   web mode: scheme://name[:port] of the site, instead of reading nginx -T
#   APP_UNIT  app mode: the unit whose listening port to use
#   APP_PORT  app mode: use this port instead of discovering it
#   WAIT      seconds to keep retrying (default 60)
#   SUDO      default "sudo -n" (tests set it empty)

set -u
SUDO="${SUDO-sudo -n}"
P="${PATH_:-/}"
case "$P" in /*) ;; *) P="/$P" ;; esac

nginx_site() { # "<scheme> <port> <addr> <name>" of the first server block that proxies somewhere
  $SUDO nginx -T 2>/dev/null | awk '
    function flush() {
      if (insrv && pass && port != "") print scheme, port, addr, (name == "" ? "localhost" : name)
      insrv = 0
    }
    # nginx -T prints each file whole, includes not inlined: depth restarts per file
    /^# configuration file / { flush(); depth = 0; next }
    {
      line = $0; sub(/#.*/, "", line)
      if (!insrv && line ~ /(^|[[:space:];{}])server[[:space:]]*\{/) {
        insrv = 1; sdepth = depth; pass = 0; port = ""; addr = ""; scheme = "http"; name = ""; v6 = 0
      }
      if (insrv) {
        if (line ~ /^[[:space:]]*listen[[:space:]]/) {
          l = line; sub(/^[[:space:]]*listen[[:space:]]+/, "", l); sub(/;.*/, "", l)
          n = split(l, t, /[[:space:]]+/)
          ssl = 0; quic = 0
          for (i = 2; i <= n; i++) { if (t[i] == "ssl") ssl = 1; if (t[i] == "quic") quic = 1 }
          a = t[1]; p = ""; ip = ""; six = 0
          if (a ~ /^unix:/ || quic) a = ""
          else if (substr(a, 1, 1) == "[") {
            six = 1; k = index(a, "]"); ip = substr(a, 1, k); p = substr(a, k + 1); sub(/^:/, "", p)
          }
          else if (a ~ /^[0-9]+$/) p = a
          else if (a ~ /:/) { ip = a; sub(/:[^:]*$/, "", ip); p = a; sub(/^.*:/, "", p) }
          else ip = a
          if (a != "") {
            if (p == "") p = 80
            if (ip == "" || ip == "*" || ip == "0.0.0.0" || ip == "[::]" || ip == "localhost") ip = "127.0.0.1"
            # the first IPv4 listen wins; an IPv6-only one only when there is nothing else
            if (port == "" || (v6 && !six)) {
              port = p; addr = ip; v6 = six; scheme = (ssl || p == 443) ? "https" : "http"
            }
          }
        }
        if (name == "" && line ~ /^[[:space:]]*server_name[[:space:]]/) {
          l = line; sub(/^[[:space:]]*server_name[[:space:]]+/, "", l); sub(/;.*/, "", l)
          n = split(l, t, /[[:space:]]+/)
          for (i = 1; i <= n && name == ""; i++) {
            s = t[i]
            if (s == "" || s == "_" || s == "\"\"" || s ~ /^~/) continue
            sub(/^\*\./, "isukit.", s); sub(/^\./, "", s); sub(/\.\*$/, ".com", s)
            name = s
          }
        }
        if (line ~ /(^|[[:space:];{])(proxy|fastcgi|uwsgi|scgi|grpc)_pass[[:space:]]/) pass = 1
      }
      o = line; depth += gsub(/\{/, "", o); depth -= gsub(/\}/, "", o)
      if (insrv && depth <= sdepth) flush()
    }
    END { flush() }' | head -1
}

resolve=()
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
  scheme=""; wport=""; addr=127.0.0.1; name=""
  if [ -n "${WEB_URL:-}" ]; then
    scheme=http; case "$WEB_URL" in *://*) scheme="${WEB_URL%%://*}" ;; esac
    name="${WEB_URL#*://}"; name="${name%%/*}"
    case "$name" in *:*) wport="${name##*:}"; name="${name%:*}" ;; esac
    if [ -z "$wport" ]; then
      if [ "$scheme" = https ]; then wport=443; else wport=80; fi
    fi
  else
    read -r scheme wport addr name <<< "$(nginx_site)"
  fi
  if [ -n "$name" ] && [ -n "$wport" ]; then
    url="$scheme://$name:$wport$P"
    resolve=(-k --resolve "$name:$wport:$addr")
  else
    url="http://localhost$P"
  fi
fi

body=$(mktemp); trap 'rm -f "$body"' EXIT
end=$(( $(date +%s) + ${WAIT:-60} ))
code=000
while :; do
  : > "$body"
  code=$(curl -s -o "$body" -w '%{http_code}' --max-time 5 ${resolve[@]+"${resolve[@]}"} "$url" 2>/dev/null) || true
  case "$code" in
    2??|3??) echo "OK|$url|$code"; exit 0 ;;
    4??)
      # nginx's own error page: nginx answered by itself, so the app (and the DB
      # behind it) were never asked. waiting does not change that.
      if [ "${MODE:-web}" != app ] && grep -qi '<center>nginx' "$body" 2>/dev/null; then
        echo "FAIL|$url|$code from nginx itself, never reached the app (the default server? set FINAL_WEB_URL)"
        exit 0
      fi
      echo "OK|$url|$code"; exit 0 ;;
  esac
  [ "$(date +%s)" -ge "$end" ] && break
  sleep 2
done
[ "$code" = 000 ] && code="no answer"
echo "FAIL|$url|$code"
exit 0
