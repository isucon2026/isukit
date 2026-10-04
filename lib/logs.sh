# shellcheck shell=bash
# isukit lib/logs.sh — `isukit setup` (tools per role) and `isukit logs on|off`.
# Sourced by ../isukit; not meant to run on its own.

cmd_setup() { load; on_hosts all setup_one; }

setup_one() { # alp on web hosts, percona-toolkit on db hosts, sysstat (pidstat) everywhere
  local roles web=0 db=0
  roles=",$(host_roles "$APP"),"
  case "$roles" in *,web,*) web=1 ;; esac
  case "$roles" in *,db,*) db=1 ;; esac
  say "installing tools on $APP ($(host_roles "$APP"))"
  { printf 'WANT_ALP=%s\nWANT_PTQD=%s\n' "$web" "$db"; cat <<'EOS'
set -e
apt_get() { sudo DEBIAN_FRONTEND=noninteractive apt-get "$@"; }
command -v pidstat >/dev/null || {
  apt_get update -qq && apt_get install -y -qq sysstat >/dev/null && echo "sysstat installed"
} || echo "sysstat install failed (non-fatal — bench runs lose per-process CPU)"
# Ubuntu turns sysstat's background collectors on at install; isukit only runs
# pidstat during a bench, and a collector firing mid-run costs score
sudo systemctl disable --now sysstat sysstat-collect.timer sysstat-summary.timer >/dev/null 2>&1 || true
[ "$WANT_ALP" = 1 ] && ! command -v alp >/dev/null && {
  V=1.0.21; A=$(uname -m); case "$A" in x86_64) A=amd64;; aarch64) A=arm64;; esac
  cd /tmp && curl -fsSL -o alp.tar.gz "https://github.com/tkuchiki/alp/releases/download/v${V}/alp_linux_${A}.tar.gz" \
    && tar xzf alp.tar.gz && sudo install -m755 alp /usr/local/bin/alp && echo "alp installed"
}
[ "$WANT_PTQD" = 1 ] && ! command -v pt-query-digest >/dev/null && {
  apt_get update -qq && apt_get install -y -qq percona-toolkit >/dev/null && echo "percona-toolkit installed"
} || true
exit 0
EOS
  } | rsh_stdin "$APP"
  say "done"
}

cmd_logs() {
  load
  lock_guard "logs ${1:-}"
  local mode="${1:-}"
  case "$mode" in on|off) ;; *) die "usage: isukit logs {on|off}" ;; esac
  local h roles wn wm any_db=0 rc=0
  for h in $(hosts_all); do
    roles=",$(host_roles "$h"),"
    wn=0; wm=0
    case "$roles" in *,web,*) wn=1 ;; esac
    case "$roles" in *,db,*)  wm=1; any_db=1 ;; esac
    [ "$wn$wm" = 00 ] && continue
    say "logs $mode on $h"
    # ISUCON practice AMIs commonly ship an 8GB root. long_query_time=0 logs
    # every query, and a benchmark run can produce gigabytes of slow log fast
    # enough to fill that root and wedge the box mid-run — warn, but still
    # enable it, since a short run under thin headroom may be exactly what's wanted.
    if [ "$mode" = on ] && [ "$wm" = 1 ]; then
      local avail_kb
      avail_kb=$(rsh "$h" "df -P /tmp | tail -1 | tr -s ' ' | cut -d' ' -f4" 2>/dev/null || true)
      if [ -n "$avail_kb" ]; then
        if [ "$avail_kb" -lt 2097152 ] 2>/dev/null; then
          warn "only $((avail_kb / 1024))MB free on /tmp on $h — long_query_time=0 logs EVERY query; a benchmark run can produce gigabytes and a full root wedges the box. enabling anyway."
        fi
      else
        warn "could not check free space on /tmp on $h before enabling slow logging"
      fi
    fi
    { printf 'MODE=%s\nWANT_NGINX=%s\nWANT_MYSQL=%s\n' "$mode" "$wn" "$wm"; remote_script logs.sh; } | rsh_stdin "$h" || rc=1
  done
  # long_query_time applies to new sessions only: make every app host reconnect,
  # wherever the db lives.
  if [ "$mode" = on ] && [ "$any_db" = 1 ] && [ -n "${APP_UNIT:-}" ]; then
    ( cmd_restart ) || warn "could not restart the app — the slow log only sees connections opened after: isukit restart"
  fi
  return "$rc"
}

logs_are_on() { # on this host: nginx carries isukit logging, or mysql logs to isukit's slow log
  rsh "$APP" "test -f /etc/nginx/conf.d/00-isukit.conf || [ \"\$(sudo -n mysql -N -B -e 'SELECT CONCAT(@@global.slow_query_log, @@global.slow_query_log_file)' 2>/dev/null)\" = 1/tmp/isukit-slow.log ]" 2>/dev/null
}
