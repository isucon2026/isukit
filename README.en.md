# isukit

One command from a repo URL to an instrumented, measurable app host.

**Contest playbook — phases, team rules, failure modes: [`RUNBOOK.md`](RUNBOOK.md).**

## Install

    curl -fsSL https://raw.githubusercontent.com/isucon2026/isukit/main/install.sh | bash

Clones/updates into `${ISUKIT_HOME:-$HOME/.isukit-src}` and symlinks `isukit`
onto PATH. Args after the script forward to the freshly installed `isukit`, so
this is also a genuine one-liner from zero to a probed, instrumented host:

    curl -fsSL https://raw.githubusercontent.com/isucon2026/isukit/main/install.sh \
      | bash -s -- go <repo-url> ubuntu@<ip> -i ~/.ssh/key.pem

    ./isukit go <repo-url> <app-ssh-target> [bench-ssh-target] [-i keyfile] [-p port]

That clones, probes the server, installs `alp` + `pt-query-digest`, turns on
LTSV nginx logging + `long_query_time=0`, and composes `BENCH_CMD` by reading
the benchmarker binary's own `--help`. Sanity-check that line, then you're in
the loop.

## The loop

    isukit bench "baseline"     # runs BENCH_CMD on the bench host, records score+git sha
    isukit alp                  # endpoints ranked by SUMMED response time
    isukit slow                 # queries ranked by total time
    isukit pprof 30             # Go CPU profile, if pprof is wired in
    isukit attribute            # compare last two runs; KEEP / REVERT / INCONCLUSIVE
    # change exactly ONE thing
    isukit deploy               # rsync + build onto the systemd ExecStart path + restart
    isukit bench "added idx X"  # record the score; manual mode prompts for the value
    isukit ship "added idx X"   # commit everything + push + draft PR, one change per commit
    isukit score                # full history

## Middleware config under git

    isukit etc adopt            # /etc -> <server repo>/etc/<same path>, symlinked back
    isukit etc status           # which repo files /etc actually reads
    isukit etc push             # local etc/ -> server; reload/restart only what changed
    isukit etc pull             # server etc/ -> local etc/

`adopt` discovers `nginx.conf`, the enabled site confs, every `.cnf` with a
`[mysqld]` section and the app's unit file, moves each into
`<server repo>/etc/` (e.g. `etc/nginx/sites-available/isucon.conf`), symlinks
`/etc` to it and keeps the original as `<path>.orig`. It then checks each tier
(`nginx -t` + reload, `daemon-reload`, mysql restart + `SELECT 1`) and rolls
back only the tier that fails. On Ubuntu it also adds the AppArmor rule mysqld
needs to read through the link. If the repo already has a file (rebuilding a
box from the repo), the repo copy wins. Once `/etc` is linked, `deploy` runs
`etc push` first. The server repo is the git root of the probed `SRC_DIR`;
override with `ETC_REPO` in `.isukit/config`. The host-side scripts live in
`remote/`.

`isukit probe` picks the app's systemd unit with a scored heuristic, not a
guarantee — see "Why it probes instead of assuming" below. If it picked wrong:

    isukit unit <systemd-unit-name>   # override + re-probe

Diagnostic:

    isukit doctor               # non-destructive check + auto-repair of config, connectivity, bench mode

Endgame:

    isukit finalize             # logs OFF -> reboot ALL hosts -> verify units -> score

## Why it probes instead of assuming

Nothing about ISUCON repo layout is stable. Checked across isucon9, 10-q, 10-f,
11-q, 11-f, 12-q, 12-f, 13, 14, and private-isu — every one of these changed:

| Thing | Observed range |
|---|---|
| Go source dir | `webapp/go`, `webapp/golang` |
| Language set | 4–8 impls; Deno once, Java once, Perl comes and goes |
| Build tool | Makefile → Taskfile.yml → neither |
| docker-compose | root / per-language / `development/` / `dev/` / **absent entirely** (10-f, 12-f) |
| systemd naming | `app.lang.service`, `app-lang.service`, `app-api-lang.service` + `app-web-lang.service`, one non-language wrapper unit |
| Extra units | matcher, payment mock, JIA API mock, PowerDNS, shipment/payment simulators |
| Env file | `/home/isucon/env.sh`, `/home/isucon/env`, none |
| Env var names | `ISUCON13_MYSQL_*` (year-prefixed) → `ISUCON_DB_*` (year-agnostic) → ad-hoc `MYSQL_*` |
| Web server | nginx — **except isucon10-final, which is Envoy** |
| Datastore | MySQL 5.7 / 8.0 / 8.0.31, MariaDB 10.3, + per-tenant SQLite (12-q) |
| Bench target flag | `-target`, `-target-url`, `-target-host`, `-target-addr`, `--target` |
| App instances | 3 (usual), 5 (12-f), 1 documented (9) |

Also: **there is no isucon15.** The org stopped sequential numbering after 14;
the next event is ISUCON2026 (2026-10-31, run by Sakura Internet). Don't write
tooling that assumes `isucon{N+1}`.

`isukit probe` therefore reads none of that from the repo. It asks the running
machine:

- **systemd is the source of truth.** It lists units whose fragment lives under
  `/etc/systemd/system` (i.e. provisioned, not distro), then `systemctl show`s
  the active one for `WorkingDirectory`, `ExecStart`, `EnvironmentFiles`, `User`.
  That single trick survives every naming convention above, including the Envoy
  year and the docker-compose-wrapper year.
- Web server and datastore by probing `is-active` across a candidate list.
- nginx log path and config files from `nginx -T`, not a guessed path.
- Go module dir by finding `go.mod` (excluding `bench*` and vendor).

The benchmarker invocation is the same story: no common flag contract across
years, so `isukit probe` (via `isukit benchprobe`) finds the benchmarker binary
under `/home/isucon` on `$BENCH`, reads its own `--help`, and composes
`BENCH_CMD` from that — see "BENCH_CMD is auto-composed, verify it" below.

**Known limit:** app-unit selection is a scored heuristic (workdir under
`/home/isucon`, exec path, env file, running user, ...), not a certainty — an
unusual layout can outscore the real app unit. `isukit probe` prints
`APP_CANDIDATES` (all units it scored, highest first) and warns when its pick
is low-confidence. Sanity-check that line; fix a wrong pick with
`isukit unit <name>`.

## Discipline (generic, not answer-specific)

- **Rank by summed time, never by mean or by count.** A 3ms endpoint hit 40,000
  times outranks a 900ms one hit twice. `alp --sort=sum` is the default here for
  that reason. Same for `pt-query-digest`, which ranks by total time already.
- **Bench before touching anything.** A baseline you didn't record is a change
  you can't evaluate.
- **One change per bench run.** Two changes and a score move tells you nothing.
- **Measurement costs score.** `long_query_time=0` and LTSV logging are heavy.
  `isukit logs off` before any run whose number you intend to keep.
- **Nothing counts until it survives a reboot.** Runtime-only state — `SET
  GLOBAL`, hand-started services, files in `/tmp`, disabled units — evaporates.
  This is where large fractions of teams lose everything on the final run.
  `isukit finalize` is that check.
- **Read the app's own logs before optimising.** An error the benchmarker is
  quietly retrying is worth more score than any index.

## Files

    .isukit/config        APP, BENCH, BENCH_CMD, SSH_OPTS, EXTRA_UNITS, EXTRA_HOSTS, BENCH_MODE
    .isukit/manifest      probe output, sourced by every other command
    .isukit/scores.tsv    when / sha / score / note / raw log
    .isukit/bench-*.log   full benchmarker output per run

All git-ignored. `.isukit/` lives inside each cloned problem repo, so multiple
contests coexist without stepping on each other.

Subdirectories: [`launch/`](launch/README.md) holds AWS pre-contest staging and
instance bootstrap scripts; [`skills/isucon/`](skills/isucon/SKILL.md) is a Claude
skill for the measure → diagnose → fix → ship → re-measure loop; [`test/`](test/)
is an offline fixture suite that validates the discovery logic against every past
ISUCON's real systemd units and configs.

## Caveats

- **BENCH_CMD is auto-composed, verify it.** `isukit benchprobe` picks the
  largest ELF binary under `/home/isucon` matching a benchmarker-ish name,
  reads its `--help`, and builds `sudo -iu <owner> sh -c '...'` from whatever
  target/nameserver flags it finds — this is the line most likely to need
  human correction. `.isukit/bench-help.txt` holds the full flag list it was
  read from. Fix it with `isukit benchcmd '<command>'` (no argument prints the
  current value); `isukit benchprobe` never overwrites a `BENCH_CMD` you've
  already set.
- `logs on` backs `/etc/nginx` up to `/etc/nginx.isukit.bak`, adds
  `conf.d/00-isukit.conf` and comments existing `access_log` lines out as
  `#isukit# access_log`, editing the real file behind any symlink. `logs off`
  undoes exactly those marked edits (the backup is kept for manual recovery
  only), so repo-linked configs stay linked and keep any tuning made since.
  While logs are on, the server's repo copy carries those markers; `etc pull`
  strips them. If the web server isn't nginx,
  `probe` warns and `logs` does nothing for the web tier.
- MySQL automation needs passwordless `sudo mysql` over the unix socket. `probe`
  reports `MYSQL_OK=0` if that isn't available.
- `pprof` requires `import _ "net/http/pprof"` plus a listener in the app; the
  command tells you the snippet if the endpoint isn't there.
- `deploy` assumes a Go app and builds onto the exact path systemd already
  execs. For a non-Go impl, deploy by hand.
- `SSH_OPTS` (config) is appended to every `ssh`/`scp` call — custom key, custom
  port, custom config file. Note ssh takes `-p <port>` but scp takes `-P
  <port>` — if you hand-roll a port flag, you need both forms.
- `EXTRA_UNITS` (config) is a space-separated list of extra units that
  `restart`/`finalize` also restart alongside the detected `APP_UNIT` —
  matcher/mock/simulator services some years ship as separate units.
- `EXTRA_HOSTS` (config) is a space-separated list of additional app instances
  (set via `isukit host add <target>`). Both `restart` and `finalize` iterate
  every host; restart order is not guaranteed across instances.
- `BENCH_MODE` (config) is either `auto` (runs `BENCH_CMD` over ssh to the bench
  host) or `manual` (you enqueue the run in the contest portal and record the
  score with `isukit bench --score <N>`). `isukit benchprobe` auto-detects `manual`
  mode when no benchmarker binary is found. On contest day (ISUCON11 onward) the
  benchmark is triggered from a web portal, not from ssh, so `manual` mode is the
  correct production state — not a failure. Flip modes with `isukit benchmode <mode>`.
  In manual mode, use `isukit bench --score <N> "<note>"` to record a passing run,
  or `isukit bench --fail "<note>"` when the run errored.
- `isukit revert [<sha>]` undoes a single commit on an `isukit/*` branch — useful
  for reverting a bad change mid-contest without losing the record in `scores.tsv`.
