#!/bin/bash
# F4b: `isukit final strip` removes exactly two things by pattern — sentinel-wrapped
# blocks and the pprof import/registrations — and leaves everything else
# final_code_findings reports (gin.Logger(), debug switches, ...) as a finding to
# judge by hand. Sources ../isukit (ISUKIT_SOURCED=1 skips main) and drives
# final_strip_candidates / final_strip_file / cmd_final_strip directly against a
# real throwaway git repo.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERBOSE=0
for a in "$@"; do [ "$a" = "-v" ] && VERBOSE=1; done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/isukit-strip.XXXXXX")"
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

setup_repo() { # fresh, ISOLATED git repo + the isukit state final strip needs
  local d
  d="$(mktemp -d "$WORK/repo.XXXXXX")"
  cd "$d" || exit 2
  git init -q
  mkdir -p .isukit
  printf 'APP=local\n' > .isukit/config
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

t_sentinel_block_stripped_exactly() {
  setup_repo
  cat > main.go <<'EOF'
package main

import "fmt"

func main() {
	fmt.Println("before")
	// isukit:measure-begin
	start := time.Now()
	defer fmt.Println(time.Since(start))
	// isukit:measure-end
	fmt.Println("after")
}
EOF
  local out
  out="$(final_strip_file "$PWD/main.go")"
  check -z "$(printf '%s\n' "$out" | grep -F 'isukit:measure')"
  check -z "$(printf '%s\n' "$out" | grep -F 'time.Now')"
  check -n "$(printf '%s\n' "$out" | grep -F 'fmt.Println("before")')"
  check -n "$(printf '%s\n' "$out" | grep -F 'fmt.Println("after")')"
}

t_pprof_import_and_registrations_removed() {
  setup_repo
  cat > main.go <<'EOF'
package main

import (
	"net/http"
	_ "net/http/pprof"
)

func main() {
	http.ListenAndServe(":6060", nil)
}
EOF
  cat > routes.go <<'EOF'
package main

import (
	"net/http"
	"net/http/pprof"
)

func registerDebug(mux *http.ServeMux) {
	mux.HandleFunc("/debug/pprof/", pprof.Index)
	mux.HandleFunc("/debug/pprof/profile", pprof.Profile)
	mux.HandleFunc("/debug/pprof/cmdline", pprof.Cmdline)
}
EOF
  local out
  out="$(final_strip_file "$PWD/main.go")"
  check -z "$(printf '%s\n' "$out" | grep -F 'net/http/pprof')"
  check -n "$(printf '%s\n' "$out" | grep -F 'net/http"')"
  out="$(final_strip_file "$PWD/routes.go")"
  check -z "$(printf '%s\n' "$out" | grep -F 'pprof.Index')"
  check -z "$(printf '%s\n' "$out" | grep -F 'pprof.Profile')"
  check -z "$(printf '%s\n' "$out" | grep -F 'pprof.Cmdline')"
  check -z "$(printf '%s\n' "$out" | grep -F 'net/http/pprof')"
}

t_gin_logger_not_removed_stays_a_finding() {
  setup_repo
  cat > main.go <<'EOF'
package main

func main() {
	r := gin.Default()
	r.Use(gin.Logger())
}
EOF
  local out
  out="$(final_strip_file "$PWD/main.go")"
  check -n "$(printf '%s\n' "$out" | grep -F 'gin.Logger()')"
  check -z "$(final_strip_candidates | grep -F main.go)"  # not a strip candidate at all
  local found
  found="$(final_code_findings | grep -vF 'pprof imported: its handlers and listener stay up')"
  check -n "$(printf '%s\n' "$found" | grep -F 'gin request logger')"
}

t_dry_run_changes_no_files() {
  setup_repo
  cat > main.go <<'EOF'
package main

import (
	_ "net/http/pprof"
)

func main() {
	// isukit:measure-begin
	x := 1
	_ = x
	// isukit:measure-end
}
EOF
  local before after
  before="$(cat main.go)"
  cmd_final_strip >/dev/null 2>&1
  after="$(cat main.go)"
  check "$before" = "$after"
}

t_apply_writes_and_is_idempotent() {
  setup_repo
  cat > main.go <<'EOF'
package main

import (
	"fmt"
	_ "net/http/pprof"
)

func main() {
	// isukit:measure-begin
	fmt.Println("measuring")
	// isukit:measure-end
	fmt.Println("hello")
}
EOF
  cmd_final_strip --apply >/dev/null 2>&1
  local rc1=$?
  check "$rc1" = 0
  check -z "$(grep -F 'isukit:measure' main.go)"
  check -z "$(grep -F 'net/http/pprof' main.go)"
  check -n "$(grep -F 'fmt.Println("hello")' main.go)"
  check -z "$(find . -name '*.isukit-strip-bak')"
  # second apply: nothing left to strip, still exits clean
  cmd_final_strip --apply >/dev/null 2>&1
  check "$?" = 0
}

t_apply_reverts_on_broken_build() {
  setup_repo
  cat > go.mod <<'EOF'
module isukit-strip-smoke

go 1.21
EOF
  cat > main.go <<'EOF'
package main

import "fmt"

func main() {
	// isukit:measure-begin
	x := 42
	// isukit:measure-end
	fmt.Println(x)
}
EOF
  local before out rc
  before="$(cat main.go)"
  out="$(cmd_final_strip --apply 2>&1)"; rc=$?
  check "$rc" != 0
  check -n "$(printf '%s' "$out" | grep -F 'broke the build')"
  check "$before" = "$(cat main.go)"
  check -z "$(find . -name '*.isukit-strip-bak')"
}

case_ strip-sentinel-block-exact        t_sentinel_block_stripped_exactly
case_ strip-pprof-import-and-routes     t_pprof_import_and_registrations_removed
case_ strip-leaves-gin-logger-finding   t_gin_logger_not_removed_stays_a_finding
case_ strip-dry-run-no-writes           t_dry_run_changes_no_files
case_ strip-apply-writes-idempotent     t_apply_writes_and_is_idempotent
case_ strip-apply-reverts-on-bad-build  t_apply_reverts_on_broken_build

echo "$TOTAL fixtures, $PASSED passed, $((TOTAL-PASSED)) failed"
[ -z "$FAILED" ]
