# shellcheck shell=bash
# isukit lib/runs.sh — `isukit bench` as one measured run, saved runs, show, score, attribute.
# Sourced by ../isukit; not meant to run on its own.

# One `isukit bench` = one run, saved under .isukit/runs/<when>/:
#   bench.log     benchmarker output (auto mode)
#   hosts.txt     per host: cpu avg/max/iowait + the top processes, sampled 1s
#   alp.txt       endpoints for this run only (every web host's log, merged)
#   slow-<h>.txt  pt-query-digest per db host
#   cpu.pprof     a CPU profile taken while the load was on (first app host)
#   meta          when / sha / score / note
# Measuring happens only while `isukit logs on` is in effect, so a logs-off
# scoring run stays clean. Logs are emptied at the start AND after collecting,
# so a portal score typed in later (--score) still gets exactly its own run.
RUNS="$STATE/runs"
PPROF_PORT_DEFAULT=6060

run_measuring() { # true if logging is on anywhere
  local h
  for h in $(hosts_all); do
    # shellcheck disable=SC2034  # HOST_OVERRIDE is read by load() in lib/core.sh
    ( HOST_OVERRIDE="$h"; load; logs_are_on ) && return 0
  done
  return 1
}

run_reset() { # run_reset <sample 0|1> -- empty the run logs everywhere; optionally start samplers
  local h roles rn rm
  for h in $(hosts_all); do
    roles=",$(host_roles "$h"),"
    rn=0; rm=0
    case "$roles" in *,web,*) rn=1 ;; esac
    case "$roles" in *,db,*)  rm=1 ;; esac
    { printf 'RESET_NGINX=%s\nRESET_MYSQL=%s\nSAMPLE=%s\n' "$rn" "$rm" "$1"; remote_script run-start.sh; } \
      | rsh_stdin "$h" 2>&1 | sed "s|^|    $h: |" >&2 || warn "could not reset/sample on $h"
  done
}

pprof_begin() { # pprof_begin <run-dir> -- start a CPU profile on the first app host, detached
  local run="$1" h port="${PPROF_PORT:-$PPROF_PORT_DEFAULT}" sec="${PPROF_SEC:-30}" delay="${PPROF_DELAY:-5}"
  h=$(hosts_with app | head -1)
  [ -n "$h" ] || return 0
  # a profile left by an earlier run (or `isukit pprof`) must never pass for this one
  rsh "$h" "rm -f /tmp/isukit-cpu.pprof /tmp/isukit-cpu.pprof.part" 2>/dev/null || true
  if [ "$(rsh "$h" "curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://localhost:$port/debug/pprof/" 2>/dev/null)" != 200 ]; then
    say "pprof: no endpoint on $h:$port — skipped (import _ \"net/http/pprof\" + a listener; PPROF_PORT in config)"
    return 0
  fi
  rsh "$h" "setsid nohup sh -c 'sleep $delay; curl -s --max-time $((sec + 30)) -o /tmp/isukit-cpu.pprof.part \"http://localhost:$port/debug/pprof/profile?seconds=$sec\" && mv /tmp/isukit-cpu.pprof.part /tmp/isukit-cpu.pprof' >/dev/null 2>&1 < /dev/null &" \
    && : > "$run/.pprof-started" \
    && say "pprof: ${sec}s CPU profile on $h starts in ${delay}s"
  return 0
}

pprof_collect() { # pprof_collect <run-dir> -- wait for the profile to finish, then fetch it
  local h port="${PPROF_PORT:-$PPROF_PORT_DEFAULT}" i=0 limit
  h=$(hosts_with app | head -1)
  [ -n "$h" ] && [ -f "$1/.pprof-started" ] || return 0
  limit=$(( ${PPROF_SEC:-30} + ${PPROF_DELAY:-5} + 5 ))
  until rsh "$h" "test -s /tmp/isukit-cpu.pprof" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -gt "$limit" ] && { warn "pprof: profile on $h did not finish — skipped"; return 0; }
    [ "$i" = 1 ] && say "pprof: waiting for the profile on $h to finish"
    sleep 1
  done
  if rpull "$h" /tmp/isukit-cpu.pprof "$1/cpu.pprof"; then say "pprof: $1/cpu.pprof"; else warn "pprof: could not fetch the profile from $h"; fi
  rm -f "$1/.pprof-started"
}

run_alp() { # run_alp <out> -- alp over every web host's log, merged onto the first one
  local webs first h
  webs=$(hosts_with web)
  first=$(printf '%s\n' $webs | head -1)
  [ -n "$first" ] || return 0
  if [ "$(printf '%s\n' $webs | wc -l | tr -d ' ')" -gt 1 ]; then
    rsh "$first" "sudo -n cp /var/log/nginx/isukit.log /tmp/isukit-alp.log 2>/dev/null || sudo -n truncate -s 0 /tmp/isukit-alp.log" \
      || warn "alp: could not stage the merged log on $first"
    for h in $webs; do
      [ "$h" = "$first" ] && continue
      rsh "$h" "sudo -n cat /var/log/nginx/isukit.log 2>/dev/null" | rsh "$first" "sudo -n tee -a /tmp/isukit-alp.log >/dev/null" \
        || warn "alp: could not merge $h's log — alp shows the other web hosts only"
    done
    # shellcheck disable=SC2034  # HOST_OVERRIDE is read by load() in lib/core.sh
    ( HOST_OVERRIDE="$first"; load; alp_one /tmp/isukit-alp.log ) > "$1" 2>/dev/null || true
  else
    # shellcheck disable=SC2034  # HOST_OVERRIDE is read by load() in lib/core.sh
    ( HOST_OVERRIDE="$first"; load; alp_one ) > "$1" 2>/dev/null || true
  fi
  [ -s "$1" ] || { rm -f "$1"; warn "alp: nothing to report for this run"; }
}

run_end() { # run_end <run-dir> <sampled 0|1> -- collect everything, then empty the logs
  # Called in a subshell after the score is recorded. Every step may fail on its
  # own (a host down, an empty log after a failed /initialize); none may stop
  # the rest, least of all the reset the next run depends on.
  local run="$1" h out
  if [ "$2" = 1 ]; then
    : > "$run/hosts.txt"
    for h in $(hosts_all); do
      out=$(remote_script run-stop.sh | rsh_stdin "$h" 2>/dev/null) || out=""
      [ -n "$out" ] && printf '%s (%s)\n%s\n\n' "$h" "$(host_roles "$h")" "$(printf '%s\n' "$out" | sed 's/^/  /')" >> "$run/hosts.txt"
    done
  fi
  run_alp "$run/alp.txt" || warn "alp: could not collect this run"
  for h in $(hosts_with db); do
    # shellcheck disable=SC2034  # HOST_OVERRIDE is read by load() in lib/core.sh
    ( HOST_OVERRIDE="$h"; load; slow_one ) > "$run/slow-$h.txt" 2>/dev/null || rm -f "$run/slow-$h.txt"
  done
  if [ "$2" = 1 ]; then pprof_collect "$run" || warn "pprof: could not collect this run"; fi
  run_reset 0 || warn "could not empty the logs for the next run — the next record may include this one"
  return 0
}

run_collect() { # run_collect <run-dir> <sampled 0|1> -- run_end, isolated: its failure is only a warning
  ( set +e; run_end "$@" ) || warn "collecting $1 stopped partway — the score is recorded; see what was saved: isukit show"
  return 0
}

run_record() { # run_record <run-dir> <when> <sha> <score> <note> -- scores.tsv + meta
  printf '%s\t%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" "$1" >> "$STATE/scores.tsv"
  printf 'when=%s\nsha=%s\nscore=%s\nnote=%s\n' "$2" "$3" "$4" "$5" > "$1/meta"
}

run_summary() { # run_summary <run-dir> -- the short view printed after a run and by `show`
  local run="$1" f
  [ -f "$run/meta" ] && awk '{ i = index($0, "="); printf "%s %s   ", substr($0, 1, i - 1), substr($0, i + 1) } END { print "" }' "$run/meta"
  if [ -s "$run/hosts.txt" ]; then echo; echo "== hosts (while the load was on) =="; cat "$run/hosts.txt"; fi
  if [ -s "$run/alp.txt" ]; then echo "== alp (top 15 by sum) =="; head -18 "$run/alp.txt"; echo; fi
  for f in "$run"/slow-*.txt; do
    [ -s "$f" ] || continue
    echo "== slow: $(basename "$f" .txt | sed 's/^slow-//') =="
    awk '/^# Profile/ { on = 1 } on && NF == 0 { exit } on' "$f"
    echo
  done
  [ -f "$run/cpu.pprof" ] && echo "pprof: go tool pprof -http=: $run/cpu.pprof"
  return 0
}

cmd_show() { # show [n | when] -- a saved run; default the latest, 2 = the one before
  need_state
  local sel="${1:-1}" run
  [ -d "$RUNS" ] || die "no saved runs yet — they are written by isukit bench while logs are on"
  case "$sel" in
    ''|*[!0-9]*) run=$(ls -1d "$RUNS"/*"$sel"* 2>/dev/null | tail -1) ;;
    *)
      local count
      count=$(ls -1d "$RUNS"/* 2>/dev/null | wc -l | tr -d ' ')
      [ "$sel" -ge 1 ] && [ "$sel" -le "$count" ] || die "only $count saved run(s) — show takes 1..$count"
      run=$(ls -1d "$RUNS"/* 2>/dev/null | tail -n "$sel" | head -1) ;;
  esac
  [ -n "$run" ] && [ -d "$run" ] || die "no run matches '$sel' — see: ls $RUNS"
  echo "run: $run"
  run_summary "$run"
}

cmd_bench() {
  load
  local mode="${BENCH_MODE:-auto}"

  if [ "$mode" = "manual" ]; then
    cmd_bench_manual "$@"
    return 0
  fi

  if [ -z "${BENCH_CMD:-}" ]; then
    warn "BENCH_CMD is empty in $CONF — attempting to auto-compose it"
    ( cmd_benchprobe ) || warn "benchprobe failed"
    load
    # benchprobe may have decided there is no benchmarker to run at all and
    # flipped us to manual. that is a successful self-repair, not a failure —
    # follow it instead of dying on the now-irrelevant empty BENCH_CMD.
    if [ "${BENCH_MODE:-auto}" = "manual" ]; then
      cmd_bench_manual "$@"
      return 0
    fi
    [ -n "${BENCH_CMD:-}" ] || die "BENCH_CMD is still empty after benchprobe — set it by hand: isukit benchcmd '<command>', or switch to the portal: isukit benchmode manual"
  fi
  local note="${*:-}"
  local sha ts run raw measure=0
  sha=$(git rev-parse --short HEAD 2>/dev/null || echo nogit)
  ts=$(date +%Y%m%d-%H%M%S)
  run="$RUNS/$ts"; mkdir -p "$run"
  raw="$run/bench.log"
  run_measuring && measure=1
  if [ "$measure" = 1 ]; then
    say "measuring this run (logs are on): logs emptied, samplers on every host"
    run_reset 1
    pprof_begin "$run"
  fi
  say "bench on $BENCH: $BENCH_CMD"
  set +e
  rsh "$BENCH" "$BENCH_CMD" 2>&1 | tee "$raw"
  local rc=${PIPESTATUS[0]}
  set -e
  local score
  score=$(grep -oiE '"?(total[ _-]?)?score"?[^0-9-]{0,12}-?[0-9]+' "$raw" | tail -1 | grep -oE '\-?[0-9]+$' || true)
  [ -n "$score" ] || score="?"
  run_record "$run" "$ts" "$sha" "$score" "${note:-}"
  [ "$measure" = 1 ] && run_collect "$run" 1
  say "score=$score  sha=$sha  rc=$rc  run=$run"
  [ "$score" = "?" ] && warn "could not parse a score — read $raw, then fix the line in $STATE/scores.tsv by hand"
  [ "$measure" = 1 ] && run_summary "$run"
  return 0
}

# BENCH_MODE=manual: no bench ssh target exists (contest day — the portal
# runs the bench). pull the score out of --score/--score=N, a --fail flag,
# or an interactive prompt, and log it the same way as an auto run.
cmd_bench_manual() {
  local score="" fail_flag=0 next_is_score=0
  local args=() a
  for a in "$@"; do
    if [ "$next_is_score" = 1 ]; then
      score="$a"; next_is_score=0; continue
    fi
    case "$a" in
      --score=*) score="${a#--score=}" ;;
      --score) next_is_score=1 ;;
      --fail) fail_flag=1 ;;
      *) args+=("$a") ;;
    esac
  done
  local note="${args[*]:-}"
  local sha ts run measure=0 sampled=0
  sha=$(git rev-parse --short HEAD 2>/dev/null || echo nogit)
  ts=$(date +%Y%m%d-%H%M%S)
  run="$RUNS/$ts"
  run_measuring && measure=1

  if [ "$fail_flag" = 1 ]; then
    mkdir -p "$run"
    run_record "$run" "$ts" "$sha" "FAIL" "${note:-}"
    [ "$measure" = 1 ] && run_collect "$run" 0
    say "score=FAIL  sha=$sha  (recorded via --fail)"
    return 0
  fi

  if [ -z "$score" ]; then
    say "BENCH_MODE=manual — run the benchmark from the ISUCON portal, then either:"
    say "  rerun:  isukit bench --score <N>"
    say "  or paste the score below"
    if [ -t 0 ]; then
      if [ "$measure" = 1 ]; then
        # an interactive run gets the full window: samplers from now, pprof from
        # when the portal says the load has started
        say "measuring this run (logs are on): logs emptied, samplers on every host"
        run_reset 1; sampled=1
        printf 'enqueue the run in the portal; press Enter once it is RUNNING (starts the CPU profile): ' >&2
        read -r _ || true
        mkdir -p "$run"
        pprof_begin "$run"
      fi
      printf 'portal score: ' >&2
      read -r score || true
    fi
  fi
  [ -n "$score" ] || die "no score given — rerun with: isukit bench --score <N>"

  case "$score" in
    -[0-9]*) local rest=${score#-}; case "$rest" in ''|*[!0-9]*) die "score must be an integer, got: $score" ;; esac ;;
    [0-9]*) case "$score" in *[!0-9]*) die "score must be an integer, got: $score" ;; esac ;;
    *) die "score must be an integer, got: $score" ;;
  esac

  mkdir -p "$run"
  # --score without the prompt still gets this run's alp / slow: the logs were
  # emptied when the previous run was collected
  run_record "$run" "$ts" "$sha" "$score" "${note:-}"
  [ "$measure" = 1 ] && run_collect "$run" "$sampled"
  say "score=$score  sha=$sha  (recorded from portal)  run=$run"
  [ "$measure" = 1 ] && run_summary "$run"
  return 0
}

cmd_score() {
  need_state
  [ -f "$STATE/scores.tsv" ] || die "no runs yet — run: isukit bench"
  { printf 'WHEN\tSHA\tSCORE\tNOTE\tLOG\n'; cat "$STATE/scores.tsv"; } | column -t -s $'\t'
}

cmd_attribute() {
  need_state
  [ -f "$STATE/scores.tsv" ] || die "no runs yet — run: isukit bench"
  local noise="${1:-10}"

  local rows n
  rows=$(awk -F'\t' '$3 ~ /^-?[0-9]+$/' "$STATE/scores.tsv" | tail -2)
  n=$(printf '%s\n' "$rows" | grep -c . || true)
  [ "$n" -ge 2 ] || die "need at least two numeric-score runs to compare (have $n) — run: isukit bench again. rows scored ? or FAIL don't count"

  printf '%s\n' "$rows" | awk -F'\t' -v noise="$noise" '
    NR==1 { pts=$1; psha=$2; pscore=$3; pnote=$4 }
    NR==2 { cts=$1; csha=$2; cscore=$3; cnote=$4 }
    END {
      printf "prev  %s  sha=%s  score=%s  note=%s\n", pts, psha, pscore, pnote
      printf "cur   %s  sha=%s  score=%s  note=%s\n", cts, csha, cscore, cnote
      if (pscore == 0) { print "prev score is 0 — cannot compute a percent delta"; exit 0 }
      denom = pscore < 0 ? -pscore : pscore
      delta = (cscore - pscore) / denom * 100
      printf "delta %.1f%%  (noise threshold +/-%s%%)\n", delta, noise
      if (delta > noise)       print "\033[32mKEEP\033[0m — improvement clears the noise floor"
      else if (delta < -noise) print "\033[31mREVERT\033[0m — regression clears the noise floor: isukit revert " csha
      else                     print "\033[33mINCONCLUSIVE\033[0m — inside noise; repeat this run 2-3x before deciding. stacking another change now makes BOTH runs unattributable"
    }'
}
