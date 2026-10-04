#!/bin/bash
# The real alp binary reading the groups remote/alp.sh derives (Go RE2 syntax).
# shellcheck source=test/e2e/lib.sh
. /k/test/e2e/lib.sh
pkgs curl ca-certificates
A=$(uname -m); case "$A" in x86_64) A=amd64 ;; aarch64) A=arm64 ;; esac
curl -fsSL -o /tmp/alp.tgz "https://github.com/tkuchiki/alp/releases/download/v1.0.21/alp_linux_${A}.tar.gz" \
  && tar xzf /tmp/alp.tgz -C /tmp && install -m755 /tmp/alp /usr/local/bin/alp || { echo "FAIL (cannot fetch alp)"; exit 1; }

L=/tmp/access.log; : > "$L"
u() { printf 'time:t\tmethod:%s\turi:%s\tstatus:200\tsize:10\treqtime:%s\tapptime:%s\tvhost:x\n' "$1" "$2" "$3" "$3" >> "$L"; }
for i in $(seq 1 40); do
  u POST "/api/livestream/$i/reaction" 0.050; u GET "/api/livestream/$i/livecomment" 0.020; u GET "/api/user/user$i/icon" 0.200
done
for i in $(seq 1 400); do u GET /api/user/me 0.005; done
u GET "/api/livestream/search?tag=a" 0.300; u GET /api/tag 0.001

out=$({ printf 'SUDO=\nLOG=%s\n' "$L"; cat /k/remote/alp.sh; } | bash -s 2>&1)
echo "$out" | sed 's/^/    /'
row() { echo "$out" | grep -F "| $1 " >/dev/null || echo "$out" | grep -F " $1 " >/dev/null; }
check "icon endpoints grouped"               row '^/api/user/[^/]+/icon$'
check "reaction endpoints grouped"           row '^/api/livestream/[^/]+/reaction$'
check "/api/user/me kept as its own row"     row '/api/user/me'
check "the heaviest group is on top"         bash -c 'echo "$0" | grep "^|" | sed -n 2p | grep -qF "/icon\$"' "$out"
check "no catch-all /api row"                bash -c '! echo "$0" | grep -qF "/api/[^/]+/[0-9a-zA-Z-]+"' "$out"
finish
