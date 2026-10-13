#!/bin/bash
# The host-side "is it really up" checks, run as-is with the commands they
# call stubbed from $WORK/bin:
#   remote/http-check.sh — finalize's answer check. Through nginx it must reach
#     the server block that proxies to the app (listen port / scheme /
#     server_name off `nginx -T`, curl --resolve + -k), and a 4xx nginx wrote
#     itself (the default server) is a FAIL, not an answer (#39).
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERBOSE=0
for a in "$@"; do [ "$a" = "-v" ] && VERBOSE=1; done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/isukit-health.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"; S="$WORK/state"; CALLS="$WORK/calls"
mkdir -p "$BIN" "$S"

# nginx -T: the file $S/nginx-T
cat > "$BIN/nginx" <<'X'
#!/bin/bash
[ "${1:-}" = -T ] && cat "$ISUKIT_T_STATE/nginx-T" 2>/dev/null
exit 0
X
# curl: records its argv; answers from $S/curl-rules, "<glob over argv>|<code>|<body>", first match
cat > "$BIN/curl" <<'X'
#!/bin/bash
echo "curl $*" >> "$ISUKIT_T_CALLS"
out=/dev/null; prev=""
for a in "$@"; do [ "$prev" = -o ] && out="$a"; prev="$a"; done
args="$*"
while IFS='|' read -r pat code body; do
  # shellcheck disable=SC2053  # the rule is a glob
  if [[ "$args" == $pat ]]; then printf '%s' "$body" > "$out"; printf '%s' "$code"; exit 0; fi
done < "$ISUKIT_T_STATE/curl-rules"
printf '000'; exit 7
X
chmod +x "$BIN"/*
export ISUKIT_T_STATE="$S" ISUKIT_T_CALLS="$CALLS"

run() { # run <script> VAR=value... -- the remote script with these inputs, stubs first on PATH
  local f="$1"; shift
  local kv
  { printf 'SUDO=\n'; for kv in "$@"; do printf '%s=%q\n' "${kv%%=*}" "${kv#*=}"; done; cat "$HERE/../remote/$f"; } \
    | PATH="$BIN:$PATH" bash -s
}
reset() { rm -f "$S"/*; : > "$CALLS"; : > "$S/curl-rules"; }

TOTAL=0; PASSED=0; FAILED=""; ERR=""
check() { [ "$@" ] || ERR="$ERR
    failed: [ $* ]"; }
case_() {
  TOTAL=$((TOTAL+1)); ERR=""
  ( "$2" ; printf '%s' "$ERR" > "$WORK/err" )
  ERR="$(cat "$WORK/err" 2>/dev/null)"
  if [ -z "$ERR" ]; then PASSED=$((PASSED+1)); echo "PASS  $1"
  else FAILED="$FAILED $1"; echo "FAIL  $1$ERR"; fi
  [ "$VERBOSE" = 1 ] && sed 's/^/      | /' "$CALLS"
  return 0
}

# isucon14 as handed out: the default servers on 80 and 443 answer from
# /var/www/html, the site is a third block on 443 ssl with a server_name
ISUCON14_T='# configuration file /etc/nginx/nginx.conf:
http {
    include /etc/nginx/sites-enabled/*;
}

# configuration file /etc/nginx/sites-enabled/isuride.conf:
upstream app {
  server 127.0.0.1:8080;
  keepalive 128;
}

server {
  listen 80 default_server;
  server_name _;
  root /var/www/html;
  location / {
    try_files $uri $uri/ =404;
  }
}

server {
  listen 443 ssl default_server;
  server_name _;
  root /var/www/html;
  location / { try_files $uri $uri/ =404; }
}

server {
  listen [::]:443 ssl;
  listen 443 ssl;
  server_name xiv.isucon.net;
  server_name *.xiv.isucon.net;
  root /home/isucon/webapp/public/;
  location / {
    try_files $uri /index.html;
  }
  location /api/internal/ {
    allow 127.0.0.1;
    deny all;
    proxy_pass http://app;
  }
}'
NGINX_404='<html><head><title>404 Not Found</title></head><body><center><h1>404 Not Found</h1></center><hr><center>nginx</center></body></html>'

t_web_reaches_the_site_block() {
  reset
  printf '%s\n' "$ISUCON14_T" > "$S/nginx-T"
  printf '%s\n' '*--resolve xiv.isucon.net:443:127.0.0.1 https://xiv.isucon.net:443/api/internal/matching|204|' > "$S/curl-rules"
  printf '%s\n' "*|404|$NGINX_404" >> "$S/curl-rules"
  local out
  out=$(run http-check.sh MODE=web PATH_=/api/internal/matching WAIT=2)
  check "$out" = "OK|https://xiv.isucon.net:443/api/internal/matching|204"
  check -n "$(grep -- ' -k ' "$CALLS")"                  # the cert is for the contest's domain, maybe self-signed
  check -z "$(grep 'localhost' "$CALLS")"
}

t_web_nginx_own_404_fails() {
  reset
  printf '%s\n' "$ISUCON14_T" > "$S/nginx-T"
  printf '%s\n' "*|404|$NGINX_404" > "$S/curl-rules"   # every request lands on the default server
  local out t0
  t0=$(date +%s)
  out=$(run http-check.sh MODE=web PATH_=/api/internal/matching WAIT=30)
  case "$out" in "FAIL|https://xiv.isucon.net:443/api/internal/matching|404 from nginx itself"*) ;; *) check "$out" = "FAIL ... 404 from nginx itself" ;; esac
  check "$(( $(date +%s) - t0 ))" -lt 10                 # a default server does not change its mind: no retrying
}

t_web_upstream_404_is_an_answer() {
  reset
  printf '%s\n' "$ISUCON14_T" > "$S/nginx-T"
  printf '%s\n' '*xiv.isucon.net*|404|{"message":"not found"}' > "$S/curl-rules"
  check "$(run http-check.sh MODE=web PATH_=/api/nothing WAIT=2)" = "OK|https://xiv.isucon.net:443/api/nothing|404"
}

t_web_url_override() {
  reset
  printf '%s\n' "$ISUCON14_T" > "$S/nginx-T"
  printf '%s\n' '*--resolve isuride.xiv.isucon.net:443:127.0.0.1 https://isuride.xiv.isucon.net:443/|200|' > "$S/curl-rules"
  check "$(run http-check.sh MODE=web WEB_URL=https://isuride.xiv.isucon.net WAIT=2)" = "OK|https://isuride.xiv.isucon.net:443/|200"
  reset
  printf '%s\n' '*--resolve isu.local:8080:127.0.0.1 http://isu.local:8080/x|200|' > "$S/curl-rules"
  check "$(run http-check.sh MODE=web WEB_URL=http://isu.local:8080 PATH_=/x WAIT=2)" = "OK|http://isu.local:8080/x|200"
}

t_web_plain_site_and_fallback() {
  reset
  # a site on 80 with no server_name: still its own port, Host localhost
  printf '# configuration file /etc/nginx/nginx.conf:\nhttp {\n  server {\n    listen 80;\n    location / { proxy_pass http://127.0.0.1:8080; }\n  }\n}\n' > "$S/nginx-T"
  printf '%s\n' '*--resolve localhost:80:127.0.0.1 http://localhost:80/|200|' > "$S/curl-rules"
  check "$(run http-check.sh MODE=web WAIT=2)" = "OK|http://localhost:80/|200"
  # a listen on one address, ssl on a port that is not 443
  reset
  printf '# configuration file /etc/nginx/conf.d/a.conf:\nserver {\n  listen 10.0.0.5:8443 ssl http2;\n  server_name isu.example;\n  location /api/ { proxy_pass http://app; }\n}\n' > "$S/nginx-T"
  printf '%s\n' '*--resolve isu.example:8443:10.0.0.5 https://isu.example:8443/|200|' > "$S/curl-rules"
  check "$(run http-check.sh MODE=web WAIT=2)" = "OK|https://isu.example:8443/|200"
  # nothing proxies (or no nginx -T): as before, http://localhost
  reset
  printf '%s\n' '*http://localhost/|200|' > "$S/curl-rules"
  check "$(run http-check.sh MODE=web WAIT=2)" = "OK|http://localhost/|200"
  check -z "$(grep -- '--resolve' "$CALLS")"
}

t_web_5xx_still_fails() {
  reset
  printf '%s\n' "$ISUCON14_T" > "$S/nginx-T"
  printf '%s\n' '*|502|<center>nginx</center>' > "$S/curl-rules"
  check "$(run http-check.sh MODE=web WAIT=0)" = "FAIL|https://xiv.isucon.net:443/|502"
}

t_app_4xx_is_an_answer() {
  reset
  printf '%s\n' '*http://127.0.0.1:8080/x|404|<center>nginx</center>' > "$S/curl-rules"
  check "$(run http-check.sh MODE=app APP_PORT=8080 PATH_=/x WAIT=2)" = "OK|http://127.0.0.1:8080/x|404"
}

case_ http-web-reaches-site-block        t_web_reaches_the_site_block
case_ http-web-nginx-own-404-fails       t_web_nginx_own_404_fails
case_ http-web-upstream-404-answers      t_web_upstream_404_is_an_answer
case_ http-web-url-override              t_web_url_override
case_ http-web-plain-site-and-fallback   t_web_plain_site_and_fallback
case_ http-web-5xx-fails                 t_web_5xx_still_fails
case_ http-app-4xx-answers               t_app_4xx_is_an_answer

echo "$TOTAL fixtures, $PASSED passed, $((TOTAL-PASSED)) failed"
[ -z "$FAILED" ]
