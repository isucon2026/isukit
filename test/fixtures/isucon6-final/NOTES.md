# isucon6-final fixture — Docker-compose host + a real test-harness gap found & fixed

Source: `refs/isucon6-final/ansible/playbook/roles/app/` (app host role) +
`roles/user/` (creates the `isucon` user).

## The real architecture

Everything runs as **Docker containers orchestrated by docker-compose** on this host.
`roles/app/tasks/main.yml` git-clones the app, symlinks a per-language compose file
(`docker-compose-php.yml`, in the shipped default) to `docker-compose.yml`, and the
ONLY systemd unit anywhere in the app-host ansible tree is a thin wrapper:
`ansible/playbook/roles/app/files/etc/systemd/system/isu.service`, which just runs
`docker-compose -f /home/isucon/webapp/docker-compose.yml up`. mysql and nginx are
both pulled as Docker images (`docker pull mysql`, `docker pull nginx:alpine`) and run
as *services inside* that compose file — never registered as host-level systemd units.

(There's a separate proxy host in this repo, `provisioning/proxy/`, with its own real
`nginx.service`/`consul.service` — deliberately excluded from this fixture, which
models only the app host, consistent with isucon13's single-host convention.)

## What's real vs synthesized

- `units/isu.service` — copied verbatim, no modifications.
- `home-isucon/webapp/*` mirrors the real, unfiltered `ls -1 webapp/` output exactly
  (19 `docker-compose*.yml` files + `go nodejs perl php python react README.md ruby
  scala sql ssl`), PLUS one extra file, `docker-compose.yml`, representing the
  deploy-time symlink target (`roles/app/tasks/main.yml` creates
  `docker-compose.yml -> docker-compose-php.yml`).
- No `units/nginx.service`, `units/mysql.service`, and no `mysql.tsv` — intentionally
  absent, because neither exists as a host-level systemd unit or a host-reachable mysql
  on this box. This is the actual, correct state of the machine.
- `docker-ps.txt` — SYNTHESIZED `docker ps --format "{{.Image}} {{.Names}}"` output
  (`nginx:alpine webapp_nginx_1`, `mysql webapp_mysql_1`, `webapp_php webapp_php_1`),
  matching the two images the repo's own `roles/app/tasks/main.yml` pulls
  (`docker pull mysql`, `docker pull nginx:alpine`) plus a plausible php app container.
  Container names use default docker-compose `<project>_<service>_<n>` naming since no
  `container_name:` override exists in the repo's compose files.

## A genuine gap found — in the TEST HARNESS, not in isukit

PROBE_SCRIPT already has a docker-aware fallback for exactly this shape (see `isukit`,
the comment right above it names isucon6-final and isucon8-final explicitly): when
`systemctl` finds no active web/db unit, it asks `docker ps --format "{{.Image}}
{{.Names}}"` and greps the image names for `nginx`/`mysql`/etc. So this is NOT a
discovery blind spot in isukit itself.

But `test/bin/` (the fixture-driven command-shim directory used to keep these tests
100% offline) had `systemctl`, `nginx`, `mysql`, `nproc`, `free` stubs — and **no
`docker` stub**. Since `command -v docker` succeeds against the real system docker
binary on any machine with Docker installed, running this fixture without a stub
**silently executed the real host's `docker ps`** and leaked whatever containers
happened to be running on the operator's laptop at test time (verified: on this
machine it picked up unrelated `liiga`/`recruit-admin` dev-environment containers,
producing `WEB_SERVER=nginx`/`DB_SERVER=mysql` for the wrong reason — a false-positive
PASS driven by host noise, not by fixture data).

**Fix applied (in `test/bin/docker`, in scope — no `isukit`/`launch/`/`skills/` files
touched):** added a fixture-driven `docker` stub matching the existing
`nginx`/`mysql`/`systemctl` convention — reads `$ISUKIT_FIXTURE/docker-ps.txt`
verbatim for `docker ps ...`, exits 1 with no output if that file is absent (same
"absent" convention as the nginx/mysql stubs), documented in `test/bin/README.md`.
This makes the docker-compose-detection code path actually deterministic and
fixture-controlled for the first time — no other existing fixture exercises it (their
`systemctl`-visible web/db units already short-circuit the docker fallback), so this
fixture is also the regression test for it going forward.

## Result 1: `isu.service` is correctly picked, but at low confidence (not a bug)

`isu.service` has no `WorkingDirectory=` at all, and its ExecStart is
`/usr/local/bin/docker-compose -f /home/isucon/webapp/docker-compose.yml up` — the
compose-file argument IS home-prefixed, but PROBE_SCRIPT's compose bonus only checks
the raw ExecStart string against a non-empty `WorkingDirectory`, which is empty here.

Score: WorkingDirectory empty (+0), ExecStart path `/usr/local/bin/docker-compose` not
home-prefixed (+0), no EnvironmentFile (+0), User=isucon (+2), compose-bonus fails
(requires non-empty WorkingDirectory) (+0), THEN the `/usr/local/bin` + empty-
WorkingDirectory penalty applies: **-3**. Total = 2 - 3 = **-1**.

Despite the negative score, `isu.service` is the only active, non-denied candidate at
all, so it's still selected as `APP_UNIT` (BEST is assigned on the first candidate seen
regardless of score, since `BESTSCORE` starts unset). Confidence correctly reports
"low" (-1 < 6). This is a correct identification with honestly-low confidence — not a
discovery gap, just a fragile-looking score that happens to still land on the right
answer because it's the only candidate.

## Result 2: `WEB_SERVER=nginx`, `DB_SERVER=mysql`, `STACK_IN_DOCKER=1` — all correct

Once `test/bin/docker` exists, PROBE_SCRIPT's docker fallback fires exactly as
designed: systemctl finds nothing (empty `WEB`/`DB`), falls through to `docker ps`,
matches `nginx:alpine`/`mysql` in the image names, and correctly reports both servers
plus `STACK_IN_DOCKER=1` as a signal that host-config-editing features (`isukit logs
on`, `alp`, slow-query tooling) need container-aware handling instead. This confirms
isukit's own docker-detection code works as intended for this year — the only real gap
was the missing test-harness stub, now fixed.

---

## UPDATE 2026-09-28 — the container blind spot is now closed

The gap described in "Result 2" above is fixed. `PROBE_SCRIPT` now falls back to the
container list when the systemd sweep finds no web server or DB: it runs
`docker ps --format "{{.Image}} {{.Names}}"` and matches the same candidate names
against it. On this fixture (`docker-ps.txt`) that yields `WEB_SERVER=nginx`,
`DB_SERVER=mysql`, plus a new key:

- `STACK_IN_DOCKER=1` — at least one tier was found only as a container, so everything
  that edits host config (`isukit logs on`, `alp`, `slow`) has to be done inside the
  container instead of on the host. `nginx -T` is now skipped in that case for the same
  reason: it cannot see a containerised config.

"Result 1" (correct pick at honestly-low confidence) is unchanged and still accurate.
