# shellcheck shell=bash
# isukit lib/analyze.sh — `isukit alp`, `slow`, `pprof`, `os`.
# Sourced by ../isukit; not meant to run on its own.

cmd_alp() { # alp [--patterns]
  load
  case "${1:-}" in
    --patterns) ALP_PRINT=1 ;;
    "") ;;
    *) die "usage: isukit alp [--patterns]" ;;
  esac
  on_hosts web alp_one
}

alp_one() { # alp_one [log] -- default: this host's live isukit.log
  local log="${1:-/var/log/nginx/isukit.log}"
  rsh "$APP" "command -v alp >/dev/null" || {
    warn "alp not installed on $APP — installing"
    setup_one
    rsh "$APP" "command -v alp >/dev/null" || die "alp still not installed after isukit setup — install by hand on $APP"
  }
  rsh "$APP" "sudo -n test -s '$log' 2>/dev/null" || \
    die "no requests in $log — run: isukit logs on, then a bench"
  # grouping regexes come from the log itself (remote/alp.sh); ALP_MATCHES in
  # the config replaces them with your own when the derived ones are wrong
  if [ "${ALP_PRINT:-0}" = 1 ]; then
    say "alp groups on $APP ($([ -n "${ALP_MATCHES:-}" ] && echo "ALP_MATCHES from config" || echo "derived from the log"))"
  else
    say "alp (sorted by summed response time — the only ranking that matters)"
  fi
  { printf 'LOG=%q\nMATCHES=%q\nTHRESH=%q\nPRINT_MATCHES=%q\n' "$log" "${ALP_MATCHES:-}" "${ALP_THRESH:-20}" "${ALP_PRINT:-0}"
    remote_script alp.sh; } | rsh_stdin "$APP"
}

cmd_slow() { load; on_hosts db slow_one; }

slow_one() {
  rsh "$APP" "sudo -n test -s /tmp/isukit-slow.log 2>/dev/null" || \
    die "no slow log (or it's empty) — run: isukit logs on, then a bench"
  rsh "$APP" "command -v pt-query-digest >/dev/null" || {
    warn "pt-query-digest not installed on $APP — installing"
    setup_one
    rsh "$APP" "command -v pt-query-digest >/dev/null" || die "pt-query-digest still not installed after isukit setup — install by hand on $APP"
  }
  say "pt-query-digest (top queries by total time)"
  rsh "$APP" "set -o pipefail; sudo -n pt-query-digest --limit=15 /tmp/isukit-slow.log | head -80"
}

cmd_pprof() {
  load
  local sec="${1:-30}" port="${2:-6060}"
  APP=$(hosts_with app | head -1)
  [ -n "$APP" ] || die "no host has role app — set one: isukit host role <target> app"
  say "CPU profile ${sec}s via $APP:$port/debug/pprof — needs net/http/pprof imported and a listener in the app"
  rsh "$APP" "curl -s -o /tmp/isukit-cpu.pprof 'http://localhost:$port/debug/pprof/profile?seconds=$sec'" \
    || die "pprof endpoint not reachable — add: import _ \"net/http/pprof\"  +  go func(){ http.ListenAndServe(\":$port\", nil) }()"
  rpull "$APP" /tmp/isukit-cpu.pprof "$STATE/cpu.pprof"
  say "go tool pprof -http=: $STATE/cpu.pprof"
}

cmd_os() { load; on_hosts all os_one; }

os_one() {
  local units
  units=$(role_units "$APP")
  say "os snapshot on $APP"
  { printf 'CHECK_UNITS=%q\n' "$units"; remote_script os.sh; } | rsh_stdin "$APP"
}
