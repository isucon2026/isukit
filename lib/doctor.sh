# shellcheck shell=bash
# isukit lib/doctor.sh — `isukit doctor` and `isukit version`.
# Sourced by ../isukit; not meant to run on its own.

cmd_version() { # which kit is running: the frozen contest tag, or a sha to report
  local d rev
  d=$(kit_dir)
  rev=$(git -C "$d" describe --tags --always --dirty 2>/dev/null || echo "not a git checkout")
  printf 'isukit %s (%s) at %s\n' "$KIT_VERSION" "$rev" "$d"
}

doctor_ok()   { printf '\033[32mOK\033[0m    %s\n' "$*"; }

doctor_warn() { printf '\033[33mWARN\033[0m  %s\n' "$*"; }

doctor_fail() { printf '\033[31mFAIL\033[0m  %s\n' "$*"; }

cmd_doctor() {
  need_state
  say "doctor"

  if [ -f "$CONF" ] && ( . "$CONF" ) 2>/dev/null; then
    doctor_ok "config parses ($CONF)"
  else
    doctor_fail "config missing or does not parse ($CONF)"
    return 1
  fi
  load

  local h dead=0
  for h in $(hosts_all); do
    if rsh "$h" "true" 2>/dev/null; then
      doctor_ok "reachable: $h ($(host_roles "$h"))"
    else
      doctor_fail "cannot reach $h — check: ssh ${SSH_OPTS:-} $h true"
      dead=1
    fi
  done
  [ "$dead" = 0 ] || return 1
  if [ "${BENCH_MODE:-auto}" = "auto" ]; then
    if rsh "$BENCH" "true" 2>/dev/null; then
      doctor_ok "reachable: $BENCH"
    else
      doctor_warn "cannot reach bench host $BENCH — check: ssh ${SSH_OPTS:-} $BENCH true"
    fi
  fi

  if [ -f "$STATE/manifest" ]; then
    doctor_ok "manifest exists"
  else
    doctor_warn "no manifest — running: isukit probe"
    cmd_probe || doctor_warn "isukit probe failed — run it by hand"
  fi
  load

  [ -n "${APP_UNIT:-}" ] || doctor_warn "no APP_UNIT in manifest — fix: isukit unit <systemd-unit-name>"
  local u ustate
  for h in $(hosts_all); do
    for u in $(role_units "$h"); do
      ustate=$(rsh "$h" "systemctl is-active '$u'" 2>/dev/null || true)
      if [ "$ustate" = "active" ]; then
        doctor_ok "$h: $u is active"
      else
        doctor_fail "$h: $u is ${ustate:-unknown} (its roles need it) — recent log:"
        rsh "$h" "sudo -n journalctl -u '$u' -n 30 --no-pager" 2>/dev/null || true
      fi
    done
  done

  if [ -n "${APP_UNIT:-}" ] && [ "${APP_UNIT_CONFIDENCE:-}" != "high" ] && [ "${APP_UNIT_CONFIDENCE:-}" != "override" ]; then
    doctor_warn "APP_UNIT_CONFIDENCE=${APP_UNIT_CONFIDENCE:-unknown} — candidates: ${APP_CANDIDATES:-none} — fix: isukit unit <name>"
  else
    doctor_ok "APP_UNIT_CONFIDENCE=${APP_UNIT_CONFIDENCE:-n/a}"
  fi

  local left
  left=$(db_left_enabled)
  if [ -n "$left" ]; then
    printf '%s\n' "$left" | while read -r h u; do
      doctor_warn "$h: $u is enabled but the host has no db role — it starts on every reboot: ssh $h sudo systemctl disable --now $u"
    done
  fi

  local missing=0
  for h in $(hosts_with 'web|db'); do
    rsh "$h" "command -v alp >/dev/null && command -v pt-query-digest >/dev/null" 2>/dev/null || missing=1
  done
  if [ "$missing" = 0 ]; then
    doctor_ok "alp + pt-query-digest installed"
  else
    doctor_warn "alp and/or pt-query-digest missing — running: isukit setup"
    cmd_setup || doctor_warn "isukit setup failed — install by hand"
  fi

  local on=""
  for h in $(hosts_all); do
    # shellcheck disable=SC2034  # HOST_OVERRIDE is read by load() in lib/core.sh
    ( HOST_OVERRIDE="$h"; load; logs_are_on ) && on="$on $h"
  done
  if [ -n "$on" ]; then
    doctor_warn "measurement logging is ON on:$on — must be OFF for a scoring run: isukit logs off"
  else
    doctor_ok "measurement logging is off"
  fi

  if [ -n "${ETC_REPO:-${SRC_DIR:-}}" ]; then
    for h in $(hosts_all); do
      # shellcheck disable=SC2034  # HOST_OVERRIDE is read by load() in lib/core.sh
      ( HOST_OVERRIDE="$h"; load
        erepo=$(etc_repo 2>/dev/null || true)
        [ -n "$erepo" ] && etc_managed "$erepo" || exit 0
        if etc_status_one >/dev/null 2>&1; then
          doctor_ok "etc: $h reads every managed config from $erepo/etc"
        else
          doctor_warn "etc: on $h some configs in $erepo/etc are not what /etc reads — run: isukit etc status"
        fi )
    done
  fi

  local pct
  pct=$(rsh "$APP" "df -P / | tail -1 | tr -s ' ' | cut -d' ' -f5 | tr -d '%'" 2>/dev/null || true)
  if [ -n "$pct" ]; then
    local free=$((100 - pct))
    if [ "$free" -lt 10 ]; then
      doctor_fail "disk on $APP: only ${free}% free"
    elif [ "$free" -lt 20 ]; then
      doctor_warn "disk on $APP: only ${free}% free"
    else
      doctor_ok "disk on $APP: ${free}% free"
    fi
  else
    doctor_warn "could not read disk usage on $APP"
  fi

  local mode="${BENCH_MODE:-auto}"
  if [ "$mode" = "manual" ]; then
    doctor_ok "BENCH_MODE=manual — 'isukit bench' will prompt for a portal score"
  elif [ -n "${BENCH_CMD:-}" ]; then
    doctor_ok "BENCH_MODE=auto, BENCH_CMD is set"
  else
    doctor_warn "BENCH_MODE=auto but BENCH_CMD is empty — run: isukit benchprobe"
  fi

  return 0
}
