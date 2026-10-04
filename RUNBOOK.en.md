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

## Where the servers come from

### Production (ISUCON2026)

- **Date: Saturday, 2026-10-31, 10:00–18:00 JST (8 hours)**
- Teams are **up to 3 people**
- **Registration closed in early August 2026** (three rounds of 300/300/335 seats, all filled)
- This year's organizer is Sakura Internet (venue: their Osaka HQ, Blooming Camp) — but **the contest environment runs on AWS, not Sakura's cloud**
- Rule: **each competitor brings their own AWS account and launches the AMI the organizers announce, on their own EC2, after the contest starts**

So the production setup is: organizers publish an AMI ID → you launch EC2 in your own account → you SSH in with your own key. No bastion, no VPN. **The procedure you build in practice is the procedure you use for real.**

Login is the `ubuntu` user, then `sudo su - isucon`.

### Practice (each person's own AWS sandbox account)

**Fixed to ap-northeast-1 (Tokyo).** Log in and confirm which account you're actually in:

```
aws sso login --profile sandbox
export AWS_PROFILE=sandbox AWS_REGION=ap-northeast-1
aws sts get-caller-identity        # launching into the wrong account is the single most common accident here
```

#### Recommended: use the `launch/` scripts (practice the exact procedure you'll use for real)

The kit ships `launch/prestage.sh` / `launch/launch.sh` — the same scripts you'll use on contest day. Practicing with these, rather than hand-assembling raw AWS CLI calls, makes the practice run *be* the contest-day procedure. Verified end-to-end against a real account (`395103361978`) on 2026-09-28:

```
cd ~/personal-projects/isucon/isukit

# ① prestage — the T-7d-equivalent step for real contest day. Needs no AMI, so do this well before contest day.
launch/prestage.sh \
  --key-name isukit \
  --key-file ~/claude-workspace/isukit.pem \
  --region ap-northeast-1 \
  --sg-name isukit-ssh \
  --allow-ip <n000r111's IP> \
  --allow-ip <imaharu's IP>
```

**Security groups cannot be changed after the instances launch. That's not an AWS limitation — it's an ISUCON rule (禁止事項, a forbidden action).** Every teammate's IP has to be in via `--allow-ip` by the time you prestage. Miss one and that person has no SSH for the entire 8 hours, with no legal remedy. The script prints the CIDRs it actually put into the SG, so check that output against the roster — not the flags you typed.

`isukit.pem` (the file behind `--key-file`) gets distributed to the team out of band. It's already `.gitignore`d — never let it land in the shared repo.

```
# ② launch — T+0, once the organizers announce the AMI
launch/launch.sh \
  --ami ami-0fcf9e8e8675a9ee4 \
  --type t3.small \
  --count 1 \
  --name-prefix isucon \
  --yes
```

`--ami` / `--type` / `--count` have no defaults on purpose. The design is that a human reads what the organizers announce on the day and types it in each time — the kit never guesses. `--root-gb` is practice-only (a bigger-than-default root volume keeps the bench log from filling the disk); on contest day the manual's sizing wins instead — changing the instance shape at all risks a 禁止事項 violation.

Once it's up, you rejoin the normal measurement flow:

```
isukit init <contest-repo-url> <dir>
isukit host app ubuntu@<public-ip> -i ~/claude-workspace/isukit.pem
isukit probe        # discovers the stack; reads nothing from the repo
isukit benchprobe    # switches BENCH_MODE to manual if no benchmarker binary is found
isukit setup         # installs alp + percona-toolkit
isukit logs on       # nginx LTSV + mysql long_query_time=0
isukit doctor        # non-destructive health check + self-repair
```

`BENCH_MODE=manual` is **the correct production state**, not a failure — since ISUCON11, the benchmark is triggered from the portal UI, and SSHing into the benchmarker host is an explicit 禁止事項.

Clean up once practice is done:

```
aws ec2 terminate-instances --instance-ids <ids>
# wait for 'terminated', then:
aws ec2 delete-security-group --group-name isukit-ssh
aws ec2 delete-key-pair --key-name isukit
```

**Verified AMI (2026-09-28):** `ami-0fcf9e8e8675a9ee4` (ap-northeast-1, x86_64) is a box with the whole isucon14 problem baked in — `isuride-*` systemd units, MySQL 8.0.46, nginx, even `alp` preinstalled. `isukit probe` nailed it in one shot with `APP_UNIT_CONFIDENCE=high`. Proven as a practice box. The matching row in the table below is now updated to verified too.

Teammates can't get into the console with their own SSO (org-level Identity Center only lets the account owner hand out permissions). If console access is needed, an IAM user directly under the account is the fallback — but SSH + the portal is normally all you need.

#### Manual: spin it up directly with the AWS CLI

The raw commands, for when you want to understand what the scripts above do internally, or want to build it without them.

#### Available AMIs (confirmed against the real account, 2026-09-02)

| Past contest | AMI | Status | SSH |
|---|---|---|---|
| isucon13 (official) | `ami-041289d910c114864` | **available** | `ubuntu` → `sudo su - isucon` |
| isucon12-qualify (official) | `ami-05c5b59deed48f66b` | **gone (InvalidAMIID.NotFound)** | — |
| isucon12-qualify (matsuu) | `ami-073140ad092048333` | **available** | `ubuntu` → `sudo -i -u isucon` |
| isucon13 (matsuu) | `ami-006d211cb716fe8a0` | unverified | `ubuntu` → `sudo -i -u isucon` |
| isucon14 (matsuu) | `ami-0fcf9e8e8675a9ee4` | **verified** (2026-09-28, ships `isuride-*` units / MySQL 8.0.46 / nginx / alp, `APP_UNIT_CONFIDENCE=high`) | `ubuntu` → `sudo -i -u isucon` |

**Official AMIs vanish without notice.** The isucon12-qualify official AMI is already gone (which is also why the official repo's `cloudformation.yaml` doesn't work as-is anymore). The fallback is the AMI table in [matsuu/aws-isucon](https://github.com/matsuu/aws-isucon) — it includes both webapp and bench boxes. **Don't hardcode an ID — check the README's table on the day you use it** (they get rebuilt and change).

For years even older or missing, there's [matsuu/cloud-init-isucon](https://github.com/matsuu/cloud-init-isucon) (builds onto plain Ubuntu via user-data; covers isucon10q/11q/11f/12q/12f/13/14/private-isu), or the repo's own `provisioning/packer` / `provisioning/ansible`.

#### Actually launching it (copy-paste ready)

```
export AWS_PROFILE=sandbox AWS_REGION=ap-northeast-1
VPC=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
SUBNET=$(aws ec2 describe-subnets --filters Name=default-for-az,Values=true --query 'Subnets[0].SubnetId' --output text)
MYIP=$(curl -s https://checkip.amazonaws.com)

# ① key (once, first time only)
aws ec2 create-key-pair --key-name isukit-sandbox --query KeyMaterial --output text > ~/.ssh/isukit-sandbox.pem
chmod 600 ~/.ssh/isukit-sandbox.pem

# ② security group (port 22 from your own IP + everything open within the group)
SG=$(aws ec2 create-security-group --group-name isukit-sandbox \
      --description "isucon practice" --vpc-id "$VPC" --query GroupId --output text)
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 22 --cidr "$MYIP/32"
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol -1 --source-group "$SG"

# ③ launch. --block-device-mappings is mandatory (the AMI defaults to 8GB / 16GB, which the bench's logs and data will fill)
aws ec2 run-instances \
  --image-id ami-041289d910c114864 \
  --instance-type c5.large \
  --key-name isukit-sandbox --security-group-ids "$SG" --subnet-id "$SUBNET" \
  --associate-public-ip-address \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=isucon13-app},{Key=purpose,Value=isucon-practice}]' \
  --query 'Instances[].InstanceId' --output text

# ④ get the public IP. This is what <app-host> actually is
aws ec2 describe-instances --filters Name=tag:purpose,Values=isucon-practice \
  Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,PublicIpAddress]' --output text
```

> **Skip `--block-device-mappings` and you'll get stuck later.** The official isucon13 AMI's default root is **8GB gp2**; matsuu's isucon12-qualify is **16GB**. A slow log with `long_query_time=0` fills that fast. Use **30GB gp3**.

#### The `<app-host>` you hand to isukit

`<app-host>` is literally the ssh destination string. Pass `ubuntu@<Public IP>` and the key via `-i`:

```
isukit host app   ubuntu@43.207.152.140 -i ~/.ssh/isukit-sandbox.pem
isukit host bench ubuntu@43.207.152.140 -i ~/.ssh/isukit-sandbox.pem   # fine to reuse the app box for bench too, if you're consolidating onto one instance for practice
```

If there are multiple instances (expected for ISUCON2026), give each host its roles
(`app`, `web`, `db`) with `isukit host role <target> <roles>`, e.g. `web,app` / `app` / `db`,
and check them with `isukit hosts`. Commands then go where their tier runs: deploy / restart
/ pprof to app hosts, nginx logging and alp to web hosts, the slow log and slow to db hosts,
etc and os to every host. Roles only route isukit; stopping mysql on app hosts, the db
host's bind-address and grants, and the app's DB_HOST are still done by hand.
Without `.isukit/hosts`, extra hosts are plain app instances:

```
isukit host add ubuntu@43.207.152.141 -i ~/.ssh/isukit-sandbox.pem
isukit host add ubuntu@43.207.152.142 -i ~/.ssh/isukit-sandbox.pem
```

`restart` and `finalize` sweep every host (restart order isn't guaranteed).

#### Instance count

- A serious practice run: app **3× c5.large** (2 vCPU / 4 GiB) + bench **1**. Same shape as production.
- Just checking the kit works, or practicing single-host tuning: **1 instance is enough** (the matsuu AMI ships the bench too, so it runs on the same box).

**Cost:** c5.large runs about **$0.107/hr** in Tokyo. Four instances for six hours ≈ **~$3**.

> **Forgetting to tear down is the real expense.** Leave four instances running and it's $300+/month. Always, once practice is done:
> ```
> aws ec2 describe-instances --filters Name=tag:purpose,Values=isucon-practice \
>   Name=instance-state-name,Values=running --query 'Reservations[].Instances[].InstanceId' --output text \
>   | xargs -r aws ec2 terminate-instances --instance-ids
> ```
> Even in a sandbox, someone real gets billed. **Tear it down the same day.**

### Local-only, if that's all you need

The absolute score numbers aren't meaningful this way, but it's still real practice touching the code.

```
cd ~/personal-projects/isucon/isucon13/development && make up && make go
```

isucon13 ships 8 compose files (one per language); isucon12-qualify ships 19. `isukit probe` still works against this setup — when `systemctl` finds nothing it falls back to `docker ps`, fills in `WEB_SERVER` / `DB_SERVER`, and sets `STACK_IN_DOCKER=1`. What doesn't work is `deploy` and `logs on` / `slow on` (they only ever rewrite host config, never touch what's inside a container). Same story running it on your own Mac: the app itself has no systemd unit, so `APP_UNIT` stays empty and warns, but web/db still get picked up.

---

## Phase 0 — Access (before the clock)

```
ssh <app-host> true && ssh <bench-host> true     # both must succeed NOW
chmod 600 ~/.ssh/<contest>.pem                    # ssh refuses 644
```

**No team repo yet (T+0)?** One person builds it in one command:

```
isukit go --new <team>/<private-repo> ubuntu@<app-host> [ubuntu@<bench-host>] -i ~/.ssh/<key>.pem \
  --invite n000r111,imaharu
```

1. **Code baseline:** the probed webapp (`SRC_DIR`) is copied to the laptop,
   committed, and pushed as a private repo with `gh repo create`; `--invite`
   users get push access. GitHub credentials stay on the laptop. Left out (and
   listed in `.gitignore`, kept on the server): `node_modules`, logs, the built
   app systemd runs, and any file over 10MB (DB dumps, big images).
2. **Config baseline:** nginx / mysql / app-unit config moves into the repo's
   `etc/` and `/etc` symlinks to it (same as `isukit etc adopt`: replaced files
   backed up under `/etc/isukit-orig/`, AppArmor rule for mysqld). Each host's
   env file is *copied* to `hosts/<host>/` as a record — env differs per host,
   so it is not linked. Committed and pushed as a second commit.
3. Then the usual `go`: tools, logging on, BENCH_CMD.

`main` ends up with two commits — code before any change, config before any
change — and you are on `work`. Those are the only places to roll back to.

Everyone else hands `go` the new repo:

```
isukit go git@github.com:<team>/<private-repo>.git ubuntu@<app-host> [ubuntu@<bench-host>] -i ~/.ssh/<key>.pem
```

From then on, change config by editing the local `etc/` and `isukit deploy` (or
`isukit etc push`); never edit `/etc` on the server directly.

With several instances, register them with roles now (all hosts start from the
same AMI; re-assign when you split in phase 3):

```
isukit host role ubuntu@<ip1> web,app,db
isukit host role ubuntu@<ip2> app
isukit hosts
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
isukit show                     # this run: per-host CPU and processes, alp, slow, pprof
```

While logs are on, each `bench` is one measured run saved to
`.isukit/runs/<when>/`. **Read the hosts part of `show` first:** the host and
process that was pinned is the bottleneck, and it says what to open next —
`mysqld` on the db host → slow; the app on an app host → pprof
(`go tool pprof -http=: <run>/cpu.pprof`); `nginx` → static files, keepalive,
workers; everything idle but the score flat → lock waits, external calls, app
errors.

alp's URI groups are derived from the log (ids, UUIDs, long tokens, and
segments with very many distinct values like user names collapse; a far busier
sibling such as `/api/user/me` stays its own row). If the grouping looks wrong,
check it with `isukit alp --patterns` and put your own comma-separated regexes
in `ALP_MATCHES` in `.isukit/config`.

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

After each one: `isukit deploy` → `isukit bench "<what you changed>"` →
`isukit show`. Keep or revert on the number alone; `isukit show 2` is the run
before, for comparison.

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

1. Re-assign roles, e.g. `web,app` / `app` / `db` with `isukit host role`.
   deploy / restart then go to app hosts, nginx logs and alp to web hosts, the
   slow log and slow to db hosts.
2. Change the layout by hand (roles only route isukit): on the db host, let
   MySQL accept remote connections (`bind-address` in `etc/`'s mysqld.cnf, a
   remote user); on app hosts, point the app at the db host — the connection
   config is in the env file (`ENV_FILE` in `.isukit/manifest`; the original is
   in `hosts/<host>/`), not in code; on every non-db host,
   `sudo systemctl disable --now mysql` (stopping alone comes back on reboot);
   on the web host, list the app hosts in nginx's upstream (`etc/`).
3. `isukit probe` again: it probes every host and warns where roles and reality
   disagree (no MySQL on the db host, MySQL still running on a non-db host, app
   hosts with a different unit or source dir).
4. `isukit deploy` → `isukit bench` → `isukit show` — this can *lose* score if
   the app was never DB-bound; revert if so. Check in `show` that the load
   moved to the host you meant.
5. Put a second app instance behind the web server, load-balanced.

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
isukit final check       # list everything that still logs or measures (changes nothing)
isukit final apply       # turn off what config can (as an etc/ diff) + clean the hosts
# remove what the app's code still does (pprof, request logger, debug) by hand -> isukit deploy
isukit bench "final: output off"   # confirm the score holds or improves with it all off
isukit ship "final: output off"
isukit finalize          # logs off -> reboot ALL hosts -> verify units -> scoring run
```

**Before the last scoring run, stop every output nobody will read.** Each line
a request writes costs score — not only isukit's measurement logging but what
was on as handed out. `final check` lists: nginx `access_log` (on by default,
even with no directive), the MySQL slow / general log (live and in `.cnf`),
sysstat collectors, isukit's samplers / files / logging, how much the app wrote
to the journal in the last 10 minutes, and in the app's Go code `net/http/pprof`,
echo / chi / gin request loggers, debug switches and `log.Print`. `final apply`
turns off what config can — `access_log off;` and the logs set to 0 in the
repo's `etc/`, then `etc push`, so it is a diff you can `git revert` — and
cleans the hosts. The app's code is only listed: fix it by hand. `finalize`
also runs `final check` first and warns about anything left.

`finalize` exists because runtime-only state evaporates on reboot, and the
final scoring run happens on a machine that may have been restarted. If you have
multiple instances, `finalize` reboots all of them and checks each host brings
up what its roles need (the app on app hosts, nginx on web hosts, MySQL on db
hosts); restart order is not guaranteed. Manually confirm each of these:

- [ ] Every service you depend on is **enabled**, not merely running:
      `systemctl is-enabled <unit>` for each unit in `.isukit/manifest`.
- [ ] Every `SET GLOBAL` you made is **also in the config file**. Runtime MySQL
      variables do not survive a restart.
- [ ] Nothing you need lives in `/tmp`.
- [ ] Slow query logging is **off** and its log file is deleted — at
      `long_query_time=0` it can fill the disk.
- [ ] Disk has free space: `df -h`.
- [ ] The app starts from cold with no manual step.
- [ ] MySQL stays **stopped** on every non-db host (forgetting `disable` brings
      it back on reboot, eating memory and CPU).
- [ ] Every app host reaches the db host, even when the db host comes up last.

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
isukit go --new <team>/<repo> <host> -i <key> [--invite u1,u2]
                            # no repo yet: build it from the server (code + config baselines)
isukit host role <t> <roles> # app / web / db, comma-separated (.isukit/hosts)
isukit hosts                # hosts, roles, and the units each must run
isukit doctor               # diagnose + auto-repair config, connectivity, bench mode
isukit os                   # server snapshot: uptime / vmstat / iostat / mpstat / free / df
isukit probe                # re-read the server after any infra change
isukit bench "note"         # score + git sha -> .isukit/scores.tsv (manual mode: --score N / --fail)
isukit score                # full run history
isukit show [n]             # a saved run: per-host CPU and processes, alp, slow, pprof (saved by bench while logs are on)
isukit attribute [pct]      # compare last two runs; KEEP / REVERT / INCONCLUSIVE
isukit alp                  # endpoints by summed response time
isukit slow                 # queries by total time
isukit pprof 30             # Go CPU profile -> .isukit/cpu.pprof
isukit deploy               # rsync + build onto the systemd ExecStart path + restart
isukit restart              # restart the app units on every app host
isukit logs on|off          # nginx LTSV + mysql slow log
isukit etc adopt|status|push|pull  # nginx/mysql/unit config into the repo's etc/, symlinked from /etc
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
