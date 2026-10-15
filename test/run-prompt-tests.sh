#!/bin/bash
# feat/interactive-prompts: ISUKIT_NO_PROMPT=1 must reproduce today's exact
# no-tty behavior (same die, same usage text, same exit code) at every call
# site that now also offers an interactive `ask()` prompt.
# Sources ../isukit (ISUKIT_SOURCED=1 skips main), stubs rsh/say/warn/gh/
# deployed/run_measuring, and drives cmd_go/cmd_host/cmd_unit/cmd_bench_manual
# and the bare `ask` helper against a throwaway .isukit state dir.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERBOSE=0
for a in "$@"; do [ "$a" = "-v" ] && VERBOSE=1; done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/isukit-prompts.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK" || exit 2

# shellcheck disable=SC2034  # read by the sourced isukit
ISUKIT_SOURCED=1
# shellcheck source=../isukit
. "$HERE/../isukit"
set +e +u +o pipefail   # isukit's own strict mode; the harness checks by hand

CALLS="$WORK/calls"
rsh() { printf '%s %s\n' "$1" "${*:2}" >> "$CALLS"; return 0; }
rsh_stdin() { cat >/dev/null; printf '%s stdin\n' "$1" >> "$CALLS"; return 0; }
say()  { :; }
warn() { printf 'warn: %s\n' "$*" >> "$CALLS"; }
gh()   { return 1; }
deployed() { printf 'deadbee main\n'; }
run_measuring() { return 1; }

setup_state() { # fresh dir with a minimal .isukit/config (need_state passes)
  local d
  d="$(mktemp -d "$WORK/st.XXXXXX")"
  cd "$d" || exit 2
  mkdir -p .isukit
  : > .isukit/config
  : > "$CALLS"
}

TOTAL=0; PASSED=0; FAILED=""; ERR=""
check() { [ "$@" ] || ERR="$ERR
    failed: [ $* ]"; }
case_() {
  TOTAL=$((TOTAL+1)); ERR=""
  ( "$2" ; printf '%s' "$ERR" > "$WORK/err" )
  ERR="$(cat "$WORK/err" 2>/dev/null)"
  if [ -z "$ERR" ]; then PASSED=$((PASSED+1)); echo "PASS  $1"
  else FAILED="$FAILED $1"; echo "FAIL  $1$ERR"; fi
  [ "$VERBOSE" = 1 ] && sed 's/^/      | /' "$CALLS" 2>/dev/null
  return 0
}

# (b) ask() itself: no tty available in this harness (no controlling terminal),
# so it already returns 1/prints nothing without even needing ISUKIT_NO_PROMPT —
# set both so the assertion holds regardless of the sandbox's tty situation.
t_ask_no_prompt_returns_1_silently() {
  local out rc
  ISUKIT_NO_PROMPT=1 out=$(ask "pick one" "default") ; rc=$?
  check "$rc" = 1
  check -z "$out"
}

t_go_dies_no_url() {
  setup_state
  local out rc
  out=$( (ISUKIT_NO_PROMPT=1 cmd_go) 2>&1 ); rc=$?
  check "$rc" != 0
  check -n "$(printf '%s' "$out" | grep -F 'usage: isukit go')"
}

t_go_dies_no_apph() {
  setup_state
  local out rc
  out=$( (ISUKIT_NO_PROMPT=1 cmd_go "myteam/isucon2026") 2>&1 ); rc=$?
  check "$rc" != 0
  check -n "$(printf '%s' "$out" | grep -F 'usage: isukit go')"
}

t_host_add_dies_no_target() {
  setup_state
  local out rc
  out=$( (ISUKIT_NO_PROMPT=1 cmd_host add) 2>&1 ); rc=$?
  check "$rc" != 0
  check -n "$(printf '%s' "$out" | grep -F 'usage: isukit host add')"
}

t_host_role_dies_no_args() {
  setup_state
  local out rc
  out=$( (ISUKIT_NO_PROMPT=1 cmd_host role) 2>&1 ); rc=$?
  check "$rc" != 0
  check -n "$(printf '%s' "$out" | grep -F 'usage: isukit host role')"
}

t_unit_dies_no_name() {
  setup_state
  local out rc
  out=$( (ISUKIT_NO_PROMPT=1 cmd_unit) 2>&1 ); rc=$?
  check "$rc" != 0
  check -n "$(printf '%s' "$out" | grep -F 'usage: isukit unit')"
}

t_bench_manual_dies_no_score() {
  setup_state
  mkdir -p .isukit/runs
  local out rc
  out=$( (ISUKIT_NO_PROMPT=1 cmd_bench_manual) 2>&1 ); rc=$?
  check "$rc" != 0
  check -n "$(printf '%s' "$out" | grep -F 'no score given')"
}

case_ ask-no-prompt-returns-1-silently   t_ask_no_prompt_returns_1_silently
case_ go-dies-no-url                     t_go_dies_no_url
case_ go-dies-no-apph                    t_go_dies_no_apph
case_ host-add-dies-no-target            t_host_add_dies_no_target
case_ host-role-dies-no-args             t_host_role_dies_no_args
case_ unit-dies-no-name                  t_unit_dies_no_name
case_ bench-manual-dies-no-score         t_bench_manual_dies_no_score

# (c) "ask returns the default on a blank answer" is skipped: it needs a real
# controlling tty with a scripted reply on /dev/tty, which a non-interactive
# test harness (and this sandboxed shell, which has no controlling terminal
# at all) can't simulate without a pty tool. ask()'s default-fallback branch
# (core.sh) is one line and was eyeballed instead.

echo "$TOTAL fixtures, $PASSED passed, $((TOTAL-PASSED)) failed"
[ -z "$FAILED" ]
