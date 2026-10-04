# shellcheck shell=bash
# isukit lib/core.sh — output, config loading, and the ssh transport every command goes through.
# Sourced by ../isukit; not meant to run on its own.

die()  { printf '\033[31m!! %s\033[0m\n' "$*" >&2; exit 1; }

say()  { printf '\033[36m:: %s\033[0m\n' "$*" >&2; }

warn() { printf '\033[33m~~ %s\033[0m\n' "$*" >&2; }

is_blank() { [ -z "$(printf '%s' "$1" | tr -d '[:space:]')" ]; } # empty or whitespace-only

normalize_ws_arg() { # normalize_ws_arg <token> -- Unicode whitespace-lookalikes -> ASCII space; ZWSP/BOM dropped
  printf '%s' "$1" | LC_ALL=C sed \
    -e $'s/\xc2\xa0/ /g' \
    -e $'s/\xe3\x80\x80/ /g' \
    -e $'s/\xe2\x80\x87/ /g' \
    -e $'s/\xe2\x80\xaf/ /g' \
    -e $'s/\xe2\x80\x89/ /g' \
    -e $'s/\xe2\x80\x8b//g' \
    -e $'s/\xef\xbb\xbf//g'
}

expand_tilde() { # expand_tilde <token> -- "~" or "~/..." -> $HOME/...; anything else unchanged
  # shellcheck disable=SC2088  # matching a literal "~" the shell did not expand
  case "$1" in
    "~")   printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s\n' "$HOME/${1#\~/}" ;;
    *)     printf '%s\n' "$1" ;;
  esac
}

check_keyfile() { # check_keyfile <resolved-path> -- call directly (not via $()) so die() aborts the script
  local f="$1" mode g o
  [ -f "$f" ] || die "identity file not found: $f"
  mode=$(stat -f '%Lp' "$f" 2>/dev/null || stat -c '%a' "$f" 2>/dev/null || true)
  [ -n "$mode" ] || return 0
  g="${mode%?}"; g="${g#"${g%?}"}"
  o="${mode#"${mode%?}"}"
  if [ "$g" != "0" ] || [ "$o" != "0" ]; then
    chmod 600 "$f" 2>/dev/null && say "chmod 600 $f (was $mode — ssh refuses group/other-readable keys)" \
      || warn "$f is mode $mode (group/other-readable) and chmod 600 failed — ssh may refuse it"
  fi
}

looks_like_keyfile() { # looks_like_keyfile <path> -- existing, readable, and named/shaped like a key
  local p="$1"
  [ -f "$p" ] && [ -r "$p" ] || return 1
  case "$p" in
    *.pem|*.key|*id_rsa) return 0 ;;
  esac
  head -c 11 "$p" 2>/dev/null | grep -q '^-----BEGIN'
}

need_state() { [ -f "$CONF" ] || die "no $CONF here. cd into the problem repo, or run: isukit init <repo-url>"; }

load() {
  need_state
  # team-wide settings (committed) first, then this laptop's own: yours win
  [ -f isukit.conf ] && . ./isukit.conf
  . "$CONF"; [ -f "$STATE/manifest" ] && . "$STATE/manifest" || true
  resolve_hosts_file
  # shellcheck disable=SC2034  # PRIMARY is read by the roles code in lib/hosts.sh
  PRIMARY="$APP"                                  # the host probe reads the manifest from
  [ -n "${HOST_OVERRIDE:-}" ] && APP="$HOST_OVERRIDE"  # on_hosts: this run targets one host
  return 0
}

# Every host is either "local" or an ssh target. Same primitives either way.
rsh() { # rsh <host> <command...>
  local h="$1"; shift
  if [ "$h" = "local" ]; then bash -lc "$*"; else ssh ${SSH_OPTS:-} -o StrictHostKeyChecking=accept-new "$h" "$*"; fi
}

rsh_stdin() { # rsh_stdin <host>   -- script on stdin
  local h="$1"
  if [ "$h" = "local" ]; then bash -s; else ssh ${SSH_OPTS:-} -o StrictHostKeyChecking=accept-new "$h" 'bash -s'; fi
}

remote_script() { # remote_script <name> -- print remote/<name>, for piping into rsh_stdin
  local f
  f="$(kit_dir)/remote/$1"
  [ -f "$f" ] || die "missing $f — reinstall isukit (install.sh) so remote/ sits next to it"
  cat "$f"
}

rpull() { # rpull <host> <remote-path> <local-path>
  local h="$1" r="$2" l="$3"
  if [ "$h" = "local" ]; then cp "$r" "$l"; else scp ${SSH_OPTS:-} -q "$h:$r" "$l"; fi
}

# Middleware config under git: the real nginx / mysql / systemd files move into
# <server repo>/etc/<same path minus /etc/> and /etc keeps a symlink to each, so
# the repo is the only copy and every tuning change is a diff. Mirroring the path
# (etc/nginx/sites-available/isucon.conf, etc/mysql/mysql.conf.d/mysqld.cnf) is
# what lets status/push/re-link work from the repo alone, with no mapping file.
# The file each adopt replaces is backed up under /etc/isukit-orig/<same path>.
# The host side lives in remote/etc-adopt.sh, etc-status.sh and etc-sums.sh.

local_repo_root() { git rev-parse --show-toplevel 2>/dev/null || pwd; }

abspath() { # abspath <path> -- resolve to an absolute path without requiring it to exist
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    "~"*) printf '%s\n' "$HOME${1#\~}" ;;
    *) printf '%s/%s\n' "$(cd "$(dirname "$1")" 2>/dev/null && pwd || pwd)" "$(basename "$1")" ;;
  esac
}
