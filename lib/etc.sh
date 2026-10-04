# shellcheck shell=bash
# isukit lib/etc.sh — `isukit etc`: nginx / mysql / unit config under git via /etc symlinks.
# Sourced by ../isukit; not meant to run on its own.

etc_repo() { # the server-side dir whose etc/ holds the linked configs
  if [ -n "${ETC_REPO:-}" ]; then printf '%s\n' "$ETC_REPO"; return 0; fi
  [ -n "${SRC_DIR:-}" ] || die "don't know where the app repo lives on $APP — run: isukit probe, or set ETC_REPO=<dir> in $CONF"
  local top
  top=$(rsh "$APP" "git -C '$SRC_DIR' rev-parse --show-toplevel 2>/dev/null" 2>/dev/null || true)
  printf '%s\n' "${top:-$SRC_DIR}"
}

etc_managed() { # etc_managed <repo> -- true if /etc on $APP already links into <repo>/etc
  [ -n "$(rsh "$APP" "find /etc/nginx /etc/mysql /etc/systemd/system -maxdepth 3 -type l -lname '$1/etc/*' 2>/dev/null | head -1" 2>/dev/null)" ]
}

etc_rsync() { # etc_rsync <src> <dst> [rsync opts...] -- one side is $APP:..., the other local
  local src="$1" dst="$2" rp="--rsync-path=sudo -n rsync"
  shift 2
  # -c: compare content, not size+mtime. A same-size edit (1000 -> 2000) within
  # the second of the last sync looks unchanged to rsync's quick check, and the
  # push silently copies nothing. The files are small; checksums are cheap.
  if [ "$APP" = "local" ]; then
    sudo -n rsync -rltc "$@" "${src#local:}" "${dst#local:}"
  else
    rsync -rltc "$@" "$rp" -e "ssh ${SSH_OPTS:-}" "$src" "$dst"
  fi
}

cmd_etc() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    adopt)  cmd_etc_adopt "$@" ;;
    status) cmd_etc_status ;;
    push)   cmd_etc_push "$@" ;;
    pull)   cmd_etc_pull ;;
    *) die "usage: isukit etc {adopt [/etc/path...]|status|push|pull}" ;;
  esac
}

# Per-host steps below run under on_hosts; whatever must happen once for the
# whole fleet afterwards (re-apply logging, restart the app) is left as a flag.
ETC_FLAGS="$STATE/.etc-flags"
etc_flag()       { mkdir -p "$ETC_FLAGS"; : > "$ETC_FLAGS/$1"; }

etc_flag_set()   { [ -f "$ETC_FLAGS/$1" ]; }

etc_flags_reset() { rm -rf "$ETC_FLAGS"; }

cmd_etc_adopt() {
  load
  local rc=0
  etc_flags_reset
  on_hosts all etc_adopt_one "$@" || rc=1
  # restarting mysqld drops the SET GLOBAL slow-log settings; put them back.
  if etc_flag_set relog; then
    say "measurement logging was on — re-applying it"
    cmd_logs on || warn "could not re-apply logging — run: isukit logs on"
  fi
  etc_flags_reset
  [ "$rc" = 0 ] || warn "some files were not adopted (see above) — the rest are linked"
  cmd_etc_pull || warn "adopt is done, but etc/ was not pulled down from $APP — resolve the files above, then: isukit etc pull"
  [ "${ISUKIT_QUIET_NEXT:-0}" = 1 ] || say "next: review $(local_repo_root)/etc/, then: isukit ship \"etc: put middleware config under git\""
  return "$rc"
}

etc_adopt_one() {
  local repo targets="$*" rc=0
  repo=$(etc_repo)
  logs_are_on && etc_flag relog
  say "etc adopt on $APP: /etc -> $repo/etc/ (symlinks; replaced files backed up under /etc/isukit-orig/)"
  { printf 'REPO=%q\nAPP_UNIT=%q\nTARGETS=%q\n' "$repo" "${APP_UNIT:-}" "$targets"; remote_script etc-adopt.sh; } \
    | rsh_stdin "$APP" || rc=$?
  return "$rc"
}

cmd_etc_status() { load; on_hosts all etc_status_one; }

etc_status_one() {
  local repo
  repo=$(etc_repo)
  { printf 'REPO=%q\n' "$repo"; remote_script etc-status.sh; } | rsh_stdin "$APP"
}

etc_sums() { # etc_sums <local|remote> <repo-dir> -- see remote/etc-sums.sh
  if [ "$1" = local ]; then
    { printf 'DIR=%q\nSUDO=\n' "$2"; remote_script etc-sums.sh; } | bash -s
  else
    { printf 'DIR=%q\n' "$2"; remote_script etc-sums.sh; } | rsh_stdin "$APP"
  fi
}

etc_unsaved_overwrites() { # etc_unsaved_overwrites <lsum> <rsum> <root> -- files a pull would clobber for good
  local f st
  for f in $(LC_ALL=C join -j 3 -o 1.1,2.1,0 <(printf '%s\n' "$1" | LC_ALL=C sort -k3) <(printf '%s\n' "$2" | LC_ALL=C sort -k3) \
               | awk '$1 != $2 { sub(/^\.\//, "", $3); print $3 }'); do
    # differs from the server: fine only if git can give the local version back
    if ! git -C "$3" rev-parse --git-dir >/dev/null 2>&1; then
      printf '%s\n' "$f"; continue
    fi
    st=$(git -C "$3" status --porcelain -- "etc/$f" 2>/dev/null)
    [ -z "$st" ] || printf '%s\n' "$f"
  done
}

etc_conflicts() { # etc_conflicts <dir-of-<host>.sums> -- "<path> <host>=<crc> ..." for files the hosts disagree on
  awk '
    { sub(/^\.\//, "", $3); h = FILENAME; sub(/.*\//, "", h); sub(/\.sums$/, "", h)
      if (!($3 in first)) first[$3] = $1; else if (first[$3] != $1) bad[$3] = 1
      seen[$3] = seen[$3] " " h "=" $1 }
    END { for (p in bad) print p seen[p] }' "$1"/*.sums 2>/dev/null | LC_ALL=C sort
}

cmd_etc_pull() { # every host's repo etc/ -> local repo etc/, minus isukit's own logging edits
  load
  local root f h lost conflicts tmp excl=()
  root=$(local_repo_root)
  tmp=$(mktemp -d)
  for h in $(hosts_all); do
    # shellcheck disable=SC2034  # HOST_OVERRIDE is read by load() in lib/core.sh
    ( HOST_OVERRIDE="$h"; load; etc_sums remote "$(etc_repo)" ) > "$tmp/$h.sums" 2>/dev/null || : > "$tmp/$h.sums"
  done
  # etc/ is one tree for the fleet. If two hosts hold different versions of a
  # file (a tuned mysqld.cnf adopted on the db host, the stock one elsewhere),
  # neither may win silently: the next push would overwrite the other host's
  # live config with it. Leave those out and say so.
  conflicts=$(etc_conflicts "$tmp")
  for f in $(printf '%s\n' "$conflicts" | awk 'NF{print $1}'); do excl+=("--exclude=/$f"); done
  # never overwrite a local edit git could not give back (untracked counts:
  # right after adopt every pulled file is untracked until it is shipped)
  lost=$(for h in $(hosts_all); do
           etc_unsaved_overwrites "$(etc_sums local "$root")" "$(cat "$tmp/$h.sums")" "$root"
         done | LC_ALL=C sort -u | grep -vxF -f <(printf '%s\n' "$conflicts" | awk 'NF{print $1}') || true)
  if [ -n "$lost" ]; then
    rm -rf "$tmp"
    warn "etc pull: not pulling — these local files differ from the hosts and are not committed:"
    printf '    etc/%s\n' $lost >&2
    warn "push them first (isukit etc push), or commit / discard them, then pull again"
    return 1
  fi
  mkdir -p "$root/etc"
  for h in $(hosts_all); do
    [ -s "$tmp/$h.sums" ] || continue
    # shellcheck disable=SC2034  # HOST_OVERRIDE is read by load() in lib/core.sh
    ( HOST_OVERRIDE="$h"; load
      repo=$(etc_repo)
      say "etc pull: $APP:$repo/etc/ -> $root/etc/"
      etc_rsync "$APP:$repo/etc/" "$root/etc/" ${excl+"${excl[@]}"} ) || { rm -rf "$tmp"; die "rsync from $h failed"; }
  done
  rm -rf "$tmp"
  # 'logs on' comments out access_log through the links, i.e. in the server's
  # repo copy. That is measurement state, not tuning — keep it out of git.
  for f in $(grep -RlsE "#isukit# |# isukit-include$" "$root/etc" || true); do
    sed -i.isukit-tmp -e "s|#isukit# access_log|access_log|" -e "/# isukit-include$/d" "$f" && rm -f "$f.isukit-tmp"
  done
  git -C "$root" status --short -- etc 2>/dev/null || true
  if [ -n "$conflicts" ]; then
    warn "etc pull: hosts disagree on these files — not pulled (checksums per host):"
    printf '%s\n' "$conflicts" | sed 's/^/    etc\//' >&2
    warn "pick the right version (ssh <host> cat <repo>/etc/<file>), put it in local etc/, then: isukit etc push"
    return 1
  fi
}

cmd_etc_push() { # local repo etc/ -> every host's repo etc/ (i.e. live /etc), then reload what changed
  load
  local from_deploy=0 rc=0
  [ "${1:-}" = "--from-deploy" ] && from_deploy=1
  etc_flags_reset
  on_hosts all etc_push_one "$from_deploy" || rc=1
  if etc_flag_set relog; then
    cmd_logs on || warn "could not re-apply logging — run: isukit logs on"
  elif etc_flag_set app-unit && [ "$from_deploy" = 0 ]; then
    # (logs on already restarts the app) — deploy restarts it right after this
    say "app unit changed — restarting the app"
    cmd_restart || rc=1
  fi
  etc_flags_reset
  return "$rc"
}

etc_push_one() { # etc_push_one <from_deploy 0|1> -- push to $APP
  local from_deploy="$1"
  local repo root changed was_on=0 rc=0
  repo=$(etc_repo)
  root=$(local_repo_root)
  [ -d "$root/etc" ] || die "no $root/etc — nothing to push (start with: isukit etc adopt)"
  # deploy only feeds hosts that already read their config from the repo
  if [ "$from_deploy" = 1 ] && ! etc_managed "$repo"; then
    say "etc push: $APP does not link /etc into $repo/etc yet — skipped (isukit etc adopt)"
    return 0
  fi
  # diff by checksum before copying (logging markers ignored on both sides): the
  # changed paths decide what is copied and what gets reloaded.
  changed=$(LC_ALL=C comm -23 <(etc_sums local "$root" | LC_ALL=C sort) <(etc_sums remote "$repo" | LC_ALL=C sort) \
    | awk 'NF{print $3}' | sed 's|^\./||')
  if [ -z "$changed" ]; then
    say "etc push: $APP:$repo/etc/ already matches — nothing to reload"
    return 0
  fi
  logs_are_on && was_on=1
  say "etc push: $root/etc/ -> $APP:$repo/etc/"
  printf '    %s\n' $changed >&2
  # only the changed files: an untouched server copy keeps its logging edits
  local list
  list=$(mktemp)
  printf '%s\n' $changed > "$list"
  etc_rsync "$root/etc/" "$APP:$repo/etc/" "--files-from=$list" || { rm -f "$list"; die "rsync to $APP failed"; }
  rm -f "$list"
  rsh "$APP" "sudo -n chown -R \"\$(stat -c %U '$repo')\" '$repo/etc'" 2>/dev/null || true

  local restart_db=0 reload_nginx=0 units=""
  printf '%s\n' $changed | grep -q '^nginx/' && reload_nginx=1
  printf '%s\n' $changed | grep -q '^mysql/' && restart_db=1
  units=$(printf '%s\n' $changed | sed -n 's|^systemd/system/||p' | tr '\n' ' ')

  if [ "$reload_nginx" = 1 ]; then
    rsh "$APP" "sudo -n nginx -t && sudo -n systemctl reload nginx" \
      || { warn "nginx -t FAILED — the broken file is live on disk but nginx still runs the old config; fix it and push again"; rc=1; }
  fi
  if [ -n "$units" ]; then
    rsh "$APP" "sudo -n systemctl daemon-reload" && say "systemd: daemon-reload ($units)"
    local u
    for u in $units; do
      if [ "$u" = "${APP_UNIT:-}" ]; then
        # restarted once for the fleet after every host is pushed
        etc_flag app-unit
        continue
      fi
      warn "unit $u changed — restart it when ready: ssh $APP sudo systemctl restart $u"
    done
  fi
  if [ "$restart_db" = 1 ]; then
    say "mysql config changed — restarting the DB (brief downtime)"
    rsh "$APP" "for s in mysql mariadb; do systemctl is-active --quiet \$s && { sudo -n systemctl restart \$s; break; }; done; sudo -n mysql -e 'SELECT 1' >/dev/null" \
      || { warn "mysql did not come back — check: ssh $APP sudo journalctl -u mysql -n 50"; rc=1; }
  fi
  # a pushed nginx file replaced the copy 'logs on' had edited, and a DB restart
  # drops SET GLOBAL — either way logging has to be put back (once, afterwards).
  if [ "$was_on" = 1 ] && { [ "$reload_nginx" = 1 ] || [ "$restart_db" = 1 ]; }; then
    etc_flag relog
  fi
  # a file new to the repo is copied up but nothing reads it until it is linked.
  etc_status_one | grep -vE '^linked ' >&2 || true
  return "$rc"
}
