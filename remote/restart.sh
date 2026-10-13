#!/bin/bash
# Runs ON AN APP HOST, sent by `isukit restart` over `ssh host bash -s`.
#
# Restarts the app's units and checks that they STAY up: one `active` right
# after the restart is not proof (a unit can be stopped a moment later — a
# dependency it Requires= going down takes it with it and nothing starts it
# again). Each unit must be active 2s after the restart and still active
# SETTLE seconds after that. If one is not, what systemd knows about it is
# printed (status, is-enabled, its links under /etc/systemd/system, the jobs
# queued, the journal since just before the restart — its own and that of what
# it Requires=/BindsTo=/PartOf=), then it is restarted once more.
#
# A unit file edited, or replaced by a link (isukit etc adopt), since the last
# daemon-reload is reloaded first: restarting it as is would run the old one.
#
# Prints "<unit> <state>" per unit; exit 0 when all are up (also after the
# retry — the diagnostics above then say what went wrong), 1 when not.
#
# Inputs (isukit prepends them as VAR=value lines):
#   UNITS   space-separated units to restart (required)
#   SETTLE  seconds a unit must stay active after the first check (default 3)
#   SUDO    default "sudo -n" (tests set it empty)

set -u
: "${UNITS:?UNITS is required}"
SUDO="${SUDO-sudo -n}"
SETTLE="${SETTLE:-3}"
# shellcheck disable=SC2206  # one unit per word
U=($UNITS)

reload_if_changed() {
  local u
  for u in "${U[@]}"; do
    if [ "$(systemctl show -p NeedDaemonReload --value "$u" 2>/dev/null)" = yes ]; then
      $SUDO systemctl daemon-reload && echo "systemd: daemon-reload first ($u changed on disk since the last one)"
      return 0
    fi
  done
}

down() { # the units not active right now, space-separated
  local u
  for u in "${U[@]}"; do systemctl is-active --quiet "$u" 2>/dev/null || printf '%s ' "$u"; done
}

restart_and_hold() { # restart, then active at +2s and still at +2+SETTLE s; sets BAD
  BAD=""
  if ! $SUDO systemctl restart "${U[@]}"; then BAD="$(down)"; [ -n "$BAD" ] || BAD="(systemctl restart failed) "; return 1; fi
  sleep 2
  BAD=$(down); [ -z "$BAD" ] || return 1
  sleep "$SETTLE"
  BAD=$(down); [ -z "$BAD" ]
}

states() {
  local u
  for u in "${U[@]}"; do printf '%s %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null)"; done
}

diagnose() { # what systemd knows about each unit that is not up, since <since>
  local since="$1" u deps d f
  echo "--- systemctl list-jobs"
  systemctl list-jobs --no-pager 2>&1 | head -20
  for u in $BAD; do
    case "$u" in \(*) continue ;; esac
    echo "--- $u: systemctl status"
    systemctl status --no-pager -l -n 0 "$u" 2>&1 | head -20
    echo "--- $u: is-enabled $(systemctl is-enabled "$u" 2>&1 | head -1)"
    systemctl show --no-pager -p LoadState,ActiveState,SubState,Result,NRestarts,FragmentPath,NeedDaemonReload,Requires,BindsTo,PartOf,Conflicts "$u" 2>&1
    echo "--- $u: links under /etc/systemd/system"
    for f in /etc/systemd/system/"$u" /etc/systemd/system/*.wants/"$u" /etc/systemd/system/*.requires/"$u"; do
      [ -e "$f" ] || [ -L "$f" ] || continue
      ls -l "$f" 2>&1
      [ -L "$f" ] && echo "    resolves to: $(readlink -f "$f" 2>&1) $([ -e "$f" ] && echo '(exists)' || echo '(MISSING)')"
    done
    deps=$(systemctl show -p Requires,BindsTo,PartOf --value "$u" 2>/dev/null | tr '\n' ' ')
    set -- -u "$u"
    for d in $deps; do set -- "$@" -u "$d"; done
    echo "--- journal since $since: $*"
    $SUDO journalctl --no-pager -o short-precise --since "$since" "$@" 2>&1 | tail -60
  done
}

reload_if_changed
since=$(date -d '-30 sec' '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S')
if restart_and_hold; then
  states
  exit 0
fi
echo "restart: not up after the restart: ${BAD% } — what systemd knows, then one more restart" >&2
diagnose "$since" >&2
$SUDO systemctl daemon-reload 2>/dev/null || true
if restart_and_hold; then
  echo "restart: up after the second restart — the first one did not hold (see above)" >&2
  states
  exit 0
fi
echo "restart: still not up after a second restart: ${BAD% }" >&2
diagnose "$since" >&2
states
exit 1
