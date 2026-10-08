# shellcheck shell=bash
# isukit lib/repo.sh — `isukit init`, the T+0 team repo (`go --new`), `ship`, `revert`.
# Sourced by ../isukit; not meant to run on its own.

norm_git_url() { # norm_git_url <url> -- drop trailing slash/.git so equivalent URLs compare equal
  local u="$1"
  u="${u%/}"
  u="${u%.git}"
  printf '%s' "$u"
}

cmd_init() {
  local url="${1:-}"; [ -n "$url" ] || die "usage: isukit init <repo-url> [dir]"
  local dir="${2:-$(basename "$url" .git)}"
  if [ -d "$dir" ]; then
    # re-run safety: reuse a matching clone, refuse to touch anything else.
    if git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
      local origin
      origin=$(git -C "$dir" remote get-url origin 2>/dev/null || true)
      if [ -z "$origin" ]; then
        die "'$dir' exists and is a git repo but has no 'origin' remote (looks like a partial/failed clone) — inspect or move it aside by hand, then retry"
      elif [ "$(norm_git_url "$origin")" = "$(norm_git_url "$url")" ]; then
        say "reusing existing repo at '$dir' (origin already matches $url)"
        git -C "$dir" fetch --quiet 2>/dev/null || warn "fetch failed (offline?) — continuing with the existing local state"
      else
        die "'$dir' already exists as a git repo with a different origin ('$origin', requested '$url') — pick a different directory or resolve it by hand"
      fi
    else
      die "'$dir' already exists and is not a git repo — pick a different directory or resolve it by hand"
    fi
  else
    git clone "$url" "$dir"
  fi
  cd "$dir" || die "cannot enter $dir"
  mkdir -p "$STATE"
  git rev-parse --verify work >/dev/null 2>&1 || git switch -c work >/dev/null 2>&1 || true
  init_state
}

init_state() { # .isukit/{config,.gitignore,notes.md} in the current dir; an existing config is kept
  mkdir -p "$STATE"
  # isukit-score notes (attached by bench) ride rebase/amend and show in plain git log
  git config notes.rewriteRef refs/notes/isukit
  git config notes.displayRef refs/notes/isukit
  if [ -f "$CONF" ]; then
    local kept
    kept=$( . "$CONF" 2>/dev/null; printf 'APP=%s BENCH=%s BENCH_CMD=%s' "${APP:-local}" "${BENCH:-local}" "${BENCH_CMD:+<already set, kept>}" )
    say "existing $CONF kept as-is ($kept)"
  else
    cat > "$CONF" <<EOF
# isukit config — edit APP/BENCH after 'isukit host', BENCH_CMD after 'isukit probe'
APP=local          # ssh target of the app server (the one you tune), or 'local'
BENCH=local        # ssh target of the bench server (the one that scores you)
# auto = run BENCH_CMD over ssh on \$BENCH; manual = a human enqueues a run in the
# contest portal and pastes the score back (contest day: no bench binary, no ssh
# to the bench host allowed). 'isukit benchprobe' flips this to manual on its own
# when it can't find a bench binary. Toggle by hand: isukit benchmode [auto|manual]
BENCH_MODE=auto
# Run verbatim on \$BENCH. Auto-composed by 'isukit probe' (see 'isukit benchprobe')
# from the benchmarker binary's own --help output — verify it, the flag names
# differ every year. Set/override by hand with: isukit benchcmd '<command>'
BENCH_CMD=''
SSH_OPTS=''        # extra ssh/scp flags, e.g. '-F ./ssh_config' or '-i ~/key.pem -p 2222'
EXTRA_UNITS=''     # space-separated extra units 'restart'/'finalize' also restart
EXTRA_HOSTS=''     # space-separated extra ssh targets — other app instances;
                   # 'restart'/'finalize' hit these too. add with: isukit host add <target>
ETC_REPO=''        # server dir whose etc/ holds the /etc symlink targets ('isukit etc');
                   # empty = git root of the probed SRC_DIR, else SRC_DIR
EOF
  fi
  cat > "$STATE/.gitignore" <<'EOF'
*
EOF
  if [ ! -f "$STATE/notes.md" ]; then
    cat > "$STATE/notes.md" <<'EOF'
## Manual facts
- score formula:
- /initialize path + time limit + required response fields:
- fail conditions:
- restart verification:
- explicitly forbidden:
EOF
  fi
  say "initialised in $(pwd)"
  say "next: isukit host app <ssh-target>   (and bench)   then: isukit probe"
  grep -rilE 'bench|benchmark' README* docs/ 2>/dev/null | head -5 | sed 's/^/    read: /' >&2 || true
}

# `isukit go --new owner/repo ...`: at T+0 the code exists only on the servers.
# Pull the probed webapp to the laptop, commit it as the code baseline and push
# it as a private repo (GitHub credentials stay on the laptop; nothing is
# pushed from the servers). Then put the middleware config under git the same
# way `etc adopt` does, plus a copy of each host's env file, as a second
# baseline commit — so "before we touched the code" and "before we touched the
# config" are both one checkout away.
REPO_NEW_MAXSIZE_MB=10

repo_new_prepare() { # repo_new_prepare <owner/repo> -- local dir + .isukit, before any host is known
  local slug="$1" dir="${1##*/}"
  command -v gh >/dev/null 2>&1 || die "--new needs the GitHub CLI: install gh, then gh auth login"
  gh auth status >/dev/null 2>&1 || die "gh is not logged in: gh auth login"
  gh repo view "$slug" >/dev/null 2>&1 && die "$slug already exists on GitHub — use it instead: isukit go <its clone url> ..."
  [ -e "$dir" ] && die "'$dir' already exists here — --new builds a fresh repo; cd elsewhere or remove it"
  mkdir -p "$dir" && cd "$dir" || die "cannot create $dir"
  git init -q && git symbolic-ref HEAD refs/heads/main
  init_state
  say "new repo $slug: will be built from the server in $(pwd)"
}

repo_new_baseline() { # repo_new_baseline <owner/repo> <invite,list>
  load
  local slug="$1" invite="$2" big bin u
  [ -n "${SRC_DIR:-}" ] || die "probe found no webapp dir on $APP — build the repo by hand (RUNBOOK §3)"
  # files too big for git stay on the server; deploy never deletes them there
  big=$(rsh "$APP" "sudo -n find '$SRC_DIR' -type f -size +${REPO_NEW_MAXSIZE_MB}M -not -path '$SRC_DIR/.git/*' 2>/dev/null" | sed "s|^$SRC_DIR/||" || true)
  bin=""
  [ -n "${APP_EXEC:-}" ] && [ "${APP_EXEC#"$SRC_DIR"/}" != "$APP_EXEC" ] && bin="${APP_EXEC#"$SRC_DIR"/}"
  local -a ex=(--exclude=.git --exclude=node_modules --exclude='*.log' --exclude=__pycache__ --exclude=.venv --exclude=target)
  [ -n "$bin" ] && big=$(printf '%s\n' $big | grep -vxF "$bin" || true)   # listed once, as the built app
  for u in $big $bin; do ex+=("--exclude=/$u"); done
  say "code baseline: $APP:$SRC_DIR/ -> $(pwd)/"
  if [ "$APP" = "local" ]; then
    sudo -n rsync -rlpt "${ex[@]}" "$SRC_DIR/" ./ || die "copying $SRC_DIR failed"
    sudo -n chown -R "$(id -u):$(id -g)" . 2>/dev/null || true
  else
    rules_allow_host "$APP"
    rsync -rlpt "${ex[@]}" --rsync-path="sudo -n rsync" -e "ssh ${SSH_OPTS:-}" "$APP:$SRC_DIR/" ./ \
      || die "copying $APP:$SRC_DIR failed"
  fi
  {
    printf '\n# --- isukit go --new\n'
    printf '%s\n' '**/node_modules/' '*.log' '**/__pycache__/' '**/.venv/' '**/target/'
    [ -n "$bin" ] && printf '# the built app (systemd runs it; deploy rebuilds it)\n/%s\n' "$bin"
    if [ -n "$big" ]; then
      printf '# over %sMB on %s — left on the server, not in git\n' "$REPO_NEW_MAXSIZE_MB" "$APP"
      printf '/%s\n' $big
    fi
  } >> .gitignore
  [ -z "$big" ] || warn "left on the server (over ${REPO_NEW_MAXSIZE_MB}MB, listed in .gitignore): $(printf '%s ' $big)"
  git add -A
  git commit -q -m "baseline: $APP:$SRC_DIR before any change" || die "nothing to commit — is $SRC_DIR empty?"
  say "creating private repo $slug"
  gh repo create "$slug" --private --source . --remote origin --push >/dev/null \
    || die "gh repo create failed — the baseline is committed here; create the repo and push by hand"
  for u in $(printf '%s' "$invite" | tr , ' '); do
    gh api -X PUT "repos/$slug/collaborators/$u" -f permission=push >/dev/null 2>&1 \
      && say "invited $u (push)" || warn "could not invite $u — do it by hand: gh api -X PUT repos/$slug/collaborators/$u -f permission=push"
  done

  # this repo's root IS the server's webapp dir: pin it, so etc/ never lands in
  # some git root above it on the server (a /home/isucon/.git would otherwise win)
  if grep -q '^ETC_REPO=' "$CONF"; then
    sed -i.bak "s|^ETC_REPO=.*|ETC_REPO='$SRC_DIR'|" "$CONF" && rm -f "$CONF.bak"
  else
    printf "ETC_REPO='%s'\n" "$SRC_DIR" >> "$CONF"
  fi
  load
  say "config baseline: /etc -> repo etc/ (symlinks), env files -> hosts/<host>/"
  ISUKIT_QUIET_NEXT=1 cmd_etc_adopt || warn "etc adopt reported problems (above) — the rest of the baseline goes on"
  repo_record_env
  git add -A
  if git commit -q -m "etc: middleware config and env as handed out, before any change"; then
    git push -q origin main || warn "push of the config baseline failed — push by hand: git push origin main"
  fi
  # a third commit, so both baselines stay exactly as handed out
  if repo_new_ci; then
    git add .github && git commit -q -m "ci: build the Go app on every push to main and every PR" \
      && { git push -q origin main || warn "push of the CI workflow failed — push by hand: git push origin main"; }
  fi
  github_discord_hook "$slug"
  git switch -q -c work
  say "repo ready: $(git remote get-url origin)  (baseline on main, you are on work)"
}

repo_new_ci() { # .github/workflows/isukit-ci.yml: does main still build? (true if written)
  local rel
  [ -n "${GO_DIR:-}" ] && [ "${GO_DIR#"$SRC_DIR"/}" != "$GO_DIR" ] || { warn "no Go module inside $SRC_DIR — no CI workflow written"; return 1; }
  rel="${GO_DIR#"$SRC_DIR"/}"
  mkdir -p .github/workflows
  cat > .github/workflows/isukit-ci.yml <<YML
# written by isukit go --new: a merge that breaks the build shows up here (and
# in #git), not as a failed deploy. vet is reported, never blocking — the code
# as handed out may not pass it.
name: ci
on:
  push:
    branches: [main]
  pull_request:
jobs:
  build:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: $rel
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version-file: $rel/go.mod
      - run: go build ./...
      - run: go vet ./...
        continue-on-error: true
YML
  say "CI: .github/workflows/isukit-ci.yml (go build in $rel; vet reported, not blocking)"
}

# github_discord_hook [owner/repo] -- GitHub posts PRs, pushes and CI results
# to #git through Discord's GitHub-compatible endpoint (<webhook>/github).
github_discord_hook() {
  local slug="${1:-}" url="${DISCORD_WEBHOOK_GIT:-}"
  [ -n "$url" ] || return 0
  command -v gh >/dev/null 2>&1 || { warn "no gh — add the #git webhook by hand: repo Settings > Webhooks > $url/github"; return 0; }
  [ -n "$slug" ] || slug=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)
  [ -n "$slug" ] || { warn "cannot tell which GitHub repo this is"; return 0; }
  if gh api "repos/$slug/hooks" -f name=web -f "config[url]=${url%/}/github" -f "config[content_type]=json" \
       -F active=true -f "events[]=push" -f "events[]=pull_request" -f "events[]=check_suite" >/dev/null 2>&1; then
    say "#git: GitHub posts pushes, PRs and CI results for $slug to Discord"
  else
    warn "could not add the #git webhook to $slug (admin rights?) — by hand: repo Settings > Webhooks > ${url%/}/github"
  fi
}

cmd_notify() { # notify github -- (re)wire #git for this repo
  load
  case "${1:-}" in
    github) [ -n "${DISCORD_WEBHOOK_GIT:-}" ] || die "set DISCORD_WEBHOOK_GIT in $CONF first"; github_discord_hook ;;
    *) die "usage: isukit notify github" ;;
  esac
}

repo_record_env() { # hosts/<host>/<envfile>: a per-host record, not linked — env differs per host
  local h
  for h in $(hosts_all); do
    # shellcheck disable=SC2034  # HOST_OVERRIDE is read by load() in lib/core.sh
    ( HOST_OVERRIDE="$h"; load
      [ -n "${ENV_FILE:-}" ] || exit 0
      mkdir -p "hosts/$h"
      rsh "$APP" "sudo -n cat '$ENV_FILE'" > "hosts/$h/$(basename "$ENV_FILE")" 2>/dev/null \
        || { rm -f "hosts/$h/$(basename "$ENV_FILE")"; warn "could not read $ENV_FILE on $h"; } )
  done
}

slugify() { # slugify <text> -- lowercase, non-alnum -> '-', squeeze/trim, cap 40 chars
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-40
}

ship_build_check() { # the Go app must build and vet here before it reaches a PR or the servers
  local mod dir
  command -v go >/dev/null 2>&1 || { warn "no go here — skipping the build check"; return 0; }
  mod=$(find . -maxdepth 4 -name go.mod -not -path "*/bench*" -not -path "*/vendor/*" -not -path "./.isukit/*" | head -1)
  [ -n "$mod" ] || return 0
  dir=$(dirname "$mod")
  say "build check: go build + go vet in $dir"
  ( cd "$dir" && go build ./... ) \
    || die "the app does not build — fix it before shipping (isukit ship --no-check to ship anyway)"
  # the code as handed out may not pass vet: report, never block
  ( cd "$dir" && go vet ./... ) || warn "go vet reports the above — worth a look, not blocking"
}

ship_preview() { # ship_preview [path...] -- show what ship is about to stage, before it happens
  say "ship preview (-- ${*:-everything changed}):"
  git status --short -- "$@" | sed 's/^/    /' >&2 || true
}

ship_size_gate() { # ship_size_gate [path...] -- refuse an oversized commit (lines=added+deleted across tracked+untracked)
  local files lines max_files max_lines
  files=$(git status --short -- "$@" | wc -l | tr -d ' ')
  lines=$(
    { git diff --numstat -- "$@"
      git diff --cached --numstat -- "$@"
      git ls-files --others --exclude-standard -- "$@" | while IFS= read -r f; do
        [ -f "$f" ] && printf '%s\t0\t%s\n' "$(wc -l < "$f" | tr -d ' ')" "$f"
      done
    } | awk '{a+=$1+$2} END{print a+0}'
  )
  max_files="${SHIP_MAX_FILES:-10}"
  max_lines="${SHIP_MAX_LINES:-300}"
  [ "$files" -le "$max_files" ] && [ "$lines" -le "$max_lines" ] && return 0
  rules_override ship-size "shipping $files files / $lines lines (limits: $max_files / $max_lines)" || \
    die "this commit is $files files / $lines lines — over SHIP_MAX_FILES=$max_files / SHIP_MAX_LINES=$max_lines.
    A commit this size cannot be cherry-picked or reverted cleanly.
    Split it, use --only <paths>, or set ISUKIT_OVERRIDE='<reason>'."
}

cmd_ship() {
  load   # SHIP_MAX_FILES/SHIP_MAX_LINES live in isukit.conf; this is how every other cmd_* reads it
  local check=1 measure=0
  local -a only=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --no-check) check=0; shift ;;
      --measure) measure=1; shift ;;
      --only)
        shift
        [ "$#" -ge 2 ] || die "usage: isukit ship [--no-check] [--measure] [--only <path>...] \"<message>\""
        while [ "$#" -gt 1 ]; do only+=("$1"); shift; done
        ;;
      *) break ;;
    esac
  done
  local msg="${1:-}"
  [ -n "$msg" ] || die "usage: isukit ship [--no-check] [--measure] [--only <path>...] \"<message>\""
  git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repo"
  [ -n "$(git status --porcelain 2>/dev/null)" ] || die "nothing to ship — working tree is clean"
  [ "$check" = 0 ] || ship_build_check

  ship_preview ${only+"${only[@]}"}
  ship_size_gate ${only+"${only[@]}"}

  local slug branch n=1
  slug=$(slugify "$msg")
  [ -n "$slug" ] || slug="change"
  branch="isukit/$slug"
  while git show-ref --verify --quiet "refs/heads/$branch"; do
    n=$((n+1))
    branch="isukit/$slug-$n"
  done

  git switch -c "$branch" || die "could not create branch $branch"
  if [ "${#only[@]}" -gt 0 ]; then
    git add -- "${only[@]}"
  else
    git add -A
  fi
  if [ "$measure" = 1 ]; then
    msg=$(git interpret-trailers --trailer 'Isukit-Measure: true' <<< "$msg")
  fi
  git commit -m "$msg" || die "commit failed"
  local sha
  sha=$(git rev-parse --short HEAD)

  rules_repo_private

  if git push -u origin "$branch"; then
    if git rev-parse -q --verify refs/notes/isukit >/dev/null 2>&1; then
      git push origin refs/notes/isukit 2>/dev/null || warn "push of score notes (refs/notes/isukit) failed — push by hand when ready: git push origin refs/notes/isukit"
    fi
    if git rev-parse -q --verify refs/notes/isukit-measure >/dev/null 2>&1; then
      git push origin refs/notes/isukit-measure 2>/dev/null || warn "push of measure notes (refs/notes/isukit-measure) failed — push by hand when ready: git push origin refs/notes/isukit-measure"
    fi
    if command -v gh >/dev/null 2>&1; then
      gh pr create --draft --fill || warn "gh pr create failed — push succeeded, open the PR by hand"
    fi
  else
    warn "push failed — committed locally on $branch ($sha) — push by hand when ready"
  fi

  say "shipped $sha on $branch — your turn on the servers: isukit lock, deploy, bench, attribute"
}

cmd_revert() {
  local sha="${1:-}"
  git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repo"

  if [ -z "$sha" ]; then
    local cur
    cur=$(git branch --show-current 2>/dev/null || true)
    case "$cur" in
      isukit/*) sha=$(git rev-parse --short HEAD) ;;
    esac
    if [ -z "$sha" ]; then
      local b
      for b in $(git for-each-ref --sort=-committerdate --format='%(refname:short)' 'refs/heads/isukit/*'); do
        if git merge-base --is-ancestor "$b" HEAD 2>/dev/null; then
          sha=$(git rev-parse --short "$b")
          break
        fi
      done
    fi
    [ -n "$sha" ] || die "no isukit/* branch reachable from HEAD — pass one by hand: isukit revert <sha>"
  fi

  say "reverting $sha"
  git revert --no-edit "$sha" || die "revert failed — resolve conflicts by hand, then: git revert --continue"
  say "reverted $sha — next: isukit deploy, then isukit bench"
}

cmd_pick() {
  local sha="${1:-}"
  [ -n "$sha" ] || die "usage: isukit pick <sha>"
  git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repo"

  if ! git cherry-pick "$sha"; then
    die "cherry-pick of $sha conflicts — resolve by hand, then: git cherry-pick --continue (or --abort)
conflicted paths:
$(git diff --name-only --diff-filter=U 2>/dev/null)"
  fi

  local new_sha note
  new_sha=$(git rev-parse --short HEAD)
  git notes --ref=isukit copy "$sha" HEAD 2>/dev/null
  note=$(git notes --ref=isukit show HEAD 2>/dev/null || true)
  say "picked $sha as $new_sha${note:+ — carried: $note}"
}

measure_commits() { # sha<TAB>date<TAB>subject<TAB>author of every live labelled commit on HEAD, newest first
  git rev-parse --git-dir >/dev/null 2>&1 || return 0

  local trailer_shas note_shas reverted_shas qualifying sha

  trailer_shas=$(git log --format='%H %(trailers:key=Isukit-Measure,valueonly)' HEAD 2>/dev/null \
    | awk '$2 == "true" { print $1 }')

  note_shas=""
  if git rev-parse -q --verify refs/notes/isukit-measure >/dev/null 2>&1; then
    while IFS=' ' read -r _ sha; do
      [ -n "$sha" ] || continue
      git merge-base --is-ancestor "$sha" HEAD 2>/dev/null && note_shas="$note_shas$sha
"
    done <<< "$(git notes --ref=isukit-measure list 2>/dev/null)"
  fi

  reverted_shas=$(git log --format='%B' HEAD 2>/dev/null \
    | grep -oE 'This reverts commit [0-9a-f]{40}' | awk '{print $4}')

  qualifying=$(printf '%s\n%s\n' "$trailer_shas" "$note_shas" | grep -v '^$' | sort -u)
  [ -n "$qualifying" ] || return 0

  # Walk HEAD's own history once — it is already newest-first, and unlike a
  # re-sort on %ct it never ties same-second commits in sha-hash order.
  git log --format='%H%x09%ad%x09%s%x09%an' --date=short HEAD 2>/dev/null | while IFS=$'\t' read -r sha date subject author; do
    [ -n "$sha" ] || continue
    grep -qxF "$sha" <<< "$qualifying" || continue
    grep -qxF "$sha" <<< "$reverted_shas" && continue
    printf '%s\t%s\t%s\t%s\n' "$sha" "$date" "$subject" "$author"
  done
}

cmd_measures() {
  git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repo"
  local rows
  rows=$(measure_commits)
  if [ -z "$rows" ]; then
    say "no measurement commits live in HEAD"
    return 0
  fi
  local sha date subject author
  while IFS=$'\t' read -r sha date subject author; do
    [ -n "$sha" ] || continue
    printf '%s  %s  %-40s  %s\n' "${sha:0:7}" "$date" "$subject" "$author"
  done <<< "$rows"
}

cmd_measure() { # isukit measure <sha> | isukit measure --undo <sha>
  git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repo"
  local undo=0
  case "${1:-}" in
    --undo) undo=1; shift ;;
  esac
  local arg="${1:-}" sha
  [ -n "$arg" ] || die "usage: isukit measure [--undo] <sha>"
  sha=$(git rev-parse --verify "$arg" 2>/dev/null) || die "no such commit: $arg"

  if [ "$undo" = 1 ]; then
    if git log --format='%(trailers:key=Isukit-Measure,valueonly)' -1 "$sha" 2>/dev/null | grep -qx 'true'; then
      die "$sha carries the Isukit-Measure trailer in its commit message — a trailer cannot be undone, only a note can; the message itself stays as history (no rewrite)."
    fi
    git notes --ref=isukit-measure remove "$sha" 2>/dev/null || die "no isukit-measure note on $sha to remove"
    say "removed the isukit-measure note on ${sha:0:7}"
    return 0
  fi

  git notes --ref=isukit-measure add -f -m 'true' "$sha" || die "could not add isukit-measure note on $sha"
  say "labelled ${sha:0:7} as a measurement commit — push it: git push origin refs/notes/isukit-measure"
}
