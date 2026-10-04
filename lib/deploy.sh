# shellcheck shell=bash
# isukit lib/deploy.sh — `isukit deploy`, `restart`, `finalize`.
# Sourced by ../isukit; not meant to run on its own.

cmd_deploy() {
  load
  local force=0
  [ "${1:-}" = "--force" ] && force=1
  lock_guard deploy
  [ "$force" = 1 ] || deploy_guard
  # configs first: once /etc links into the repo, the repo's etc/ is what runs.
  # (hosts that do not link /etc yet are skipped inside the push)
  if [ -d "$(local_repo_root)/etc" ] && [ -n "${ETC_REPO:-${SRC_DIR:-}}" ]; then
    cmd_etc_push --from-deploy || warn "etc push reported errors (above) — continuing with the app deploy"
  fi
  # env files too: the restart below picks them up
  if [ -d "$(local_repo_root)/hosts" ]; then
    cmd_env_push --from-deploy || warn "env push reported errors (above) — continuing with the app deploy"
  fi
  on_hosts app deploy_one "$force" || die "deploy failed on some app host (above) — not restarting a half-deployed fleet"
  # compose mode brings each host up itself; binary mode restarts once, everywhere
  [ "${APP_EXEC_RAW#*compose}" != "${APP_EXEC_RAW:-}" ] || cmd_restart
  deploy_record
  local d_sha d_branch
  read -r d_sha d_branch <<< "$(deployed)"
  printf '🚀 %s deployed %s `%s` to %s app host(s)\n' "$(who_am_i)" "$d_branch" "$d_sha" "$(hosts_with app | wc -l | tr -d ' ')" | notify ops
}

deploy_one() { # deploy_one <force 0|1> -- ship the source to $APP and build it there
  local force="$1"
  local local_src
  local_src=$(find . -maxdepth 4 -name go.mod -not -path "*/bench*" -not -path "*/vendor/*" | head -1)
  [ -n "$local_src" ] || die "no local go.mod found under $(pwd)"
  local_src=$(dirname "$local_src")

  if [ "${APP_EXEC_RAW#*compose}" != "${APP_EXEC_RAW:-}" ]; then
    # COMPOSE MODE: app unit runs docker compose — rsync source, then up --build.
    local cfile remote_dir
    cfile=$(printf "%s" "$APP_EXEC_RAW" | sed -n 's/.*-f *\([^ ]*\).*/\1/p')
    [ -n "$cfile" ] || die "app unit runs docker compose but no -f <file> found in ExecStart — deploy by hand"
    remote_dir=$(dirname "$cfile")
    say "COMPOSE MODE: rsync $local_src/ -> $APP:$remote_dir/"
    if [ "$APP" = "local" ]; then
      rsync -a --delete --exclude .git "$local_src/" "$remote_dir/"
    else
      rsync -a --delete --exclude .git -e "ssh ${SSH_OPTS:-}" "$local_src/" "$APP:$remote_dir/"
    fi
    say "docker compose -f $cfile up -d --build"
    rsh "$APP" "cd $remote_dir && sudo -n docker compose -f $cfile up -d --build 2>&1 | tail -40"
    return 0
  fi

  # BINARY MODE: build straight onto the path systemd already execs.
  [ -n "${GO_DIR:-}" ] || die "no GO_DIR in manifest — run: isukit probe"
  local out="${APP_EXEC:-}"
  [ -n "$out" ] || die "no APP_EXEC in manifest — run: isukit probe, or build by hand"
  if [ "$force" != 1 ]; then
    [ "${out#/home/isucon}" != "$out" ] || die "APP_EXEC ($out) isn't under /home/isucon — refusing to overwrite it. Pass --force to override."
    local out_dir
    out_dir=$(dirname "$out")
    if [ "$out_dir" != "$GO_DIR" ] && { [ -z "${APP_WORKDIR:-}" ] || [ "$out_dir" != "$APP_WORKDIR" ]; }; then
      die "APP_EXEC ($out) is not in GO_DIR ($GO_DIR) or APP_WORKDIR (${APP_WORKDIR:-unset}) — refusing to overwrite a binary outside the app's own build/work directory. Pass --force to override."
    fi
    if rsh "$APP" "test -f '$out'" 2>/dev/null; then
      local head2
      head2=$(rsh "$APP" "head -c2 '$out' 2>/dev/null" || true)
      [ "$head2" != "#!" ] || die "APP_EXEC ($out) looks like a script (starts with #!), not a Go binary — refusing to overwrite it. Pass --force to override."
    fi
  fi
  local exec_base
  exec_base=$(basename "$out")
  say "rsync $local_src/ -> $APP:$GO_DIR/"
  if [ "$APP" = "local" ]; then
    rsync -a --exclude .git --exclude "$exec_base" "$local_src/" "$GO_DIR/"
  else
    rsync -a --exclude .git --exclude "$exec_base" -e "ssh ${SSH_OPTS:-}" "$local_src/" "$APP:$GO_DIR/"
  fi
  say "building -> $out"
  local tmp="/tmp/isukit-build.$$"
  rsh "$APP" "cd $GO_DIR && go build -o $tmp . 2>&1 | head -40 && echo BUILD_OK" || die "build failed — see the compiler output above"
  rsh "$APP" "sudo -n install -m 0755 -o ${APP_USER:-isucon} $tmp '$out' && rm -f $tmp" || die "install failed — check sudo permissions for ${APP_USER:-isucon} on $APP"
}

cmd_restart() {
  load
  lock_guard restart
  local units="${APP_UNIT:-} ${EXTRA_UNITS:-}"
  units="$(printf '%s' "$units" | sed 's/^ *//;s/ *$//')"
  [ -n "$units" ] || die "no APP_UNIT in manifest — run: isukit probe"
  local h rc bad=""
  [ -n "$(hosts_with app)" ] || die "no host has role app — set one: isukit host role <target> app"
  for h in $(hosts_with app); do
    say "restarting on $h:$units"
    # never let one host abort the loop: a silent partial restart is exactly
    # what fails the post-contest verification. collect failures, report them
    # all, fail at the end. (db-only / web-only hosts are not app hosts.)
    rc=0
    rsh "$h" "sudo -n systemctl restart $units && sleep 2 && systemctl is-active $units" || rc=$?
    [ "$rc" = 0 ] || { warn "restart failed on $h (rc=$rc) — that host may not run all of: $units"; bad="$bad $h"; }
  done
  [ -z "$bad" ] || die "restart incomplete on:$bad — fix before any scoring run"
}

# Generalized reproducibility gate: the benchmark must pass after a cold boot.
# Every year, a large fraction of teams FAIL here on settings they only ever
# applied at runtime (SET GLOBAL, manual service starts, /tmp artefacts).
finalize_http() { # print one "OK|url|code" / "FAIL|url|why" per web and app host
  local h
  for h in $(hosts_with web); do
    { printf 'MODE=web\nPATH_=%q\nWAIT=%q\n' "${FINAL_CHECK_PATH:-/}" "${FINAL_HTTP_WAIT:-60}"; remote_script http-check.sh; } \
      | rsh_stdin "$h" 2>/dev/null | sed "s|^|$h |" || echo "$h FAIL|nginx|could not run the check"
  done
  for h in $(hosts_with app); do
    { printf 'MODE=app\nPATH_=%q\nAPP_UNIT=%q\nAPP_PORT=%q\nWAIT=%q\n' "${FINAL_CHECK_PATH:-/}" "${APP_UNIT:-}" "${FINAL_APP_PORT:-}" "${FINAL_HTTP_WAIT:-60}"
      remote_script http-check.sh; } \
      | rsh_stdin "$h" 2>/dev/null | sed "s|^|$h |" || echo "$h FAIL|${APP_UNIT:-app}|could not run the check"
  done
  return 0
}

cmd_finalize() {
  load
  lock_guard finalize
  local hosts
  hosts="$(hosts_all | tr '\n' ' ' | sed 's/^ *//;s/ *$//')"
  local h
  [ "$(printf '%s\n' $hosts | wc -l | tr -d ' ')" -gt 1 ] && warn "multiple hosts ($hosts) — reboot/return order across them is NOT guaranteed, never assume cross-host startup dependencies"
  local left
  left=$(db_left_enabled)
  [ -z "$left" ] || printf '%s\n' "$left" | while read -r h u; do
    warn "$h has no db role but $u is still ENABLED — it comes back on this reboot: ssh $h sudo systemctl disable --now $u"
  done
  cmd_final_check || warn "the final check found things that still cost score (above) — isukit final apply, bench, then finalize"
  say "1/4 turning measurement logging OFF (it costs real score)"
  cmd_logs off
  say "2/4 rebooting: $hosts"
  for h in $hosts; do
    rsh "$h" "sudo -n systemctl reboot" || true
  done
  say "3/4 waiting for all hosts to come back"
  for h in $hosts; do
    local i=0
    until rsh "$h" "true" 2>/dev/null; do
      i=$((i+1))
      [ $i -gt 60 ] && die "$h did not return after reboot — check by hand: ssh ${SSH_OPTS:-} $h true"
      sleep 5
    done
  done
  local want units_bad=0
  for h in $hosts; do
    # with roles, each host must bring up what its roles need; without, every
    # host is assumed to be a copy of the probed one.
    if [ -f "$HOSTS_FILE" ]; then want=$(role_units "$h"); else want="${UNITS_ACTIVE:-}"; fi
    [ -n "$want" ] || continue
    rsh "$h" "systemctl is-active $want" \
      || { units_bad=$((units_bad + 1)); warn "some units did not come up on their own on $h — enable them: ssh ${SSH_OPTS:-} $h sudo systemctl enable --now $want"; }
  done
  # active is not answering: ask every web host through nginx and every app host
  # directly, so a box that came back without its DB or upstream shows up now,
  # not as a failed scoring run
  local http bad
  say "checking every web host (through nginx) and app host (directly) answers ${FINAL_CHECK_PATH:-/}"
  http=$(finalize_http)
  printf '%s\n' "$http" | awk '{ split($2, f, "|"); printf "    %-24s %-4s %s  %s\n", $1, f[1], f[2], f[3] }' >&2
  bad=$(printf '%s\n' "$http" | grep -c ' FAIL|' || true)
  if [ "$bad" != 0 ]; then
    warn "$bad host(s) do not answer after the reboot — fix that before any scoring run (journalctl -u <unit>, is the DB reachable?)"
    warn "FINAL_CHECK_PATH in $CONF picks a path that touches the DB; FINAL_APP_PORT if the app port is not discoverable"
  fi
  printf '🏁 %s ran finalize — reboot: every host back; units: %s; HTTP: %s%s\n' "$(who_am_i)" \
    "$([ "$units_bad" = 0 ] && echo "all up" || echo "$units_bad host(s) missing some")" \
    "$([ "$bad" = 0 ] && echo "every host answers" || echo "$bad host(s) do NOT answer")" \
    "$([ "$bad" = 0 ] && [ "$units_bad" = 0 ] || echo " — fix before the final run")" | notify ops
  say "4/4 scoring run"
  if [ "${BENCH_MODE:-auto}" = "manual" ]; then
    [ "$bad" = 0 ] || warn "do NOT enqueue the portal run until every host answers"
    say "BENCH_MODE=manual — enqueue a run in the contest portal NOW, then record it:"
    say "    isukit bench --score <N> \"post-reboot verification\""
    warn "finalize is NOT complete until that run is recorded and passes"
    return 0
  fi
  cmd_bench "post-reboot verification"
}
