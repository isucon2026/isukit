#!/bin/bash
# Runs ON EVERY HOST, sent by `isukit final apply` over `ssh host bash -s`.
#
# The host-side half of the final cleanup: stop what isukit started for
# measuring and remove what it left. Config files are NOT edited here — the
# nginx / mysql changes go through the repo's etc/ and `etc push`, so they are
# a diff that can be reviewed and reverted.
#
# Inputs (isukit prepends them as VAR=value lines):
#   WANT_MYSQL  1 = db host: also switch the live slow / general log off
#   SUDO        default "sudo -n"

set -u
SUDO="${SUDO-sudo -n}"

if [ -f /tmp/isukit-run/pids ]; then
  # shellcheck disable=SC2046  # one pid per word
  kill $(cat /tmp/isukit-run/pids) 2>/dev/null && echo "stopped isukit samplers"
fi
for f in /var/log/nginx/isukit.log /tmp/isukit-slow.log /tmp/isukit-alp.log /tmp/isukit-cpu.pprof /tmp/isukit-cpu.pprof.part /tmp/isukit-run; do
  $SUDO test -e "$f" && $SUDO rm -rf "$f" && echo "removed $f"
done
# Ubuntu enables sysstat's collectors on install; isukit only runs pidstat on demand
for t in sysstat-collect.timer sysstat-summary.timer sysstat.service; do
  if systemctl is-active --quiet "$t" 2>/dev/null || [ "$(systemctl is-enabled "$t" 2>/dev/null)" = enabled ]; then
    $SUDO systemctl disable --now "$t" >/dev/null 2>&1 && echo "disabled $t"
  fi
done
if [ "${WANT_MYSQL:-0}" = 1 ] && $SUDO mysql -e "SELECT 1" >/dev/null 2>&1; then
  $SUDO mysql -e "SET GLOBAL slow_query_log = 0; SET GLOBAL general_log = 0;" 2>/dev/null \
    && echo "mysql: slow / general log off (live)"
fi
exit 0
