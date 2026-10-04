#!/bin/bash
# Shared setup for the e2e scenarios. Sourced INSIDE a throwaway ubuntu
# container (see run.sh) — it installs packages and rewrites /etc freely.
#
# The real isukit runs end to end with APP=local; only the services it talks to
# are stubbed: systemctl / nginx / mysql answer like a box running isu-go,
# nginx and mysql, sudo just runs the command, gh pushes to a local bare repo.
set -u
K=/k                     # the repo, mounted read-only by run.sh
# shellcheck disable=SC2034  # used by the scenarios that source this file
I="$K/isukit"
FAILS=0

pkgs() { apt-get update -qq >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null 2>&1; }

check() { # check <description> <test...>
  local d="$1"; shift
  if "$@"; then echo "  ok    $d"; else echo "  FAIL  $d"; FAILS=$((FAILS + 1)); fi
}
finish() { [ "$FAILS" = 0 ] && { echo "PASS"; exit 0; }; echo "FAIL ($FAILS)"; exit 1; }
plain() { sed 's/\x1b\[[0-9;]*m//g'; }

stubs() {
  mkdir -p /stub
  cat > /stub/sudo <<'X'
#!/bin/bash
while [ $# -gt 0 ]; do case "$1" in -u) shift 2;; -*) shift;; *) break;; esac; done
exec "$@"
X
  cat > /stub/systemctl <<'X'
#!/bin/bash
echo "systemctl $*" >> /tmp/systemctl.calls
# units disabled with `disable --now` stay down: is-active / is-enabled say so
case "$1" in
  disable) shift; for u in "$@"; do case "$u" in -*) ;; *) echo "$u" >> /tmp/disabled-units ;; esac; done; exit 0 ;;
  is-active) for u in "$@"; do grep -qxF -- "$u" /tmp/disabled-units 2>/dev/null && exit 3; done; exit 0 ;;
  is-enabled) grep -qxF -- "${*: -1}" /tmp/disabled-units 2>/dev/null && { echo disabled; exit 1; }; echo enabled; exit 0 ;;
  list-units) printf '%s\n' "isu-go.service loaded active running isu" "nginx.service loaded active running n" "mysql.service loaded active running m" ;;
  show)
    p="$3"; u="${*: -1}"
    case "$p:$u" in
      FragmentPath:isu-go.service) echo /etc/systemd/system/isu-go.service ;;
      FragmentPath:*) echo "/lib/systemd/system/$u" ;;
      WorkingDirectory:isu-go.service) echo /home/isucon/webapp/go ;;
      ExecStart:isu-go.service) echo "{ path=/home/isucon/webapp/go/isu ; argv[]=/home/isucon/webapp/go/isu ; }" ;;
      EnvironmentFiles:isu-go.service) echo "/home/isucon/env.sh (ignore_errors=no)" ;;
      User:isu-go.service) echo isucon ;;
      MainPID:*) cat /tmp/mainpid 2>/dev/null || echo 0 ;;
      Type:*) echo simple ;;
    esac ;;
esac
exit 0
X
  cat > /stub/nginx <<'X'
#!/bin/bash
[ "${1:-}" = "-T" ] && { echo "# configuration file /etc/nginx/nginx.conf:"; cat /etc/nginx/nginx.conf; }
exit 0
X
  cat > /stub/mysql <<'X'
#!/bin/bash
# SET GLOBAL x = v is remembered in /tmp/mysql-vars; SELECT @@GLOBAL.x reads it back
case "$*" in
  *VERSION*) echo 8.0.36 ;;
  *@@GLOBAL.max_connections*) grep -h max_connections /etc/mysql/mysql.conf.d/mysqld.cnf 2>/dev/null | tr -dc 0-9 ;;
  *"SELECT @@GLOBAL."*) v="${*##*@@GLOBAL.}"; v="${v%% *}"; awk -v k="$v" '$1 == k { r = $2 } END { print (r == "" ? 0 : r) }' /tmp/mysql-vars 2>/dev/null ;;
  *"SET GLOBAL"*) printf '%s\n' "$*" | grep -oE 'SET GLOBAL [a-z_]+ ?= ?[^;"]+' | sed -E 's/SET GLOBAL ([a-z_]+) ?= ?(.*)/\1 \2/' >> /tmp/mysql-vars ;;
esac
exit 0
X
  cat > /stub/gh <<'X'
#!/bin/bash
echo "gh $*" >> /tmp/gh.calls
case "$1 $2" in
  "auth status") exit 0 ;;
  "repo view") exit 1 ;;
  "repo create") git init -q --bare /srv/remote.git && git remote add origin /srv/remote.git && git push -q -u origin main ;;
esac
exit 0
X
  for c in apparmor_parser pt-query-digest; do printf '#!/bin/bash\nexit 0\n' > "/stub/$c"; done
  [ -x /usr/local/bin/alp ] || printf '#!/bin/bash\nexit 0\n' > /stub/alp
  chmod +x /stub/*
  export PATH="/stub:$PATH"
  if command -v git >/dev/null 2>&1; then
    git config --global user.email e2e@isukit; git config --global user.name e2e
    git config --global init.defaultBranch main
  fi
}

server() { # a contest box as handed out: webapp, middleware config, env file
  mkdir -p /home/isucon/webapp/go /home/isucon/webapp/sql /home/isucon/webapp/public \
    /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/nginx/conf.d \
    /etc/mysql/mysql.conf.d /etc/systemd/system /var/log/nginx
  printf 'module isu\n' > /home/isucon/webapp/go/go.mod
  printf 'package main\n' > /home/isucon/webapp/go/main.go
  echo css > /home/isucon/webapp/public/a.css
  printf 'http {\n    include /etc/nginx/conf.d/*.conf;\n    include /etc/nginx/sites-enabled/*;\n    access_log /var/log/nginx/access.log;\n}\n' > /etc/nginx/nginx.conf
  printf 'server {\n    listen 80;\n    access_log /var/log/nginx/isucon.log;\n}\n' > /etc/nginx/sites-available/isucon.conf
  ln -sf ../sites-available/isucon.conf /etc/nginx/sites-enabled/isucon.conf
  printf '[mysqld]\nmax_connections = 1000\n' > /etc/mysql/mysql.conf.d/mysqld.cnf
  printf '[Service]\nExecStart=/home/isucon/webapp/go/isu\n' > /etc/systemd/system/isu-go.service
  printf 'export MYSQL_HOST=127.0.0.1\n' > /home/isucon/env.sh
}

laptop_for() { # laptop_for <dir> -- a clone of the server's webapp with isukit pointed at APP=local
  git -C /home/isucon/webapp init -q && git -C /home/isucon/webapp add -A && git -C /home/isucon/webapp commit -qm base
  git clone -q /home/isucon/webapp "$1" && cd "$1" || exit 1
  mkdir -p .isukit
  printf "APP=local\nBENCH=local\nBENCH_MODE=manual\nBENCH_CMD=''\nSSH_OPTS=''\nETC_REPO=/home/isucon/webapp\n" > .isukit/config
  printf 'APP_UNIT=isu-go.service\nSRC_DIR=/home/isucon/webapp\nWEB_SERVER=nginx\nDB_SERVER=mysql\n' > .isukit/manifest
}
