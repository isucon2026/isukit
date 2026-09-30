#!/bin/bash
# Runs ON EVERY HOST, sent by `isukit bench` over `ssh host bash -s`.
#
# Opens a measurement window: empties the logs this host's roles write (so the
# run's alp / slow see this run only), and starts 1-second samplers for the
# whole box (vmstat) and per process (pidstat). The samplers detach from ssh and
# are capped by MAXSEC, so an abandoned run cannot leave them going forever.
# `isukit bench` also calls this with SAMPLE=0 after collecting a run, so the
# next record starts clean even when no window is opened (a portal score typed
# in afterwards with --score).
#
# Inputs (isukit prepends them as VAR=value lines):
#   RESET_NGINX  1 = empty /var/log/nginx/isukit.log (web hosts)
#   RESET_MYSQL  1 = empty /tmp/isukit-slow.log (db hosts)
#   SAMPLE       1 = start the samplers
#   MAXSEC       sampler cap in seconds (default 1800)
#   SUDO         default "sudo -n"

set -u
SUDO="${SUDO-sudo -n}"
D=/tmp/isukit-run

# a sampler left behind by an interrupted run would write into this window
if [ -f "$D/pids" ]; then
  # shellcheck disable=SC2046  # one pid per word
  kill $(cat "$D/pids") 2>/dev/null || true
fi

if [ "${RESET_NGINX:-0}" = 1 ] && $SUDO test -f /var/log/nginx/isukit.log; then
  # nginx appends (O_APPEND), so truncating in place is safe while it runs
  $SUDO truncate -s 0 /var/log/nginx/isukit.log && echo "nginx: isukit.log emptied"
fi
if [ "${RESET_MYSQL:-0}" = 1 ] && $SUDO test -f /tmp/isukit-slow.log; then
  $SUDO truncate -s 0 /tmp/isukit-slow.log && echo "mysql: slow log emptied"
  timeout 5 $SUDO mysql -e "FLUSH SLOW LOGS" 2>/dev/null || true
fi

[ "${SAMPLE:-0}" = 1 ] || exit 0

rm -rf "$D" && mkdir -p "$D" || { echo "sampling: cannot create $D" >&2; exit 1; }
nproc > "$D/ncpu" 2>/dev/null || echo 1 > "$D/ncpu"
start() { # start <name> <cmd...> -- detached, capped, pid recorded
  local name="$1"; shift
  setsid nohup timeout "${MAXSEC:-1800}" "$@" > "$D/$name.log" 2>&1 < /dev/null &
  echo $! >> "$D/pids"
}
start vmstat vmstat -n 1
if command -v pidstat >/dev/null 2>&1; then
  # LC_ALL=C: a locale with AM/PM splits the time column and shifts every field
  start pidstat env LC_ALL=C pidstat -u -h 1
  echo "sampling: vmstat + pidstat every 1s"
else
  echo "sampling: vmstat every 1s (no pidstat — per-process CPU needs: apt install sysstat, or isukit setup)"
fi
