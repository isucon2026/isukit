#!/bin/bash
# Runs ON THE BENCH HOST, sent by `isukit benchprobe` over `ssh host bash -s`.
#
# Finds the benchmarker binary and reads its own --help to compose BENCH_CMD;
# prints KEY=value lines (%q-quoted). No per-year lookup table.

set -u
S() { printf "%s=%s\n" "$1" "$(printf "%q" "$2")"; }

CANDS=""
while IFS= read -r f; do
  case "$f" in
    */src/*) continue ;;
    */vendor/*) continue ;;
    *.go) continue ;;
  esac
  b=$(basename "$f")
  hit=0
  case "$b" in
    bench) hit=1 ;;
    bench_*) hit=1 ;;
    benchmarker) hit=1 ;;
    *bench*_linux_*) hit=1 ;;
  esac
  [ "$hit" = 1 ] && CANDS="$CANDS $f"
done < <(find /home/isucon -maxdepth 4 -type f -perm -u+x 2>/dev/null)
CANDS="${CANDS# }"
S BENCH_CANDIDATES "$CANDS"

BEST=""; BESTSIZE=-1
for f in $CANDS; do
  if file "$f" 2>/dev/null | grep -q ELF; then
    sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
    [ "$sz" -gt "$BESTSIZE" ] && BEST="$f" && BESTSIZE="$sz"
  fi
done
if [ -z "$BEST" ]; then
  for f in $CANDS; do
    sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
    [ "$sz" -gt "$BESTSIZE" ] && BEST="$f" && BESTSIZE="$sz"
  done
fi
S BENCH_BIN "$BEST"
if [ -n "$BEST" ]; then
  S BENCH_DIR   "$(dirname "$BEST")"
  S BENCH_OWNER "$(stat -c %U "$BEST" 2>/dev/null || echo isucon)"
fi

HELP=""
if [ -n "$BEST" ]; then
  HELP="$("$BEST" --help 2>&1 | head -200)"
  [ -n "$HELP" ] || HELP="$("$BEST" -h 2>&1 | head -200)"
  [ -n "$HELP" ] || HELP="$("$BEST" help 2>&1 | head -200)"
fi
HELPFILE="/tmp/isukit-bench-help.$$"
printf "%s\n" "$HELP" > "$HELPFILE"
S BENCH_HELP_FILE "$HELPFILE"

has_tok() {
  printf "%s\n" "$HELP" | grep -Eq "(^|[^A-Za-z0-9-])$1([^A-Za-z0-9-]|\$)"
}

TFLAG=""
for f in -target-addr -target-url --target-url -target-host --target -target --addr -addr; do
  if [ -z "$TFLAG" ] && has_tok "$f"; then TFLAG="$f"; fi
done
S BENCH_TARGET_FLAG "$TFLAG"

NS=0; NSFLAG=""
if has_tok --nameserver; then NS=1; NSFLAG="--nameserver"; fi
if [ "$NS" = 0 ] && has_tok -nameserver; then NS=1; NSFLAG="-nameserver"; fi
S BENCH_HAS_NAMESERVER "$NS"
S BENCH_NAMESERVER_FLAG "$NSFLAG"

SSL=0
has_tok --enable-ssl && SSL=1
has_tok -tls && SSL=1
S BENCH_HAS_SSL_FLAG "$SSL"

SUB=""
if printf "%s\n" "$HELP" | grep -Eq "^(COMMANDS:|Available Commands:)"; then
  has_tok run && SUB="run"
fi
S BENCH_SUBCMD "$SUB"
