#!/bin/bash
# End-to-end: each scenario runs the real isukit inside its own throwaway
# ubuntu container (they rewrite /etc and install packages). Needs docker.
#   bash test/e2e/run.sh            # all, through the bash entry point
#   bash test/e2e/run.sh etc bench  # some
#   E2E_GO=1 bash test/e2e/run.sh   # all, through the Go binary (needs go)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
IMAGE="${E2E_IMAGE:-ubuntu:24.04}"
command -v docker >/dev/null 2>&1 || { echo "FATAL: e2e needs docker" >&2; exit 2; }

if [ "$#" -gt 0 ]; then names=("$@"); else names=(etc bench new alp final http team rules); fi

# E2E_GO=1: the same scenarios through the Go entry point, built for the
# container's arch into the repo (mounted read-only below)
GO_ENV=()
if [ "${E2E_GO:-0}" = 1 ]; then
  arch=$(docker run --rm "$IMAGE" uname -m)
  case "$arch" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; esac
  (cd "$REPO" && CGO_ENABLED=0 GOOS=linux GOARCH="$arch" go build -o .e2e-bin/isukit ./cmd/isukit) \
    || { echo "FATAL: go build for linux/$arch failed" >&2; exit 2; }
  GO_ENV=(-e ISUKIT_BIN=/k/.e2e-bin/isukit)
  echo "(through the Go binary, linux/$arch)"
fi
TOTAL=0; PASSED=0; FAILED=""
for n in "${names[@]}"; do
  [ -f "$HERE/$n.sh" ] || { echo "FATAL: no scenario $n" >&2; exit 2; }
  TOTAL=$((TOTAL + 1))
  echo "== $n"
  if docker run --rm ${GO_ENV[@]+"${GO_ENV[@]}"} -v "$REPO:/k:ro" "$IMAGE" bash "/k/test/e2e/$n.sh"; then
    PASSED=$((PASSED + 1))
  else
    FAILED="$FAILED $n"
  fi
done
echo "$TOTAL scenarios, $PASSED passed, $((TOTAL - PASSED)) failed${FAILED:+ —$FAILED}"
[ -z "$FAILED" ]
