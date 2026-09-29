#!/bin/bash
# Prints "<crc> <size> ./<path>" for every file under <DIR>/etc, one per line,
# sorted. The checksum is taken with isukit's own `logs on` markers removed, so
# a server copy that logging has edited compares equal to the clean laptop copy
# and only real config changes show up. Runs on either side: `isukit etc push`
# and `etc pull` compare the laptop's output with the app host's.
#
# Inputs (isukit prepends them as VAR=value lines):
#   DIR    repo dir whose etc/ is summed (required); missing etc/ prints nothing
#   SUDO   default "sudo -n" (the server repo may sit under a 0750 /home)

set -u
: "${DIR:?DIR is required}"
SUDO="${SUDO-sudo -n}"
[ -n "$SUDO" ] && ! $SUDO true 2>/dev/null && SUDO=""
$SUDO test -d "$DIR/etc" || exit 0
cd / || exit 1
$SUDO find "$DIR/etc" -type f | LC_ALL=C sort | while IFS= read -r f; do
  sum=$($SUDO sed -e 's|#isukit# access_log|access_log|' -e '/# isukit-include$/d' "$f" | cksum)
  printf '%s ./%s\n' "$sum" "${f#"$DIR"/etc/}"
done
