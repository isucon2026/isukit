#!/bin/bash
# Two people, one server: alice and bob are two clones of the team repo on the
# same machine (ISUKIT_WHO tells them apart), sharing the server as APP=local.
# shellcheck source=test/e2e/lib.sh
. /k/test/e2e/lib.sh
pkgs git rsync procps curl python3
stubs; server
git -C /home/isucon/webapp init -q && git -C /home/isucon/webapp add -A && git -C /home/isucon/webapp commit -qm base
git clone -q --bare /home/isucon/webapp /srv/origin.git
# Discord stand-in: every webhook body, one JSON per line
cat > /tmp/discord.py <<'P'
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        open("/tmp/discord.log", "ab").write(body + b"\n")
        self.send_response(204); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", 9999), H).serve_forever()
P
python3 /tmp/discord.py & sleep 1
for who in alice bob; do
  git clone -q /srv/origin.git "/laptop/$who"
  mkdir -p "/laptop/$who/.isukit"
  printf '*\n' > "/laptop/$who/.isukit/.gitignore"      # as isukit init writes it
  printf "APP=local\nBENCH=local\nBENCH_MODE=auto\nBENCH_CMD='echo score: 1234'\nSSH_OPTS=''\nDISCORD_WEBHOOK=http://127.0.0.1:9999/hook\n" > "/laptop/$who/.isukit/config"
  printf 'APP_UNIT=isu-go.service\nSRC_DIR=/home/isucon/webapp\nGO_DIR=/home/isucon/webapp/go\n' > "/laptop/$who/.isukit/manifest"
done
as() { local who="$1"; shift; ( cd "/laptop/$who" && ISUKIT_WHO="$who" "$I" "$@" ) 2>&1 | plain; }

echo "turns"
as alice lock >/tmp/out
as bob deploy > /tmp/bob.deploy
check "bob's deploy refused while alice holds"   grep -q 'busy — alice: turn' /tmp/bob.deploy
check "and it says who and what"                  grep -q 'alice: turn for' /tmp/bob.deploy
as bob lock status > /tmp/status
check "lock status shows the holder"              grep -q 'held — alice' /tmp/status
as alice unlock >/dev/null
check "unlock frees the servers"                  bash -c '[ ! -e /var/tmp/isukit.lock ]'

echo "one shared record"
as bob bench "bob's run" > /tmp/bob.bench
check "bob's run is published"                    grep -q 'run shared: isukit-runs' /tmp/bob.bench
check "no lock left after the bench"              bash -c '[ ! -e /var/tmp/isukit.lock ]'
as alice score > /tmp/alice.score
check "alice sees bob's run"                      grep -E "1234 +main +bob" /tmp/alice.score

echo "discord"
said() { python3 -c 'import json,sys
for l in open("/tmp/discord.log"):
    print(json.loads(l)["content"])' | grep -qF -- "$1"; }
check "lock announced"                            said "🔒 alice has the servers"
check "release announced"                         said "🔓 alice handed the servers back"
check "bob's score posted with branch and who"    said "📊 **1234**"
check "  ... and who ran it"                      said "main by bob"

echo "deploy never rolls back merged work"
( cd /laptop/bob && git checkout -q -b isukit/stale )
( cd /laptop/alice && echo x > go/new.go && git add -A && git -c user.email=a@a -c user.name=alice commit -qm "merged" && git push -q origin HEAD:main )
as bob deploy > /tmp/bob.stale
check "a branch without origin/main is refused"   grep -q 'does not contain origin/main' /tmp/bob.stale
( cd /laptop/bob && echo y > uncommitted )
( cd /laptop/bob && git rebase -q origin/main 2>/dev/null )
as bob deploy > /tmp/bob.dirty
check "uncommitted changes are refused"           grep -q 'uncommitted changes would be deployed' /tmp/bob.dirty
finish
