# shellcheck shell=bash
# isukit lib/rules.sh — ISUCON2026 regulation enforcement: refusals, not docs.
# Sourced by ../isukit (right after core.sh); not meant to run on its own.

# --- time helpers

rules_epoch() { # rules_epoch <ISO8601 e.g. 2026-10-31T18:00:00+0900> -> epoch on stdout
  date -d "$1" +%s 2>/dev/null || date -j -f '%Y-%m-%dT%H:%M:%S%z' "$1" +%s 2>/dev/null
}

rules_in_contest() { # 0 if CONTEST_START <= now <= CONTEST_END, 1 otherwise/unset/unparseable
  local s e now
  [ -n "${CONTEST_START:-}" ] && [ -n "${CONTEST_END:-}" ] || return 1
  s=$(rules_epoch "$CONTEST_START") || { warn "CONTEST_START='$CONTEST_START' did not parse — treating as not in contest"; return 1; }
  e=$(rules_epoch "$CONTEST_END") || { warn "CONTEST_END='$CONTEST_END' did not parse — treating as not in contest"; return 1; }
  now=$(date +%s)
  [ "$now" -ge "$s" ] && [ "$now" -le "$e" ]
}

rules_after_contest() { # 0 if CONTEST_END set, parses, and now > it
  local e now
  [ -n "${CONTEST_END:-}" ] || return 1
  e=$(rules_epoch "$CONTEST_END") || { warn "CONTEST_END='$CONTEST_END' did not parse — treating as not after contest"; return 1; }
  now=$(date +%s)
  [ "$now" -gt "$e" ]
}

# --- override hatch: a human typing a reason, logged, not a silent bypass

rules_override() { # rules_override <guard-name> <message> -> 0 if overridden, 1 if not
  [ -n "${ISUKIT_OVERRIDE:-}" ] || return 1
  warn "OVERRIDE [$1]: $2"
  warn "  reason: $ISUKIT_OVERRIDE"
  printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(who_am_i)" "$1" "$ISUKIT_OVERRIDE" \
    >> "$STATE/overrides.log"
  return 0
}

# --- GUARD G1 (E4: 提供されていないサーバーへの直接アクセス禁止)

rules_allow_host() { # rules_allow_host <host> -- die if not a host this team was given
  local h="$1" x roles
  [ "$h" = "local" ] && return 0
  for x in $(hosts_all); do
    [ "$h" = "$x" ] || continue
    if rules_in_contest; then
      roles=",$(host_roles "$h"),"
      case "$roles" in *,bench,*)
        rules_override host-allow "connecting to bench host '$h' during the contest window" && return 0
        die "refusing to connect to '$h' — not a host this team was given.
  ISUCON2026 禁止事項: 提供されていないサーバーへの直接アクセス（ベンチマーカーへのログイン試行を含む）は失格。
  '$h' is registered with the 'bench' role and the contest window is active — no ssh to the benchmarker while it may be running.
  if the day-of manual says otherwise: ISUKIT_OVERRIDE='<reason>' isukit ..."
        ;;
      esac
    fi
    return 0
  done
  for x in "${APP:-}" ${EXTRA_HOSTS:-}; do
    [ -n "$x" ] && [ "$h" = "$x" ] && return 0
  done
  if [ -n "${BENCH:-}" ] && [ "$h" = "$BENCH" ] && [ "${BENCH_MODE:-auto}" = "auto" ] && ! rules_in_contest; then
    return 0
  fi
  rules_override host-allow "connecting to '$h', not in the registered host set" && return 0
  die "refusing to connect to '$h' — not a host this team was given.
  ISUCON2026 禁止事項: 提供されていないサーバーへの直接アクセス（ベンチマーカーへのログイン試行を含む）は失格。
  registered hosts: $(hosts_all | tr '\n' ' ')${APP:+ $APP}${EXTRA_HOSTS:+ $EXTRA_HOSTS}
  if the day-of manual says otherwise: ISUKIT_OVERRIDE='<reason>' isukit ..."
}

# --- GUARD G2 (contest clock) -- called from lib/team.sh's lock_guard as its first line

rules_clock_guard() { # rules_clock_guard <what> -- warns before CONTEST_START, dies after CONTEST_END
  rules_after_contest || {
    if [ -n "${CONTEST_START:-}" ]; then
      local s now
      s=$(rules_epoch "$CONTEST_START") 2>/dev/null || return 0
      now=$(date +%s)
      if [ "$now" -lt "$s" ]; then
        warn "contest has not started yet (CONTEST_START=$CONTEST_START) — '$1' will change servers before T+0"
      fi
    fi
    return 0
  }
  rules_override contest-clock "running '$1' after CONTEST_END ($CONTEST_END)" && return 0
  die "競技終了時刻 ($CONTEST_END) を過ぎています — '$1' はサーバーを変更します。
  ISUCON2026: 競技終了後、主催者がインスタンスを再起動して追試を行います。
  終了後にサーバーへ変更を加えると追試の再現性を壊し、失格の対象です。
  read-only commands (show, score, alp, slow, rules check) still work."
}

# --- GUARD G4 (E1: 終了時刻まで競技内容の公開・共有禁止, repo visibility half)

rules_repo_private() { # 0 if private or unverifiable (warns), dies if public without an override
  command -v gh >/dev/null || { warn "gh not found — cannot verify the repo is private"; return 0; }
  local v
  v=$(gh repo view --json visibility -q .visibility 2>/dev/null) || { warn "could not read repo visibility (no gh auth / not a GitHub remote?) — cannot verify it is private"; return 0; }
  [ "$v" = "PRIVATE" ] && return 0
  rules_override repo-visibility "repo visibility is $v, not PRIVATE" && return 0
  die "this repository is $v. ISUCON2026 禁止事項: 競技終了時刻まで競技内容を公開・共有してはならない（失格）.
  make it private:  gh repo edit --visibility private --accept-visibility-change-consequences"
}

# --- `isukit rules check|baseline|show`

cmd_rules() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    check)    cmd_rules_check ;;
    baseline) cmd_rules_baseline "$@" ;;
    show)     cmd_rules_show ;;
    langs)    cmd_rules_langs ;;
    *) die "usage: isukit rules {check|baseline [sha]|show|langs}" ;;
  esac
}

# --- reboot survivability (R1-R9, remote/rules-reboot.sh) + implementation enumeration

rules_host_findings() { # "<host>\t<what>\t<how>" per finding, every host by its roles (FIX only)
  local h roles unit extra web db multi=0
  [ "$(hosts_all | grep -c .)" -gt 1 ] && multi=1
  for h in $(hosts_all); do
    roles=",$(host_roles "$h"),"
    unit="" extra="" web="" db=""
    case "$roles" in *,app,*) unit="${APP_UNIT:-}"; extra="${EXTRA_UNITS:-}" ;; esac
    case "$roles" in *,web,*) web=$(host_fact "$h" WEB_SERVER) ;; esac
    case "$roles" in *,db,*)  db=$(host_fact "$h" DB_SERVER) ;; esac
    { printf 'APP_UNIT=%q\nEXTRA_UNITS=%q\nWEB_SERVER=%q\nDB_SERVER=%q\nMULTI_HOST=%s\nINIT_PATH=%q\n' \
        "$unit" "$extra" "$web" "$db" "$multi" "${INIT_PATH:-/initialize}"; remote_script rules-reboot.sh; } \
      | rsh_stdin "$h" 2>/dev/null \
      | awk -F'|' -v h="$h" '$1 == "FIX" { printf "%s\t%s\t%s\n", h, $2, $3 }' \
      || printf '%s\t%s\t%s\n' "$h" "could not check this host" "ssh ${SSH_OPTS:-} $h true"
  done
  return 0
}

rules_impl_report() { # "<unit>\t<enabled|disabled>\t<active|inactive>" per reference-impl unit on the app host
  local h
  h=$(hosts_with app | head -1); [ -n "$h" ] || h="${APP:-local}"
  { printf 'APP_UNIT=%q\n' "${APP_UNIT:-}"; remote_script rules-reboot.sh; } \
    | rsh_stdin "$h" 2>/dev/null \
    | awk -F'|' '$1 == "IMPL" { printf "%s\t%s\t%s\n", $2, $3, $4 }'
}

rules_impl_lang_of_unit() { # rules_impl_lang_of_unit <unit> -> go/perl/php/python/ruby/rust/nodejs, or nothing (rc 1)
  local u="$1" lang
  for lang in go perl php python ruby rust nodejs; do
    case "$u" in *-"$lang".service|*."$lang".service) printf '%s\n' "$lang"; return 0 ;; esac
  done
  case "$u" in
    *-golang.service|*.golang.service) printf 'go\n';     return 0 ;;
    *-py.service|*.py.service)         printf 'python\n'; return 0 ;;
    *-rb.service|*.rb.service)         printf 'ruby\n';   return 0 ;;
    *-node.service|*.node.service)     printf 'nodejs\n'; return 0 ;;
  esac
  return 1
}

cmd_rules_langs() { # isukit rules langs -- enumerate reference-implementation units; this team has decided Go
  load
  local h rows cur new_candidate enabled_units enabled_n unit lang
  h=$(hosts_with app | head -1); [ -n "$h" ] || h="${APP:-local}"
  say "rules langs: reference-implementation units on $h"
  rows=$(rules_impl_report)
  if [ -z "$rows" ]; then
    warn "  no reference-implementation units found on $h (expects ...-<lang>.service or ...<lang>.service)"
  else
    printf '%s\n' "$rows" | awk -F'\t' -v au="${APP_UNIT:-}" '{
      printf "  %-28s %-9s %-9s%s\n", $1, $2, $3, ($1 == au ? "   <- APP_UNIT" : "")
    }'
  fi
  enabled_units=$(printf '%s\n' "$rows" | awk -F'\t' '$2 == "enabled" { print $1 }')
  enabled_n=$(printf '%s\n' "$enabled_units" | grep -c . || true)

  cur="${APP_UNIT:-$(printf '%s\n' "$enabled_units" | head -1)}"
  new_candidate=$(printf '%s\n' "$rows" | awk -F'\t' -v c="$cur" '$1 != c && $1 != "" { print $1; exit }')
  echo "  switch command: sudo systemctl disable --now ${cur:-<old>} && sudo systemctl enable --now ${new_candidate:-<new>}"
  case "$new_candidate" in *php*)
    echo "    + nginx needs its own php site enabled: sudo ln -s /etc/nginx/sites-available/<the php conf> /etc/nginx/sites-enabled/ && sudo systemctl reload nginx" ;;
  esac

  echo "  regulations guarantee nothing about the relative performance of the reference implementations（「その各々の性能が一致することは保証されない」）— switching the reference implementation is a legitimate, sometimes large, score lever that costs no application code."
  echo "  this team has already decided: Go (IMPL_LANG='${IMPL_LANG:-go}'). rules langs is NOT a \"pick a language\" tool here — its job is to catch the accident: someone enables another implementation to compare it, forgets to disable --now it, and the reboot then lets the two race for the port."

  if [ "$enabled_n" = 1 ]; then
    unit=$(printf '%s\n' "$enabled_units" | head -1)
    lang=$(rules_impl_lang_of_unit "$unit") || lang=""
    if [ -n "$lang" ]; then
      if grep -q '^IMPL_LANG=' isukit.conf 2>/dev/null; then
        sed -i.bak "s|^IMPL_LANG=.*|IMPL_LANG='$lang'|" isukit.conf; rm -f isukit.conf.bak
      else
        printf "IMPL_LANG='%s'\n" "$lang" >> isukit.conf
      fi
      say "  IMPL_LANG='$lang' written to isukit.conf (exactly one implementation enabled: $unit)"
    fi
  elif [ "$enabled_n" -gt 1 ]; then
    warn "  $enabled_n implementations enabled at once ($enabled_units) — not rewriting IMPL_LANG; this is exactly the accident this command exists to catch. disable the ones you are not using."
  fi
}

cmd_rules_baseline() {
  load
  local arg="${1:-}"
  if [ -z "$arg" ]; then
    if [ -n "${BASELINE_SHA:-}" ]; then
      say "BASELINE_SHA=$BASELINE_SHA"
    else
      say "BASELINE_SHA is unset. the repo's own first commit:"
      git rev-list --max-parents=0 HEAD 2>/dev/null | tail -1
    fi
    return 0
  fi
  local sha
  sha=$(git rev-parse --verify "$arg" 2>/dev/null) || die "'$arg' does not resolve to a commit"
  if grep -q '^BASELINE_SHA=' isukit.conf 2>/dev/null; then
    sed -i.bak "s|^BASELINE_SHA=.*|BASELINE_SHA='$sha'|" isukit.conf; rm -f isukit.conf.bak
  else
    printf "BASELINE_SHA='%s'\n" "$sha" >> isukit.conf
  fi
  say "BASELINE_SHA=$sha written to isukit.conf"
}

cmd_rules_check() {
  load
  local fail=0
  say "rules check: auditing against the ISUCON2026 regulations (nothing is changed)"

  echo "== assets (変更禁止: JS/CSS/media)"
  if [ -n "${BASELINE_SHA:-}" ]; then
    local hit any=0
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      case "$hit" in .isukit/*|node_modules/*|vendor/*|*/node_modules/*|*/vendor/*) continue ;; esac
      echo "  $hit   modified since baseline — JS/CSS/media content may not be changed (失格)"
      any=1; fail=1
    done < <(git diff --name-only --diff-filter=MD "$BASELINE_SHA" -- \
      '*.js' '*.mjs' '*.cjs' '*.css' '*.scss' '*.png' '*.jpg' '*.jpeg' '*.gif' '*.svg' '*.webp' '*.ico' '*.bmp' \
      '*.mp4' '*.webm' '*.mov' '*.mp3' '*.wav' '*.woff' '*.woff2' '*.ttf' '*.eot' 2>/dev/null)
    [ "$any" = 1 ] || say "  no asset changes since baseline"
  else
    warn "  BASELINE_SHA is unset — run: isukit rules baseline <sha>"
  fi

  echo "== reproducibility (追試)"
  if [ -f "$STATE/scores.tsv" ]; then
    local best cold
    best=$(awk -F'\t' '$3 ~ /^-?[0-9]+(\.[0-9]+)?$/ { if ($3+0 > b+0 || n == 0) { b = $3; n = 1 } } END { print b+0 }' "$STATE/scores.tsv")
    cold=$(awk -F'\t' '$4 ~ /^cold:/ { c = $3 } END { print c }' "$STATE/scores.tsv")
    if [ -z "$cold" ]; then
      echo "  no cold re-run recorded. 追試は再起動後に行われます — isukit finalize を競技時間内に最低一度は通すこと."
      fail=1
    else
      awk -v b="$best" -v c="$cold" -v m="${REPRO_MIN:-0.8}" 'BEGIN {
        ratio = (b == 0) ? 0 : c / b
        printf "  best=%s cold=%s ratio=%.3f (floor %.3f)\n", b, c, ratio, m
        exit (ratio >= m) ? 0 : 1
      }' || { echo "  登録スコアに近い結果が再現されなければ失格です。ウォームキャッシュ前提のスコアを登録しないこと。"; fail=1; }
    fi
  else
    echo "  no $STATE/scores.tsv yet — no bench runs recorded"
    fail=1
  fi

  echo "== egress (E3: 処理の外部委託禁止)"
  local urls u known=0
  urls=$( { [ -n "${ENV_FILE:-}" ] && [ -f "$ENV_FILE" ] && cat "$ENV_FILE"; find etc -type f -exec cat {} + 2>/dev/null; } \
    | grep -oE 'https?://[^"'"'"' ]+|[A-Za-z0-9.-]+:[0-9]+' 2>/dev/null | sort -u || true)
  for u in $urls; do
    case "$u" in *localhost*|*127.0.0.1*|*::1*|unix:*) continue ;; esac
    for h in $(hosts_all) ${APP:-} ${EXTRA_HOSTS:-}; do
      case "$u" in *"$h"*) known=1 ;; esac
    done
    [ "$known" = 1 ] && { known=0; continue; }
    warn "  $u — host outside the registered set. monitoring/testing from an external machine is fine; delegating request processing during the benchmark is not (E3)."
  done

  echo "== repo visibility"
  if rules_repo_private 2>&1 | sed 's/^/  /'; then
    :
  else
    echo "  FAIL: repository is not private (see above)"
    fail=1
  fi

  echo "== maintenance endpoint (${INIT_PATH:-/initialize})"
  if [ -z "${APP:-}" ] || [ "$APP" = "local" ]; then
    warn "  APP is local/unset — skipping the HTTP check"
  else
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' -m "${INIT_TIMEOUT:-30}" -X POST "http://$APP:${FINAL_APP_PORT:-80}${INIT_PATH:-/initialize}" 2>/dev/null)
    case "$code" in 404|405) code=$(curl -s -o /dev/null -w '%{http_code}' -m "${INIT_TIMEOUT:-30}" "http://$APP:${FINAL_APP_PORT:-80}${INIT_PATH:-/initialize}" 2>/dev/null) ;; esac
    case "$code" in
      2??) echo "  $code — ok" ;;
      *) echo "  $code — maintenance endpoint did not return 2xx"; fail=1 ;;
    esac
  fi

  echo "== contest mode"
  if [ -z "${CONTEST_START:-}" ] || [ -z "${CONTEST_END:-}" ]; then
    warn "  contest window not set — the clock guard and the benchmarker-host interlock are inactive. set CONTEST_START/CONTEST_END in isukit.conf before the contest."
  else
    say "  CONTEST_START=$CONTEST_START CONTEST_END=$CONTEST_END"
  fi

  echo "== reboot survivability (再起動試験で落ちるもの)"
  local findings
  findings=$(rules_host_findings)
  if [ -n "$findings" ]; then
    printf '%s\n' "$findings" | awk -F'\t' '{ printf "  FAIL %-16s %s\n       -> %s\n", $1, $2, $3 }'
    fail=1
  else
    say "  nothing found that would not come back after a reboot"
  fi

  echo "== implementation language (IMPL_LANG)"
  if [ -n "${IMPL_LANG:-}" ]; then
    local irows enabled_units enabled_n cur_lang cur_unit
    irows=$(rules_impl_report)
    enabled_units=$(printf '%s\n' "$irows" | awk -F'\t' '$2 == "enabled" { print $1 }')
    enabled_n=$(printf '%s\n' "$enabled_units" | grep -c . || true)
    if [ "$enabled_n" = 1 ]; then
      cur_unit=$(printf '%s\n' "$enabled_units" | head -1)
      cur_lang=$(rules_impl_lang_of_unit "$cur_unit") || cur_lang=""
      if [ -n "$cur_lang" ] && [ "$cur_lang" != "$IMPL_LANG" ]; then
        echo "  IMPL_LANG='$IMPL_LANG' but the enabled implementation is $cur_unit ($cur_lang) — half-finished language switch?"
        fail=1
      else
        say "  IMPL_LANG='$IMPL_LANG' matches the enabled implementation ($cur_unit)"
      fi
    elif [ "$enabled_n" -gt 1 ]; then
      say "  IMPL_LANG drift check skipped — multiple implementations enabled, see reboot survivability above"
    else
      warn "  IMPL_LANG='$IMPL_LANG' set but no enabled reference-implementation unit found to compare against"
    fi
  else
    warn "  IMPL_LANG is unset — run: isukit rules langs (this team's default is go)"
  fi

  if [ "$fail" = 0 ]; then
    say "nothing failing"
    return 0
  fi
  return 1
}

cmd_rules_show() {
  cat <<'EOF'
ISUCON2026 regulation clause -> what isukit enforces
=====================================================

E4  提供されていないサーバーへの直接アクセス禁止
    （ベンチマーカーへのログイン試行を含む）
    guard: rules_allow_host refuses ssh/scp/rsync to any host not in
           isukit.hosts / APP / EXTRA_HOSTS, and refuses the bench host
           during the contest window unless BENCH_MODE=auto and the
           contest hasn't started.

競技終了時刻後にサーバーへ変更を加えること（追試の再現性を壊す）
    guard: rules_clock_guard (wired into lock_guard) dies on any
           server-changing command after CONTEST_END. read-only commands
           (show, score, alp, slow, rules check) are unaffected.

E1  終了時刻まで競技内容を公開・共有してはならない
    guard: notify() drops (fails closed) any Discord post during the
           contest window unless NOTIFY_PRIVATE_ACK names a confirmed
           members-only channel.
    guard: rules_repo_private refuses `isukit ship`'s git push, and
           `isukit rules check`, if the GitHub repo is not PRIVATE.

変更禁止: JS/CSS/メディアコンテンツ
    check: isukit rules check diffs the working tree against
           BASELINE_SHA for *.js/*.css/images/video/audio/fonts.

追試で再現されないスコアの登録（ウォームキャッシュ前提等）
    check: isukit rules check compares the last 'cold:'-noted score
           against the best recorded score, floor REPRO_MIN.

E3  処理を外部（ベンチマーク対象外のサーバー）へ委託すること
    check: isukit rules check greps the env file and etc/ for URLs
           outside the registered host set (WARN only — monitoring /
           testing from elsewhere is explicitly permitted, see below).

メンテナンス用コマンド（/initialize 等）が機能し続けること
    check: isukit rules check POSTs INIT_PATH on APP and expects 2xx.

再起動試験で落ちるもの (reboot survivability, R1-R9)
    check: isukit rules check runs remote/rules-reboot.sh on every host
           (reboot survivability section above). a FAIL here means a cold
           reboot changes what's running or loses data; the memcached and
           innodb_flush_log_at_trx_commit findings are informational only.
    command: isukit rules langs enumerates the reference-implementation
           units directly (enabled/disabled, active/inactive) and shows
           the switch command.

明示的に許可されていること (explicitly permitted — teams lose real score
self-censoring over things the regulations plainly allow):
    - 初期実装をベースにしてもしなくてもよい（丸ごと書き直してよい）
    - 提供される初期実装の言語は Go / Perl / PHP / Python / Ruby / Rust /
      Node.js、各々の性能が一致することは保証されない
      → 言語の乗り換えは正当な高速化手段 (see: isukit rules langs)
    - ミドルウェアの差し替え・設定変更、サーバーの役割変更
    - スキーマ変更・インデックス追加、DBミドルウェアの差し替え
    - キャッシュ機構の追加、遅延書き込みのためのジョブキューの追加
      （ただし「計測中に書き込まれたデータが再起動後に取得できること」は
      守る必要がある。R8 参照）
    - AIを活用したコード分析・生成

変更禁止、ただし境界に注意:
    - アクセス先のURI — ただしサーバー側で生成する部分（IDなど）は、
      文字種を変えない範囲で自由に生成してよい。[0-9a-zA-Z_] のIDを
      別方式で生成するのは可、数値IDをULIDにするのは不可。
    - レスポンス（HTML DOM / JSONオブジェクト）の構造 — ただし表示に
      影響しない範囲での空白文字の増減は許可される。HTMLのminify・
      gzipは可。
    - JavaScript/CSSファイルの内容 — ファイルの中身が禁止であって配信
      方法ではない。nginxから静的配信する・gzip/brotliをかける・
      Cache-Controlを付けるのは内容を変えていないので可。逆に
      JS/CSSそのものをminifyするのはファイル内容の変更で不可。
    - 画像・動画等メディアファイルの内容 — WebP等への再エンコードは
      内容の変更で不可。

human: nobody can automate this
    - what you actually do with ISUKIT_OVERRIDE is on you — every use is
      logged to .isukit/overrides.log with who and why.
    - reading the day-of manual, the regulation PDF, and the Discord
      announcements is still on a person.
EOF
}
