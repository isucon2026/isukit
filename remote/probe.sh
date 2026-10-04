#!/bin/bash
# Runs ON EVERY HOST, sent by `isukit probe` over `ssh host bash -s`.
#
# The whole point of the kit: interrogates the RUNNING SERVER, never the repo,
# and prints KEY=value lines (%q-quoted) that isukit saves as the manifest.
#
# Inputs (isukit prepends them as VAR=value lines):
#   APP_UNIT_OVERRIDE  the app unit to use instead of the scored pick

set -u
S() { printf "%s=%s\n" "$1" "$(printf "%q" "$2")"; }
SUDO=""; sudo -n true 2>/dev/null && SUDO="sudo -n"

# --- machine
S HOST_CPUS  "$(nproc 2>/dev/null || echo ?)"
S HOST_MEM   "$(free -m 2>/dev/null | awk "/^Mem:/{print \$2\"MB\"}")"
S HOST_OS    "$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"

# --- locally-provisioned systemd units (fragment under /etc/systemd/system).
# This is the year-agnostic hook: catches isuride-go.service, isucondition.go.service,
# xsuportal-api-golang.service, isuports.service alike, without name guessing.
UNITS=$(systemctl list-units --type=service --all --no-legend --plain 2>/dev/null | awk "{print \$1}" \
  | while read -r u; do
      f=$(systemctl show -p FragmentPath --value "$u" 2>/dev/null)
      [ "${f#/etc/systemd/system/}" != "$f" ] && echo "$u"
    done | sort -u | tr "\n" " ")
S UNITS_LOCAL "$UNITS"
ACTIVE=""; for u in $UNITS; do systemctl is-active --quiet "$u" && ACTIVE="$ACTIVE $u"; done
S UNITS_ACTIVE "${ACTIVE# }"

# --- introspect the active app unit: gives workdir, binary, env file, user.
# Scored, not first-match-wins: alphabetical UNITS_LOCAL order used to hand this
# to whatever infra unit sorted first (aws-env-*, blackauth, isupipe-cache).
DENY_PAT="nginx* mysql* mariadb* redis* postgres* docker* containerd* envoy* memcached* aws-* cloud-init* systemd-* ssh* sshd* cron* getty* dbus* snap* unattended* chrony* ntp* rsyslog* datadog* td-agent* filebeat* node_exporter* netdata* envcheck* env-checker* blackauth* *mock* *pdns* *powerdns* *bench*"
is_denied() {
  local n="$1" p
  for p in $DENY_PAT; do
    # shellcheck disable=SC2053  # $p is a glob from DENY_PAT, matched on purpose
    [[ "$n" == $p ]] && return 0
  done
  return 1
}
CANDS=""; BEST=""; BESTSCORE=""
for u in $ACTIVE; do
  is_denied "$u" && continue
  [ "$(systemctl show -p Type --value "$u" 2>/dev/null)" = "oneshot" ] && continue
  wd=$(systemctl show -p WorkingDirectory --value "$u" 2>/dev/null)
  execraw=$(systemctl show -p ExecStart --value "$u" 2>/dev/null)
  execpath=$(printf "%s" "$execraw" | sed "s/.*path=\([^ ]*\).*/\1/")
  envf=$(systemctl show -p EnvironmentFiles --value "$u" 2>/dev/null | sed "s/ (ignore_errors=[a-z]*)//g")
  usr=$(systemctl show -p User --value "$u" 2>/dev/null)
  sc=0
  [ -n "$wd" ] && [ "${wd#/home/isucon}" != "$wd" ] && sc=$((sc+4))
  [ "${execpath#/home/isucon}" != "$execpath" ] && sc=$((sc+3))
  [ -n "$envf" ] && sc=$((sc+2))
  [ "$usr" = "isucon" ] && sc=$((sc+2))
  [ "${execraw#*compose}" != "$execraw" ] && [ -n "$wd" ] && [ "${wd#/home/isucon}" != "$wd" ] && sc=$((sc+2))
  if [ "${execpath#/opt}" != "$execpath" ] || [ "${execpath#/usr/local/bin}" != "$execpath" ]; then
    [ -z "$wd" ] && sc=$((sc-3))
  fi
  CANDS="$CANDS $u:$sc"
  if [ -z "$BESTSCORE" ] || [ "$sc" -gt "$BESTSCORE" ]; then BEST="$u"; BESTSCORE="$sc"; fi
done
CANDS_SORTED=$(printf "%s\n" $CANDS | sort -t: -k2,2 -rn | tr "\n" " ")
S APP_CANDIDATES "${CANDS_SORTED% }"

APPUNIT="$BEST"; CONFIDENCE="low"
if [ -n "${APP_UNIT_OVERRIDE:-}" ]; then
  APPUNIT="$APP_UNIT_OVERRIDE"; CONFIDENCE="override"
elif [ -n "$BESTSCORE" ] && [ "$BESTSCORE" -ge 6 ]; then
  CONFIDENCE="high"
fi
S APP_UNIT "$APPUNIT"
S APP_UNIT_CONFIDENCE "$CONFIDENCE"
if [ -n "$APPUNIT" ]; then
  S APP_WORKDIR  "$(systemctl show -p WorkingDirectory --value "$APPUNIT")"
  S APP_EXEC_RAW "$(systemctl show -p ExecStart --value "$APPUNIT")"
  S APP_EXEC     "$(systemctl show -p ExecStart --value "$APPUNIT" | sed "s/.*path=\([^ ]*\).*/\1/")"
  S APP_ENVFILE  "$(systemctl show -p EnvironmentFiles --value "$APPUNIT" | sed "s/ (ignore_errors=[a-z]*)//g")"
  S APP_USER     "$(systemctl show -p User --value "$APPUNIT")"
fi

# --- process manager. isucon5-final ran every language under supervisord, so the only
# systemd-visible unit is supervisor.service itself. `systemctl restart supervisor` does
# restart the app, so keeping it as APP_UNIT is correct -- but it is the manager, not the
# app, and the per-program handle is supervisorctl. Say which one this is instead of
# leaving a bare low confidence score to imply it.
PROC_MANAGER=systemd
case "$APPUNIT" in
  supervisor*)
    PROC_MANAGER=supervisor
    S SUPERVISOR_PROGRAMS "$($SUDO supervisorctl status 2>/dev/null | awk "{print \$1}" | tr "\n" " ")"
    ;;
esac
S PROC_MANAGER "$PROC_MANAGER"

# --- env file: path varies (env.sh / env / absent). Find it, do not assume.
ENVF=""
for c in /home/isucon/env.sh /home/isucon/env /home/isucon/.env; do [ -f "$c" ] && ENVF="$c" && break; done
S ENV_FILE "$ENVF"
[ -n "$ENVF" ] && S ENV_KEYS "$(grep -oE "^(export +)?[A-Z_][A-Z0-9_]*" "$ENVF" | sed "s/export *//" | tr "\n" " ")"

# --- source tree on the server + which languages are present
SRC=""
for c in /home/isucon/webapp /home/isucon/*/webapp /home/isucon/private_isu/webapp; do [ -d "$c" ] && SRC="$c" && break; done
S SRC_DIR "$SRC"
[ -n "$SRC" ] && S SRC_LANGS "$(LC_ALL=C ls -1 "$SRC" 2>/dev/null | tr "\n" " ")"
GOMODS=$(find /home/isucon -maxdepth 5 -name go.mod \
  -not -path "*/vendor/*" -not -path "*/bench*" -not -path "*/blackauth*" \
  -not -path "*/portal*" -not -path "*/data/*" -not -path "*/env-checker*" \
  -not -path "*/envcheck*" -not -path "*/tools/*" 2>/dev/null)
GOMOD=""
for g in $GOMODS; do [ "${g#*/webapp/}" != "$g" ] && GOMOD="$g" && break; done
[ -z "$GOMOD" ] && GOMOD=$(printf "%s\n" $GOMODS | head -1)
S GO_DIR "$(dirname "${GOMOD:-/}" 2>/dev/null)"
S GO_VER "$(go version 2>/dev/null || echo none)"

# --- web server: nginx is usual, Envoy happened (isucon10-final), h2o/caddy possible
WEB=""; WEB_SRC=""
for s in nginx h2o envoy caddy apache2 httpd; do systemctl is-active --quiet "$s" 2>/dev/null && WEB="$s" && WEB_SRC=host && break; done
# isucon8-final and isucon6-final ran the entire stack under docker-compose: systemctl
# sees ONE wrapper unit and nothing else, so the systemctl sweep above reports "no web
# server" on a box that plainly has one. Ask docker before believing that.
DOCKER_PS=""
command -v docker >/dev/null 2>&1 && DOCKER_PS="$($SUDO docker ps --format "{{.Image}} {{.Names}}" 2>/dev/null)"
IN_DOCKER=0
if [ -z "$WEB" ] && [ -n "$DOCKER_PS" ]; then
  for s in nginx h2o envoy caddy apache httpd; do
    printf "%s\n" "$DOCKER_PS" | grep -qi "$s" && WEB="$s" && WEB_SRC=docker && IN_DOCKER=1 && break
  done
fi
S WEB_SERVER "$WEB"
# host-native nginx only: `nginx -T` on the host cannot see a containerised config, and
# `isukit logs on` rewrites the host nginx.conf — both are wrong when WEB_SRC=docker.
if [ "$WEB" = "nginx" ] && [ "$WEB_SRC" = "host" ]; then
  ALOG_LINES="$($SUDO nginx -T 2>/dev/null | grep -vE "^[[:space:]]*#" | grep -oE "access_log[[:space:]]+[^ ;]+" | awk "{print \$2}")"
  S NGINX_ACCESS_LOGS "$(printf "%s" "$ALOG_LINES" | tr "\n" " ")"
  NGINX_LASTLOG=""
  for p in $ALOG_LINES; do [ "$p" != "off" ] && NGINX_LASTLOG="$p"; done
  S NGINX_ACCESS_LOG "$NGINX_LASTLOG"
  S NGINX_CONFS "$($SUDO nginx -T 2>/dev/null | grep -oE "^# configuration file [^:]+" | awk "{print \$4}" | tr "\n" " ")"
  S NGINX_HAS_CONFD "$($SUDO nginx -T 2>/dev/null | grep -cE "include.*conf\.d" || true)"
fi

# --- datastores: MySQL/MariaDB usual, SQLite appeared (isucon12-q), redis common
DB=""
for s in mysql mariadb postgresql; do systemctl is-active --quiet "$s" 2>/dev/null && DB="$s" && break; done
if [ -z "$DB" ] && [ -n "$DOCKER_PS" ]; then
  for s in mysql mariadb postgres; do
    printf "%s\n" "$DOCKER_PS" | grep -qi "$s" && DB="$s" && IN_DOCKER=1 && break
  done
  [ "$DB" = "postgres" ] && DB=postgresql
fi
S DB_SERVER "$DB"
# 1 = at least one of the web/db tiers was found only as a container. Everything that
# edits host config (logs on, alp, slow) has to be done inside the container instead.
S STACK_IN_DOCKER "$IN_DOCKER"
S CACHE "$(for s in redis-server redis memcached; do systemctl is-active --quiet $s 2>/dev/null && echo -n "$s "; done)"
MYSQL="$SUDO mysql"
if $MYSQL -e "SELECT 1" >/dev/null 2>&1; then
  S MYSQL_OK 1
  S MYSQL_VER  "$($MYSQL -N -B -e "SELECT VERSION()" 2>/dev/null)"
  S MYSQL_SLOW "$($MYSQL -N -B -e "SELECT @@slow_query_log_file" 2>/dev/null)"
  S MYSQL_DBS  "$($MYSQL -N -B -e "SHOW DATABASES" 2>/dev/null | grep -vE "^(information_schema|performance_schema|mysql|sys)$" | tr "\n" " ")"
else
  S MYSQL_OK 0
fi
S SQLITE_FILES "$(find /home/isucon -maxdepth 4 \( -name "*.db" -o -name "*.sqlite*" \) 2>/dev/null | head -5 | tr "\n" " ")"

# --- tooling we depend on
S HAS_ALP  "$(command -v alp >/dev/null && echo 1 || echo 0)"
S HAS_PTQD "$(command -v pt-query-digest >/dev/null && echo 1 || echo 0)"
S HAS_DOCKER "$(command -v docker >/dev/null && echo 1 || echo 0)"
