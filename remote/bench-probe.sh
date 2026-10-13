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

# sub_help <subcmd> -- the subcommand's own --help, appended to the help file
# too so bench-help.txt shows the flags BENCH_CMD was composed from. (The test
# harness replaces this function with a fixture.)
sub_help() {
  local t
  t="$("$BEST" "$1" --help 2>&1 | head -200)"
  printf '\n$ %s %s --help\n%s\n' "$(basename "$BEST")" "$1" "$t" >> "$HELPFILE"
  printf '%s\n' "$t"
}

has_tok() {
  printf "%s\n" "$HELP" | grep -Eq "(^|[^A-Za-z0-9-])$1([^A-Za-z0-9-]|\$)"
}

# A subcommand-style CLI (urfave "COMMANDS:", cobra "Available Commands:")
# lists only its subcommands at the top: isucon14's --addr / --target /
# --payment-url show up in `bench run --help` alone. Find the subcommand
# first, then look for every flag in its help as well.
SUB=""
if printf "%s\n" "$HELP" | grep -Eq "^(COMMANDS:|Available Commands:)"; then
  has_tok run && SUB="run"
fi
S BENCH_SUBCMD "$SUB"
if [ -n "$SUB" ] && [ -n "${BEST:-}" ] && declare -F sub_help >/dev/null; then
  HELP="$HELP
$(sub_help "$SUB")"
fi

TFLAG=""
for f in -target-addr -target-url --target-url -target-host --target -target --addr -addr; do
  if [ -z "$TFLAG" ] && has_tok "$f"; then TFLAG="$f"; fi
done
S BENCH_TARGET_FLAG "$TFLAG"

# both a URL target and an ip:port one (isucon14: --target https://<vhost>
# --addr <ip>:443): the URL names the vhost, the addr says where to connect.
AFLAG=""
case "$TFLAG" in
  *addr) ;;
  ?*) for f in --addr -addr; do
        if [ -z "$AFLAG" ] && has_tok "$f"; then AFLAG="$f"; fi
      done ;;
esac
S BENCH_ADDR_FLAG "$AFLAG"

NS=0; NSFLAG=""
if has_tok --nameserver; then NS=1; NSFLAG="--nameserver"; fi
if [ "$NS" = 0 ] && has_tok -nameserver; then NS=1; NSFLAG="-nameserver"; fi
S BENCH_HAS_NAMESERVER "$NS"
S BENCH_NAMESERVER_FLAG "$NSFLAG"

SSL=0
has_tok --enable-ssl && SSL=1
has_tok -tls && SSL=1
S BENCH_HAS_SSL_FLAG "$SSL"

# the app calls the benchmarker back (isucon14's payment server): from another
# box it has to be told the bench box's own address, and the port it binds.
PFLAG=""; PPFLAG=""; PPORT=""
for f in --payment-url -payment-url; do
  if [ -z "$PFLAG" ] && has_tok "$f"; then PFLAG="$f"; fi
done
for f in --payment-bind-port -payment-bind-port; do
  if [ -z "$PPFLAG" ] && has_tok "$f"; then PPFLAG="$f"; fi
done
if [ -n "$PPFLAG" ]; then
  PPORT=$(printf "%s\n" "$HELP" | grep -E -- "(^|[^A-Za-z0-9-])$PPFLAG([^A-Za-z0-9-]|\$)" \
    | grep -oE 'default:? *"?[0-9]+' | grep -oE '[0-9]+' | head -1)
fi
if [ -z "$PPORT" ] && [ -n "$PFLAG" ]; then
  PPORT=$(printf "%s\n" "$HELP" | grep -E -- "(^|[^A-Za-z0-9-])$PFLAG([^A-Za-z0-9-]|\$)" \
    | grep -oE ':[0-9]+' | grep -oE '[0-9]+' | head -1)
fi
S BENCH_PAYMENT_URL_FLAG "$PFLAG"
S BENCH_PAYMENT_PORT_FLAG "$PPFLAG"
S BENCH_PAYMENT_PORT "$PPORT"
