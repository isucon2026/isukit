#!/bin/bash
# remote/alp.sh derives alp's -m groups from the log itself. These cases feed it
# synthetic LTSV logs shaped like past contests and assert the derived regexes
# (PRINT_MATCHES=1 stops before alp runs, so no alp binary is needed): ids and
# high-fan-out segments collapse, literal endpoints stay their own row, and
# every regex is anchored.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALP_SH="$HERE/../remote/alp.sh"
VERBOSE=0
for a in "$@"; do [ "$a" = "-v" ] && VERBOSE=1; done
[ -f "$ALP_SH" ] || { echo "FATAL: missing $ALP_SH" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/isukit-alp.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

uri() { printf 'time:2026-10-31T10:00:00+09:00\tmethod:GET\turi:%s\tstatus:200\treqtime:0.010\n' "$1"; }
derive() { # derive <log> -- the regexes alp.sh would pass, one per line
  { printf 'SUDO=\nLOG=%q\nPRINT_MATCHES=1\nTHRESH=%s\n' "$1" "${THRESH:-20}"; cat "$ALP_SH"; } | bash -s
}

TOTAL=0; PASSED=0; FAILED=""; ERR=""; OUT=""
check() { [ "$@" ] || ERR="$ERR
    failed: [ $* ]"; }
has()   { printf '%s\n' "$OUT" | grep -qxF -- "$1"; }
case_() {
  TOTAL=$((TOTAL+1)); ERR=""; OUT=""
  "$2"
  if [ -z "$ERR" ]; then PASSED=$((PASSED+1)); echo "PASS  $1"
  else FAILED="$FAILED $1"; echo "FAIL  $1$ERR"; fi
  [ "$VERBOSE" = 1 ] && printf '%s\n' "$OUT" | sed 's/^/      | /'
  return 0
}

t_isucon13_like() {
  local log="$WORK/13.log" i
  {
    for i in $(seq 1 30); do
      uri "/api/livestream/$i/reaction"; uri "/api/livestream/$i/livecomment"
      uri "/api/user/user$i/icon"; uri "/api/user/user$i/theme"
    done
    # every session asks for itself: far more hits than any one user name
    for i in $(seq 1 300); do uri "/api/user/me"; done
    uri "/api/livestream/search?tag=x"; uri "/api/tag"; uri "/api/initialize"
  } > "$log"
  OUT=$(derive "$log")
  has '^/api/livestream/[^/]+/reaction$'
  check $? = 0
  has '^/api/livestream/[^/]+/livecomment$'
  check $? = 0
  has '^/api/user/[^/]+/icon$'
  check $? = 0
  # literal endpoints get no group of their own (alp shows them as-is) and are
  # never folded into a neighbour: no pattern may match them
  local lit
  for lit in /api/user/me /api/livestream/search /api/tag /api/initialize; do
    check -z "$(printf '%s\n' "$OUT" | while read -r r; do printf '%s\n' "$lit" | grep -qE -- "$r" && echo "$r"; done)"
  done
  # every regex anchored both ends — the old unanchored /api/[^/]+/... swallowed all
  check -z "$(printf '%s\n' "$OUT" | grep -vE '^\^.*\$$')"
}

t_private_isu_like() {
  local log="$WORK/pisu.log" i
  {
    for i in $(seq 1 40); do
      uri "/image/$i.jpg"; uri "/image/$((i+1000)).png"; uri "/posts/$i"; uri "/@user$i"
    done
    uri "/"; uri "/login"; uri "/register"; uri "/posts"; uri "/comment"; uri "/css/style.css"; uri "/favicon.ico"
  } > "$log"
  OUT=$(derive "$log")
  has '^/image/[0-9]+\.jpg$'
  check $? = 0
  has '^/image/[0-9]+\.png$'
  check $? = 0
  has '^/posts/[^/]+$'
  check $? = 0
  # /@<user> collapses on its own: the plain-word siblings at the top level stay
  has '^/@[^/]+$'
  check $? = 0
  check -z "$(printf '%s\n' "$OUT" | grep -E '^\^/\[\^/\]\+')"
}

t_ids_collapse_without_fanout() {
  local log="$WORK/ids.log"
  {
    uri "/api/estate/12345"
    uri "/api/chair/0f8fad5b-d9cb-469f-a165-70867728950e"
    uri "/api/session/abcdef0123456789abcdef"
    uri "/api/token/AbCdEfGhIjKlMnOpQrStUvWx"
  } > "$log"
  OUT=$(THRESH=1000 derive "$log")
  has '^/api/estate/[^/]+$'
  check $? = 0
  has '^/api/chair/[^/]+$'
  check $? = 0
  has '^/api/session/[^/]+$'
  check $? = 0
  has '^/api/token/[^/]+$'
  check $? = 0
}

t_query_strings_and_metachars() {
  local log="$WORK/q.log" i
  {
    for i in $(seq 1 3); do uri "/api/search?q=$i"; done
    for i in $(seq 1 25); do uri "/files/v1.2/$i.txt"; done
  } > "$log"
  OUT=$(derive "$log")
  # query strings never make a new row; dots in literal segments are escaped
  check -z "$(printf '%s\n' "$OUT" | grep -F '?')"
  has '^/files/v1\.2/[0-9]+\.txt$'
  check $? = 0
}

t_config_override_wins() {
  local log="$WORK/o.log"
  uri "/api/livestream/1/reaction" > "$log"
  OUT=$({ printf 'SUDO=\nLOG=%q\nPRINT_MATCHES=1\nMATCHES=%q\n' "$log" '^/x$,^/y/[0-9]+$'; cat "$ALP_SH"; } | bash -s)
  check "$(printf '%s\n' "$OUT" | tr '\n' ' ')" = '^/x$ ^/y/[0-9]+$ '
}

case_ isucon13-like-api            t_isucon13_like
case_ private-isu-like-paths       t_private_isu_like
case_ ids-collapse-without-fanout  t_ids_collapse_without_fanout
case_ query-strings-and-metachars  t_query_strings_and_metachars
case_ config-override-wins         t_config_override_wins

echo "$TOTAL fixtures, $PASSED passed, $((TOTAL-PASSED)) failed"
[ -z "$FAILED" ]
