# shellcheck shell=bash
# isukit lib/final.sh — `isukit final check|apply`: everything that logs or measures, off before the last scoring run.
# Sourced by ../isukit; not meant to run on its own.

# Before the final score, every line a request writes that nobody will read
# costs score: nginx's own access log (on as handed out, not just isukit's),
# a slow / general log a config turns on, the app's request logger, a pprof
# listener, sysstat collecting in the background, isukit's leftovers.
# `check` lists them and changes nothing; `apply` turns off what config can
# turn off — through the repo's etc/, so it is a reviewable, revertable diff —
# and cleans the hosts. The app's code is only reported: removing a logger or
# pprof is an edit to make (and bench) by hand.

cmd_final() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    check) cmd_final_check ;;
    apply) cmd_final_apply ;;
    strip) cmd_final_strip "$@" ;;
    *) die "usage: isukit final {check|apply|strip}" ;;
  esac
}

final_host_findings() { # "<host>\t<what>\t<how>" per finding, every host by its roles
  local h roles wn wm unit
  for h in $(hosts_all); do
    roles=",$(host_roles "$h"),"
    wn=0; wm=0; unit=""
    case "$roles" in *,web,*) wn=1 ;; esac
    case "$roles" in *,db,*)  wm=1 ;; esac
    case "$roles" in *,app,*) unit="${APP_UNIT:-}" ;; esac
    { printf 'WANT_NGINX=%s\nWANT_MYSQL=%s\nAPP_UNIT=%q\n' "$wn" "$wm" "$unit"; remote_script final-check.sh; } \
      | rsh_stdin "$h" 2>/dev/null \
      | awk -F'|' -v h="$h" '$1 == "FIX" { printf "%s\t%s\t%s\n", h, $2, $3 }' \
      || printf '%s\t%s\t%s\n' "$h" "could not check this host" "ssh ${SSH_OPTS:-} $h true"
  done
  return 0
}

final_code_findings() { # "<file>:<line>\t<what>" for logging / profiling left in the app's Go code
  local root
  root=$(local_repo_root)
  # per-request loggers, debug switches and profilers that the score pays for
  local -a pats=(
    '"net/http/pprof"|pprof imported: its handlers and listener stay up'
    'middleware\.Logger\(|request logger middleware (echo / chi)'
    'gin\.Default\(\)|gin.Default() includes the request logger — gin.New() + only gin.Recovery()'
    'gin\.Logger\(|gin request logger'
    '\.Debug[[:space:]]*=[[:space:]]*true|debug mode on'
    'SetLevel\(.*DEBUG|log level DEBUG'
    'log\.Print(f|ln)?\(|log.Print in app code — fine at startup, costly per request'
  )
  local p re what
  for p in "${pats[@]}"; do
    re="${p%%|*}"; what="${p#*|}"
    grep -RnE --include='*.go' --exclude='*_test.go' --exclude-dir=vendor --exclude-dir=node_modules \
      --exclude-dir=.git --exclude-dir=.isukit --exclude-dir=etc --exclude-dir=hosts -- "$re" "$root" 2>/dev/null \
      | sed "s|^$root/||" | awk -F: -v w="$what" '{ printf "%s:%s\t%s\n", $1, $2, w }' || true
  done
  return 0   # no match is the good outcome, never a failure under set -e
}

final_strip_candidates() { # files `final strip` would touch, one per line, relative to local_repo_root
  local root
  root=$(local_repo_root)
  { grep -RlE --exclude-dir=vendor --exclude-dir=node_modules --exclude-dir=.git \
      --exclude-dir=.isukit --exclude-dir=etc --exclude-dir=hosts \
      -- 'isukit:measure-(begin|end)' "$root" 2>/dev/null
    grep -RlE --include='*.go' --exclude-dir=vendor --exclude-dir=node_modules \
      --exclude-dir=.git --exclude-dir=.isukit --exclude-dir=etc --exclude-dir=hosts \
      -- '"net/http/pprof"' "$root" 2>/dev/null
  } | sed "s|^$root/||" | LC_ALL=C sort -u
}

final_strip_file() { # final_strip_file <file> -- the stripped content, to stdout
  local f="$1" body
  body=$(awk '
    /isukit:measure-begin/ { skip = 1; next }
    /isukit:measure-end/   { skip = 0; next }
    skip { next }
    { print }
  ' "$f")
  case "$f" in
    *.go) printf '%s\n' "$body" | grep -vE '"net/http/pprof"|pprof\.(Index|Profile|Cmdline|Symbol|Trace)\b|pprof\.Handler\(' ;;
    *)    printf '%s\n' "$body" ;;
  esac
}

cmd_final_strip() { # isukit final strip [--apply] -- labelled commits, then sentinel-wrapped blocks + the pprof import/routes; everything else stays a finding
  load
  local apply=0
  case "${1:-}" in
    --apply) apply=1 ;;
    "") : ;;
    *) die "usage: isukit final strip [--apply]" ;;
  esac

  local mrows
  mrows=$(measure_commits)
  if [ -n "$mrows" ]; then
    say "final strip: labelled measurement commit(s) live in HEAD, newest first"
    printf '%s\n' "$mrows" | while IFS=$'\t' read -r sha _ subject _; do
      [ -n "$sha" ] && say "  ${sha:0:7} $subject"
    done
    if [ "$apply" -eq 1 ]; then
      local sha
      while IFS=$'\t' read -r sha _ _ _; do
        [ -n "$sha" ] || continue
        if ! git revert --no-edit "$sha"; then
          die "revert of ${sha:0:7} conflicts — stopping here, remaining labelled commit(s) untouched.
conflicted paths:
$(git diff --name-only --diff-filter=U 2>/dev/null)
resolve by hand, then: git revert --abort   (or --continue once fixed)"
        fi
      done <<< "$mrows"
      say "reverted labelled measurement commit(s) — run final strip again to re-check for sentinel/pprof findings"
    fi
  fi

  local root files f before after changed=0
  root=$(local_repo_root)
  files=$(final_strip_candidates)
  if [ -z "$files" ]; then
    say "final strip: nothing sentinel-wrapped or pprof-imported to strip"
  else
    say "final strip: $([ "$apply" -eq 1 ] && echo "writing changes" || echo "dry run — nothing written")"
    local -a backups=()
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      before="$root/$f"
      after="$(final_strip_file "$before")"
      diff -q "$before" <(printf '%s\n' "$after") >/dev/null 2>&1 && continue
      changed=1
      if [ "$apply" -eq 1 ]; then
        cp "$before" "$before.isukit-strip-bak"
        backups+=("$before")
        printf '%s\n' "$after" > "$before"
      else
        diff -u "$before" <(printf '%s\n' "$after") || true
      fi
    done <<< "$files"
    if [ "$apply" -eq 1 ] && [ "$changed" -eq 1 ]; then
      local gomod builddir buildout
      gomod=$(find "$root" -maxdepth 4 -name go.mod -not -path '*/vendor/*' 2>/dev/null | head -1)
      if [ -n "$gomod" ] && command -v go >/dev/null 2>&1; then
        builddir=$(dirname "$gomod")
        if ! buildout=$(cd "$builddir" && go build ./... 2>&1); then
          for f in ${backups+"${backups[@]}"}; do mv "$f.isukit-strip-bak" "$f"; done
          die "strip broke the build — reverted every file.
$buildout"
        fi
      fi
      for f in ${backups+"${backups[@]}"}; do rm -f "$f.isukit-strip-bak"; done
    fi
  fi
  local leftn
  leftn=$(final_code_findings | grep -vF 'pprof imported: its handlers and listener stay up' | grep -c . || true)
  say "$leftn finding(s) left for you to judge"
  if [ "$apply" -eq 1 ] && [ "$changed" -eq 1 ]; then
    say 'next: isukit ship "strip measurement" && isukit deploy && isukit bench "post-strip"'
  fi
}

cmd_final_check() {
  load
  local hostf codef
  say "final check: what still logs or measures (nothing is changed)"
  hostf=$(final_host_findings)
  codef=$(final_code_findings)
  if [ -n "$hostf" ]; then
    echo "== hosts (isukit final apply fixes these)"
    printf '%s\n' "$hostf" | awk -F'\t' '{ printf "  %-22s %s\n  %-22s   -> %s\n", $1, $2, "", $3 }'
  fi
  if [ -n "$codef" ]; then
    echo "== app code (edit by hand, then deploy + bench)"
    printf '%s\n' "$codef" | awk -F'\t' '{ printf "  %-40s %s\n", $1, $2 }'
  fi
  if [ -z "$hostf" ] && [ -z "$codef" ]; then
    say "nothing left that logs or measures"
    return 0
  fi
  return 1
}

final_edit_etc() { # final_edit_etc <local etc dir> -- access_log off, mysql logs off; prints what changed
  local d="$1" f
  if [ -d "$d/nginx" ]; then
    while IFS= read -r f; do
      grep -qE '^[[:space:]]*access_log[[:space:]]+[^o;][^;]*;' "$f" || continue
      sed -E -i.isukit-tmp 's/^([[:space:]]*)access_log[[:space:]]+[^o;][^;]*;.*$/\1access_log off; # isukit final/' "$f" \
        && rm -f "$f.isukit-tmp" && echo "  ${f#"$d"/}: access_log -> off"
    done < <(find "$d/nginx" -type f \( -name '*.conf' -o -path '*/sites-*/*' \) | LC_ALL=C sort)
    # nginx logs to its compiled-in default unless told otherwise at http level
    f="$d/nginx/nginx.conf"
    if [ -f "$f" ] && ! grep -qE '^[[:space:]]*access_log[[:space:]]+off[[:space:]]*;' "$f"; then
      awk '!done && /^[[:space:]]*http[[:space:]]*\{/ { print; print "    access_log off; # isukit final"; done = 1; next } { print }' "$f" > "$f.isukit-tmp" \
        && mv "$f.isukit-tmp" "$f" && echo "  nginx/nginx.conf: access_log off; added in http {}"
    fi
  fi
  if [ -d "$d/mysql" ]; then
    while IFS= read -r f; do
      grep -qiE '^[[:space:]]*(slow_query_log|slow-query-log|general_log|general-log)[[:space:]]*=[[:space:]]*(1|on)([[:space:]]|#|$)' "$f" || continue
      sed -E -i.isukit-tmp 's/^([[:space:]]*(slow_query_log|slow-query-log|general_log|general-log)[[:space:]]*=[[:space:]]*)(1|ON|On|on)([[:space:]]*(#.*)?)$/\10\4/' "$f" \
        && rm -f "$f.isukit-tmp" && echo "  ${f#"$d"/}: slow / general log -> 0"
    done < <(find "$d/mysql" -type f -name '*.cnf' | LC_ALL=C sort)
  fi
}

cmd_final_apply() {
  load
  lock_guard "final apply"
  local root h roles wm
  root=$(local_repo_root)
  say "1/4 isukit measurement off"
  cmd_logs off || warn "logs off reported problems (above)"
  say "2/4 config: access_log off and mysql logs off in etc/, pushed to every host"
  if [ -d "$root/etc" ]; then
    final_edit_etc "$root/etc"
    cmd_etc_push || warn "etc push reported problems (above)"
  else
    warn "no etc/ here — nginx / mysql config is not under git (isukit etc adopt). turn access_log off and the slow / general log off by hand"
  fi
  say "3/4 hosts: samplers, measurement files, sysstat, live mysql logs"
  for h in $(hosts_all); do
    roles=",$(host_roles "$h"),"; wm=0
    case "$roles" in *,db,*) wm=1 ;; esac
    { printf 'WANT_MYSQL=%s\n' "$wm"; remote_script final-clean.sh; } | rsh_stdin "$h" 2>&1 | sed "s|^|    $h: |" >&2 \
      || warn "cleanup on $h reported problems"
  done
  say "4/4 what is left"
  local left_hosts left_code
  left_hosts=$(final_host_findings | grep -c . || true)
  left_code=$(final_code_findings | grep -c . || true)
  cmd_final_check || true
  printf '🧹 %s ran final apply — left: %s on the hosts, %s in the app code%s\n' "$(who_am_i)" "$left_hosts" "$left_code" \
    "$([ "$left_code" != 0 ] && printf ' (pprof / loggers to remove by hand)')" | notify ops
  say "next: isukit bench \"final: logging off\" (compare with isukit score), then isukit ship \"final: logging off\""
  git -C "$root" status --short -- etc 2>/dev/null || true
}
