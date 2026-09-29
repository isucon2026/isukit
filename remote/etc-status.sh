#!/bin/bash
# Runs ON THE APP HOST, sent by `isukit etc status` over `ssh host bash -s`.
#
# For every file in <REPO>/etc, reports whether /etc really reads it through a
# symlink. Exit 0 = all linked; 1 = at least one is not; 3 = nothing managed yet.
#
# Inputs (isukit prepends them as VAR=value lines):
#   REPO       server dir whose etc/ holds the managed files (required)
#   ETC_ROOT   default /etc (tests point it at a throwaway tree)

set -u
: "${REPO:?REPO is required}"
E=$(cd "${ETC_ROOT:-/etc}" && pwd -P)
DEST="$REPO/etc"
BAD=0; N=0
[ -d "$DEST" ] || { echo "etc: $DEST does not exist — nothing is managed yet (isukit etc adopt)"; exit 3; }
LIST=$(mktemp)
trap 'rm -f "$LIST"' EXIT
find "$DEST" -type f ! -path "$DEST/apparmor.d/*" | sort > "$LIST"
while read -r p; do
  rel="${p#"$DEST"/}"; f="$E/$rel"; N=$((N+1))
  if [ -L "$f" ] && [ "$(readlink "$f")" = "$p" ]; then
    echo "linked      $f"
  elif [ -L "$f" ]; then
    echo "OTHER LINK  $f -> $(readlink "$f")"; BAD=1
  elif [ -e "$f" ]; then
    echo "NOT LINKED  $f (a plain file — repo edits never reach it; fix: isukit etc adopt $f)"; BAD=1
  else
    echo "NO TARGET   $f (only in the repo; fix: isukit etc adopt $f)"; BAD=1
  fi
done < "$LIST"
[ "$N" = 0 ] && { echo "etc: $DEST has no files — nothing is managed yet (isukit etc adopt)"; exit 3; }
exit $BAD
