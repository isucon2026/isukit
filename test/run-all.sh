#!/bin/bash
# Runs every suite and prints one combined summary line.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A fixture name narrows ONE suite: probe fixtures are directories under fixtures/,
# bench fixtures are fixtures/bench/*.help, and the two name spaces barely overlap.
# Forwarding the name to both made the suite that does not have it exit 2 FATAL, which
# read as a broken harness rather than "wrong suite". Route the name; forward flags.
ONLY=""; FLAGS=()
for a in "$@"; do
  case "$a" in -*) FLAGS+=("$a") ;; *) ONLY="$a" ;; esac
done

run_suite() {  # <script> <fixture-exists-test-result>
  if [ -n "$ONLY" ] && [ "$2" != "yes" ]; then
    echo "skip: $ONLY is not a $3 fixture"
    return 0
  fi
  "$HERE/$1" ${FLAGS+"${FLAGS[@]}"} ${ONLY:+"$ONLY"}
}

PROBE_HAS=no; [ -z "$ONLY" ] || [ -d "$HERE/fixtures/$ONLY" ] && PROBE_HAS=yes
BENCH_HAS=no; [ -z "$ONLY" ] || [ -f "$HERE/fixtures/bench/$ONLY.help" ] && BENCH_HAS=yes

PROBE_OUT="$(run_suite run-probe-tests.sh "$PROBE_HAS" probe)"
PROBE_RC=$?
echo "$PROBE_OUT"

BENCH_OUT="$(run_suite run-bench-tests.sh "$BENCH_HAS" bench)"
BENCH_RC=$?
echo "$BENCH_OUT"

# etc and hosts cases are scenarios, not per-year fixtures: full runs only.
ETC_OUT=""; ETC_RC=0; HOSTS_OUT=""; HOSTS_RC=0; ALP_OUT=""; ALP_RC=0
if [ -z "$ONLY" ]; then
  ETC_OUT="$("$HERE/run-etc-tests.sh" ${FLAGS+"${FLAGS[@]}"})"
  ETC_RC=$?
  echo "$ETC_OUT"
  HOSTS_OUT="$("$HERE/run-hosts-tests.sh" ${FLAGS+"${FLAGS[@]}"} 2>/dev/null)"
  HOSTS_RC=$?
  echo "$HOSTS_OUT"
  ALP_OUT="$("$HERE/run-alp-tests.sh" ${FLAGS+"${FLAGS[@]}"})"
  ALP_RC=$?
  echo "$ALP_OUT"
fi

parse_summary() {
  echo "$1" | grep -oE '[0-9]+ fixtures, [0-9]+ passed, [0-9]+ failed' | tail -1 \
    | sed -E 's/([0-9]+) fixtures, ([0-9]+) passed, ([0-9]+) failed/\1 \2 \3/'
}

read -r P_TOTAL P_PASS P_FAIL <<< "$(parse_summary "$PROBE_OUT")"
read -r B_TOTAL B_PASS B_FAIL <<< "$(parse_summary "$BENCH_OUT")"
read -r E_TOTAL E_PASS E_FAIL <<< "$(parse_summary "$ETC_OUT")"
read -r H_TOTAL H_PASS H_FAIL <<< "$(parse_summary "$HOSTS_OUT")"
read -r A_TOTAL A_PASS A_FAIL <<< "$(parse_summary "$ALP_OUT")"

# A skipped suite prints no summary line, so parse_summary yields empty fields.
TOTAL=$((${P_TOTAL:-0} + ${B_TOTAL:-0} + ${E_TOTAL:-0} + ${H_TOTAL:-0} + ${A_TOTAL:-0}))
PASS=$((${P_PASS:-0} + ${B_PASS:-0} + ${E_PASS:-0} + ${H_PASS:-0} + ${A_PASS:-0}))
FAIL=$((${P_FAIL:-0} + ${B_FAIL:-0} + ${E_FAIL:-0} + ${H_FAIL:-0} + ${A_FAIL:-0}))

echo "$TOTAL fixtures, $PASS passed, $FAIL failed"

[ "$PROBE_RC" -eq 0 ] && [ "$BENCH_RC" -eq 0 ] && [ "$ETC_RC" -eq 0 ] && [ "$HOSTS_RC" -eq 0 ] && [ "$ALP_RC" -eq 0 ]
