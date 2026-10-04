#!/bin/bash
# etc adopt -> status -> push -> pull against a real /etc (in the container).
# shellcheck source=test/e2e/lib.sh
. /k/test/e2e/lib.sh
pkgs git rsync
stubs; server
laptop_for /laptop

echo "etc adopt"
"$I" etc adopt >/tmp/out 2>&1
check "nginx.conf is a link into the repo"   [ "$(readlink /etc/nginx/nginx.conf)" = /home/isucon/webapp/etc/nginx/nginx.conf ]
check "site conf is a link into the repo"    [ "$(readlink /etc/nginx/sites-available/isucon.conf)" = /home/isucon/webapp/etc/nginx/sites-available/isucon.conf ]
check "mysqld.cnf is a link into the repo"   [ "$(readlink /etc/mysql/mysql.conf.d/mysqld.cnf)" = /home/isucon/webapp/etc/mysql/mysql.conf.d/mysqld.cnf ]
check "app unit is a link into the repo"     [ "$(readlink /etc/systemd/system/isu-go.service)" = /home/isucon/webapp/etc/systemd/system/isu-go.service ]
check "backups kept outside include dirs"    [ -f /etc/isukit-orig/nginx/nginx.conf ]
check "nothing left in sites-enabled"        [ "$(ls /etc/nginx/sites-enabled)" = isucon.conf ]
check "pulled down to the laptop"            [ -f etc/mysql/mysql.conf.d/mysqld.cnf ]
check "status: all linked"                   "$I" etc status >/dev/null 2>&1

echo "etc push"
sed -i 's/max_connections = 1000/max_connections = 2000/' etc/mysql/mysql.conf.d/mysqld.cnf
"$I" etc push >/tmp/out 2>&1
check "live /etc sees the laptop edit"       grep -q 2000 /etc/mysql/mysql.conf.d/mysqld.cnf
check "only mysql restarted"                 grep -q 'restarting the DB' /tmp/out
"$I" etc push >/tmp/out 2>&1
check "second push is a no-op"               grep -q 'already matches' /tmp/out

echo "etc pull guards"
git add etc && git commit -qm etc
sed -i 's/2000/3000/' etc/mysql/mysql.conf.d/mysqld.cnf
check "pull refuses over an unpushed edit"   bash -c '! "$0" etc pull >/dev/null 2>&1' "$I"
check "and the edit is still there"          grep -q 3000 etc/mysql/mysql.conf.d/mysqld.cnf
git checkout -q etc

echo "logs on/off through the links"
"$I" logs on >/tmp/out 2>&1
check "access_log commented in the repo copy" grep -q '#isukit# access_log' /home/isucon/webapp/etc/nginx/nginx.conf
check "links survive logs on"                [ -L /etc/nginx/nginx.conf ]
printf 'x\n' >> etc/nginx/sites-available/isucon.conf
"$I" etc push >/tmp/out 2>&1
check "marker-only file not overwritten"     grep -q '#isukit# access_log' /home/isucon/webapp/etc/nginx/nginx.conf
"$I" logs off >/tmp/out 2>&1
check "logs off restores the line"           bash -c '! grep -q "#isukit#" /home/isucon/webapp/etc/nginx/nginx.conf'
check "links survive logs off"               [ -L /etc/nginx/nginx.conf ]
finish
