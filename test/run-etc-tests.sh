#!/bin/bash
# Runs remote/etc-adopt.sh and remote/etc-status.sh as-is, plus LOGS_SCRIPT
# (extracted verbatim from ../isukit), against a throwaway /etc tree and asserts
# the symlink-management
# contract: adopt moves configs into <repo>/etc and links them back, is idempotent,
# rolls back a tier that fails its check, lets the repo win on a fresh box, and
# `logs on` -> `logs off` leaves the linked files byte-identical and still linked.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISUKIT="$HERE/../isukit"
ADOPT_SH="$HERE/../remote/etc-adopt.sh"
STATUS_SH="$HERE/../remote/etc-status.sh"
VERBOSE=0
for a in "$@"; do [ "$a" = "-v" ] && VERBOSE=1; done

extract() { # extract <VAR> -- the body of a VAR='...' heredoc-style assignment
  awk -v v="$1" '
    $0 == v "='"'"'" { grab=1; next }
    grab && /^'"'"'$/ { exit }
    grab { print }
  ' "$ISUKIT"
}
LOGS="$(extract LOGS_SCRIPT)"
[ -n "$LOGS" ] || { echo "FATAL: could not extract LOGS_SCRIPT from $ISUKIT" >&2; exit 2; }
for f in "$ADOPT_SH" "$STATUS_SH"; do
  [ -f "$f" ] || { echo "FATAL: missing $f" >&2; exit 2; }
done

T=""
BIN="$(mktemp -d "${TMPDIR:-/tmp}/isukit-etc-bin.XXXXXX")"
trap 'rm -rf "$BIN" ${T:+"$T"}' EXIT
cp "$HERE/bin/sudo" "$BIN/sudo"
cat > "$BIN/nginx" <<'EOF'
#!/bin/bash
exit "${NGINX_RC:-0}"
EOF
for c in systemctl apparmor_parser; do printf '#!/bin/bash\nexit 0\n' > "$BIN/$c"; done
# mysql answers SELECT @@GLOBAL.x with $MYSQL_LIVE (default 1000 = the fixture's
# max_connections), so the "file values are live" check runs for real.
cat > "$BIN/mysql" <<'EOF'
#!/bin/bash
case "$*" in *@@GLOBAL*) echo "${MYSQL_LIVE:-1000}" ;; esac
exit 0
EOF
chmod +x "$BIN"/*

NGINX_CONF='user www-data;
http {
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
    access_log /var/log/nginx/access.log;
}'
SITE_CONF='server {
    listen 80;
    access_log /var/log/nginx/isucon.log;
}'
MYSQLD_CNF='[mysqld]
max_connections = 1000'

new_tree() { # fresh fake /etc + empty repo under $T
  [ -n "$T" ] && rm -rf "$T"
  T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/isukit-etc.XXXXXX")" && pwd -P)"
  E="$T/etc"; R="$T/repo"
  mkdir -p "$E/nginx/sites-available" "$E/nginx/sites-enabled" "$E/nginx/conf.d" \
    "$E/mysql/mysql.conf.d" "$E/systemd/system" "$E/apparmor.d/local" "$R"
  printf '%s\n' "$NGINX_CONF" > "$E/nginx/nginx.conf"
  printf '%s\n' "$SITE_CONF"  > "$E/nginx/sites-available/isucon.conf"
  ln -s ../sites-available/isucon.conf "$E/nginx/sites-enabled/isucon.conf"
  ln -s /etc/alternatives/my.cnf "$E/mysql/my.cnf"
  printf '%s\n' "$MYSQLD_CNF" > "$E/mysql/mysql.conf.d/mysqld.cnf"
  printf '[mysql]\n' > "$E/mysql/mysql.conf.d/mysql.cnf"
  printf '[Service]\nExecStart=/home/isucon/webapp/go/isu\n' > "$E/systemd/system/isu-go.service"
  printf 'profile mysqld {}\n' > "$E/apparmor.d/usr.sbin.mysqld"
}

OUT=""
# same framing isukit uses: VAR=value lines, then the script, on bash's stdin
run_adopt()  { OUT="$( { printf 'SUDO=\nETC_ROOT=%q\nREPO=%q\nAPP_UNIT=isu-go.service\nTARGETS=\n' "$E" "$R"; cat "$ADOPT_SH"; } | PATH="$BIN:$PATH" bash -s 2>&1)"; }
run_status() { OUT="$( { printf 'ETC_ROOT=%q\nREPO=%q\n' "$E" "$R"; cat "$STATUS_SH"; } | PATH="$BIN:$PATH" bash -s 2>&1)"; }
run_logs()   { OUT="$(printf 'MODE=%s\nAPP_UNIT=isu-go.service\n%s\n' "$1" "${LOGS//\/etc\//$E/}" | PATH="$BIN:$PATH" bash -s 2>&1)"; }

TOTAL=0; PASSED=0; FAILED=""; ERR=""
check() { [ "$@" ] || ERR="$ERR
    failed: [ $* ]"; }
linked_to() { [ -L "$1" ] && [ "$(readlink "$1")" = "$2" ]; }

case_() { # case_ <name> <function>
  TOTAL=$((TOTAL+1)); ERR=""
  "$2"
  if [ -z "$ERR" ]; then
    PASSED=$((PASSED+1)); echo "PASS  $1"
  else
    FAILED="$FAILED $1"; echo "FAIL  $1$ERR"
  fi
  [ "$VERBOSE" = 1 ] && printf '%s\n' "$OUT" | sed 's/^/      | /'
  return 0
}

t_adopt() {
  new_tree
  run_adopt; local rc=$?
  check "$rc" = 0
  check -n "$(linked_to "$E/nginx/nginx.conf" "$R/etc/nginx/nginx.conf" && echo y)"
  check -n "$(linked_to "$E/nginx/sites-available/isucon.conf" "$R/etc/nginx/sites-available/isucon.conf" && echo y)"
  check -n "$(linked_to "$E/mysql/mysql.conf.d/mysqld.cnf" "$R/etc/mysql/mysql.conf.d/mysqld.cnf" && echo y)"
  check -n "$(linked_to "$E/systemd/system/isu-go.service" "$R/etc/systemd/system/isu-go.service" && echo y)"
  # sites-enabled stays the distro's own relative link, now two hops from the repo
  check "$(readlink "$E/nginx/sites-enabled/isucon.conf")" = "../sites-available/isucon.conf"
  # client-only cnf and the alternatives link are not config for the server
  check -f "$E/mysql/mysql.conf.d/mysql.cnf" -a ! -L "$E/mysql/mysql.conf.d/mysql.cnf"
  check "$(readlink "$E/mysql/my.cnf")" = "/etc/alternatives/my.cnf"
  check "$(cat "$R/etc/nginx/nginx.conf")" = "$NGINX_CONF"
  check "$(cat "$E/isukit-orig/nginx/nginx.conf")" = "$NGINX_CONF"
  check -n "$(grep -F "$R/etc/mysql/** r," "$E/apparmor.d/local/usr.sbin.mysqld")"
  check -f "$R/etc/apparmor.d/local/usr.sbin.mysqld"
}

t_idempotent() {
  new_tree
  run_adopt
  local before; before="$(cd "$T" && find . -exec ls -ld {} + | awk '{print $1, $NF}' | sort)"
  run_adopt; local rc=$?
  check "$rc" = 0
  check -z "$(printf '%s\n' "$OUT" | grep '^linked:')"
  check "$(grep -cF "$R/etc/mysql/** r," "$E/apparmor.d/local/usr.sbin.mysqld")" = 1
  check "$(cd "$T" && find . -exec ls -ld {} + | awk '{print $1, $NF}' | sort)" = "$before"
}

t_status() {
  new_tree
  run_status; check "$?" = 3
  run_adopt
  run_status; local rc=$?
  check "$rc" = 0
  check "$(printf '%s\n' "$OUT" | grep -c '^linked ')" = 4
  # a file added to the repo but never linked must be reported, not ignored
  mkdir -p "$R/etc/nginx/conf.d"; printf "x\n" > "$R/etc/nginx/conf.d/extra.conf"
  run_status; rc=$?
  check "$rc" = 1
  check -n "$(printf '%s\n' "$OUT" | grep "^NO TARGET .*conf.d/extra.conf")"
}

t_logs_roundtrip() {
  new_tree
  run_adopt
  run_logs on; check "$?" = 0
  check -n "$(linked_to "$E/nginx/nginx.conf" "$R/etc/nginx/nginx.conf" && echo y)"
  check -n "$(linked_to "$E/nginx/sites-available/isucon.conf" "$R/etc/nginx/sites-available/isucon.conf" && echo y)"
  check -f "$E/nginx/conf.d/00-isukit.conf"
  check -n "$(grep '#isukit# access_log' "$R/etc/nginx/sites-available/isucon.conf")"
  check -n "$(grep '#isukit# access_log' "$R/etc/nginx/nginx.conf")"
  run_logs off; check "$?" = 0
  check -n "$(linked_to "$E/nginx/nginx.conf" "$R/etc/nginx/nginx.conf" && echo y)"
  check -n "$(linked_to "$E/nginx/sites-available/isucon.conf" "$R/etc/nginx/sites-available/isucon.conf" && echo y)"
  check ! -e "$E/nginx/conf.d/00-isukit.conf"
  check "$(cat "$R/etc/nginx/nginx.conf")" = "$NGINX_CONF"
  check "$(cat "$R/etc/nginx/sites-available/isucon.conf")" = "$SITE_CONF"
  check -z "$(find "$E" "$R" -name '*.isukit-tmp')"
}

t_nginx_rollback() {
  new_tree
  NGINX_RC=1 run_adopt; local rc=$?
  export -n NGINX_RC 2>/dev/null || true
  check "$rc" = 1
  check -f "$E/nginx/nginx.conf" -a ! -L "$E/nginx/nginx.conf"
  check "$(cat "$E/nginx/nginx.conf")" = "$NGINX_CONF"
  check ! -e "$R/etc/nginx/nginx.conf"
  check -f "$E/nginx/sites-available/isucon.conf" -a ! -L "$E/nginx/sites-available/isucon.conf"
  # the other tiers are independent and stay adopted
  check -n "$(linked_to "$E/mysql/mysql.conf.d/mysqld.cnf" "$R/etc/mysql/mysql.conf.d/mysqld.cnf" && echo y)"
}

t_repo_wins() {
  new_tree
  # the repo was populated on a previous box; this box's nginx.conf differs
  mkdir -p "$R/etc/nginx"
  printf 'tuned\n' > "$R/etc/nginx/nginx.conf"
  run_adopt; local rc=$?
  check "$rc" = 0
  check -n "$(linked_to "$E/nginx/nginx.conf" "$R/etc/nginx/nginx.conf" && echo y)"
  check "$(cat "$E/nginx/nginx.conf")" = "tuned"
  check "$(cat "$E/isukit-orig/nginx/nginx.conf")" = "$NGINX_CONF"
  check -n "$(printf '%s\n' "$OUT" | grep 'REPO COPY WINS')"
}

t_backup_outside_include_dirs() {
  new_tree
  # some images ship a plain file in sites-enabled/ rather than a link
  rm "$E/nginx/sites-enabled/isucon.conf"
  printf '%s\n' "$SITE_CONF" > "$E/nginx/sites-enabled/plain.conf"
  run_adopt; check "$?" = 0
  check -n "$(linked_to "$E/nginx/sites-enabled/plain.conf" "$R/etc/nginx/sites-enabled/plain.conf" && echo y)"
  # nothing but the link may sit in an include dir, or nginx loads it as config
  check "$(ls "$E/nginx/sites-enabled")" = "plain.conf"
  check -z "$(find "$E" -name '*.orig')"
  check -f "$E/isukit-orig/nginx/sites-enabled/plain.conf"
}

t_readopt_keeps_current() {
  new_tree
  run_adopt
  # a package upgrade replaced the link with a fresh plain file
  rm "$E/nginx/nginx.conf"; printf 'from-upgrade\n' > "$E/nginx/nginx.conf"
  run_adopt; check "$?" = 0
  local newest
  newest=$(ls "$E"/isukit-orig/nginx/nginx.conf.* 2>/dev/null | tail -1)
  check -n "$newest"
  check "$(cat "$newest")" = "from-upgrade"
  check "$(cat "$E/isukit-orig/nginx/nginx.conf")" = "$NGINX_CONF"
  check -n "$(printf '%s\n' "$OUT" | grep -F "kept as $newest")"
}

t_rollback_uses_this_runs_backup() {
  new_tree
  run_adopt
  rm "$E/nginx/nginx.conf"; printf 'from-upgrade\n' > "$E/nginx/nginx.conf"
  NGINX_RC=1 run_adopt; check "$?" = 1
  check -f "$E/nginx/nginx.conf" -a ! -L "$E/nginx/nginx.conf"
  check "$(cat "$E/nginx/nginx.conf")" = "from-upgrade"
}

t_mysql_value_not_live() {
  new_tree
  MYSQL_LIVE=151 run_adopt; check "$?" = 1
  check -n "$(printf '%s\n' "$OUT" | grep 'max_connections is 1000 in the linked file but 151 live')"
  check -f "$E/mysql/mysql.conf.d/mysqld.cnf" -a ! -L "$E/mysql/mysql.conf.d/mysqld.cnf"
  check "$(cat "$E/mysql/mysql.conf.d/mysqld.cnf")" = "$MYSQLD_CNF"
  # nginx is an independent tier and stays adopted
  check -n "$(linked_to "$E/nginx/nginx.conf" "$R/etc/nginx/nginx.conf" && echo y)"
}

t_mysql_unreadable() {
  new_tree
  if [ "$(id -u)" = 0 ]; then return 0; fi   # root reads through chmod 000
  mkdir -p "$R/etc/mysql/mysql.conf.d"
  printf '%s\n' "$MYSQLD_CNF" > "$R/etc/mysql/mysql.conf.d/mysqld.cnf"
  chmod 000 "$R/etc/mysql/mysql.conf.d/mysqld.cnf"
  run_adopt; local rc=$?
  chmod 644 "$R/etc/mysql/mysql.conf.d/mysqld.cnf"
  check "$rc" = 1
  check -n "$(printf '%s\n' "$OUT" | grep 'cannot read')"
  check -f "$E/mysql/mysql.conf.d/mysqld.cnf" -a ! -L "$E/mysql/mysql.conf.d/mysqld.cnf"
}

case_ adopt-links-discovered-configs t_adopt
case_ adopt-is-idempotent            t_idempotent
case_ status-reports-link-state      t_status
case_ logs-on-off-keeps-links        t_logs_roundtrip
case_ nginx-failure-rolls-back-tier  t_nginx_rollback
case_ repo-copy-wins-on-fresh-box    t_repo_wins
case_ backup-outside-include-dirs    t_backup_outside_include_dirs
case_ readopt-keeps-current-version  t_readopt_keeps_current
case_ rollback-uses-this-runs-backup t_rollback_uses_this_runs_backup
case_ mysql-value-not-live-rollback  t_mysql_value_not_live
case_ mysql-unreadable-rollback      t_mysql_unreadable

echo "$TOTAL fixtures, $PASSED passed, $((TOTAL-PASSED)) failed"
[ -z "$FAILED" ]
