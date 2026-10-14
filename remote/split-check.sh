#!/bin/bash
# Runs ON ONE HOST, sent by `isukit probe` / `doctor` / `finalize` (split_findings).
#
# After a split every host still has the whole image: the app, its helpers,
# nginx and mysql. Read-only: reports what this host would run that its roles
# hand to another host. One line per finding:
#   DEP|<unit>|<Requires|BindsTo|Wants>|<db unit>|<unit file>
#   ON|<unit>|<enabled or empty>|<active or empty>
# DEP lines come first: a unit that Requires= mysql stops with it.
#
# Inputs (isukit prepends them as VAR=value lines):
#   OFF_UNITS  units this host's roles say must be neither enabled nor running
#   DEP_UNITS  units whose dependency on a local datastore matters (app units
#              on a host without the db role)

set -u
for u in ${DEP_UNITS:-}; do
  for p in Requires BindsTo Wants; do
    for d in $(systemctl show -p "$p" --value "$u" 2>/dev/null); do
      case "$d" in
        mysql*|mariadb*|postgresql*)
          printf 'DEP|%s|%s|%s|%s\n' "$u" "$p" "$d" "$(systemctl show -p FragmentPath --value "$u" 2>/dev/null)" ;;
      esac
    done
  done
done
for u in ${OFF_UNITS:-}; do
  e=$(systemctl is-enabled "$u" 2>/dev/null); a=$(systemctl is-active "$u" 2>/dev/null)
  case "$e" in enabled*) ;; *) e="" ;; esac
  [ "$a" = active ] || a=""
  [ -n "$e$a" ] && printf 'ON|%s|%s|%s\n' "$u" "$e" "$a"
done
exit 0
