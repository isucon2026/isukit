---
name: isucon-start
description: Bring an ISUCON team from "the organizers just gave us an IP" to "instrumented, baselined, and in git" — adopt the server's code into the team repo, verify isukit's discovery against the real box, read the manual for the scoring and disqualification rules, and record a baseline. Run this once at T+0, then hand off to /isucon. Triggers - "isucon-start", "ISUCON開始", "T+0", "contest just started", "we got the IP".
---

# ISUCON T+0 bootstrap

You run the first hour. The loop skill (`/isucon`) runs the other seven.

Your job is to turn an SSH target into a measured, version-controlled, understood
starting position — and then stop. **You do not optimize anything in this skill.**
Not one index, not one query, not one line of application code. A team that starts
tuning before it has a baseline has thrown away its ability to tell whether anything
it does afterwards worked.

`isukit` is your hands. Run `isukit help` for the live command surface — it is
authoritative over this file.

---

## What you were given

The invocation looks like:

    /isucon-start ubuntu@<ip> -i ~/.ssh/<key>.pem [bench-host] [--repo <team-repo-url>]

If `--repo` is absent, ask for it once before doing anything destructive — the team
repo URL is the one value that cannot be discovered from the server. Everything
else you may infer or probe for. If the team has no repo yet, that is fine: `isukit
adopt` creates it.

Defaults for this team, to be confirmed not assumed: org `isucon2026`, collaborators
`n000r111` and `imaharu`, AWS profile `sandbox` in `ap-northeast-1`.

---

## 1. Preflight — before the clock eats anything

    chmod 600 <keyfile>
    ssh <app-host> true

A `644` key is rejected by ssh with a message that reads like a server problem.
Check it first; it costs a second and it is the single most common T+0 stall.

If the host is unreachable, stop and say so plainly. Do not start guessing at
security groups — on contest day the SG was fixed at prestage time and **cannot be
changed after launch**, which is an ISUCON rule, not an AWS limitation. An
unreachable host is a human escalation, not something to work around.

---

## 2. Adopt the server's code into the team repo

    isukit adopt <team-repo-url> <app-host> -i <keyfile> \
      --collab n000r111 --collab imaharu

This is the step with a deadline on it. Until it finishes, the contest code exists
in exactly one place — the server — and only one person can work on it.

`adopt` pulls the tree down to this laptop, commits it as an untouched baseline,
creates the private repo, pushes, and invites the other two. The direction matters:
nothing is ever pushed *from* the contest box, because the box has no GitHub
credential and minting one at T+0 is pure waste.

**The baseline commit is the only place the team can retreat to.** If `adopt`
reports that it had nothing to commit, something is wrong — investigate before
continuing, do not shrug it off.

When it finishes, tell the other two humans their one command:

    isukit go <team-repo-url> <app-host> -i <their-key>

---

## 3. Verify the discovery — the part that actually needs you

`isukit probe` asks the running machine rather than reading the repo, because no
two ISUCON years lay their repos out the same way. It is a **scored heuristic, not
a guarantee**, and this is the moment to audit it. Read `.isukit/manifest` and
check each line against the real box:

| Manifest key | How you verify it |
|---|---|
| `APP_UNIT` | `systemctl status <unit>` — is this really the application, or a wrapper, a mock, a matcher? |
| `APP_UNIT_CONFIDENCE` | `low` means **stop and look**. `override` means a human already decided. |
| `WEB_SERVER` | Is it actually nginx? Some years ship H2O, Envoy, or OpenResty. |
| `DB_SERVER` | MySQL is the common case, not the only one — PostgreSQL and per-tenant SQLite have both appeared. |
| `ENV_FILE` | The app's DB connection lives here, not in code. You will need it in phase 3. |
| `STACK_IN_DOCKER` | If `1`, `logs on` and `slow on` edit host config that nothing reads. Say so out loud. |
| `PROC_MANAGER` | `supervisor` means per-program restarts go through `supervisorctl`, not `systemctl`. |
| `BENCH_MODE` | See below. |

Wrong unit? `isukit unit <name>` overrides it and re-probes. Do not hand-edit the
manifest; it is regenerated.

**Count the instances.** ISUCON2026 is expected to hand out more than one. Every
extra app instance needs `isukit host add <target>` or `restart` and `finalize`
will silently skip it — and a service that never came back after the final reboot
scores zero no matter how fast it was.

### BENCH_MODE is the thing people get wrong

If `benchprobe` set `BENCH_MODE=manual`, **that is the correct contest-day state.**
From ISUCON11 onward the benchmarker is triggered from a portal web UI by a human
and there is no participant-facing binary. Do not go hunting for one. SSHing the
benchmarker host is an explicit rules violation — it is a disqualification risk,
not a shortcut.

In `manual` mode a human enqueues the run and you record the result:

    isukit bench --score <N> "<note>"
    isukit bench --fail "<note>"

If the mode is `auto` (practice against a past year), sanity-check the generated
`BENCH_CMD` against the repo's own README before trusting it. The target flag has
been spelled five different ways across years; `.isukit/bench-help.txt` holds the
benchmarker's real flag list. Fix with `isukit benchcmd '<line>'`.

---

## 4. Read the manual — while the baseline bench runs

This is reconnaissance, not optional reading, and it is the highest-value use of
the minutes a benchmark run is burning anyway. Find the contest manual (usually in
the adopted repo under `docs/`, or linked from the portal) and extract four things
into `.isukit/notes.md`:

1. **What the score formula actually rewards.** It is not always throughput. Some
   years weight specific endpoints, some penalize errors, some gate on a ratio.
   Optimizing the wrong quantity is the most expensive mistake available.
2. **The disqualification conditions.** Hitting one makes speed irrelevant.
3. **The `/initialize` contract** — exact path, method, timeout, required response
   body. The path has been `/initialize`, `GET /initialize`, `/api/initialize`, and
   in one year absent entirely. A timeout here zeroes the run.
4. **The prohibitions** — what you are not allowed to change. Instance shape,
   returning fabricated data, dropping tables, extra instances.

Read these out to the team. Everyone optimizing against a formula nobody read is
how eight hours disappear.

---

## 5. Baseline, then instrument, then baseline again

Order matters and the two numbers are not comparable:

    isukit logs off
    isukit bench "baseline"      # the real number — measurement logging costs score
    isukit logs on
    isukit bench "instrumented — do not compare to baseline"
    isukit alp                   # endpoints by SUMMED response time
    isukit slow                  # queries by total time

**Always sort by total time.** A 3 ms endpoint called 40,000 times outweighs a
900 ms one called twice. `alp` and `pt-query-digest` are both configured this way
by default; if you ever find yourself reading a mean or a count, stop.

Then read the application's own error log:

    ssh <app-host> 'journalctl -u <APP_UNIT> -n 200 --no-pager'

Errors the benchmarker is silently retrying are free score and they do not appear
in any latency profile. Check this before anybody touches an index.

---

## 6. Hand off and stop

Produce one briefing the whole team can read, containing:

- instance count, and the manifest line for each
- `APP_UNIT` and whether its confidence was high, low, or overridden
- web server, datastore, env file path
- `BENCH_MODE`, and who on the team owns the bench
- the baseline score and the instrumented score, labelled as not comparable
- top 3 endpoints by total time, top 3 queries by total time
- the four manual findings from §4
- the team repo URL and the baseline commit sha

Then say, explicitly, that bootstrap is complete and the loop starts with
`/isucon`. **Do not roll on into optimizing.** The handoff is the deliverable.

---

## Hard rules for this phase

- **No code changes.** None. Phase 1 is read-only by design.
- **Never SSH the benchmarker host.** Rules violation.
- **Never launch extra instances** beyond what the organizers specified.
- **Do not change instance types or counts** — shape changes can themselves be
  prohibited.
- **Do not invent a score.** If a bench run did not happen, there is no number.
  A fabricated row in `scores.tsv` poisons every `attribute` verdict after it.
- **One benchmark at a time, one person owning it.** Two concurrent runs make
  every number from both meaningless.

## If isukit itself misbehaves

    isukit doctor     # non-destructive check + self-repair
    isukit os         # uptime, vmstat, iostat, free, df on the app host

`doctor` re-probes and re-runs setup. If the kit is genuinely broken, fall back to
raw ssh and keep the team moving — the contest does not pause for tooling. Record
what broke in `.isukit/notes.md` so it gets fixed after.
