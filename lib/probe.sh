# shellcheck shell=bash
# isukit lib/probe.sh — `isukit probe` (every host -> manifests), benchprobe / benchcmd / benchmode, unit.
# Sourced by ../isukit; not meant to run on its own.

# The whole point of the kit. Interrogates the RUNNING SERVER, not the repo.

cmd_probe() {
  load
  local override
  override=$( . "$CONF" 2>/dev/null; printf '%s' "${APP_UNIT_OVERRIDE:-}" )
  say "probing app host: $APP"
  { printf 'APP_UNIT_OVERRIDE=%s\n' "$override"; remote_script probe.sh; } | rsh_stdin "$APP" > "$STATE/manifest.tmp" \
    || die "probe failed — check connectivity by hand: ssh ${SSH_OPTS:-} $APP true"
  mv "$STATE/manifest.tmp" "$STATE/manifest"
  cat "$STATE/manifest"
  echo
  . "$STATE/manifest"
  [ "${APP_UNIT:-}" = "" ] && warn "no app systemd unit found — is the app containerised? check UNITS_LOCAL / docker ps"
  if [ -n "${APP_UNIT:-}" ] && [ "${APP_UNIT_CONFIDENCE:-}" != "high" ] && [ "${APP_UNIT_CONFIDENCE:-}" != "override" ]; then
    warn "picked '$APP_UNIT' with LOW confidence — candidates: ${APP_CANDIDATES:-none}"
    warn "if that's wrong: isukit unit <name>"
  fi
  [ "${WEB_SERVER:-}" != "nginx" ] && warn "web server is '${WEB_SERVER:-none}', not nginx — 'isukit logs' handles nginx only; profile at the app layer instead"
  if [ "${STACK_IN_DOCKER:-0}" = "1" ]; then
    warn "web and/or db run as CONTAINERS, not host services — 'isukit logs on' and 'isukit slow on' edit host config and will do nothing here"
    warn "edit the compose file / container config instead, then: isukit restart"
  fi
  [ "${PROC_MANAGER:-systemd}" = "supervisor" ] && warn "app is under supervisord, not systemd — '$APP_UNIT' restarts ALL of it; per-program: supervisorctl restart <${SUPERVISOR_PROGRAMS:-name}>"
  [ "${MYSQL_OK:-0}" != "1" ] && warn "cannot reach mysql as root over socket — slow-log automation is off"
  say "manifest written to $STATE/manifest"
  cp "$STATE/manifest" "$(host_manifest "$APP")"
  probe_fleet "$override"
  # subshell: benchprobe's failure path is `die`, i.e. exit(1) of the whole
  # script. The app manifest above is already written and useful on its own, so
  # a bench host we cannot reach must not discard it — nor abort `isukit go`
  # before setup/logs have run. benchprobe only writes files, so losing its
  # shell state costs nothing.
  ( cmd_benchprobe ) || warn "benchprobe failed — set the bench path by hand: isukit benchmode manual (portal), or isukit benchcmd '<command>'"
}

probe_fleet() { # probe_fleet <unit-override> -- every other host into manifest.<host>, then compare
  local override="$1" h f
  local primary="$APP"
  for h in $(hosts_all); do
    [ "$h" = "$primary" ] && continue
    f=$(host_manifest "$h")
    say "probing $h ($(host_roles "$h"))"
    if { printf 'APP_UNIT_OVERRIDE=%s\n' "$override"; remote_script probe.sh; } | rsh_stdin "$h" > "$f.tmp" 2>/dev/null && [ -s "$f.tmp" ]; then
      mv "$f.tmp" "$f"
    else
      rm -f "$f.tmp"; warn "could not probe $h — its checks fall back to what other hosts report"
    fi
  done
  [ "$(hosts_all | wc -l | tr -d ' ')" -gt 1 ] || return 0
  # what the roles promise vs what each box is actually running
  local roles v pv db_unit
  db_unit=$(host_fact "$primary" DB_SERVER)
  for h in $(hosts_all); do
    f=$(host_manifest "$h"); [ -f "$f" ] || continue
    roles=",$(host_roles "$h"),"
    case "$roles" in *,app,*)
      for v in APP_UNIT SRC_DIR GO_DIR; do
        pv=$( . "$STATE/manifest" 2>/dev/null; eval "printf '%s' \"\${$v:-}\"" )
        local hv; hv=$( . "$f" 2>/dev/null; eval "printf '%s' \"\${$v:-}\"" )
        [ "$hv" = "$pv" ] || warn "$h: $v is '${hv:-none}' but '${pv:-none}' on $primary — deploy/restart assume app hosts match the probed one"
      done ;;
    esac
    local hdb; hdb=$( . "$f" 2>/dev/null; printf '%s' "${DB_SERVER:-}" )
    case "$roles" in
      *,db,*) [ -n "$hdb" ] || warn "$h has role db but no running mysql/mariadb/postgresql was found on it" ;;
      *)      [ -z "$hdb" ] || warn "$h has no db role but $hdb is running there — once the split is done: ssh $h sudo systemctl disable --now $hdb" ;;
    esac
    case "$roles" in *,web,*)
      local hweb; hweb=$( . "$f" 2>/dev/null; printf '%s' "${WEB_SERVER:-}" )
      [ -n "$hweb" ] || warn "$h has role web but no running web server was found on it" ;;
    esac
  done
  [ -n "$db_unit" ] || [ -z "$(hosts_with db)" ] || [ -n "$(host_fact "$(hosts_with db | head -1)" DB_SERVER)" ] \
    || warn "no host reports a datastore — finalize/doctor cannot check the db role"
  return 0
}

db_left_enabled() { # print each non-db host where the fleet's DB unit is still enabled (comes back on reboot)
  local h u
  [ -f "$HOSTS_FILE" ] || return 0
  u=$(host_fact "$(hosts_with db | head -1)" DB_SERVER)
  [ -n "$u" ] || return 0
  for h in $(hosts_all); do
    case ",$(host_roles "$h")," in *,db,*) continue ;; esac
    [ "$(rsh "$h" "systemctl is-enabled '$u' 2>/dev/null" 2>/dev/null)" = enabled ] && printf '%s %s\n' "$h" "$u"
  done
  return 0
}

cmd_unit() {
  need_state
  local name="${1:-}"; [ -n "$name" ] || die "usage: isukit unit <systemd-unit-name>"
  if grep -q "^APP_UNIT_OVERRIDE=" "$CONF" 2>/dev/null; then
    sed -i.bak "s|^APP_UNIT_OVERRIDE=.*|APP_UNIT_OVERRIDE=$name|" "$CONF"; rm -f "$CONF.bak"
  else
    printf 'APP_UNIT_OVERRIDE=%s\n' "$name" >> "$CONF"
  fi
  say "APP_UNIT_OVERRIDE = $name — re-probing"
  cmd_probe
}

# The other thing that varies every year: how to invoke the benchmarker.
# Same discipline as PROBE_SCRIPT — read it off the binary's own --help,
# never a per-year lookup table.

cmd_benchprobe() {
  load
  say "probing benchmarker on $BENCH"
  remote_script bench-probe.sh | rsh_stdin "$BENCH" > "$STATE/bench-manifest.tmp" \
    || die "benchprobe failed — check connectivity by hand: ssh ${SSH_OPTS:-} $BENCH true"
  mv "$STATE/bench-manifest.tmp" "$STATE/bench-manifest"
  cat "$STATE/bench-manifest"
  echo
  . "$STATE/bench-manifest"

  if [ -z "${BENCH_BIN:-}" ]; then
    warn "no benchmarker binary found under /home/isucon on $BENCH — expected on contest day, the portal runs the bench for you"
    if grep -q "^BENCH_MODE=auto" "$CONF" 2>/dev/null && grep -q "^BENCH_CMD=''" "$CONF" 2>/dev/null; then
      sed -i.bak "s|^BENCH_MODE=.*|BENCH_MODE=manual|" "$CONF"; rm -f "$CONF.bak"
      say "BENCH_MODE = manual — 'isukit bench' will now prompt for the portal score"
    fi
    return 0
  fi

  if [ -n "${BENCH_HELP_FILE:-}" ]; then
    rpull "$BENCH" "$BENCH_HELP_FILE" "$STATE/bench-help.txt" 2>/dev/null || warn "could not pull help text ($BENCH_HELP_FILE)"
  fi

  local binbase cmdline
  binbase=$(basename "$BENCH_BIN")
  cmdline="cd ${BENCH_DIR:-.} && ./$binbase"
  [ -n "${BENCH_SUBCMD:-}" ] && cmdline="$cmdline $BENCH_SUBCMD"
  case "${BENCH_TARGET_FLAG:-}" in
    *-addr) cmdline="$cmdline $BENCH_TARGET_FLAG 127.0.0.1:443" ;;
    *) ;;
  esac
  [ "${BENCH_HAS_NAMESERVER:-0}" = "1" ] && cmdline="$cmdline ${BENCH_NAMESERVER_FLAG:---nameserver} 127.0.0.1"

  local composed="sudo -iu ${BENCH_OWNER:-isucon} sh -c '$cmdline'"
  say "composed BENCH_CMD (auto, from the binary's own --help):"
  printf '    %s\n' "$composed"
  warn "unverified — see $STATE/bench-help.txt for the full flag list; if this needs correcting: isukit benchcmd '<corrected command>'"

  if grep -q "^BENCH_CMD=''" "$CONF" 2>/dev/null; then
    cmd_benchcmd "$composed"
  else
    warn "BENCH_CMD already set in $CONF — leaving it, the line above is FYI only"
  fi
}

cmd_benchcmd() {
  need_state
  local line="${1:-}"
  if [ -z "$line" ]; then
    ( . "$CONF" 2>/dev/null; printf '%s\n' "${BENCH_CMD:-}" )
    return 0
  fi
  local q r
  q=$(printf '%s' "$line" | sed "s/'/'\\\\''/g")
  r=$(printf '%s' "$q" | sed 's/[\&|]/\\&/g')
  sed -i.bak "s|^BENCH_CMD=.*|BENCH_CMD='$r'|" "$CONF"; rm -f "$CONF.bak"
  say "BENCH_CMD = $line"
}

cmd_benchmode() {
  need_state
  local mode="${1:-}"
  if [ -z "$mode" ]; then
    ( . "$CONF" 2>/dev/null; printf '%s\n' "${BENCH_MODE:-auto}" )
    return 0
  fi
  case "$mode" in
    auto|manual) ;;
    *) die "usage: isukit benchmode [auto|manual]" ;;
  esac
  sed -i.bak "s|^BENCH_MODE=.*|BENCH_MODE=$mode|" "$CONF"; rm -f "$CONF.bak"
  say "BENCH_MODE = $mode"
}
