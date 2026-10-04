#!/bin/bash
# Runs ON EVERY HOST, sent by `isukit os` over `ssh host bash -s`.
#
# A point-in-time snapshot: uptime, vmstat / iostat / mpstat, memory, disk, and
# the state of the units this host's roles need. Tolerates missing tools.
#
# Inputs (isukit prepends them as VAR=value lines):
#   CHECK_UNITS  space-separated units to report on

set -u
echo "== uptime =="
uptime

echo
echo "== vmstat 1 5 =="
command -v vmstat >/dev/null 2>&1 && vmstat 1 5 || echo "vmstat not installed (apt install sysstat)"

echo
echo "== iostat -x 1 3 =="
command -v iostat >/dev/null 2>&1 && iostat -x 1 3 || echo "iostat not installed (apt install sysstat)"

echo
echo "== mpstat -P ALL 1 3 =="
command -v mpstat >/dev/null 2>&1 && mpstat -P ALL 1 3 || echo "mpstat not installed (apt install sysstat)"

echo
echo "== free -h =="
free -h

echo
echo "== df -h =="
df -h

echo
echo "== units =="
for u in $CHECK_UNITS; do
  st=$(systemctl is-active "$u" 2>/dev/null || true)
  printf "%s: %s\n" "$u" "${st:-unknown}"
done
