# shellcheck shell=bash
# isukit lib/team.sh — several people, one set of servers: whose turn it is,
# what is deployed, and one shared record of every run.
# Sourced by ../isukit; not meant to run on its own.

# Branches are parallel, the servers are not: a bench, a deploy or a config
# push changes what everyone measures. So a lock on the probed host says whose
# turn it is; deploy refuses what would roll back the team's merged work and
# records what it put there; and runs are published to a branch of the team
# repo, so whoever looks — and attribute's "compared to main" — sees all of them.

LOCK_FILE=/var/tmp/isukit.lock          # survives the reboots finalize does
DEPLOYED_FILE=/var/tmp/isukit.deployed
SHARED_RUNS_BRANCH=isukit-runs

who_am_i() { # ISUKIT_WHO, else git user.name, else the login — one word, no separators
  local w="${ISUKIT_WHO:-}"
  [ -n "$w" ] || w=$(git config user.name 2>/dev/null || true)
  [ -n "$w" ] || w=$(id -un 2>/dev/null || echo someone)
  printf '%s' "$w" | tr -s " \t|'\"" '_'
}
lock_host() { printf '%s' "${PRIMARY:-$APP}"; }
lock_read() { rsh "$(lock_host)" "sudo -n cat $LOCK_FILE 2>/dev/null" 2>/dev/null | head -1; }
lock_describe() { # lock_describe <line> -- "alice: bench for 4m"
  local who what since
  IFS='|' read -r who what since _ <<< "$1"
  printf '%s: %s for %sm' "$who" "$what" "$(( ($(date +%s) - ${since:-0}) / 60 ))"
}
lock_take() { # lock_take <what> <hold|cmd> -- 0 taken, 2 already mine, 1 someone else's
  local me line cur
  me=$(who_am_i)
  line="$me|$1|$(date +%s)|$2"
  # noclobber makes the create atomic: two people can never both get it
  if rsh "$(lock_host)" "sudo -n sh -c 'set -C; printf \"%s\\n\" \"$line\" > $LOCK_FILE' 2>/dev/null" 2>/dev/null; then
    LOCK_TAKEN="$line"   # what lock_release_cmd may remove: exactly this, nothing else
    return 0
  fi
  cur=$(lock_read)
  [ -n "$cur" ] || return 1
  [ "${cur%%|*}" = "$me" ] && return 2
  return 1
}

# lock_guard <what> -- every command that changes the servers or measures
# them starts with this. Nested calls (deploy -> etc push -> logs on) find the
# lock already held by this process and go on; only the taker releases it.
lock_guard() {
  [ "${ISUKIT_LOCKED:-0}" = 1 ] && return 0
  local rc=0
  lock_take "$1" cmd || rc=$?
  case "$rc" in
    0) ISUKIT_LOCKED=1; trap lock_release_cmd EXIT ;;
    2) ISUKIT_LOCKED=1 ;;      # held by me (isukit lock, or my other command)
    *) die "the servers are busy — $(lock_describe "$(lock_read)"). wait for them; if it is stale: isukit unlock --force" ;;
  esac
}
lock_release_cmd() { # only the per-command lock this process took; a held turn stays
  [ -n "${LOCK_TAKEN:-}" ] || return 0
  rsh "$(lock_host)" "sudo -n sh -c 'grep -qxF \"$LOCK_TAKEN\" $LOCK_FILE 2>/dev/null && rm -f $LOCK_FILE'" >/dev/null 2>&1 || true
}

cmd_lock() { # lock [status] -- take the servers for your turn (deploy, bench, ... until unlock)
  load
  local cur rc=0
  case "${1:-}" in
    status)
      cur=$(lock_read)
      if [ -n "$cur" ]; then say "held — $(lock_describe "$cur")"; else say "free"; fi
      return 0 ;;
    "") ;;
    *) die "usage: isukit lock [status]" ;;
  esac
  lock_take turn hold || rc=$?
  case "$rc" in
    0) say "the servers are yours ($(who_am_i)) until: isukit unlock" ;;
    2) rsh "$(lock_host)" "sudo -n sh -c 'printf \"%s\\n\" \"$(who_am_i)|turn|$(date +%s)|hold\" > $LOCK_FILE'" >/dev/null 2>&1
       say "the servers are yours ($(who_am_i)) until: isukit unlock" ;;
    *) die "the servers are busy — $(lock_describe "$(lock_read)")" ;;
  esac
}

cmd_unlock() { # unlock [--force] -- hand the servers back
  load
  local cur
  cur=$(lock_read)
  [ -n "$cur" ] || { say "already free"; return 0; }
  if [ "${cur%%|*}" != "$(who_am_i)" ] && [ "${1:-}" != "--force" ]; then
    die "held by someone else — $(lock_describe "$cur"). only if they are gone: isukit unlock --force"
  fi
  rsh "$(lock_host)" "sudo -n rm -f $LOCK_FILE" && say "the servers are free"
}

# --- deploy: never roll back merged work; record what was deployed
deploy_guard() { # stop a deploy that would put unreviewable or outdated code on the shared servers
  local root
  root=$(local_repo_root)
  git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || return 0
  [ -z "$(git -C "$root" status --porcelain 2>/dev/null)" ] \
    || die "uncommitted changes would be deployed — nobody could reproduce that run. commit them (isukit ship) or stash; isukit deploy --force to deploy anyway"
  git -C "$root" remote get-url origin >/dev/null 2>&1 || return 0
  git -C "$root" fetch -q origin 2>/dev/null || { warn "could not fetch origin — skipping the 'contains main' check"; return 0; }
  if git -C "$root" rev-parse -q --verify origin/main >/dev/null 2>&1; then
    git -C "$root" merge-base --is-ancestor origin/main HEAD \
      || die "this branch does not contain origin/main — deploying it rolls back what the team already merged. git rebase origin/main, then deploy (isukit deploy --force to deploy anyway)"
  fi
}
deploy_record() { # what is on the servers now: sha|branch|who|when
  local root sha branch
  root=$(local_repo_root)
  sha=$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo nogit)
  branch=$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
  [ -z "$(git -C "$root" status --porcelain 2>/dev/null)" ] || sha="$sha+dirty"
  rsh "$(lock_host)" "sudo -n sh -c 'printf \"%s\\n\" \"$sha|$branch|$(who_am_i)|$(date +%s)\" > $DEPLOYED_FILE'" >/dev/null 2>&1 || true
}
deployed() { # "sha branch" the servers run: the deploy record, else this checkout
  local line root
  line=$(rsh "$(lock_host)" "cat $DEPLOYED_FILE 2>/dev/null" 2>/dev/null | head -1)
  if [ -n "$line" ]; then
    printf '%s %s\n' "$(printf '%s' "$line" | cut -d'|' -f1)" "$(printf '%s' "$line" | cut -d'|' -f2)"
    return 0
  fi
  root=$(local_repo_root)
  printf '%s %s\n' "$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo nogit)" \
    "$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
}

# --- shared runs: a branch of the team repo, one directory per run
shared_dir() { printf '%s/%s/shared\n' "$(local_repo_root)" "$STATE"; }
shared_ready() { # make .isukit/shared a worktree of the runs branch, up to date; false if there is no remote
  local root d
  root=$(local_repo_root); d=$(shared_dir)
  git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || return 1
  git -C "$root" remote get-url origin >/dev/null 2>&1 || return 1
  if [ ! -e "$d/.git" ]; then
    git -C "$root" fetch -q origin "$SHARED_RUNS_BRANCH" 2>/dev/null || true
    if git -C "$root" rev-parse -q --verify "origin/$SHARED_RUNS_BRANCH" >/dev/null 2>&1; then
      git -C "$root" worktree add -q -B "$SHARED_RUNS_BRANCH" "$d" "origin/$SHARED_RUNS_BRANCH" >/dev/null 2>&1 || return 1
    else
      git -C "$root" worktree add -q --detach "$d" >/dev/null 2>&1 || return 1
      git -C "$d" checkout -q --orphan "$SHARED_RUNS_BRANCH" && git -C "$d" rm -rqf . >/dev/null 2>&1
      git -C "$d" clean -fdq >/dev/null 2>&1
      printf '# isukit runs\n\nOne directory per `isukit bench`, published by whoever ran it.\n' > "$d/README.md"
      git -C "$d" add README.md && git -C "$d" commit -q -m "isukit runs" || return 1
    fi
  else
    git -C "$d" pull -q --rebase origin "$SHARED_RUNS_BRANCH" >/dev/null 2>&1 || true
  fi
}
runs_publish() { # runs_publish <run-dir> -- copy the run into the shared branch and push it
  local run="$1" d name f
  shared_ready || { warn "runs are not shared (no origin remote) — only this laptop has $run"; return 0; }
  d=$(shared_dir)
  name="$(basename "$run")-$(who_am_i)"
  mkdir -p "$d/runs/$name"
  for f in meta hosts.txt alp.txt "$run"/slow-*.txt cpu.pprof; do
    f="$run/$(basename "$f")"
    [ -f "$f" ] || continue
    case "$f" in *.pprof) [ "$(wc -c < "$f")" -lt 2000000 ] || continue ;; esac
    cp "$f" "$d/runs/$name/"
  done
  [ -f "$run/bench.log" ] && tail -200 "$run/bench.log" > "$d/runs/$name/bench.log"
  git -C "$d" add "runs/$name" && git -C "$d" commit -q -m "run $name: $(sed -n 's/^score=//p' "$run/meta" 2>/dev/null)" || return 0
  # one directory per run: a rebase onto someone else's run never conflicts
  for _ in 1 2 3; do
    git -C "$d" push -q origin "$SHARED_RUNS_BRANCH" >/dev/null 2>&1 && { say "run shared: $SHARED_RUNS_BRANCH/runs/$name"; return 0; }
    git -C "$d" pull -q --rebase origin "$SHARED_RUNS_BRANCH" >/dev/null 2>&1 || true
  done
  warn "could not push $SHARED_RUNS_BRANCH — the run is committed in $d; push it later: git -C $d push origin $SHARED_RUNS_BRANCH"
}

# runs_view -- every known run, oldest first: when \t sha \t score \t note \t dir \t branch \t who
# The shared branch when there is one (everyone's runs); else this laptop's run
# dirs; else, for a kit older than runs/, this laptop's scores.tsv.
runs_view() {
  local d dir
  d=$(shared_dir)
  if [ -d "$d/runs" ] && [ -n "$(ls -A "$d/runs" 2>/dev/null)" ]; then
    for dir in "$d"/runs/*/; do run_line "${dir%/}"; done | LC_ALL=C sort
  elif [ -d "$RUNS" ] && [ -n "$(ls -A "$RUNS" 2>/dev/null)" ]; then
    for dir in "$RUNS"/*/; do run_line "${dir%/}"; done | LC_ALL=C sort
  elif [ -f "$STATE/scores.tsv" ]; then
    cat "$STATE/scores.tsv"
  fi
}
run_line() { # run_line <run-dir> -- one runs_view line from its meta (or just its name)
  if [ -f "$1/meta" ]; then
    awk -v dir="$1" -F= '
      { k = $1; sub(/^[^=]*=/, ""); v[k] = $0 }
      END { printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", v["when"], v["sha"], v["score"], v["note"], dir, v["branch"], v["who"] }' "$1/meta"
  else
    printf '%s\t\t\t\t%s\t\t\n' "$(basename "$1")" "$1"
  fi
}
