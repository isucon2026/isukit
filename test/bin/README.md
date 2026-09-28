# test/bin — fixture-driven command shims

`run-probe-tests.sh` prepends this directory to `PATH` before running the
extracted `PROBE_SCRIPT`, so these stand in for the real host commands
PROBE_SCRIPT calls. Every stub reads `$ISUKIT_FIXTURE` (the current
`test/fixtures/<year>/` directory) for its canned data — no stub hardcodes
per-year behavior.

## Contract

- **`systemctl`** — reads `$ISUKIT_FIXTURE/units/*.service` (unit files,
  copied/synthesized verbatim) and `$ISUKIT_FIXTURE/active` (newline list of
  bare unit names currently active). Implements `list-units`, `is-active`,
  `show -p PROP[,PROP2] [--value] UNIT`, plus `list-unit-files`/`cat` for
  spec completeness (PROBE_SCRIPT doesn't call either today). Every unit in
  `units/` is reported as locally provisioned (`FragmentPath` under
  `/etc/systemd/system/`). Any `WorkingDirectory`/`ExecStart`/
  `EnvironmentFile` value starting with the literal `/home/isucon` is
  rewritten to `$ISUKIT_FAKE_HOME`, mirroring the same substitution
  `run-probe-tests.sh` applies to the PROBE_SCRIPT text itself — see
  `test/README.md` for why both sides need it.
- **`nginx`** — `-T` dumps `$ISUKIT_FIXTURE/nginx/**/*.conf` as
  `# configuration file /etc/nginx/<relpath>:` blocks, the shape real
  `nginx -T` prints. No `nginx/` dir (or no `.conf` files in it) → exit 1,
  no output, simulating a host that isn't running nginx. `-v` prints a fixed
  version banner to stderr.
- **`mysql`** — reads `$ISUKIT_FIXTURE/mysql.tsv` (tab-separated
  `KEY<TAB>VALUE`: `VERSION`, `SLOW_LOG_FILE`, `DATABASES` space-separated).
  No `mysql.tsv` → every call fails (exit 1), simulating an unreachable/absent
  MySQL (Postgres/SQLite years). Matches `-e "<query>"` text against
  `SELECT 1`, `VERSION()`, `SLOW_QUERY_LOG_FILE`, `SHOW DATABASES`.
- **`nproc`** / **`free`** — fixed plausible output, not fixture-driven.
  Neither `HOST_CPUS` nor `HOST_MEM` is in any fixture's `expected`.
- **`docker`** — shadows the real host `docker` binary so PROBE_SCRIPT's
  `docker ps --format "{{.Image}} {{.Names}}"` fallback (used when systemctl
  finds no active web/db unit — e.g. a docker-compose-only year like
  isucon6-final) doesn't leak the operator's actual running containers into
  an "offline" test. `ps` prints `$ISUKIT_FIXTURE/docker-ps.txt` verbatim
  (one `<image> <name>` pair per line, the shape `--format` asks for); no
  such file → no output, simulating a host where nothing is running under
  Docker, same "absent" convention as the nginx/mysql stubs.
- **`supervisorctl`** — reads `$ISUKIT_FIXTURE/supervisorctl-status.txt`
  verbatim for `status` (real `supervisorctl status` output shape: one
  `<program>  RUNNING  pid N, uptime H:MM:SS` line per managed program). No
  such file → no output, simulating a host with no supervisord at all.
- **`sudo`** — PROBE_SCRIPT probes `sudo -n true` and, if that succeeds,
  prefixes its nginx/mysql/docker calls with `sudo -n`. Real `sudo` would
  make results depend on the operator's cached timestamp and would reset
  `PATH`, bypassing every stub above it. This stub strips leading `-flag`
  args and `exec`s the remaining command in-process, so `sudo -n nginx -T`
  etc. still resolve to the stubs in this directory.

Add a new stub only when a year's PROBE_SCRIPT path needs a command not
listed here (e.g. `redis-cli`, `psql`) — keep it fixture-driven the same way.
