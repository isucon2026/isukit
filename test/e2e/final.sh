#!/bin/bash
# isukit final check / apply: everything that logs or measures, found and turned off.
# shellcheck source=test/e2e/lib.sh
. /k/test/e2e/lib.sh
pkgs git rsync
stubs; server
# as handed out (plus a team that tuned with the slow log on in the .cnf)
printf '[mysqld]\nmax_connections = 1000\nslow_query_log = 1\n' > /etc/mysql/mysql.conf.d/mysqld.cnf
cat > /home/isucon/webapp/go/main.go <<'G'
package main

import (
	"log"
	_ "net/http/pprof"

	"github.com/labstack/echo/v4"
	"github.com/labstack/echo/v4/middleware"
)

func main() {
	e := echo.New()
	e.Use(middleware.Logger())
	log.Println("listening")
}
G
laptop_for /laptop
"$I" etc adopt >/tmp/out 2>&1
git add etc && git commit -qm "etc: baseline"          # as `isukit ship` would
"$I" logs on >/tmp/out 2>&1
printf 'uri:/x\n' > /var/log/nginx/isukit.log
mkdir -p /tmp/isukit-run
sleep 600 & echo $! > /tmp/isukit-run/pids             # a sampler left behind

echo "final check (before)"
"$I" final check 2>&1 | plain > /tmp/check1; rc=${PIPESTATUS[0]}
sed 's/^/    | /' /tmp/check1
check "check fails while things still log"   [ "$rc" != 0 ]
check "isukit logging reported"              grep -q 'isukit measurement logging is still on' /tmp/check1
check "running samplers reported"            grep -q 'samplers' /tmp/check1
check "measurement files reported"           grep -q 'measurement files left' /tmp/check1
check "sysstat collector reported"           grep -q 'sysstat-collect.timer is active' /tmp/check1
check "slow log in the .cnf reported"        grep -q 'mysql config turns a log on: mysql/mysql.conf.d/mysqld.cnf' /tmp/check1
check "pprof import reported"                grep -q 'go/main.go:.*pprof imported' /tmp/check1
check "echo logger reported"                 grep -q 'go/main.go:.*request logger middleware' /tmp/check1

echo "final apply"
"$I" final apply 2>&1 | plain > /tmp/apply; sed 's/^/    | /' /tmp/apply | tail -25
check "laptop nginx.conf: access_log off"    grep -qE '^[[:space:]]*access_log off;' etc/nginx/nginx.conf
check "laptop site conf: access_log off"     grep -qE '^[[:space:]]*access_log off;' etc/nginx/sites-available/isucon.conf
check "no access_log left on (live)"         bash -c '! grep -RhE "^[[:space:]]*access_log[[:space:]]+/" /etc/nginx/'
check "live config through the link"         grep -q 'access_log off; # isukit final' /etc/nginx/nginx.conf
check "slow log 0 in the .cnf (live)"        grep -qE '^slow_query_log = 0' /etc/mysql/mysql.conf.d/mysqld.cnf
check "slow log off (live variable)"         [ "$(mysql -N -B -e 'SELECT @@GLOBAL.slow_query_log')" = 0 ]
check "isukit logging removed"               [ ! -e /etc/nginx/conf.d/00-isukit.conf ]
check "samplers stopped, files removed"      [ ! -e /tmp/isukit-run ] && [ ! -e /var/log/nginx/isukit.log ]
check "sysstat collector disabled"           bash -c '! systemctl is-active --quiet sysstat-collect.timer'
check "change is a reviewable diff"          bash -c 'git diff --quiet -- etc; [ $? = 1 ]'

echo "final check (after)"
"$I" final check 2>&1 | plain > /tmp/check2
sed 's/^/    | /' /tmp/check2
check "hosts clean"                          bash -c '! grep -q "== hosts" /tmp/check2'
check "app code still listed for a human"    grep -q '== app code' /tmp/check2
finish
