#!/bin/bash
# Runs PROBE_SCRIPT (extracted verbatim, read-only, from ../isukit) against
# every fixture in test/fixtures/<year>/ and asserts its S KEY=value output
# matches fixtures/<year>/expected. See test/README.md for the full design.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
ISUKIT="$REPO_ROOT/isukit"
FIXTURES_DIR="$HERE/fixtures"

VERBOSE=0
ONLY=""
for a in "$@"; do
  case "$a" in
    -v) VERBOSE=1 ;;
    *) ONLY="$a" ;;
  esac
done

# --- extract PROBE_SCRIPT verbatim from isukit (read-only; never hand-copied).
extract_probe_script() {
  awk '
    /^PROBE_SCRIPT='"'"'$/ { grab=1; next }
    grab && /^'"'"'$/ { exit }
    grab { print }
  ' "$ISUKIT"
}

RAW_PROBE="$(extract_probe_script)"
if [ -z "$RAW_PROBE" ]; then
  echo "FATAL: could not extract PROBE_SCRIPT from $ISUKIT" >&2
  exit 2
fi

TOTAL=0
PASSED=0
FAILED_FIXTURES=""

run_one() {
  fx="$1"
  name="$(basename "$fx")"
  [ -f "$fx/expected" ] || return 0
  TOTAL=$((TOTAL + 1))

  FAKE_HOME="$(mktemp -d "${TMPDIR:-/tmp}/isukit-probe-test.XXXXXX")"
  # Mirror the fixture's home-isucon/ tree (if any) into FAKE_HOME so
  # filesystem checks ([ -d ], find) see the same layout string-prefix
  # checks in the rewritten script text expect.
  if [ -d "$fx/home-isucon" ]; then
    cp -R "$fx/home-isucon/." "$FAKE_HOME/"
  fi

  # Symmetric fixture-root relocation: replace the literal /home/isucon
  # PROBE_SCRIPT hardcodes with this fixture's FAKE_HOME, on BOTH the script
  # text (here) and the systemctl stub's unit-file property values (its own
  # rewrite() using the same $ISUKIT_FAKE_HOME). Without both sides, string
  # prefix-strip checks like ${wd#/home/isucon} desync from what the stub
  # reports. See test/README.md.
  REWRITTEN_PROBE="${RAW_PROBE//\/home\/isucon/$FAKE_HOME}"

  OUT="$(PATH="$HERE/bin:$PATH" \
         ISUKIT_FIXTURE="$fx" \
         ISUKIT_FAKE_HOME="$FAKE_HOME" \
         bash -c "$REWRITTEN_PROBE" 2>&1)"

  if [ "$VERBOSE" = "1" ]; then
    echo "--- $name: full PROBE_SCRIPT output ---"
    echo "$OUT"
    echo "--- end $name ---"
  fi

  fail_lines=""

  # Source expected into an isolated associative-free namespace via a
  # subshell-safe eval: prefix every var so we never collide with our own.
  eval "$(sed 's/^/EXP_/' "$fx/expected")"

  while IFS= read -r ekey; do
    [ -z "$ekey" ] && continue
    exp_var="EXP_$ekey"
    expected_val="${!exp_var-}"

    # Pull the matching KEY=<%q-quoted-value> line out of PROBE_SCRIPT's
    # output (S() emits printf "%q" on the value) and unquote it properly.
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
  done < <(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$fx/expected")

  rm -rf "$FAKE_HOME"

  if [ -z "$fail_lines" ]; then
    echo "PASS $name"
    PASSED=$((PASSED + 1))
  else
    while IFS= read -r fl; do
      [ -z "$fl" ] && continue
      echo "FAIL $name: $fl"
    done <<< "$fail_lines"
    FAILED_FIXTURES="$FAILED_FIXTURES $name"
  fi
}

if [ -n "$ONLY" ]; then
  fx="$FIXTURES_DIR/$ONLY"
  if [ ! -d "$fx" ]; then
    echo "FATAL: no such fixture: $fx" >&2
    exit 2
  fi
  run_one "$fx"
else
  for fx in "$FIXTURES_DIR"/*/; do
    fx="${fx%/}"
    [ -f "$fx/expected" ] || continue
    run_one "$fx"
  done
fi

echo "probe: $TOTAL fixtures, $PASSED passed, $((TOTAL - PASSED)) failed"
[ -z "$FAILED_FIXTURES" ]
