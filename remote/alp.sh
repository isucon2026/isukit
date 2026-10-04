#!/bin/bash
# Runs ON THE APP HOST, sent by `isukit alp` over `ssh host bash -s`.
#
# alp only groups URIs it is given a regex for, and one loose regex swallows
# everything (an unanchored '/api/[^/]+/...' matched every /api/x/y into a single
# row). So the patterns are derived from this log itself, per path segment:
#   1. a segment that looks like an id collapses: digits, uuid, long hex or token,
#      digits with an extension (123.jpg)
#   2. a position where one prefix fans out into THRESH+ distinct values collapses
#      too (/api/user/<name>/icon, /img/<file>, /@<user>) — no per-year knowledge
#      needed. Values with a leading sigil (@, ~) are counted as their own group,
#      and a value hit HOT times more than its siblings' average stays literal:
#      /api/user/me is its own endpoint, not one more <name>
# Every pattern is anchored ^...$ and only wildcarded ones are passed, so a
# literal endpoint (/api/user/me) is never folded into a neighbour.
#
# Inputs (isukit prepends them as VAR=value lines):
#   LOG        LTSV access log (default /var/log/nginx/isukit.log)
#   MATCHES    comma-separated alp -m regexes; set = use these verbatim instead
#   THRESH     fan-out that makes a segment a wildcard (default 20)
#   HOT        a sibling with HOT x the average hits stays literal (default 10)
#   SORT       alp --sort key (default sum)
#   LIMIT      rows to show (default 30)
#   PRINT_MATCHES=1  print the derived regexes, one per line, and exit (tests)
#   SUDO       default "sudo -n"

set -u
SUDO="${SUDO-sudo -n}"
LOG="${LOG:-/var/log/nginx/isukit.log}"
THRESH="${THRESH:-20}"
HOT="${HOT:-10}"

derive_matches() {
  $SUDO cat "$LOG" | awk -F '\t' -v thresh="$THRESH" -v hot="$HOT" '
    # no {n} intervals and no "]" inside brackets: mawk (Ubuntu default awk) and
    # BSD awk disagree on both.
    function hexish(s) { return s ~ /^[0-9a-fA-F]+$/ }
    function is_uuid(s) {
      if (length(s) != 36) return 0
      if (substr(s, 9, 1) != "-" || substr(s, 14, 1) != "-" || substr(s, 19, 1) != "-" || substr(s, 24, 1) != "-") return 0
      t = s; gsub(/-/, "", t)
      return length(t) == 32 && hexish(t)
    }
    function is_id(s) {
      return s ~ /^[0-9]+$/ || is_uuid(s) ||
             (length(s) >= 16 && hexish(s)) ||
             (length(s) >= 20 && s ~ /^[0-9A-Za-z_-]+$/)
    }
    function num_ext(s) { return s ~ /^[0-9]+\.[A-Za-z0-9]+$/ }
    function esc(s,    i, c, o) {
      o = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (index(".+*?(){}|^$\\[]", c)) o = o "\\"
        o = o c
      }
      return o
    }
    {
      u = ""
      for (i = 1; i <= NF; i++) if (substr($i, 1, 4) == "uri:") { u = substr($i, 5); break }
      if (u == "" || u !~ /^\//) next
      sub(/[?#].*/, "", u)
      if (!(u in seen)) { seen[u] = 0; uris[++n] = u }
      seen[u]++
    }
    END {
      maxd = 0
      for (k = 1; k <= n; k++) {
        d = split(substr(uris[k], 2), parts, "/")
        depth[k] = d
        if (d > maxd) maxd = d
        for (j = 1; j <= d; j++) {
          s = parts[j]
          # a leading sigil (/@alice, /~bob) is part of the route shape: count
          # and collapse those apart from plain words, or /@<user> fan-out would
          # also swallow /api, /image, /login at the same level.
          c1 = substr(s, 1, 1)
          cls[k, j] = (c1 != "" && c1 !~ /[0-9A-Za-z]/) ? c1 : ""
          wild[k, j] = 1
          if (num_ext(s)) { ext = s; sub(/^[0-9]+/, "", ext); seg[k, j] = "[0-9]+" esc(ext) }
          else if (is_id(s)) seg[k, j] = "[^/]+"
          else { seg[k, j] = esc(s); wild[k, j] = 0 }
        }
      }
      # fan-out pass, shallow to deep, so a collapsed prefix is shared below it
      for (j = 1; j <= maxd; j++) {
        split("", fan); split("", vals); split("", hits); split("", total)
        for (k = 1; k <= n; k++) {
          if (depth[k] < j) continue
          p = ""
          for (i = 1; i < j; i++) p = p "/" seg[k, i]
          g = p SUBSEP cls[k, j]
          key = g SUBSEP seg[k, j]
          if (!(key in vals)) { vals[key] = 1; fan[g]++ }
          hits[key] += seen[uris[k]]; total[g] += seen[uris[k]]
          grp[k] = g; gkey[k] = key
        }
        for (k = 1; k <= n; k++) {
          if (depth[k] < j || fan[grp[k]] < thresh || wild[k, j]) continue
          # far busier than an average sibling: a route of its own (/api/user/me)
          if (hits[gkey[k]] >= hot * total[grp[k]] / fan[grp[k]]) continue
          seg[k, j] = esc(cls[k, j]) "[^/]+"; wild[k, j] = 1
        }
      }
      for (k = 1; k <= n; k++) {
        r = ""; w = 0
        for (j = 1; j <= depth[k]; j++) { r = r "/" seg[k, j]; if (wild[k, j]) w = 1 }
        if (w) out["^" r "$"] = 1
      }
      for (r in out) print r
    }' | LC_ALL=C sort
}

if [ -z "${MATCHES:-}" ]; then
  MATCHES=$(derive_matches | paste -sd, -)
fi
if [ "${PRINT_MATCHES:-0}" = 1 ]; then
  printf '%s\n' "$MATCHES" | tr ',' '\n' | sed '/^$/d'
  exit 0
fi

set -- ltsv --file="$LOG" --sort="${SORT:-sum}" -r --limit="${LIMIT:-30}" \
  -o count,method,uri,min,max,sum,avg,p95,p99
[ -n "$MATCHES" ] && set -- "$@" -m "$MATCHES"
$SUDO alp "$@" 2>&1 | head -$(( ${LIMIT:-30} + 20 ))
