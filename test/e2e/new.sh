#!/bin/bash
# `isukit go --new`: the team repo built from the server, code + config baselines.
# shellcheck source=test/e2e/lib.sh
. /k/test/e2e/lib.sh
pkgs git rsync sysstat procps
stubs; server
head -c 12000000 /dev/zero > /home/isucon/webapp/go/isu          # the built app
head -c 12000000 /dev/zero > /home/isucon/webapp/sql/dump.sql    # too big for git

mkdir /laptop && cd /laptop || exit 1
DISCORD_WEBHOOK_GIT=https://discord.test/hooks/git "$I" go --new myteam/isu26 local --invite alice,bob </dev/null 2>&1 | plain > /tmp/out
cd /laptop/isu26 || { cat /tmp/out; exit 1; }

check "baselines + CI: three commits on main"  [ "$(git --git-dir=/srv/remote.git rev-list --count main)" = 3 ]
check "code baseline has the source"         git --git-dir=/srv/remote.git cat-file -e main~2:go/main.go
check "code baseline has no isukit files"    bash -c '! git --git-dir=/srv/remote.git cat-file -e main~2:.github/workflows/isukit-ci.yml 2>/dev/null'
check "config baseline has etc/"             git --git-dir=/srv/remote.git cat-file -e main~1:etc/nginx/nginx.conf
check "env file recorded per host"           git --git-dir=/srv/remote.git cat-file -e main~1:hosts/local/env.sh
git --git-dir=/srv/remote.git show main:.github/workflows/isukit-ci.yml > /tmp/ci.yml 2>/dev/null
check "CI builds the Go module"              grep -q 'working-directory: go' /tmp/ci.yml
check "CI reads the Go version from go.mod"  grep -q 'go-version-file: go/go.mod' /tmp/ci.yml
check "vet never blocks"                     bash -c "grep -A1 'go vet' /tmp/ci.yml | grep -q 'continue-on-error: true'"
check "#git wired through Discord's /github" grep -q 'repos/myteam/isu26/hooks .*config\[url\]=https://discord.test/hooks/git/github' /tmp/gh.calls
check "  ... for pushes, PRs and CI"         grep -q 'events\[\]=push .*events\[\]=pull_request .*events\[\]=check_suite' /tmp/gh.calls
check "built app not in git"                 bash -c '! git ls-files --error-unmatch go/isu >/dev/null 2>&1'
check "big file not in git"                  bash -c '! git ls-files --error-unmatch sql/dump.sql >/dev/null 2>&1'
check "binary listed once in .gitignore"     [ "$(grep -cx /go/isu .gitignore)" = 1 ]
check "/etc links into the server webapp"    [ "$(readlink /etc/nginx/nginx.conf)" = /home/isucon/webapp/etc/nginx/nginx.conf ]
check "ETC_REPO pinned to the webapp"        grep -qx "ETC_REPO='/home/isucon/webapp'" .isukit/config
check "config baseline has no log markers"   bash -c '! git show main:etc/nginx/nginx.conf | grep -q isukit'
check "collaborators invited"                [ "$(grep -c 'collaborators/' /tmp/gh.calls)" = 2 ]
check "left on the work branch"              [ "$(git branch --show-current)" = work ]

echo "team sharing: roles and env files in the repo"
"$I" host role local web,app,db >/dev/null 2>&1
check "roles written to the shared isukit.hosts" [ -f isukit.hosts ] && [ ! -f .isukit/hosts ]
sed -i 's/127.0.0.1/10.0.1.13/' hosts/local/env.sh
"$I" env push >/tmp/env.out 2>&1
check "env push writes the host's env file"   grep -q 'MYSQL_HOST=10.0.1.13' /home/isucon/env.sh
check "and restarts the app"                  grep -q 'restarting the app' /tmp/env.out
check "env status: same"                      bash -c '"$0" env status 2>/dev/null | grep -q " same$"' "$I"
finish
