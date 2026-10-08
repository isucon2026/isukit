#!/bin/bash
# Runs ON EVERY HOST, sent by `isukit rules check` (reboot-survivability section)
# and by `isukit rules langs` (implementation enumeration), both over
# `ssh host bash -s`.
#
# ISUCON2026's post-contest re-examination (追試) reboots every instance in an
# unspecified order and re-runs the benchmark cold. Most of what breaks that
# is invisible on a running box: a unit that is active but was never enabled,
# a second reference-implementation unit left enabled alongside the one in
# use (they all share one port — the reboot picks a winner at random), a
# tmpfs mount missing from fstab, a sysctl tuned at the shell and never
# written down, a cache with nothing durable backing it. Lists findings
# without changing anything. Two kinds of line, nothing else on stdout:
#   FIX|<what is wrong>|<how to fix it>        -- counts as a failure
#   INFO|<what>|<how>                          -- informational only
# Plus, for `rules langs`'s enumeration (ignored by `rules check`'s FIX/INFO
# filtering):
#   IMPL|<unit>|<enabled|disabled>|<active|inactive>
#
# Inputs (isukit prepends them as VAR=value lines):
#   APP_UNIT     the app unit currently pointed at (may be empty)
#   EXTRA_UNITS  space-separated extra units restart/finalize also touch
#   WEB_SERVER   web server unit (e.g. nginx), may be empty
#   DB_SERVER    db server unit (e.g. mysql), may be empty
#   MULTI_HOST   1 if this team's fleet has more than one host
#   INIT_PATH    maintenance endpoint path (unused here; carried for parity
#                with final-check.sh's calling convention)
#   SUDO         default "sudo -n"
#
# sudo may or may not be passwordless here: every check below prefers a path
# that works without it, and a file sudo can't read just drops out of that
# check's input rather than aborting the script.

set -u
SUDO="${SUDO-sudo -n}"
fix()  { printf 'FIX|%s|%s\n' "$1" "$2"; }
info() { printf 'INFO|%s|%s\n' "$1" "$2"; }
impl() { printf 'IMPL|%s|%s|%s\n' "$1" "$2" "$3"; }

is_enabled() { systemctl is-enabled "$1" 2>/dev/null; }
is_active_q() { systemctl is-active --quiet "$1" 2>/dev/null; }

HAVE_SYSTEMCTL=0
command -v systemctl >/dev/null 2>&1 && HAVE_SYSTEMCTL=1

# --- R1: a unit running but not enabled is not coming back after the reboot
# test; the inverse (enabled but not running) is reported too.
if [ "$HAVE_SYSTEMCTL" = 1 ]; then
  for u in "${APP_UNIT:-}" "${WEB_SERVER:-}" "${DB_SERVER:-}" ${EXTRA_UNITS:-}; do
    [ -n "$u" ] || continue
    en=$(is_enabled "$u")
    if is_active_q "$u"; then
      [ "$en" = enabled ] || fix "$u is running but not enabled — it will NOT come back after the reboot test" "sudo systemctl enable $u"
    else
      [ "$en" = enabled ] && fix "$u is enabled but not active" "sudo systemctl start $u, or disable it if it should stay down"
    fi
  done
fi

# --- R2 (+ IMPL lines for `rules langs`): ISUCON ships the webapp in Go, Perl,
# PHP, Python, Ruby, Rust and Node.js, all binding the same port. More than
# one enabled reference-implementation unit means the reboot picks the
# winner at random.
impl_langs="go golang perl php python py ruby rb rust nodejs node"
impl_units=""
if [ "$HAVE_SYSTEMCTL" = 1 ]; then
  for d in /etc/systemd/system /lib/systemd/system /usr/lib/systemd/system; do
    [ -d "$d" ] || continue
    for lang in $impl_langs; do
      for f in "$d"/*-"$lang".service "$d"/*."$lang".service; do
        [ -f "$f" ] || continue
        u=$(basename "$f")
        case " $impl_units " in *" $u "*) continue ;; esac
        impl_units="$impl_units $u"
      done
    done
  done
fi

enabled_impls="" enabled_n=0 active_unenabled=""
for u in $impl_units; do
  en=$(is_enabled "$u")
  if is_active_q "$u"; then ac=active; else ac=inactive; fi
  impl "$u" "${en:-unknown}" "$ac"
  if [ "$en" = enabled ]; then
    enabled_impls="$enabled_impls $u"; enabled_n=$((enabled_n + 1))
  elif [ "$ac" = active ]; then
    active_unenabled="$active_unenabled $u"
  fi
done
enabled_impls="${enabled_impls# }"
if [ "$enabled_n" -gt 1 ]; then
  fix "$enabled_n implementation units are enabled ($enabled_impls) — they share one port, so the reboot picks the winner at random" "sudo systemctl disable --now <the ones you are not using>"
elif [ "$enabled_n" -eq 0 ] && [ -n "$active_unenabled" ]; then
  for u in $active_unenabled; do
    fix "the running implementation $u is not enabled" "sudo systemctl enable $u"
  done
fi

# --- R3: PHP's extra step — nginx needs its own php site enabled, or it is
# still routing to whatever used to be there.
case " $enabled_impls " in
  *php*)
    php_site=0
    for d in /etc/nginx/sites-enabled /etc/nginx/conf.d; do
      [ -d "$d" ] || continue
      $SUDO grep -Rqsi 'php' "$d" 2>/dev/null && php_site=1
    done
    [ "$php_site" = 1 ] || fix "the PHP implementation is enabled but nginx has no php site enabled — nginx is still routing to the old upstream" "sudo ln -s /etc/nginx/sites-available/<the php conf> /etc/nginx/sites-enabled/ && sudo systemctl reload nginx"
    ;;
esac

# --- R4: a tmpfs mount that only exists because something mounted it by hand
if [ -r /proc/mounts ]; then
  while read -r _dev mp fstype _rest; do
    [ "$fstype" = tmpfs ] || continue
    case "$mp" in
      /run|/run/*|/dev/shm|/sys/fs/cgroup|/sys/fs/cgroup/*|/tmp) continue ;;
    esac
    if [ -r /etc/fstab ] && awk -v m="$mp" '$1 !~ /^#/ && $2 == m { f = 1 } END { exit !f }' /etc/fstab; then
      :
    else
      fix "tmpfs mounted at $mp is not in /etc/fstab — it disappears on reboot" "add it to /etc/fstab, or stop depending on it"
    fi
  done < /proc/mounts
fi

# --- R5: sysctl tuned at runtime but drifted from (or absent from) config.
# Only unambiguous drift (a config file disagreeing with the live value) is a
# FIX; params set nowhere in config get one informational line, not a guess
# at what the kernel default would have been.
sysctl_params="net.core.somaxconn net.ipv4.tcp_max_syn_backlog net.ipv4.ip_local_port_range net.ipv4.tcp_tw_reuse net.core.netdev_max_backlog fs.file-max vm.swappiness vm.overcommit_memory"
if command -v sysctl >/dev/null 2>&1; then
  unconfigured=""
  for p in $sysctl_params; do
    runtime=$(sysctl -n "$p" 2>/dev/null) || continue
    cfg_val="" cfg_file=""
    for cf in /etc/sysctl.conf /etc/sysctl.d/*.conf; do
      [ -f "$cf" ] || continue
      v=$(awk -F= -v p="$p" '
        $0 ~ /^[[:space:]]*#/ { next }
        { k = $1; sub(/^[[:space:]]+/, "", k); sub(/[[:space:]]+$/, "", k)
          if (k == p) { v = $2; sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]*(#.*)?$/, "", v) } }
        END { print v }' "$cf" 2>/dev/null)
      [ -n "$v" ] && { cfg_val="$v"; cfg_file="$cf"; }
    done
    if [ -n "$cfg_val" ]; then
      [ "$runtime" = "$cfg_val" ] || fix "sysctl $p is $runtime at runtime but $cfg_val in $cfg_file — reboot reverts it" "sysctl -w $p=$runtime to match, or fix the config file"
    else
      unconfigured="$unconfigured $p"
    fi
  done
  [ -n "$unconfigured" ] && info "sysctl set at runtime only, in no config file:$unconfigured" "not re-discovered the hard way after a reboot: persist the ones that matter in /etc/sysctl.d/"
fi

# --- R6: a unix socket under a volatile directory with no way to recreate
# that directory after the reboot (no tmpfiles.d rule, no RuntimeDirectory=)
sock_paths=""
if [ -d /etc/nginx ]; then
  for s in $($SUDO grep -RhoE '/[^[:space:];"'"'"']+\.sock' /etc/nginx 2>/dev/null); do
    case " $sock_paths " in *" $s "*) ;; *) sock_paths="$sock_paths $s" ;; esac
  done
fi
# the app unit's own EnvironmentFile=, if it names one and it is readable —
# isukit does not currently hand this script an app-env-file path directly
if [ "$HAVE_SYSTEMCTL" = 1 ] && [ -n "${APP_UNIT:-}" ]; then
  for ef in $(systemctl show -p EnvironmentFile --value "$APP_UNIT" 2>/dev/null | sed -E 's/\(ignore_errors=[^)]*\)//g'); do
    [ -r "$ef" ] || continue
    for s in $(grep -hoE '/[^[:space:];"'"'"']+\.sock' "$ef" 2>/dev/null); do
      case " $sock_paths " in *" $s "*) ;; *) sock_paths="$sock_paths $s" ;; esac
    done
  done
fi
for s in $sock_paths; do
  case "$s" in /run/*|/var/run/*|/tmp/*) ;; *) continue ;; esac
  dir=$(dirname "$s")
  rule_found=0
  for td in /etc/tmpfiles.d /usr/lib/tmpfiles.d; do
    [ -d "$td" ] || continue
    $SUDO grep -Rqs "^[dD][[:space:]]\+$dir\b" "$td" 2>/dev/null && rule_found=1
  done
  if [ "$rule_found" != 1 ] && [ "$HAVE_SYSTEMCTL" = 1 ]; then
    name=$(basename "$dir")
    for uf in /etc/systemd/system/*.service /lib/systemd/system/*.service /usr/lib/systemd/system/*.service; do
      [ -f "$uf" ] || continue
      $SUDO grep -qsE "^RuntimeDirectory=.*(^|[[:space:]])$name([[:space:]]|\$)" "$uf" 2>/dev/null && rule_found=1
    done
  fi
  [ "$rule_found" = 1 ] || fix "unix socket $s lives under $dir, a volatile directory with no /etc/tmpfiles.d rule and no unit's RuntimeDirectory= to recreate it" "add a tmpfiles.d rule for $dir, or RuntimeDirectory=$name in the owning unit"
done

# --- R7: restart policy, multi-host only — reboot order across hosts is not
# guaranteed, so Restart=no on the app is a race against the DB host
if [ "${MULTI_HOST:-0}" = 1 ] && [ "$HAVE_SYSTEMCTL" = 1 ] && [ -n "${APP_UNIT:-}" ]; then
  restart_policy=$(systemctl show -p Restart --value "$APP_UNIT" 2>/dev/null)
  [ "$restart_policy" = no ] && fix "$APP_UNIT has Restart=no and the DB is on another host — reboot order is not guaranteed, so a race leaves the app dead" "add Restart=always and RestartSec=5 to the unit, then systemctl daemon-reload"
fi

# --- R8: cache / datastore durability across the reboot (C3) — the trap
# where a permitted optimization (a cache, a write-behind queue) becomes an
# instant disqualification through a flush that never happens
if command -v redis-cli >/dev/null 2>&1 && redis-cli ping 2>/dev/null | grep -q PONG; then
  aof=$(redis-cli CONFIG GET appendonly 2>/dev/null | tail -1)
  save=$(redis-cli CONFIG GET save 2>/dev/null | tail -1)
  if [ "$aof" = no ] && [ -z "$save" ]; then
    fix "redis has neither AOF nor RDB enabled — anything written during the benchmark is gone after the reboot" "redis-cli CONFIG SET appendonly yes (and persist it in redis.conf)"
  fi
fi
if command -v pgrep >/dev/null 2>&1 && pgrep -x memcached >/dev/null 2>&1; then
  info "memcached is listening" "volatile by design — nothing written to it survives any restart, not just the reboot test; fine as long as nothing load-bearing for C3 lives only there"
fi
if command -v mysql >/dev/null 2>&1 && $SUDO mysql -N -B -e "SELECT 1" >/dev/null 2>&1; then
  v=$($SUDO mysql -N -B -e "SELECT @@GLOBAL.innodb_flush_log_at_trx_commit" 2>/dev/null)
  [ -n "$v" ] && [ "$v" != 1 ] && info "innodb_flush_log_at_trx_commit=$v" "a legitimate speed-up during the contest, but committed data can be lost on reboot — set it back to 1 before the final run, or accept the 追試 risk knowingly"
fi

# --- R9: unit files that do not even parse
if command -v systemd-analyze >/dev/null 2>&1; then
  verify_out=$(systemd-analyze verify /etc/systemd/system/*.service 2>&1)
  if [ -n "$verify_out" ]; then
    printf '%s\n' "$verify_out" | grep -iE 'error|Failed' | while IFS= read -r l; do
      fix "systemd-analyze verify: $l" "fix the unit file named above, then systemctl daemon-reload"
    done
  fi
fi

exit 0
