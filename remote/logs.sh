#!/bin/bash
# Runs ON WEB / DB HOSTS, sent by `isukit logs on|off` over `ssh host bash -s`.
#
# Turns measurement logging on or off: nginx LTSV (web hosts) and the MySQL
# slow log at long_query_time=0 (db hosts). Must be off for scoring runs.
#
# Inputs (isukit prepends them as VAR=value lines):
#   MODE        on | off
#   WANT_NGINX  1 = this host is a web host (default 1)
#   WANT_MYSQL  1 = this host is a db host (default 1)

set -u
SUDO="sudo -n"
RC=0
# find -L + readlink -f: once `isukit etc adopt` has run, nginx.conf and the site
# confs are symlinks into the repo. grep -r skips them, and sed -i on the link
# would replace it with a plain file and silently cut the repo out. Edit the real
# file behind every link instead (sites-enabled and sites-available resolve to
# the same file, hence sort -u).
ngx_files() {
  find -L /etc/nginx -type f ! -name "*.isukit-tmp" -exec grep -lE "$1" {} + 2>/dev/null \
    | while IFS= read -r f; do readlink -f "$f"; done | sort -u
}
# --- nginx: LTSV carrying request_time, which the stock "combined" format lacks.
# WANT_NGINX / WANT_MYSQL: which tiers this host holds (its roles); default both.
if [ "${WANT_NGINX:-1}" = 1 ] && systemctl is-active --quiet nginx 2>/dev/null; then
  if [ "$MODE" = on ]; then
    [ -d /etc/nginx.isukit.bak ] || $SUDO cp -a /etc/nginx /etc/nginx.isukit.bak
    $SUDO mkdir -p /etc/nginx/conf.d
    $SUDO tee /etc/nginx/conf.d/00-isukit.conf >/dev/null <<"NGXCONF"
log_format ltsv "time:$time_iso8601\tmethod:$request_method\turi:$request_uri\tstatus:$status\tsize:$body_bytes_sent\treqtime:$request_time\tapptime:$upstream_response_time\tvhost:$host";
access_log /var/log/nginx/isukit.log ltsv;
NGXCONF
    for f in $(ngx_files "^[[:space:]]*access_log" | grep -v 00-isukit.conf); do
      $SUDO sed -i.isukit-tmp "s|^\([[:space:]]*\)access_log|\1#isukit# access_log|" "$f" && $SUDO rm -f "$f.isukit-tmp"
    done
    NGX_MAIN=$(readlink -f /etc/nginx/nginx.conf)
    grep -qE "include.*conf\.d" "$NGX_MAIN" 2>/dev/null || \
      $SUDO sed -i "0,/^http {/s|^http {|http {\n    include /etc/nginx/conf.d/*.conf; # isukit-include|" "$NGX_MAIN"
    if $SUDO nginx -t && $SUDO systemctl reload nginx; then
      echo "nginx: ltsv -> /var/log/nginx/isukit.log"
    else
      echo "nginx: FAILED to enable ltsv logging" >&2
      RC=1
    fi
  else
    # Undo exactly what "on" did, by its markers. Restoring /etc/nginx.isukit.bak
    # wholesale would clobber repo symlinks made after the backup (or resurrect
    # stale ones), and throw away any tuning done since. The backup stays on disk
    # for manual recovery only.
    MARKED=$(ngx_files "#isukit# |# isukit-include$")
    if [ -f /etc/nginx/conf.d/00-isukit.conf ] || [ -n "$MARKED" ]; then
      $SUDO rm -f /etc/nginx/conf.d/00-isukit.conf
      for f in $MARKED; do
        $SUDO sed -i.isukit-tmp -e "s|#isukit# access_log|access_log|" -e "/# isukit-include$/d" "$f" && $SUDO rm -f "$f.isukit-tmp"
      done
      if $SUDO nginx -t && $SUDO systemctl reload nginx; then
        echo "nginx: isukit logging removed, original access_log lines back"
      else
        echo "nginx: FAILED to reload after removing isukit logging (backup: /etc/nginx.isukit.bak)" >&2
        RC=1
      fi
    fi
  fi
fi
# --- mysql: long_query_time=0 captures every query. MUST be off for scoring runs.
if [ "${WANT_MYSQL:-1}" = 1 ] && $SUDO mysql -e "SELECT 1" >/dev/null 2>&1; then
  if [ "$MODE" = on ]; then
    if $SUDO mysql -e "SET GLOBAL slow_query_log_file=\"/tmp/isukit-slow.log\"; SET GLOBAL long_query_time=0; SET GLOBAL slow_query_log=1;" 2>/dev/null; then
      echo "mysql: slow log -> /tmp/isukit-slow.log (long_query_time=0)"
    else
      echo "mysql: FAILED to enable slow log" >&2
      RC=1
    fi
  else
    if $SUDO mysql -e "SET GLOBAL slow_query_log=0;" 2>/dev/null; then
      echo "mysql: slow log off"
    else
      echo "mysql: FAILED to disable slow log" >&2
      RC=1
    fi
  fi
fi
exit $RC
