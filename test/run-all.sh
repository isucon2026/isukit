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

# etc, hosts and rules cases are scenarios, not per-year fixtures: full runs only.
ETC_OUT=""; ETC_RC=0; HOSTS_OUT=""; HOSTS_RC=0; ALP_OUT=""; ALP_RC=0; RULES_OUT=""; RULES_RC=0; PROV_OUT=""; PROV_RC=0; SHIP_OUT=""; SHIP_RC=0; NOTES_OUT=""; NOTES_RC=0; FIN_OUT=""; FIN_RC=0; STRIP_OUT=""; STRIP_RC=0; PPROF_OUT=""; PPROF_RC=0; MEAS_OUT=""; MEAS_RC=0
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
  RULES_OUT="$("$HERE/run-rules-tests.sh" ${FLAGS+"${FLAGS[@]}"} 2>/dev/null)"
  RULES_RC=$?
  echo "$RULES_OUT"
  PROV_OUT="$("$HERE/run-provenance-tests.sh" ${FLAGS+"${FLAGS[@]}"} 2>/dev/null)"
  PROV_RC=$?
  echo "$PROV_OUT"
  SHIP_OUT="$("$HERE/run-ship-size-tests.sh" ${FLAGS+"${FLAGS[@]}"} 2>/dev/null)"
  SHIP_RC=$?
  echo "$SHIP_OUT"
  NOTES_OUT="$("$HERE/run-notes-tests.sh" ${FLAGS+"${FLAGS[@]}"} 2>/dev/null)"
  NOTES_RC=$?
  echo "$NOTES_OUT"
  FIN_OUT="$("$HERE/run-finalize-guard-tests.sh" ${FLAGS+"${FLAGS[@]}"} 2>/dev/null)"
  FIN_RC=$?
  echo "$FIN_OUT"
  STRIP_OUT="$("$HERE/run-final-strip-tests.sh" ${FLAGS+"${FLAGS[@]}"} 2>/dev/null)"
  STRIP_RC=$?
  echo "$STRIP_OUT"
  PPROF_OUT="$("$HERE/run-pprof-tests.sh" ${FLAGS+"${FLAGS[@]}"} 2>/dev/null)"
  PPROF_RC=$?
  echo "$PPROF_OUT"
  MEAS_OUT="$("$HERE/run-measure-tests.sh" ${FLAGS+"${FLAGS[@]}"} 2>/dev/null)"
  MEAS_RC=$?
  echo "$MEAS_OUT"
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
read -r R_TOTAL R_PASS R_FAIL <<< "$(parse_summary "$RULES_OUT")"
read -r V_TOTAL V_PASS V_FAIL <<< "$(parse_summary "$PROV_OUT")"
read -r S_TOTAL S_PASS S_FAIL <<< "$(parse_summary "$SHIP_OUT")"
read -r N_TOTAL N_PASS N_FAIL <<< "$(parse_summary "$NOTES_OUT")"
read -r F_TOTAL F_PASS F_FAIL <<< "$(parse_summary "$FIN_OUT")"
read -r X_TOTAL X_PASS X_FAIL <<< "$(parse_summary "$STRIP_OUT")"
read -r PP_TOTAL PP_PASS PP_FAIL <<< "$(parse_summary "$PPROF_OUT")"
read -r MEAS_TOTAL MEAS_PASS MEAS_FAIL <<< "$(parse_summary "$MEAS_OUT")"

# A skipped suite prints no summary line, so parse_summary yields empty fields.
TOTAL=$((${P_TOTAL:-0} + ${B_TOTAL:-0} + ${E_TOTAL:-0} + ${H_TOTAL:-0} + ${A_TOTAL:-0} + ${R_TOTAL:-0} + ${V_TOTAL:-0} + ${S_TOTAL:-0} + ${N_TOTAL:-0} + ${F_TOTAL:-0} + ${X_TOTAL:-0} + ${PP_TOTAL:-0} + ${MEAS_TOTAL:-0}))
PASS=$((${P_PASS:-0} + ${B_PASS:-0} + ${E_PASS:-0} + ${H_PASS:-0} + ${A_PASS:-0} + ${R_PASS:-0} + ${V_PASS:-0} + ${S_PASS:-0} + ${N_PASS:-0} + ${F_PASS:-0} + ${X_PASS:-0} + ${PP_PASS:-0} + ${MEAS_PASS:-0}))
FAIL=$((${P_FAIL:-0} + ${B_FAIL:-0} + ${E_FAIL:-0} + ${H_FAIL:-0} + ${A_FAIL:-0} + ${R_FAIL:-0} + ${V_FAIL:-0} + ${S_FAIL:-0} + ${N_FAIL:-0} + ${F_FAIL:-0} + ${X_FAIL:-0} + ${PP_FAIL:-0} + ${MEAS_FAIL:-0}))

echo "$TOTAL fixtures, $PASS passed, $FAIL failed"

[ "$PROBE_RC" -eq 0 ] && [ "$BENCH_RC" -eq 0 ] && [ "$ETC_RC" -eq 0 ] && [ "$HOSTS_RC" -eq 0 ] && [ "$ALP_RC" -eq 0 ] && [ "$RULES_RC" -eq 0 ] && [ "$PROV_RC" -eq 0 ] && [ "$SHIP_RC" -eq 0 ] && [ "$NOTES_RC" -eq 0 ] && [ "$FIN_RC" -eq 0 ] && [ "$STRIP_RC" -eq 0 ] && [ "$PPROF_RC" -eq 0 ] && [ "$MEAS_RC" -eq 0 ]
