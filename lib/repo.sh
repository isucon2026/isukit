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
  git switch -q -c work
  say "repo ready: $(git remote get-url origin)  (baseline on main, you are on work)"
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
  ( cd "$dir" && go build ./... && go vet ./... ) \
    || die "the app does not build — fix it before shipping (isukit ship --no-check to ship anyway)"
}

cmd_ship() {
  local check=1
  [ "${1:-}" = "--no-check" ] && { check=0; shift; }
  local msg="${1:-}"
  [ -n "$msg" ] || die "usage: isukit ship [--no-check] \"<message>\""
  git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repo"
  [ -n "$(git status --porcelain 2>/dev/null)" ] || die "nothing to ship — working tree is clean"
  [ "$check" = 0 ] || ship_build_check

  local slug branch n=1
  slug=$(slugify "$msg")
  [ -n "$slug" ] || slug="change"
  branch="isukit/$slug"
  while git show-ref --verify --quiet "refs/heads/$branch"; do
    n=$((n+1))
    branch="isukit/$slug-$n"
  done

  git switch -c "$branch" || die "could not create branch $branch"
  git add -A
  git commit -m "$msg" || die "commit failed"
  local sha
  sha=$(git rev-parse --short HEAD)

  if git push -u origin "$branch"; then
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
