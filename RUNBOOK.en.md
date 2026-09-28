# ISUCON runbook

Contest-agnostic. Phases are percentages of total contest time so this works for
a 3h mock and an 8h real run alike. The 8h column is just the arithmetic.

## What isukit is

A bootstrap + measurement kit for ISUCON, at `~/personal-projects/isucon/isukit/`.
One bash script, no dependencies. It does four things and nothing else:

1. **Bootstrap** — `isukit go <repo-url> <app-host> [bench-host]` clones the
   problem repo, interrogates the server, installs `alp` + `pt-query-digest`,
   and turns on LTSV nginx logging + `long_query_time=0`.
2. **Discover** — `probe` asks the *running host* what the app is (systemd unit,
   `WorkingDirectory`, `ExecStart`, env file, datastore) and writes
   `.isukit/manifest`. It deliberately reads nothing from the repo, because no
   part of ISUCON repo layout is stable across years — Go dir, build tool,
   compose presence, unit naming, env file, env var names and bench flags all
   differ. Interrogating systemd is the one trick that survives all of them.
   When systemd finds nothing (isucon6-final, isucon8-final, or a local
   `make up` dev stack all run under docker-compose), `probe` falls back to
   `docker ps` and still fills in `WEB_SERVER`/`DB_SERVER`, setting
   `STACK_IN_DOCKER=1`. `deploy` / `logs on` / `slow on` still only ever touch
   host config, so they no-op on that box — edit the compose file / container
   config directly, then `isukit restart`.
3. **Measure** — `bench` records score + git sha per run; `alp` / `slow` /
   `pprof` rank endpoints and queries by *summed* time; `score` is the history.
4. **Ship** — `deploy` builds onto the exact path systemd already execs;
   `finalize` runs the endgame (logs off → reboot → verify units → score).

Per-contest state lives in `.isukit/` inside each cloned problem repo, so
multiple contests coexist. The one thing it cannot discover is `BENCH_CMD`: the
benchmarker's target flag differs every year, so that line is filled by hand.

Architecture, the unit-picking heuristic, and the caveats (nginx-only `logs`,
Go-only `deploy`, passwordless-`sudo` requirement) are in `README.md`.

| Phase | % of clock | 8h | Rule |
|---|---|---|---|
| 0 Access | before start | — | Nothing is measured yet |
| 1 Baseline & recon | 0–12% | 0:00–1:00 | **No code changes** |
| 2 Cheap structural | 12–40% | 1:00–3:15 | One change per bench |
| 3 Distribute | 40–60% | 3:15–4:50 | Only after single-host is profiled |
| 4 Application logic | 60–80% | 4:50–6:25 | Highest risk, highest ceiling |
| 5 Freeze & verify | 80–100% | 6:25–8:00 | **Change freeze at 80%** |

---

## Team rules — agree to these before the clock starts

- **One bench owner.** Only one benchmark runs at a time, and one person queues
  them. Two concurrent runs make every number meaningless.
- **One branch, small commits.** `isukit` records the git sha with every score;
  that's only useful if a sha means one change. Use `isukit ship "<note>"` to
  automate this: creates a new `isukit/<slug>` branch, commits, pushes, and opens
  a draft PR — one commit per meaningful change, so it's revertable.
- **One change per bench run.** Two changes and a score move tells you nothing
  about which one did it.
- **Score drops → revert immediately.** Don't debug a regression during the
  contest. `isukit revert` undoes the last commit (or any commit by sha), then
  re-bench to confirm you're back and move on.
- **30-minute timebox.** A change that hasn't moved the score in 30 minutes gets
  dropped, not pushed harder.
- **Say the number out loud.** Every bench result gets announced. Nobody
  optimises against a stale mental model of the score.

Suggested split for three people: one on infra/measurement (owns `isukit`,
alp/slow output, deploys, the score log), one on DB (schema, indexes, queries),
one on app code. The infra person is also the bench owner.

---

## First steps when things go wrong

Run `isukit doctor` — it's a non-destructive diagnostic and auto-repair:

```
isukit doctor   # check config / connectivity / manifest / unit / tools / logs / disk / bench mode
isukit os       # quick OS snapshot: uptime / vmstat / iostat / mpstat / free / df
```

---

## Phase 0 — Access (before the clock)

```
ssh <app-host> true && ssh <bench-host> true     # both must succeed NOW
chmod 600 ~/.ssh/<contest>.pem                    # ssh refuses 644
./isukit go <repo-url> <app-host> <bench-host>
```

**Repo already cloned?** `init` adopts an existing directory instead of cloning
it. Run it from the *parent* dir, passing the dir name, then continue by hand:

```
isukit init <repo-url> <existing-dir>   # skips the clone if <existing-dir> exists
cd <existing-dir>
isukit host app <ssh-target|local>
isukit probe
```

Note `init` also creates and switches to a `work` branch in that repo.

Then open the repo README and fill the single line the kit can't discover:

```
$EDITOR .isukit/config      # BENCH_CMD='...'
```

The benchmarker's target flag is different every year — `-target`,
`-target-url`, `-target-host`, `-target-addr`, `--target`. Copy it verbatim from
the README; don't guess it.

Read `.isukit/manifest` aloud to the team: how many instances, which units are
running, how much RAM, which datastore. That's your machine budget for the day.

---

## Bench modes: `auto` and `manual`

**Auto mode** — `isukit bench` runs `BENCH_CMD` via ssh on the bench host.
Standard for practice.

**Manual mode** — the benchmarker is triggered from a contest portal (web UI),
and you record the score by hand. **This is the correct production state on
ISUCON11+.** SSH-triggered benches are forbidden; the benchmark portal is your
only tool.

On contest day, enqueue the run in the portal and record the result:

```
isukit bench --score 12345 "added index X"   # record a passing run
isukit bench --fail "timeout"                 # record a failure
```

`isukit benchprobe` auto-detects `manual` mode when no benchmarker binary is
found on the bench host. Switch modes by hand anytime:

```
isukit benchmode manual      # toggle auto ↔ manual
isukit benchmode             # show current mode
```

**Why this matters:** practice with `manual` mode to be ready for contest day.

---

## Phase 1 — Baseline & recon (0–12%) · no code changes

**1. Get the number.**

```
isukit logs off
isukit bench "baseline"
```

Measurement logging costs real score, so the baseline is taken clean. Every
later decision is "did it beat this?"

**2. Read the manual while the bench runs.** Specifically hunt for:

- What the score formula actually rewards. Throughput is not always it —
  some years weight specific endpoints, penalise errors, or gate on a ratio.
- **Failure conditions.** These zero you regardless of speed.
- The `/initialize` timeout and what it must return.
- Anything the rules forbid (returning fake data, dropping tables, etc).

**3. Read the app's own error log.** Errors the benchmarker quietly retries are
free score, and they're invisible in a latency profile.

```
ssh <app-host> 'journalctl -u <APP_UNIT> -n 200 --no-pager'   # unit name is in .isukit/manifest
```

**4. Now instrument and re-bench.**

```
isukit logs on
isukit bench "instrumented — do not compare to baseline"
isukit alp
isukit slow
```

**Read `alp` by summed response time, never by mean or count.** A 3ms endpoint
hit 40,000 times outranks a 900ms one hit twice. The kit sorts that way by
default. Same for `pt-query-digest`, which already ranks by total time.

Write the top 3 endpoints and top 3 queries somewhere the whole team can see.
That list is the work queue for phase 2.

---

## Phase 2 — Cheap structural wins (12–40%)

Generic, in rough order of payoff-per-risk. Verify each against *your* profile
before doing it — this is a checklist of where to look, not a list of answers.

- [ ] **Missing indexes.** From `isukit slow`: columns appearing in `WHERE`,
      `ORDER BY`, and `JOIN` conditions on the heaviest queries. `EXPLAIN` before
      and after. Reference implementations routinely ship with none.
- [ ] **N+1 queries.** Signature in `pt-query-digest`: a query with a huge call
      count and small per-call time dominating total time. Fix by joining or by
      batching with `IN`.
- [ ] **Static files served by the application.** Move them to the web server.
      Check `isukit alp` for asset paths appearing at all.
- [ ] **Connection pool defaults.** In Go, `SetMaxOpenConns` /
      `SetMaxIdleConns` unset means unbounded opens and 2 idle — pathological
      under load. Size it to the DB's `max_connections`, not higher.
- [ ] **Per-request work that isn't per-request.** Config parsed, templates
      compiled, files read, or crypto derived inside the handler.
- [ ] **Expensive password hashing / crypto** on a hot path with a tunable cost
      factor.
- [ ] **App-side sorting or filtering of a full table** that the DB could do with
      an index.
- [ ] **The web server's own limits** — worker count, `keepalive` to upstream,
      open file limits. Cheap, but only after the app stops being the bottleneck.

After each one: `isukit deploy` → `isukit bench "<what you changed>"`. Keep or
revert on the number alone.

Benchmark scores jitter run-to-run, so small deltas are not meaningful. Use
`isukit attribute` to compare the last two runs; it returns KEEP / REVERT /
INCONCLUSIVE based on whether the delta exceeds the noise band (default ±10%):

```
isukit attribute           # default: ±10% threshold
isukit attribute 5         # set threshold to ±5%
```

Always one change per run — if you stack two changes and the score moves, you
don't know which one did it.

---

## Phase 3 — Distribute across instances (40–60%)

Only start this once a single host is profiled and the bottleneck is *known*.
Splitting services before you know what's hot just moves the problem plus adds
network latency.

Typical progression, contest-independent:

1. Move the datastore to a second instance. Update the app's connection config —
   it comes from the env file (`ENV_FILE` in `.isukit/manifest`), not from code.
2. Confirm the DB actually accepts remote connections and the app reconnects.
3. `isukit bench` — this can *lose* score if the app was never DB-bound. Revert
   if so.
4. Put a second app instance behind the web server, load-balanced.

Every distribution step adds a new thing that must survive a reboot. Note each
one; phase 5 checks them.

---

## Phase 4 — Application logic (60–80%)

Highest ceiling, highest risk of breaking benchmark validation. Generic patterns:

- [ ] **Cache what doesn't change per request** — in-process for single-instance,
      shared store once distributed. Get invalidation right or you fail
      validation, which scores 0 no matter how fast you are.
- [ ] **Precompute on write instead of on read**, when reads dominate the profile.
- [ ] **Batch external calls and DB round-trips.**
- [ ] **Stop generating data you throw away** — over-fetched columns, rows
      filtered in the app, responses built then discarded.
- [ ] **Profile before believing any of this.** `isukit pprof 30` if the app has
      `net/http/pprof` wired in; otherwise wire it in early, it's a two-line
      change.

Re-run `isukit alp` after each accepted change. The bottleneck moves, and the
top of the list from phase 1 is stale by now.

---

## Phase 5 — Freeze & verify (80–100%)

**Change freeze at 80%.** No new optimisations after this point, regardless of
how good the idea is. This phase is about not losing what you already earned.

```
isukit logs off          # measurement logging is costing you score right now
isukit finalize          # logs off -> reboot ALL hosts -> verify units -> scoring run
```

`finalize` exists because runtime-only state evaporates on reboot, and the
final scoring run happens on a machine that may have been restarted. If you have
multiple instances (set via `isukit host add`), `finalize` reboots all of them,
though restart order is not guaranteed. Manually confirm each of these:

- [ ] Every service you depend on is **enabled**, not merely running:
      `systemctl is-enabled <unit>` for each unit in `.isukit/manifest`.
- [ ] Every `SET GLOBAL` you made is **also in the config file**. Runtime MySQL
      variables do not survive a restart.
- [ ] Nothing you need lives in `/tmp`.
- [ ] Slow query logging is **off** and its log file is deleted — at
      `long_query_time=0` it can fill the disk.
- [ ] Disk has free space: `df -h`.
- [ ] The app starts from cold with no manual step.

Then run the benchmark two or three more times. Scores vary run to run; you want
to know your *reliable* number, not your luckiest one. If a late run fails, you
still have time to revert to the last green sha from `isukit score`.

Stop touching things at 95%.

---

## Failure modes that cost whole contests

These are the generic ways teams lose everything, independent of the year's problem:

| Failure | Prevention |
|---|---|
| Measurement logging left on for the final run | `isukit logs off`, verified in phase 5 |
| Config applied at runtime only, lost on reboot | `isukit finalize`, plus the enabled-units check |
| Service not enabled, dead after reboot | `systemctl is-enabled` on every unit |
| Disk full from `long_query_time=0` | Delete the slow log during phase 5 |
| Benchmark validation failure | Re-bench after *every* caching change |
| `/initialize` exceeding its timeout | Keep initialisation cheap; time it |
| Two benches running at once | One bench owner, enforced |
| Unrevertable state — schema edited by hand | All schema changes go in a migration file in git |
| No baseline recorded | Phase 1 is not optional |

---

## Subdirectories

- **`launch/`** — AWS pre-contest staging and instance bootstrap scripts
  (`prestage.sh`, `launch.sh`, `user-data.sh`). Used only if your organizers say
  "launch from this AMI" with no turnkey template. See [`launch/README.md`](launch/README.md).
- **`skills/isucon/`** — Claude AI skill for the measure → diagnose → fix →
  ship → re-measure loop. Symlinked to `~/.claude/skills/` by `install.sh`.
  Activate with `/isukit`.
- **`test/`** — offline fixture suite that validates discovery logic against
  real ISUCON systemd units and nginx configs from past years. Run with
  `test/run-all.sh`. See [`test/README.md`](test/) — the "## Known discovery gaps"
  section documents the tool's real limits.

---

## Quick reference

```
isukit doctor               # diagnose + auto-repair config, connectivity, bench mode
isukit os                   # server snapshot: uptime / vmstat / iostat / mpstat / free / df
isukit probe                # re-read the server after any infra change
isukit bench "note"         # score + git sha -> .isukit/scores.tsv (manual mode: --score N / --fail)
isukit score                # full run history
isukit attribute [pct]      # compare last two runs; KEEP / REVERT / INCONCLUSIVE
isukit alp                  # endpoints by summed response time
isukit slow                 # queries by total time
isukit pprof 30             # Go CPU profile -> .isukit/cpu.pprof
isukit deploy               # rsync + build onto the systemd ExecStart path + restart
isukit restart              # restart discovered app units (+ EXTRA_HOSTS)
isukit logs on|off          # nginx LTSV + mysql slow log
isukit ship "note"          # new branch -> commit -> push -> draft PR
isukit revert [sha]         # git revert to undo a change
isukit finalize             # the endgame sequence (all hosts)
```

### Key manifest fields

| Key | Meaning |
|---|---|
| `APP_UNIT` | Discovered systemd unit for the app |
| `APP_UNIT_CONFIDENCE` | Confidence in `APP_UNIT`: `high` / `low` / `override` |
| `ENV_FILE` | Path to the env file the app reads |
| `WEB_SERVER` | Discovered web server (e.g. `nginx`) |
| `DB_SERVER` | Discovered datastore (e.g. `mysql`) |
| `STACK_IN_DOCKER` | `1` if web and/or db was found only via `docker ps` (`systemctl` saw nothing). `logs on` / `slow on` only ever rewrite host config, so they're silent no-ops here — edit the compose file / container config directly, then `isukit restart` |
| `PROC_MANAGER` | `systemd` or `supervisor`. When `supervisor`, `APP_UNIT` is `supervisor.service`, and restarting it restarts every program under it |
| `SUPERVISOR_PROGRAMS` | Only set when `PROC_MANAGER=supervisor`. Space-separated program names from `supervisorctl status`. Restart a single one with `supervisorctl restart <program>` |
