#!/bin/bash
# remote/http-check.sh, the after-reboot "does it answer" check finalize runs:
# the app's port found from its unit's process, 2xx-4xx vs 5xx / no answer,
# and retrying while a service is still coming up.
# shellcheck source=test/e2e/lib.sh
. /k/test/e2e/lib.sh
pkgs curl python3 iproute2 procps
stubs
cat > /tmp/srv.py <<'P'
import http.server, sys
code = int(sys.argv[2])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(404 if self.path == "/missing" else code); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(("0.0.0.0", int(sys.argv[1])), H).serve_forever()
P
# nginx's default server as handed out: its own 404 page whatever the Host; the
# site answers only for its server_name
cat > /tmp/vhost.py <<'P'
import http.server, sys
name = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        ok = name and self.headers.get("Host", "").split(":")[0] == name
        self.send_response(200 if ok else 404); self.end_headers()
        if not ok: self.wfile.write(b"<html><body><center><h1>404 Not Found</h1></center><hr><center>nginx</center></body></html>")
    def log_message(self, *a): pass
http.server.HTTPServer(("0.0.0.0", int(sys.argv[1])), H).serve_forever()
P
hc() { { printf 'SUDO=\n'; for kv in "$@"; do printf '%s\n' "$kv"; done; cat /k/remote/http-check.sh; } | bash -s; }

python3 /tmp/srv.py 18080 200 & echo $! > /tmp/mainpid     # the app, as its unit's main process
python3 /tmp/srv.py 80 502 &                               # nginx with no upstream left
sleep 1
check "app port discovered from the unit"    bash -c '[ "$0" = "OK|http://127.0.0.1:18080/|200" ]' "$(hc MODE=app APP_UNIT=isu-go.service WAIT=2)"
check "4xx is an answer"                     bash -c '[ "$0" = "OK|http://127.0.0.1:18080/missing|404" ]' "$(hc MODE=app APP_UNIT=isu-go.service PATH_=/missing WAIT=2)"
check "502 through nginx is a failure"       bash -c '[ "$0" = "FAIL|http://localhost/|502" ]' "$(hc MODE=web WAIT=2)"
check "nothing listening is a failure"       bash -c '[ "$0" = "FAIL|http://127.0.0.1:9/|no answer" ]' "$(hc MODE=app APP_PORT=9 WAIT=2)"
echo 0 > /tmp/mainpid
check "no port found says so"                bash -c 'case "$0" in "FAIL|isu-go.service|no listening port"*) ;; *) exit 1 ;; esac' "$(hc MODE=app APP_UNIT=isu-go.service WAIT=1)"
# a service still starting: answers 3s into a 10s wait
( sleep 3; python3 /tmp/srv.py 18081 200 ) &
check "retries while the box comes up"       bash -c '[ "$0" = "OK|http://127.0.0.1:18081/|200" ]' "$(hc MODE=app APP_PORT=18081 WAIT=10)"
# through nginx: the server block that proxies, by its port and server_name (#39)
python3 /tmp/vhost.py 18443 isu.test &
python3 /tmp/vhost.py 18444 "" &
mkdir -p /etc/nginx
printf 'http {\n  server {\n    listen 18444 default_server;\n    root /var/www/html;\n  }\n  server {\n    listen 18443;\n    server_name isu.test;\n    location / { proxy_pass http://127.0.0.1:18080; }\n  }\n}\n' > /etc/nginx/nginx.conf
sleep 1
check "web: the site's own block, Host = its server_name" bash -c '[ "$0" = "OK|http://isu.test:18443/|200" ]' "$(hc MODE=web WAIT=2)"
check "web: nginx's own 404 never reached the app"        bash -c 'case "$0" in "FAIL|http://other.test:18444/|404 from nginx itself"*) ;; *) exit 1 ;; esac' "$(hc MODE=web WEB_URL=http://other.test:18444 WAIT=2)"
finish
