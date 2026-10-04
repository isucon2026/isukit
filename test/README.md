# test/ — offline fixture suite

Proves isukit's *discovery* logic against every past ISUCON year without a VM, an AWS
bill, or an ssh session. Run it:

```
bash test/run-all.sh                  # everything
bash test/run-all.sh isucon8-final    # one fixture (the other suite says "skip")
bash test/run-all.sh -v isucon13      # ...and dump the full probe output
```

Current state: **65 fixtures, 65 passed, 0 failed** (17 probe + 13 bench + 11 etc + 19 hosts + 5 alp).

`run-alp-tests.sh` feeds `remote/alp.sh` synthetic LTSV logs shaped like past contests
and asserts the alp groups it derives (ids and high fan-out segments collapse, a far
busier sibling like `/api/user/me` stays literal, every regex anchored).

`run-hosts-tests.sh` sources `isukit` (`ISUKIT_SOURCED=1` skips `main`), swaps the ssh
transport for a recorder and asserts which host each command reaches, with and
without a `.isukit/hosts` roles file. Full runs only, like the etc suite.

`run-etc-tests.sh` is different in kind: it runs `remote/etc-adopt.sh` and
`remote/etc-status.sh` as-is (plus `LOGS_SCRIPT`, extracted) against a throwaway
`/etc` tree via `ETC_ROOT`, and checks the symlink contract — adopt, idempotence,
status, `logs on`/`off` leaving linked files byte-identical, per-tier rollback
to this run's backup, backups kept out of include dirs, the repo copy winning on
a fresh box, and the mysql checks (unreadable file, value not live). It runs only on a full `run-all.sh`.

## Why fixtures instead of real hosts

isukit's whole design bet is *discover, never assume*: it reads systemd, nginx, docker
and the benchmarker's `--help` at runtime rather than hardcoding any year's layout. That
bet is only worth anything if it survives contact with how much the years actually
differ — PostgreSQL instead of MySQL, supervisord instead of systemd, everything inside
docker-compose, Envoy or H2O instead of nginx, `GET /initialize` vs `POST /api/initialize`.
So the suite replays each year's **real** systemd units, nginx configs and directory
listings (sourced from `../../refs/<year>/`, provenance recorded per fixture in
`NOTES.md`) through the unmodified discovery code.

Passing every year is the evidence that the 2026 problem — whose shape nobody knows until
10:00 JST on 2026-10-31 — has a good chance of being handled too.

## How it works

Neither runner copies isukit's logic. Both **extract it verbatim** from `../isukit` at
run time:

- `run-probe-tests.sh` awks out the whole `PROBE_SCRIPT` heredoc and runs it per fixture.
- `run-bench-tests.sh` awks out the `has_tok()` tail of `BENCH_PROBE_SCRIPT` and feeds it
  `$HELP` straight from a fixture. The binary-discovery preamble (`find -perm -u+x`,
  `file`, `stat`) is deliberately not exercised — it needs a real filesystem.

If you rename or reshape those two heredocs, the extractors fail loudly with
`FATAL: could not extract ...` rather than silently testing nothing.

The extracted script runs with `PATH=test/bin:$PATH`, so every command it shells out to
is answered from the fixture dir named by `$ISUKIT_FIXTURE`. Its `S KEY=value` output
(`%q`-quoted) is then compared key-by-key against the fixture's `expected`. Only keys
present in `expected` are asserted, so a fixture can pin the three things it is actually
about and ignore the rest.

### The /home/isucon relocation

`PROBE_SCRIPT` hardcodes `/home/isucon`, which the test cannot create. So the runner
mirrors `fixtures/<year>/home-isucon/` into a temp dir and rewrites `/home/isucon` →
that dir **on both sides**: in the extracted script text, and inside the `systemctl` stub
(via `$ISUKIT_FAKE_HOME`, which rewrites unit-file `WorkingDirectory=`/`ExecStart=`
values the same way). Rewriting only one side desyncs the prefix-strip scoring
(`${wd#/home/isucon}`) from what the stub reports, and every confidence score goes wrong
at once.

## Stubs (`test/bin/`)

| stub | reads | notes |
|---|---|---|
| `systemctl` | `units/*.service`, `active` | list-units / is-active / show -p / cat |
| `nginx` | `nginx.conf` etc. | answers `nginx -T` |
| `mysql` | `mysql.tsv` | absent file = DB unreachable, which is a real state for some years |
| `docker` | `docker-ps.txt` | shadows the **real** docker on the dev laptop — see below |
| `supervisorctl` | `supervisorctl-status.txt` | only isucon5-final has one |
| `sudo` | — | strips flags and execs the rest, keeping every call inside `test/bin` |
| `free`, `nproc` | — | fixed plausible values |

`docker` and `sudo` are not conveniences, they are containment. The probe calls
`command -v docker` and then `$SUDO docker ps`; without stubs, a test run would query the
developer's own machine, and real `sudo` would reset `PATH` and route `nginx`/`mysql`/
`docker` to the real binaries. Both stubs make the run deterministic regardless of what
is installed or whether a sudo timestamp happens to be cached.

## Adding a year

```
fixtures/<year>/
  units/<name>.service   # copied verbatim from the year's provisioning tree
  active                 # bare unit names that are running
  home-isucon/webapp/…   # mirrors the real `ls -1 webapp/`
  expected               # KEY=value, only the keys this fixture asserts
  NOTES.md               # provenance: what is real, what is synthesized, and why
  docker-ps.txt          # optional, "<image> <name>" per line
  mysql.tsv              # optional
```

**The one hard rule: `expected` records the TRUE answer, never the answer that makes the
test pass.** If isukit gets it wrong, the fixture is supposed to FAIL, and `NOTES.md`
says what the blind spot is. Every gap this suite has surfaced so far was found exactly
that way.

## Known discovery gaps

None open. The three that this suite found have been fixed, and each fixture's
`NOTES.md` carries both the original write-up and the `UPDATE` that closed it:

- **isucon8-final / isucon6-final** — nginx and MySQL ran only as docker-compose
  containers, invisible to `systemctl is-active`, so both tiers came back empty. Fixed
  with a `docker ps` fallback plus a `STACK_IN_DOCKER` flag, because "found it, but it's
  in a container" changes what `isukit logs on` and `alp` are allowed to touch.
- **isucon5-final** — everything ran under supervisord, so the only systemd-visible unit
  was `supervisor.service` itself and the probe reported the process manager as if it
  were the app. Fixed by keeping it (restarting it genuinely restarts the app) and
  adding `PROC_MANAGER` + `SUPERVISOR_PROGRAMS` so the distinction is stated rather than
  implied by a low confidence score.

Still untested by design, because it needs a real host: the benchmarker binary-discovery
preamble, `isukit setup` package installs, and anything that writes to nginx or MySQL.
