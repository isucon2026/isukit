# shellcheck shell=bash
# isukit lib/notify.sh — post what happened to Discord: scores to #bench,
# who has the servers / what was deployed / the endgame to #servers.
# Sourced by ../isukit; not meant to run on its own.

# Discord webhooks, set per laptop (.isukit/config or the environment — never
# isukit.conf: a webhook URL lets anyone post):
#   DISCORD_WEBHOOK_BENCH  bench results
#   DISCORD_WEBHOOK_OPS    lock / unlock, deploy, final, finalize
#   DISCORD_WEBHOOK        both, when the specific one is unset
# Unset = nothing is sent. Posting is best effort: 5s at most, and a failure
# only warns — Discord being down must never stop a bench or a deploy.

notify_url() { # notify_url <bench|ops>
  case "$1" in
    bench) printf '%s' "${DISCORD_WEBHOOK_BENCH:-${DISCORD_WEBHOOK:-}}" ;;
    ops)   printf '%s' "${DISCORD_WEBHOOK_OPS:-${DISCORD_WEBHOOK:-}}" ;;
  esac
}

json_string() { # stdin -> one JSON string literal (quotes included)
  # control characters out, then escape \ " tab; lines joined with \n
  LC_ALL=C tr -d '\000-\010\013\014\016-\037' | awk 'BEGIN { ORS = ""; printf "\"" }
    { gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t"); gsub(/\r/, ""); if (NR > 1) printf "\\n"; printf "%s", $0 }
    END { printf "\"" }'
}

clip_lines() { # keep whole lines under 1900 bytes: Discord caps a message at 2000 characters
  awk '{ n += length($0) + 1; if (n > 1900) { print "…"; exit } print }'
}

notify_tag() { # which repo is talking: NOTIFY_TAG, else origin's name, else the dir's
  local t="${NOTIFY_TAG:-}" u
  if [ -z "$t" ]; then
    u=$(git -C "$(local_repo_root)" remote get-url origin 2>/dev/null || true)
    if [ -n "$u" ]; then t=$(basename "$u" .git); else t=$(basename "$(local_repo_root)"); fi
  fi
  printf '%s' "$t"
}

notify() { # notify <bench|ops> -- message on stdin
  local url body
  url=$(notify_url "$1")
  if [ -z "$url" ] || [ "${ISUKIT_NOTIFY:-1}" = 0 ]; then cat >/dev/null; return 0; fi
  if rules_in_contest && [ -z "${NOTIFY_PRIVATE_ACK:-}" ]; then
    rules_override notify-scope "posting to Discord during the contest window without NOTIFY_PRIVATE_ACK" \
      || { warn "notify suppressed: NOTIFY_PRIVATE_ACK is unset and the contest window is active (ISUCON2026 E1 — 終了時刻まで競技内容を公開・共有してはならない)"; cat >/dev/null; return 0; }
  fi
  # practice and contest repos may post to the same channel by mistake: say which
  body=$({ printf '[%s] ' "$(notify_tag)"; cat; } | clip_lines | json_string)
  curl -sS -m 5 -o /dev/null -H 'Content-Type: application/json' \
    -d "{\"username\":\"isukit\",\"allowed_mentions\":{\"parse\":[]},\"content\":$body}" "$url" 2>/dev/null \
    || warn "could not post to Discord ($1) — carrying on"
  return 0
}

# --- what each event says

vs_main() { # vs_main <score> -- "+11.4% vs main 3810  KEEP", or nothing without a main run before it
  local s="$1" base
  case "$s" in ''|*[!0-9-]*) return 0 ;; esac
  base=$(runs_view | awk -F'\t' '$3 ~ /^-?[0-9]+$/' | sed '$d' | awk -F'\t' '$6 == "main" { b = $3 } END { print b }')
  [ -n "$base" ] && [ "$base" != 0 ] || return 0
  awk -v s="$s" -v b="$base" -v noise="${NOISE_PCT:-10}" 'BEGIN {
    d = (s - b) / (b < 0 ? -b : b) * 100
    v = (d > noise) ? "KEEP" : (d < -noise) ? "REVERT" : "INCONCLUSIVE"
    printf "%+.1f%% vs main %s  %s", d, b, v }'
}

pr_url() { # the open PR for a branch, if gh is here and knows one
  command -v gh >/dev/null 2>&1 || return 0
  [ -n "$1" ] && [ "$1" != main ] && [ "$1" != "?" ] || return 0
  gh pr list --head "$1" --state all --limit 1 --json url --jq '.[0].url // ""' 2>/dev/null || true
}

notify_bench() { # notify_bench <run-dir> -- the run as one message for #bench
  local run="$1" score sha branch who note pr vm
  [ -n "$(notify_url bench)" ] || return 0
  score=$(sed -n 's/^score=//p' "$run/meta"); sha=$(sed -n 's/^sha=//p' "$run/meta")
  branch=$(sed -n 's/^branch=//p' "$run/meta"); who=$(sed -n 's/^who=//p' "$run/meta")
  note=$(sed -n 's/^note=//p' "$run/meta")
  vm=$(vs_main "$score")
  pr=$(pr_url "$branch")
  {
    printf '📊 **%s**%s\n' "$score" "${vm:+  ($vm)}"
    printf '%s by %s%s  `%s`%s\n' "$branch" "$who" "${note:+ — \"$note\"}" "$sha" "${pr:+  $pr}"
    # hosts.txt: "<host> (<roles>)" then "  cpu avg 94% ..." / "  procs  isuride 142% ..."
    [ -s "$run/hosts.txt" ] && awk '
      /^[^ ]/ { h = $1; next }
      /^  cpu / { c[h] = $3 }
      /^  procs/ { p[h] = $2 " " $3 }
      END { for (k in c) printf "%s cpu %s%s\n", k, c[k], (p[k] == "" ? "" : " (" p[k] ")") }' "$run/hosts.txt" | sort | sed 's/^/· /'
    # alp.txt rows: | COUNT | METHOD | URI | MIN | MAX | SUM | ...
    [ -s "$run/alp.txt" ] && awk -F'|' 'NF > 7 && $2 !~ /COUNT/ && $2 ~ /[0-9]/ {
        gsub(/^ +| +$/, "", $3); gsub(/^ +| +$/, "", $4); gsub(/^ +| +$/, "", $7)
        printf "· %s %s  %ss\n", $3, $4, $7; if (++n == 3) exit }' "$run/alp.txt"
  } | notify bench
}
