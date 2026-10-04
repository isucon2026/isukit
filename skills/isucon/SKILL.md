---
name: isucon
description: Run the ISUCON measure -> diagnose -> one-fix -> PR -> re-measure loop against a live contest server. Use at the start of an ISUCON (or a practice run on a past isucon repo) to bring up instrumentation and then drive tuning from evidence only. Triggers - "isucon", "isukit", "ISUCON始める", "bench", "計測して直す".
---

# ISUCON agent loop

You are the measurement-and-attribution engine for an ISUCON team. Humans read the
manual and make product calls; you run the loop underneath them.

**The one rule that outranks every other instruction in this file: never change code
you have not measured.** If you cannot point at a line of alp / pt-query-digest /
pprof / benchmarker output that says a thing is slow, you do not touch that thing.
A plausible-looking N+1 that no profile implicates is not a finding, it is a guess.
Guesses are how teams spend eight hours going backwards.

`isukit` is your hands. This file is your judgment. Run `isukit help` for the exact
command surface; it is discovered-at-runtime by design and may know things this file
does not.

---

## 0. Situational awareness — do this before anything else

Establish which world you are in, because the loop differs:

| | Practice (a past `isucon/isuconNN` repo) | Contest day (ISUCON2026) |
|---|---|---|
| Benchmark trigger | a `bench` binary you run yourself | **a portal web UI a human clicks** |
| Bench host | yours, SSH-able | **off-limits — SSHing it is a rules violation** |
| Score source | benchmarker stdout | portal job result, pasted back by a human |
| isukit mode | `BENCH_MODE=auto` | `BENCH_MODE=manual` |

`isukit benchprobe` decides this for you and writes `BENCH_MODE` into `.isukit/config`
(it flips to `manual` the moment it finds no benchmarker binary). Check it with
`isukit benchmode`, and **believe it**. If it says `manual`, every `isukit bench` will stop and
ask a human to enqueue a run in the portal and paste the score. That is correct
behaviour, not a failure. Do not try to "fix" it by finding a bench binary to run —
on contest day there isn't one, and hunting for it on the bench host is prohibited.

Getting a shell on the servers is **not** part of this loop, and it differs between
contest day (the day's manual — in ISUCON14 a team CloudFormation template, `isucon@`,
GitHub keys) and practice (`launch/` + a past AMI, `ubuntu@` + a `.pem`). Read
`references/environment.md` once; never run `launch/` on contest day unless the manual
leaves the launch to you.

Then, once you can SSH, before touching anything:

0. Bring the whole kit up in one command, from the directory you want the problem repo in.
   No team repo yet (T+0): `isukit go --new <team>/<repo> <app-ssh-target> [-i <keyfile>]`
   — it commits the server's code and config as two baselines plus a CI, and pushes a
   private repo. Everyone else: `isukit go <repo-url> <app-ssh-target> [-i <keyfile>]`.
   Both write `.isukit/config`, probe the app host and the benchmarker (settling
   `BENCH_MODE`), install the tools and turn logging on, and print the exact next command
   for the bench mode they landed in — follow that, don't guess. If it half-finishes,
   `isukit doctor` re-runs the missing pieces; nothing in it is destructive to re-run.
1. Read the contest manual and regulations **in full**. They change every year. Extract
   and write into `.isukit/notes.md`: the score formula, the fail conditions, the
   `/initialize` contract (path, time limit, required response fields), the restart
   verification rules, and anything explicitly forbidden.
2. Confirm `isukit probe` output matches reality — especially `APP_UNIT`. If confidence
   is `low`, read `APP_CANDIDATES` and fix it with `isukit unit <name>` before doing
   anything else. Every later step depends on this being right.
3. Check `.isukit/manifest` for `STACK_IN_DOCKER` and `PROC_MANAGER` before you touch
   logging or restarts.
   - `STACK_IN_DOCKER=1` means the web and/or db tier only showed up via `docker ps`
     (isucon6-final, isucon8-final). `isukit logs on` / `isukit slow on` rewrite HOST
     config and are silent no-ops there — do not trust them, and do not conclude "no
     slow queries" from an empty slow log on this box. Edit the compose file / container
     config instead, then `isukit restart`.
   - `PROC_MANAGER=supervisor` (isucon5-final) means `APP_UNIT` is `supervisor.service`:
     restarting it restarts every language at once. To restart a single program, use
     `supervisorctl restart <program>` with a name from `SUPERVISOR_PROGRAMS`.
4. If the contest handed out **more than one instance**, give each its roles:
   `isukit host role <target> <app,web,db>`, then `isukit probe`, and commit
   `isukit.hosts` so every teammate's isukit targets the same boxes. deploy / restart go
   to app hosts, nginx logs and alp to web hosts, the slow log to db hosts, and `finalize`
   checks each host's roles. ISUCON2026 explicitly does **not** guarantee the order
   instances come back in, so never build a fix that assumes one host is up before another.
5. Take a baseline **on main**: `git switch main && isukit logs off && isukit bench baseline`.
   `attribute` judges every later change against the latest run deployed from main; a loop
   with no main baseline cannot attribute anything.

---

## 1. The loop

Repeat until the clock runs out. One pass = one change.

```
measure  ->  diagnose  ->  ONE fix  ->  ship (PR)  ->  re-measure  ->  keep or revert
```

### 1.1 Measure

```
isukit logs on          # nginx LTSV + mysql slow log (long_query_time=0)
isukit bench            # with logging ON — this run is for evidence, not for score
isukit show             # that run, saved: per-host CPU + top processes while loaded,
                        # alp, slow per db host, a CPU profile taken during the load
```

Read `show` top-down and the order is not stylistic: **the hosts block says which box and
process was pinned** (mysqld on the db host → the slow log; the app on an app host →
pprof; everything idle but the score flat → lock waits, external calls, app errors);
**alp says which endpoint, the slow log and pprof say why.** Going straight to the slow
log gets you optimising a query that the hot endpoint never calls.

Before you read alp output at all, check that dynamic path segments are grouped. isukit
derives the groups from the log (ids, UUIDs, long tokens, segments with very many values;
a far busier sibling like `/users/me` stays its own row) — `isukit alp --patterns` shows
them. If you still see `/users/1`, `/users/2` as separate rows, the ranking is meaningless:
put your own regexes in `ALP_MATCHES` (`.isukit/config` or the team's `isukit.conf`),
re-run alp, then read it.

Sort by **SUM**, never by AVG or MAX. The endpoint you must fix is the one consuming the
most total time. A 4-second endpoint called twice matters less than a 40ms endpoint called
ten thousand times.

### 1.2 Diagnose

Match the evidence against `references/trigger-fix.md`. That table is the accumulated
diagnosis knowledge from past winners' writeups and official 講評 — use it, do not
re-derive it.

Write the diagnosis down before you write any code, in this shape:

```
EVIDENCE:  <the literal line(s) from alp/slow/pprof, quoted>
CLAIM:     <what is slow, and why>
FIX:       <the single smallest change that tests the claim>
PREDICT:   <expected direction and rough magnitude of score change>
RISK:      <what this could break — correctness, /initialize, restart survival>
```

If you cannot fill `EVIDENCE` with literal tool output, **stop**. Go back to measuring.

`PREDICT` is not ceremony. It is the thing that makes the next step informative: a fix
that lands where you predicted confirms your model of the system; a fix that doesn't
means your model is wrong and the next three fixes built on it will also be wrong.

### 1.3 ONE fix

One change per bench run. Not two small related ones. Not "while I was in there".

The moment you bundle two changes, you have permanently lost the ability to know which
one helped — and given how noisy ISUCON scores are (see §2), you will likely end up
keeping a change that hurt because it rode in with one that helped.

Prefer, in this order:
1. **Index / query shape** — biggest ratio of score to risk, and reversible.
2. **N+1 collapse** — high value, moderate risk (ordering and dedup semantics change).
3. **Middleware config** (`innodb_buffer_pool_size`, nginx static serving, keepalive).
4. **Caching** — highest risk in the whole game. See §3.
5. **Architecture** (sharding, server split) — only with hours left and evidence that the
   DB is the system-wide binding constraint.

### 1.4 Ship

```
isukit ship "add composite index on reservations(user_id, created_at)"
```

This runs `go build` (and reports `go vet`) first, then branches, commits just your
working-tree change, pushes, and opens a **draft PR**.

The PR is not a review gate — nobody is going to review it inside eight hours, and the
server has to actually run the change to score it. It exists for three reasons, all of
which matter more under time pressure than code review does:

- **Attribution.** `isukit score` records the sha with every run, so the score history
  reads as a list of changes, not a list of numbers.
- **Revert handle.** When a change turns out to cost score, `isukit revert` takes exactly
  that change back out without disturbing the four good ones you shipped after it.
- **Parallel safety.** Two humans and an agent editing one checkout is how a team loses
  an hour to a merge they didn't intend. Branches are parallel; **the servers are not** —
  measuring is a turn (next section).

### 1.5 Re-measure

Measuring is a turn on shared servers. On your branch:

```
git fetch && git rebase origin/main   # main as it is now + your one change
isukit lock                           # others' deploy / bench now stop with "busy — <you>"
isukit deploy                         # refuses uncommitted work or a branch without main
isukit logs off                       # logging costs real score — never score with it on
isukit bench "<what you changed>"     # posted to Discord #bench, shared on isukit-runs
```

### 1.6 Keep or revert

`isukit attribute` compares the latest run against **the latest run deployed from main**
(not against the other person's branch), **with the noise band applied**. Its verdict is
one of:

- **KEEP** — improvement is outside the noise band. Merge the PR (`gh pr merge`) right
  away so the other branch can rebase onto it, then `isukit unlock`.
- **REVERT** — regression is outside the noise band. Do not merge; `git switch main &&
  isukit deploy` to put main back, `isukit unlock`, and take the lesson.
- **INCONCLUSIVE** — the delta is inside the noise band. This is the common case and the
  one where discipline is actually tested. Re-run the bench 2–3 more times before
  deciding. Do **not** stack the next change on top of an unresolved one; you will never
  untangle them.

Then go back to 1.1 — **re-measure from scratch**. Do not carry forward your old ranking.
The bottleneck moves after every successful fix; this is the single most-reported mistake
in the entire writeup corpus. The alp output you took three fixes ago is describing a
system that no longer exists.

---

## 2. Score noise — why single runs lie

This is not a caveat, it is a load-bearing property of the contest:

- ISUCON13's own cautionary notes treat a restart-rerun scoring under **75%** of the live
  score as a pass, i.e. the organisers themselves tolerate a 25% warm-vs-cold spread.
- ISUCON14's 講評 documents 「かなりぶれていたベンチマークスコア」 — noise injected by `rand`
  in the problem's own matching logic, not by anything competitors did.
- ISUCON10's portal silently failed 1,546 bench jobs and left 1,808 stuck. Some fraction
  of "my change did nothing" that year was infrastructure.

Consequences you must actually act on:

- **A single run never attributes a change.** Treat any delta under ~10% as noise until
  two more runs agree with it.
- Run the **same** revision twice early on to measure your own noise floor. Fifteen
  minutes spent there saves you from chasing three phantom regressions later.
- If the score swings on genuinely unchanged code, suspect nondeterminism in your own hot
  path (map iteration order, `rand`, goroutine scheduling) before blaming infrastructure.
- **Never fabricate or round up a score.** Score fabrication is disqualification. If a run
  failed, record it as failed.

---

## 3. Caching — read this before you cache anything

Caching is the most-reported score-destroyer in the corpus, and it destroys score in a
specific way: it makes the benchmarker's validation phase fail, which costs you far more
than the caching gained. Before adding any cache, answer all four in writing:

1. **Every** write path that invalidates this — have you enumerated them, including the
   ones in other handlers, in batch jobs, and in `/initialize`?
2. Does `/initialize` clear it? If the cache survives a reset, the next bench run starts
   from corrupted state and every subsequent measurement is garbage.
3. Does it survive a process restart correctly — or does the app come back serving stale
   data that the post-contest restart verification will catch?
4. Under concurrency, can a thundering herd on a cold key make this *worse* than no cache?
   (NaruseJun's ISUCON12 run: `singleflight` on the master-version cache turned a wild
   200k–270k swing into a reliable 270k+.)

If you cannot answer all four, do a different fix. There is always a different fix.

---

## 4. Restart survival — test it during the contest, not at the end

Every year a significant number of teams post a good live score and then fail the
post-contest restart verification, scoring zero. It is always the same cause: settings
applied at runtime that were never written down — `SET GLOBAL ...`, a manually-started
service, a file in `/tmp`, a process launched by hand outside systemd.

`isukit finalize` runs the real thing: logs off → reboot every host → verify each host's
roles came back → ask every web host (through nginx) and app host (directly) over HTTP →
score. Set `FINAL_CHECK_PATH` to a path that touches the DB, so "up but cannot reach the
DB" fails here and not in the organisers' re-run. **Run it at least twice during the
contest**, not once at the end. Before the last one, `isukit final check` lists everything
that still logs or measures (nginx access_log, the slow log, app loggers, pprof) and
`isukit final apply` turns off what config can. p1ass lost
ISUCON10 qualification to an `/initialize` timeout that only ever appeared after a cold
boot — it was invisible in every warm run they did all day.

Every config change must land in a file on disk that survives reboot. If you typed it
into a mysql prompt, it does not count.

---

## 5. Hard prohibitions

Violating any of these can disqualify the team. They are not negotiable and they are not
subject to "but it would help":

- **Do not access the benchmarker server**, by SSH or otherwise.
- Do not benchmark via external resources outside the approved servers.
- **Do not create EC2 instances other than those the manual tells you to create.** The
  harness must never spin up a helper box of its own.
- Do not change instance types, security groups, or the `envcheck` service.
- Do not do anything on the servers after the contest end time.
- Do not fabricate scores.

If a fix you are considering needs any of the above, it is not a fix. Drop it.

---

## 6. Time discipline

Rough shape of an 8-hour contest. Adjust, but know when you are behind:

| Elapsed | What must be true |
|---|---|
| +0:30 | Manual read, repo initialised, all members have server access |
| +1:00 | `isukit probe` correct, logs on, **baseline score recorded** |
| +1:30 | First alp/slow triage done, first fix shipped and measured |
| +5:00 | Stop starting architecture-scale changes; nothing new gets finished after this |
| +7:00 | **Feature freeze.** `isukit final check` / `final apply`, then `isukit finalize`. Only revert, never add |
| +7:30 | Final `isukit finalize`, confirm every host answers and the restart run scores |
| +8:00 | Hands off the servers |

The +7:00 freeze is the one people skip and regret. A change that is measured but not
restart-verified is a change that might be worth zero.

---

## 7. When isukit itself fails

The kit discovers everything at runtime precisely because ISUCON's shape changes every
year, so discovery failing is an expected state, not a broken tool. Work the failure:

- `isukit doctor` — self-diagnoses the config/manifest and repairs what it can.
- "busy — <who>: <what> for Nm" → someone else's turn. `isukit lock status`; only if they
  are gone, `isukit unlock --force`.
- deploy refuses → commit (`isukit ship`) and `git rebase origin/main`; `--force` only if
  you accept that nobody can reproduce that run.
- Probe picked the wrong app unit → `isukit unit <name>` (read `APP_CANDIDATES` first).
- No bench binary found → you are in portal mode. Set `isukit benchmode manual` and carry
  on; this is normal on contest day.
- `BENCH_CMD` composed wrong → `isukit benchcmd '<corrected>'`. The flag names differ
  every year; the auto-composition is a starting point, not an oracle.
- Web server is not nginx (Envoy and h2o have both appeared) → `isukit logs` won't help.
  Profile at the application layer instead.
- Score history looks wrong → `isukit score` prints it; rows are appended, so a bad row
  is edited by hand in `.isukit/scores.tsv`, never silently recomputed.
- Nothing works → fall back to raw `ssh`, `journalctl -u <unit>`, `mysql`, `top`. The kit
  is a convenience. The loop in §1 is the actual method, and it runs fine by hand.

**Report what actually happened.** If a step was skipped or a run failed, say so. A
harness that hides failures is worse than no harness, because the team will act on the
score history as if it were true.

---

## References

- `references/trigger-fix.md` — the full signal → diagnosis → fix table, with effort and
  risk per row, plus the ranked list of known traps.
- `references/variance.md` — how past ISUCONs differed year to year. Read this when
  discovery fails and you need to know what shapes are plausible.
- `references/initialize.md` — the `/initialize` contract and how teams have failed it.
- `references/environment.md` — getting a shell: contest day (the manual; ISUCON14's
  CloudFormation / `isucon@` / GitHub keys, account risks) vs practice (`launch/`).
