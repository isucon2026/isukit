# shellcheck shell=bash
# isukit lib/hosts.sh — host roles (.isukit/hosts), `isukit host` / `hosts`, and go's ssh_config.
# Sourced by ../isukit; not meant to run on its own.

# .isukit/hosts: "<ssh-target> <role,role...>" per line, # comments. Roles:
#   app  runs the webapp unit     -> deploy, restart, pprof
#   web  runs nginx               -> nginx logging, alp
#   db   runs mysql               -> slow log, slow
# Without the file, the pre-roles layout holds: $APP does all three and every
# EXTRA_HOSTS entry is an app instance. $APP stays the host probe reads.
HOSTS_FILE="$STATE/hosts"
KNOWN_ROLES="app web db"
host_lines() { # "<target> <roles>" per host
  local h
  if [ -f "$HOSTS_FILE" ]; then
    awk '!/^[[:space:]]*(#|$)/ { print $1, ($2 == "" ? "app" : $2) }' "$HOSTS_FILE"
  else
    printf '%s web,app,db\n' "${PRIMARY:-$APP}"
    for h in ${EXTRA_HOSTS:-}; do printf '%s app\n' "$h"; done
  fi
}

hosts_all()  { host_lines | awk '{ print $1 }'; }

host_roles() { host_lines | awk -v h="$1" '$1 == h { print $2 }'; }

hosts_with() { # hosts_with <role>[|<role>...] -- hosts holding any of them
  host_lines | awk -v want="$1" '{
    n = split($2, r, ","); m = split(want, w, "|")
    for (i = 1; i <= n; i++) for (j = 1; j <= m; j++) if (r[i] == w[j]) { print $1; next }
  }'
}

host_manifest() { printf '%s/manifest.%s\n' "$STATE" "$(printf '%s' "$1" | tr '/' '_')"; }

host_fact() { # host_fact <host> <KEY> -- that host's probed value; else the first any host reported
  # The fleet runs one web server and one datastore kind, but only the hosts that
  # still run them report them: after mysql is stopped on the probed host, its
  # own manifest says DB_SERVER=''. Never let that erase the db host's checks.
  local f v
  f=$(host_manifest "$1")
  if [ -f "$f" ]; then
    v=$( . "$f" 2>/dev/null; eval "printf '%s' \"\${$2:-}\"" )
    [ -n "$v" ] && { printf '%s\n' "$v"; return 0; }
  fi
  for f in "$STATE/manifest" "$STATE"/manifest.*; do
    [ -f "$f" ] || continue
    v=$( . "$f" 2>/dev/null; eval "printf '%s' \"\${$2:-}\"" )
    [ -n "$v" ] && { printf '%s\n' "$v"; return 0; }
  done
  return 0
}

role_units() { # units a host must be running, from its roles
  local r u=""
  for r in $(host_roles "$1" | tr , ' '); do
    case "$r" in
      app) u="$u ${APP_UNIT:-} ${EXTRA_UNITS:-}" ;;
      web) u="$u $(host_fact "$1" WEB_SERVER)" ;;
      db)  u="$u $(host_fact "$1" DB_SERVER)" ;;
    esac
  done
  printf '%s\n' $u | awk 'NF && !seen[$0]++' | tr '\n' ' ' | sed 's/ *$//'
}

on_hosts() { # on_hosts <role|all> <fn> [args...] -- run fn once per matching host, $APP pointed at it
  local sel="$1" fn="$2" hosts h n bad=""
  shift 2
  if [ "$sel" = all ]; then hosts=$(hosts_all); else hosts=$(hosts_with "$sel"); fi
  [ -n "$hosts" ] || die "no host has role '$sel' — set one: isukit host role <target> ${sel%%|*}"
  n=$(printf '%s\n' $hosts | wc -l | tr -d ' ')
  for h in $hosts; do
    [ "$n" -gt 1 ] && say "── $h ($(host_roles "$h"))"
    # subshell: die inside fn stops this host only, and $APP never leaks back
    # shellcheck disable=SC2034  # HOST_OVERRIDE is read by load() in lib/core.sh
    ( HOST_OVERRIDE="$h"; load; "$fn" "$@" ) || bad="$bad $h"
  done
  [ -z "$bad" ] || { warn "failed on:$bad"; return 1; }
}

cmd_host() {
  need_state
  local role="${1:-}" target="${2:-}" opts=""
  [ "$#" -gt 2 ] && { shift 2; opts="$*"; }
  # If go's per-host ssh_config is in play (SSH_OPTS carries -F) and the caller isn't
  # replacing it wholesale (no -F in the new opts), redirect app/bench -i/-p into that
  # ssh_config's Host block instead of clobbering the global SSH_OPTS. Skip when target
  # is already the isukit-app/isukit-bench alias (that's cmd_go writing it originally).
  local rewrite_ssh_config=0 orig_target="$target"
  if { [ "$role" = "app" ] || [ "$role" = "bench" ]; } \
     && [ "$target" != "isukit-$role" ] && [ -f "$STATE/ssh_config" ]; then
    case " $opts " in
      *" -F "*) : ;;
      *)
        local cur_ssh_opts
        cur_ssh_opts=$( . "$CONF" 2>/dev/null; printf '%s' "${SSH_OPTS:-}" )
        case " $cur_ssh_opts " in
          *" -F "*) rewrite_ssh_config=1 ;;
        esac
        ;;
    esac
  fi
  [ "$rewrite_ssh_config" = 1 ] && target="isukit-$role"
  case "$role" in
    app)
      local old_app
      old_app=$( . "$CONF" 2>/dev/null; printf '%s' "${APP:-}" )
      sed -i.bak "s|^APP=.*|APP=$target|"   "$CONF"; rm -f "$CONF.bak"
      # the roles file names hosts by target: the probed host moving must move
      # its line too, or deploy/restart/logs keep going to the old box
      if [ -f "$HOSTS_FILE" ] && [ -n "$old_app" ] && [ "$old_app" != "$target" ]; then
        if awk -v h="$target" '$1 == h { f = 1 } END { exit !f }' "$HOSTS_FILE"; then
          :
        elif awk -v h="$old_app" '$1 == h { f = 1 } END { exit !f }' "$HOSTS_FILE"; then
          awk -v o="$old_app" -v n="$target" '$1 == o { $1 = n } { print }' "$HOSTS_FILE" > "$HOSTS_FILE.tmp" \
            && mv "$HOSTS_FILE.tmp" "$HOSTS_FILE"
          say "$HOSTS_FILE: $old_app -> $target (roles kept)"
        else
          warn "$target is not in $HOSTS_FILE — give it roles: isukit host role $target <roles>"
        fi
      fi ;;
    bench) sed -i.bak "s|^BENCH=.*|BENCH=$target|" "$CONF"; rm -f "$CONF.bak" ;;
    add)
      [ -n "$target" ] || die "usage: isukit host add <ssh-target>"
      if [ -f "$HOSTS_FILE" ]; then
        # roles file in charge: an added host is an app instance unless told otherwise
        awk -v h="$target" '$1 == h { found = 1 } END { exit !found }' "$HOSTS_FILE" \
          && { say "$target already in $HOSTS_FILE — no-op"; return 0; }
        printf '%s app\n' "$target" >> "$HOSTS_FILE"
        say "$target = app   (change with: isukit host role $target <roles>)"
        return 0
      fi
      local cur
      cur=$( . "$CONF" 2>/dev/null; printf '%s' "${EXTRA_HOSTS:-}" )
      case " $cur " in
        *" $target "*) say "EXTRA_HOSTS already has $target — no-op" ;;
        *)
          cur=$(printf '%s' "$cur $target" | sed 's/^ *//;s/ *$//')
          local cur_q
          cur_q=$(printf '%s' "$cur" | sed "s/'/'\\\\''/g")
          sed -i.bak "s|^EXTRA_HOSTS=.*|EXTRA_HOSTS='$cur_q'|" "$CONF"; rm -f "$CONF.bak"
          say "EXTRA_HOSTS = $cur"
          ;;
      esac
      return 0 ;;
    role)
      local roles="$opts" r
      [ -n "$target" ] && [ -n "$roles" ] || die "usage: isukit host role <ssh-target> <role,role...>   (roles: $KNOWN_ROLES)"
      for r in $(printf '%s' "$roles" | tr , ' '); do
        case " $KNOWN_ROLES " in *" $r "*) ;; *) die "unknown role '$r' — roles are: $KNOWN_ROLES" ;; esac
      done
      load
      # first use: write the implied pre-roles layout down, so nothing is dropped
      if [ ! -f "$HOSTS_FILE" ]; then
        local seed   # read before the redirect creates the file host_lines would see
        seed=$(host_lines)
        printf '# <ssh-target> <roles>   roles: %s\n%s\n' "$KNOWN_ROLES" "$seed" > "$HOSTS_FILE"
      fi
      awk -v h="$target" '$1 != h' "$HOSTS_FILE" > "$HOSTS_FILE.tmp"
      printf '%s %s\n' "$target" "$roles" >> "$HOSTS_FILE.tmp"
      mv "$HOSTS_FILE.tmp" "$HOSTS_FILE"
      say "$target = $roles"
      cmd_hosts
      return 0 ;;
    *) die "usage: isukit host {app|bench|add|role} <ssh-target|local> [ssh opts... | roles]" ;;
  esac
  if [ "$rewrite_ssh_config" = 1 ]; then
    local w val prev="" new_key="" new_port=""
    for w in $opts; do
      case "$w" in
        -i=*|--identity=*|--key=*) val=$(expand_tilde "${w#*=}"); check_keyfile "$val"; new_key="$val" ;;
        -p=*)                      new_port="${w#*=}" ;;
      esac
      case "$prev" in
        -i|--identity|--key) val=$(expand_tilde "$w"); check_keyfile "$val"; new_key="$val" ;;
        -p)                  new_port="$w" ;;
      esac
      prev="$w"
    done
    [ -n "$new_key" ] && new_key=$(abspath "$new_key")
    local existing_key existing_port
    existing_key=$(awk '/^Host isukit-'"$role"'$/{f=1;next} f&&/^Host /{exit} f&&/^  IdentityFile /{print $2; exit}' "$STATE/ssh_config")
    existing_port=$(awk '/^Host isukit-'"$role"'$/{f=1;next} f&&/^Host /{exit} f&&/^  Port /{print $2; exit}' "$STATE/ssh_config")
    local block_file="$STATE/.ssh_block.$$"
    go_ssh_host_block "isukit-$role" "$orig_target" "${new_key:-$existing_key}" "${new_port:-$existing_port}" > "$block_file"
    awk -v role="isukit-$role" -v blockfile="$block_file" '
      $0 == "Host " role {while ((getline line < blockfile) > 0) print line; close(blockfile); skip=1; next}
      skip && /^Host /{skip=0}
      skip && $0==""{skip=0; print; next}
      skip {next}
      {print}
    ' "$STATE/ssh_config" > "$STATE/ssh_config.new" && mv "$STATE/ssh_config.new" "$STATE/ssh_config"
    rm -f "$block_file"
    # the catch-all mirrors the app host's credentials: a new app key or port
    # must reach the hosts added by IP too, or they stop connecting
    if [ "$role" = app ] && grep -q '^Host \*$' "$STATE/ssh_config" && { [ -n "$new_key" ] || [ -n "$new_port" ]; }; then
      local c_user c_key c_port
      c_user=$(awk '/^Host \*$/{f=1;next} f&&/^Host /{exit} f&&/^  User /{print $2; exit}' "$STATE/ssh_config")
      c_key=$(awk '/^Host \*$/{f=1;next} f&&/^Host /{exit} f&&/^  IdentityFile /{print $2; exit}' "$STATE/ssh_config")
      c_port=$(awk '/^Host \*$/{f=1;next} f&&/^Host /{exit} f&&/^  Port /{print $2; exit}' "$STATE/ssh_config")
      [ "${orig_target#*@}" != "$orig_target" ] && c_user="${orig_target%%@*}"
      awk '/^Host \*$/{skip=1; next} skip && /^Host /{skip=0} skip{next} {print}' "$STATE/ssh_config" \
        | awk 'NF{last=NR} {line[NR]=$0} END{for(i=1;i<=last;i++) print line[i]}' > "$STATE/ssh_config.new"
      { printf '\n'; go_ssh_catchall_block "$c_user" "${new_key:-$c_key}" "${new_port:-$c_port}"; } >> "$STATE/ssh_config.new"
      mv "$STATE/ssh_config.new" "$STATE/ssh_config"
    fi
    chmod 600 "$STATE/ssh_config" 2>/dev/null || true
    say "updated isukit-$role in $STATE/ssh_config (SSH_OPTS keeps -F)"
  elif [ -n "$opts" ]; then
    local w val prev="" expanded=""
    for w in $opts; do
      case "$w" in
        --identity=*) val=$(expand_tilde "${w#--identity=}"); check_keyfile "$val"; w="--identity=$val" ;;
        --key=*)      val=$(expand_tilde "${w#--key=}");      check_keyfile "$val"; w="--key=$val" ;;
        -i=*)         val=$(expand_tilde "${w#-i=}");         check_keyfile "$val"; w="-i=$val" ;;
        *)            w=$(expand_tilde "$w") ;;
      esac
      case "$prev" in
        -i|--identity|--key) check_keyfile "$w" ;;
      esac
      expanded="$expanded $w"; prev="$w"
    done
    expanded="${expanded# }"
    local opts_q
    opts_q=$(printf '%s' "$expanded" | sed "s/'/'\\\\''/g")
    sed -i.bak "s|^SSH_OPTS=.*|SSH_OPTS='$opts_q'|" "$CONF"; rm -f "$CONF.bak"
    say "SSH_OPTS = $expanded"
  fi
  say "$role = $target"
}

cmd_hosts() {
  load
  local h roles units
  [ -f "$HOSTS_FILE" ] || say "no $HOSTS_FILE — pre-roles layout ($APP does everything). set roles: isukit host role <target> <roles>"
  while read -r h roles; do
    units=$(role_units "$h")
    printf '  %-28s %-12s %s%s\n' "$h" "$roles" "${units:-?}" "$([ "$h" = "$PRIMARY" ] && printf '   (probe)')"
  done < <(host_lines)
  [ -n "$(hosts_with app)" ] || warn "no host has role app — deploy/restart have nowhere to go"
  case " $(hosts_all | tr '\n' ' ') " in *" $PRIMARY "*) ;; *) warn "APP=$PRIMARY (the probed host) is not listed in $HOSTS_FILE" ;; esac
}

go_ssh_catchall_block() { # go_ssh_catchall_block <user> <keyfile> <port> -- 'Host *': hosts added by IP
  printf 'Host *\n'
  [ -n "$1" ] && printf '  User %s\n' "$1"
  [ -n "$2" ] && printf '  IdentityFile %s\n' "$2"
  [ -n "$3" ] && printf '  Port %s\n' "$3"
  printf '  StrictHostKeyChecking accept-new\n'
}

go_ssh_host_block() { # go_ssh_host_block <alias> <user@host|host> <keyfile> <port>
  local alias="$1" target="$2" key="$3" port="$4" user=""
  local host="$target" # split: local expands all args before assigning, so $target isn't set yet on one line
  if [ "${target#*@}" != "$target" ]; then
    user="${target%%@*}"
    host="${target#*@}"
  fi
  printf 'Host %s\n' "$alias"
  printf '  HostName %s\n' "$host"
  [ -n "$user" ] && printf '  User %s\n' "$user"
  [ -n "$key" ]  && printf '  IdentityFile %s\n' "$key"
  [ -n "$port" ] && printf '  Port %s\n' "$port"
  printf '  StrictHostKeyChecking accept-new\n'
}
