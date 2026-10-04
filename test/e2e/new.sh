#!/bin/bash
# `isukit go --new`: the team repo built from the server, code + config baselines.
# shellcheck source=test/e2e/lib.sh
. /k/test/e2e/lib.sh
pkgs git rsync sysstat procps
stubs; server
head -c 12000000 /dev/zero > /home/isucon/webapp/go/isu          # the built app
head -c 12000000 /dev/zero > /home/isucon/webapp/sql/dump.sql    # too big for git

mkdir /laptop && cd /laptop || exit 1
"$I" go --new myteam/isu26 local --invite alice,bob </dev/null 2>&1 | plain > /tmp/out
cd /laptop/isu26 || { cat /tmp/out; exit 1; }

check "two baseline commits on main"         [ "$(git --git-dir=/srv/remote.git rev-list --count main)" = 2 ]
check "code baseline has the source"         git --git-dir=/srv/remote.git cat-file -e main~1:go/main.go
check "config baseline has etc/"             git --git-dir=/srv/remote.git cat-file -e main:etc/nginx/nginx.conf
check "env file recorded per host"           git --git-dir=/srv/remote.git cat-file -e main:hosts/local/env.sh
check "built app not in git"                 bash -c '! git ls-files --error-unmatch go/isu >/dev/null 2>&1'
check "big file not in git"                  bash -c '! git ls-files --error-unmatch sql/dump.sql >/dev/null 2>&1'
check "binary listed once in .gitignore"     [ "$(grep -cx /go/isu .gitignore)" = 1 ]
check "/etc links into the server webapp"    [ "$(readlink /etc/nginx/nginx.conf)" = /home/isucon/webapp/etc/nginx/nginx.conf ]
check "ETC_REPO pinned to the webapp"        grep -qx "ETC_REPO='/home/isucon/webapp'" .isukit/config
check "config baseline has no log markers"   bash -c '! git show main:etc/nginx/nginx.conf | grep -q isukit'
check "collaborators invited"                [ "$(grep -c 'collaborators/' /tmp/gh.calls)" = 2 ]
check "left on the work branch"              [ "$(git branch --show-current)" = work ]
finish
