#!/bin/bash
# Runs ON THE APP HOST, sent by `isukit etc status` over `ssh host bash -s`.
#
# For every file in <REPO>/etc, reports whether /etc really reads it through a
# symlink. Exit 0 = all linked; 1 = at least one is not; 3 = nothing managed yet.
# Files of a tier this host's roles don't run (nginx without web, mysql without
# db, the app's units without app) are not expected here: listed only if linked.
#
# Inputs (isukit prepends them as VAR=value lines):
#   REPO       server dir whose etc/ holds the managed files (required)
#   APP_UNIT / EXTRA_UNITS  the app's units (systemd/system/<unit> is app-tier)
#   WANT_NGINX / WANT_MYSQL / WANT_APP  1 (default) = this host's roles include
#              web / db / app
#   ETC_ROOT   default /etc (tests point it at a throwaway tree)

set -u
: "${REPO:?REPO is required}"
E=$(cd "${ETC_ROOT:-/etc}" && pwd -P)
DEST="$REPO/etc"
BAD=0; N=0; ALL=0
WANT_NGINX="${WANT_NGINX:-1}"; WANT_MYSQL="${WANT_MYSQL:-1}"; WANT_APP="${WANT_APP:-1}"
[ -d "$DEST" ] || { echo "etc: $DEST does not exist — nothing is managed yet (isukit etc adopt)"; exit 3; }
LIST=$(mktemp)
trap 'rm -f "$LIST"' EXIT
wanted() { # wanted <path under etc/> -- same split as etc-adopt.sh
  case "$1" in
    nginx/*) [ "$WANT_NGINX" = 1 ] ;;
    mysql/*) [ "$WANT_MYSQL" = 1 ] ;;
    systemd/system/*)
      case " ${APP_UNIT:-} ${EXTRA_UNITS:-} " in
        *" ${1#systemd/system/} "*) [ "$WANT_APP" = 1 ] ;;
        *) true ;;
      esac ;;
    *) true ;;
  esac
}
find "$DEST" -type f ! -path "$DEST/apparmor.d/*" | sort > "$LIST"
while read -r p; do
  rel="${p#"$DEST"/}"; f="$E/$rel"; ALL=$((ALL+1))
  if [ -L "$f" ] && [ "$(readlink "$f")" = "$p" ]; then
    echo "linked      $f"; N=$((N+1))
    continue
  fi
  wanted "$rel" || continue
  N=$((N+1))
  if [ -L "$f" ]; then
    echo "OTHER LINK  $f -> $(readlink "$f")"; BAD=1
  elif [ -e "$f" ]; then
    echo "NOT LINKED  $f (a plain file — repo edits never reach it; fix: isukit etc adopt $f)"; BAD=1
  else
    echo "NO TARGET   $f (only in the repo; fix: isukit etc adopt $f)"; BAD=1
  fi
done < "$LIST"
[ "$N" = 0 ] && [ "$ALL" -gt 0 ] && { echo "etc: nothing in $DEST is for this host's roles"; exit 0; }
[ "$N" = 0 ] && { echo "etc: $DEST has no files — nothing is managed yet (isukit etc adopt)"; exit 3; }
exit $BAD
