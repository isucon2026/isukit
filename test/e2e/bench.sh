#!/bin/bash
# One measured `isukit bench`: real vmstat/pidstat samplers, a pprof endpoint
# (a python stand-in), logs emptied before and after, everything saved.
# shellcheck source=test/e2e/lib.sh
. /k/test/e2e/lib.sh
pkgs git rsync sysstat procps curl python3
stubs; server
laptop_for /laptop
printf "BENCH_MODE=auto\nBENCH_CMD='timeout 3 sh -c \"while :; do :; done\"; echo \"score: 4242\"'\nPPROF_SEC=2\nPPROF_DELAY=0\n" >> .isukit/config

cat > /tmp/pprof.py <<'P'
import http.server, time, urllib.parse
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        if u.path == "/debug/pprof/profile":
            time.sleep(int(urllib.parse.parse_qs(u.query).get("seconds", ["1"])[0]))
        self.send_response(200); self.end_headers(); self.wfile.write(b"PPROF")
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", 6060), H).serve_forever()
P
python3 /tmp/pprof.py & sleep 1

# logging on, with a stale request that must NOT be counted for this run
: > /etc/nginx/conf.d/00-isukit.conf
printf 'uri:/stale\n' > /var/log/nginx/isukit.log; printf '# stale\n' > /tmp/isukit-slow.log
printf '/tmp/isukit-cpu.pprof is stale\n' > /tmp/isukit-cpu.pprof
cat > /stub/pt-query-digest <<'X'
#!/bin/bash
grep -q fresh "${@: -1}" && printf '# Profile\n# Rank Query ID Response time\n#    1 0xABC  1.0 100.0%%  SELECT fresh\n\n'
X
chmod +x /stub/pt-query-digest
( sleep 1; printf 'time:t\tmethod:GET\turi:/api/fresh/1\tstatus:200\treqtime:0.1\n' >> /var/log/nginx/isukit.log
  printf '# Query_time: 1 fresh\n' >> /tmp/isukit-slow.log ) &

"$I" bench "e2e run" </dev/null 2>&1 | plain > /tmp/out
run=$(ls -1d .isukit/runs/* | tail -1)
check "score recorded against the run"       awk -F'\t' -v r="$run" '$3 == 4242 && $5 == r { f = 1 } END { exit !f }' .isukit/scores.tsv
check "meta written"                         grep -q '^score=4242' "$run/meta"
check "per-host summary with real samplers"  grep -q '^  cpu    avg' "$run/hosts.txt"
check "per-process line from pidstat"        grep -q '^  procs' "$run/hosts.txt"
check "slow saved for this run only"         grep -q 'SELECT fresh' "$run/slow-local.txt"
check "pprof taken during the load"          [ "$(cat "$run/cpu.pprof")" = PPROF ]
check "logs emptied after collecting"        [ ! -s /var/log/nginx/isukit.log ] && [ ! -s /tmp/isukit-slow.log ]
check "no sampler left running"              bash -c '! pgrep -x vmstat >/dev/null && ! pgrep -x pidstat >/dev/null'
check "show prints the saved run"            bash -c '"$0" show 2>&1 | grep -q "score 4242"' "$I"
check "show past the last run is an error"   bash -c '! "$0" show 9 >/dev/null 2>&1' "$I"
finish
