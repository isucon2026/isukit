# shellcheck shell=bash
# isukit lib/env.sh — `isukit env`: each host's env file (DB_HOST and friends) under git.
# Sourced by ../isukit; not meant to run on its own.

# The env file is where a box learns where its DB is — and it differs per
# box (app hosts point at the db host), so it is not linked like etc/. Each
# host's copy lives in the repo as hosts/<host>/<file> (go --new records them)
# and that copy is the truth: edit it, commit it, `isukit env push` (or
# deploy) writes it to the host. The change is a diff the team sees and can
# revert, instead of an ssh edit nobody else knows about.

env_file_of() { host_fact "$1" ENV_FILE; }   # where that host's app reads it
env_local() { # env_local <host> -- the repo copy for that host, "" if the host has no env file
  local ef
  ef=$(env_file_of "$1")
  [ -n "$ef" ] || return 0
  printf '%s/hosts/%s/%s\n' "$(local_repo_root)" "$(printf '%s' "$1" | tr '/' '_')" "$(basename "$ef")"
}
env_remote_sum() { rsh "$1" "sudo -n cksum < '$2' 2>/dev/null" 2>/dev/null | awk '{print $1, $2}'; }
env_local_sum()  { cksum < "$1" | awk '{print $1, $2}'; }

cmd_env() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    status) cmd_env_status ;;
    pull)   cmd_env_pull ;;
    push)   cmd_env_push "$@" ;;
    *) die "usage: isukit env {status|pull|push}" ;;
  esac
}

cmd_env_status() {
  load
  local h ef lf state
  for h in $(hosts_all); do
    ef=$(env_file_of "$h"); lf=$(env_local "$h")
    if [ -z "$ef" ]; then state="no env file (probe found none)"
    elif [ ! -f "$lf" ]; then state="not in the repo — isukit env pull"
    elif [ "$(env_local_sum "$lf")" = "$(env_remote_sum "$h" "$ef")" ]; then state="same"
    else state="DIFFERS — isukit env push (repo -> host) or env pull (host -> repo)"
    fi
    printf '  %-28s %-28s %s\n' "$h" "${ef:--}" "$state"
  done
}

cmd_env_pull() { # every host's env file -> hosts/<host>/, never over an unsaved local edit
  load
  local h ef lf root st tmp
  root=$(local_repo_root)
  for h in $(hosts_all); do
    ef=$(env_file_of "$h"); lf=$(env_local "$h")
    [ -n "$ef" ] || continue
    tmp=$(mktemp)
    if ! rsh "$h" "sudo -n cat '$ef'" > "$tmp" 2>/dev/null; then
      rm -f "$tmp"; warn "could not read $ef on $h"; continue
    fi
    if [ -f "$lf" ] && ! cmp -s "$tmp" "$lf"; then
      st=$(git -C "$root" status --porcelain -- "${lf#"$root"/}" 2>/dev/null)
      if ! git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || [ -n "$st" ]; then
        rm -f "$tmp"; warn "$h: ${lf#"$root"/} has edits not committed and not pushed — push them (isukit env push) or commit / discard them first"; continue
      fi
    fi
    mkdir -p "$(dirname "$lf")" && mv "$tmp" "$lf" && say "$h: $ef -> ${lf#"$root"/}"
  done
}

cmd_env_push() { # hosts/<host>/<file> -> each host; restart the app where it changed
  load
  lock_guard "env push"
  local from_deploy=0 h ef lf changed_app=0 rc=0
  [ "${1:-}" = "--from-deploy" ] && from_deploy=1
  for h in $(hosts_all); do
    ef=$(env_file_of "$h"); lf=$(env_local "$h")
    [ -n "$ef" ] && [ -f "$lf" ] || continue
    [ "$(env_local_sum "$lf")" = "$(env_remote_sum "$h" "$ef")" ] && continue
    # tee into the existing file keeps its owner and mode (the app user reads it)
    if rsh "$h" "sudo -n tee '$ef' >/dev/null" < "$lf"; then
      say "env: ${lf#"$(local_repo_root)"/} -> $h:$ef"
      case ",$(host_roles "$h")," in *,app,*) changed_app=1 ;; esac
    else
      warn "env: could not write $ef on $h"; rc=1
    fi
  done
  # the app reads its env at start: restart once, unless deploy does it right after
  if [ "$changed_app" = 1 ] && [ "$from_deploy" = 0 ]; then
    say "env changed on an app host — restarting the app"
    cmd_restart || rc=1
  fi
  return "$rc"
}
