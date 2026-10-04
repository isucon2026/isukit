#!/bin/bash
# Runs the flag-detection tail of BENCH_PROBE_SCRIPT (extracted verbatim,
# read-only, from ../isukit -- everything from `has_tok() {` onward, which is
# pure text matching against $HELP) against every fixtures/bench/<year>.help
# and asserts the S KEY=value output matches <year>.expected. The binary-
# discovery preamble (find -perm -u+x, file, stat) is never exercised: $HELP
# is set directly from the fixture instead of by running a real binary.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
ISUKIT="$REPO_ROOT/isukit"
BENCH_DIR="$HERE/fixtures/bench"

VERBOSE=0
ONLY=""
for a in "$@"; do
  case "$a" in
    -v) VERBOSE=1 ;;
    *) ONLY="$a" ;;
  esac
done

TAIL_SCRIPT="$(awk '
  /^S\(\) \{/ { print; next }
  /^has_tok\(\) \{/ { tail=1 }
  tail { print }
' "$(dirname "$ISUKIT")/remote/bench-probe.sh")"

if [ -z "$TAIL_SCRIPT" ]; then
  echo "FATAL: could not extract the has_tok tail from remote/bench-probe.sh" >&2
  exit 2
fi

TOTAL=0
PASSED=0
FAILED_FIXTURES=""

run_one() {
  helpfile="$1"
  year="$(basename "$helpfile" .help)"
  expfile="$BENCH_DIR/$year.expected"
  [ -f "$expfile" ] || return 0
  TOTAL=$((TOTAL + 1))

  OUT="$(HELP="$(cat "$helpfile")" bash -c "$TAIL_SCRIPT" 2>&1)"

  if [ "$VERBOSE" = "1" ]; then
    echo "--- $year: full tail-script output ---"
    echo "$OUT"
    echo "--- end $year ---"
  fi

  fail_lines=""
  eval "$(sed 's/^/EXP_/' "$expfile")"

  while IFS= read -r ekey; do
    [ -z "$ekey" ] && continue
    exp_var="EXP_$ekey"
    expected_val="${!exp_var-}"

    qline="$(printf '%s\n' "$OUT" | grep -m1 "^${ekey}=")"
    if [ -z "$qline" ]; then
      fail_lines="$fail_lines
$ekey expected=$expected_val got=<no output line>"
      continue
    fi
    qval="${qline#*=}"
    got_val=""
    eval "got_val=$qval"

    if [ "$got_val" != "$expected_val" ]; then
      fail_lines="$fail_lines
$ekey expected=$expected_val got=$got_val"
    fi
  done < <(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$expfile")

  if [ -z "$fail_lines" ]; then
    echo "PASS $year"
    PASSED=$((PASSED + 1))
  else
    while IFS= read -r fl; do
      [ -z "$fl" ] && continue
      echo "FAIL $year: $fl"
    done <<< "$fail_lines"
    FAILED_FIXTURES="$FAILED_FIXTURES $year"
  fi
}

if [ -n "$ONLY" ]; then
  hf="$BENCH_DIR/$ONLY.help"
  if [ ! -f "$hf" ]; then
    echo "FATAL: no such fixture: $hf" >&2
    exit 2
  fi
  run_one "$hf"
else
  for hf in "$BENCH_DIR"/*.help; do
    [ -f "$hf" ] || continue
    run_one "$hf"
  done
fi

echo "bench: $TOTAL fixtures, $PASSED passed, $((TOTAL - PASSED)) failed"
[ -z "$FAILED_FIXTURES" ]
