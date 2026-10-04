#!/bin/bash
# End-to-end: each scenario runs the real isukit inside its own throwaway
# ubuntu container (they rewrite /etc and install packages). Needs docker.
#   bash test/e2e/run.sh            # all
#   bash test/e2e/run.sh etc bench  # some
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
IMAGE="${E2E_IMAGE:-ubuntu:24.04}"
command -v docker >/dev/null 2>&1 || { echo "FATAL: e2e needs docker" >&2; exit 2; }

if [ "$#" -gt 0 ]; then names=("$@"); else names=(etc bench new alp); fi
TOTAL=0; PASSED=0; FAILED=""
for n in "${names[@]}"; do
  [ -f "$HERE/$n.sh" ] || { echo "FATAL: no scenario $n" >&2; exit 2; }
  TOTAL=$((TOTAL + 1))
  echo "== $n"
  if docker run --rm -v "$REPO:/k:ro" "$IMAGE" bash "/k/test/e2e/$n.sh"; then
    PASSED=$((PASSED + 1))
  else
    FAILED="$FAILED $n"
  fi
done
echo "$TOTAL scenarios, $PASSED passed, $((TOTAL - PASSED)) failed${FAILED:+ —$FAILED}"
[ -z "$FAILED" ]
