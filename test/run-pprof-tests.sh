#!/bin/bash
# F5: `isukit pprof on|off` wires / removes a private-mux pprof endpoint in
# func main(), under isukit:measure-begin/end sentinels. Sources ../isukit
# (ISUKIT_SOURCED=1 skips main) and drives cmd_pprof_on / cmd_pprof_off
# directly against a real throwaway Go module + git repo, same shape as
# run-final-strip-tests.sh (off reuses cmd_final_strip, this just proves on
# generates something final strip can actually remove, and both build).
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERBOSE=0
for a in "$@"; do [ "$a" = "-v" ] && VERBOSE=1; done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/isukit-pprof.XXXXXX")"
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
say()  { printf 'say: %s\n' "$*" >> "$CALLS"; }
warn() { printf 'warn: %s\n' "$*" >> "$CALLS"; }

setup_repo() { # fresh, ISOLATED git repo + a buildable Go module
  local d
  d="$(mktemp -d "$WORK/repo.XXXXXX")"
  cd "$d" || exit 2
  git init -q
  mkdir -p .isukit
  printf 'APP=local\nPPROF_PORT=7073\n' > .isukit/config
  cat > go.mod <<'EOF'
module isukit-pprof-smoke

go 1.21
EOF
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
  [ "$VERBOSE" = 1 ] && sed 's/^/      | /' "$CALLS"
  return 0
}

t_on_wires_sentinel_and_private_mux() {
  setup_repo
  cat > main.go <<'EOF'
package main

import "fmt"

func main() {
	fmt.Println("hello")
}
EOF
  local out rc
  out="$(cmd_pprof_on 2>&1)"; rc=$?
  check "$rc" = 0
  check -n "$(grep -F 'isukit:measure-begin' main.go)"
  check -n "$(grep -F 'isukit:measure-end' main.go)"
  check -n "$(grep -F '"net/http/pprof"' main.go)"
  check -n "$(grep -F '127.0.0.1:7073' main.go)"
  check -n "$(grep -F 'http.NewServeMux()' main.go)"
  check -z "$(grep -F 'http.DefaultServeMux' main.go)"
  check -z "$(grep -F '_ "net/http/pprof"' main.go)"
  check -n "$(grep -F 'ship --measure' "$CALLS")"
  check -n "$(cd . && go build ./... 2>&1; echo "rc=$?" | grep -F 'rc=0')"
}

t_on_is_idempotent() {
  setup_repo
  cat > main.go <<'EOF'
package main

import "fmt"

func main() {
	fmt.Println("hello")
}
EOF
  cmd_pprof_on >/dev/null 2>&1
  local before after out rc
  before="$(cat main.go)"
  out="$(cmd_pprof_on 2>&1)"; rc=$?
  after="$(cat main.go)"
  check "$rc" = 0
  check "$before" = "$after"
  check -n "$(grep -F 'already wired' "$CALLS")"
}

t_on_dies_without_main() {
  setup_repo
  cat > lib.go <<'EOF'
package main

func helper() string { return "no main here" }
EOF
  local out rc
  out="$(cmd_pprof_on 2>&1)"; rc=$?
  check "$rc" != 0
  check -n "$(printf '%s' "$out" | grep -F 'no func main()')"
}

t_on_dies_on_ambiguous_main() {
  setup_repo
  cat > main.go <<'EOF'
package main

func main() {}
EOF
  mkdir -p cmd/other
  cat > cmd/other/main.go <<'EOF'
package main

func main() {}
EOF
  local out rc
  out="$(cmd_pprof_on 2>&1)"; rc=$?
  check "$rc" != 0
  check -n "$(printf '%s' "$out" | grep -F 'more than one func main()')"
  check -n "$(printf '%s' "$out" | grep -F 'main.go')"
  check -n "$(printf '%s' "$out" | grep -F 'cmd/other/main.go')"
}

t_on_reverts_on_broken_build() {
  setup_repo
  cat > main.go <<'EOF'
package main

import "fmt"

func main() {
	fmt.Println("hello")
}
EOF
  cat > broken.go <<'EOF'
package main

func broken() int {
	return
}
EOF
  local before out rc
  before="$(cat main.go)"
  out="$(cmd_pprof_on 2>&1)"; rc=$?
  check "$rc" != 0
  check -n "$(printf '%s' "$out" | grep -F 'broke the build')"
  check "$before" = "$(cat main.go)"
  check -z "$(find . -name '*.isukit-strip-bak')"
}

t_off_removes_it_and_still_builds() {
  setup_repo
  cat > main.go <<'EOF'
package main

import "fmt"

func main() {
	fmt.Println("hello")
}
EOF
  cmd_pprof_on >/dev/null 2>&1
  local out rc
  out="$(cmd_pprof_off 2>&1)"; rc=$?
  check "$rc" = 0
  check -z "$(grep -F 'isukit:measure' main.go)"
  check -z "$(grep -F 'net/http/pprof' main.go)"
  check -n "$(grep -F 'fmt.Println("hello")' main.go)"
  check -n "$(go build ./... 2>&1; echo "rc=$?" | grep -F 'rc=0')"
}

case_ pprof-on-wires-sentinel-mux     t_on_wires_sentinel_and_private_mux
case_ pprof-on-idempotent             t_on_is_idempotent
case_ pprof-on-dies-without-main      t_on_dies_without_main
case_ pprof-on-dies-ambiguous-main    t_on_dies_on_ambiguous_main
case_ pprof-on-reverts-on-bad-build   t_on_reverts_on_broken_build
case_ pprof-off-removes-and-builds    t_off_removes_it_and_still_builds

echo "$TOTAL fixtures, $PASSED passed, $((TOTAL-PASSED)) failed"
[ -z "$FAILED" ]
