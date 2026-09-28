# isucon5-final fixture — KNOWN DISCOVERY GAP (intentional FAIL)

Source: `refs/isucon5-final/` (ansible provisioning under `provisioning/`... /ansible role
tree, per-language app confs under `supervisor.<lang>.conf`, PostgreSQL 9.4 db setup,
`env.sh`, nginx confs).

## The real architecture

- The app is run under **Supervisor**, via `supervisor.<lang>.conf` process configs
  (e.g. `supervisor.ruby.conf`), NOT as individual systemd units per language. There is
  no `isuxi.<lang>.service`-style unit anywhere in this repo's provisioning tree, unlike
  isucon5-qualify.
- The final ansible deploy task is `supervisorctl: name=ruby state=restarted` — ruby is
  the default active app, but it's only visible to `supervisorctl status`, not to
  `systemctl`.
- DB is **PostgreSQL 9.4** (`postgresql.conf`/`pg_hba.conf` under `/etc/postgresql/9.4/`),
  not MySQL.

## What's real vs synthesized

- `units/nginx.service` — SYNTHESIZED standard package unit (apt nginx, no custom unit
  shipped).
- `units/postgresql.service` — SYNTHESIZED. Note: real Debian/Ubuntu postgresql packages
  of this era typically expose per-cluster units like `postgresql@9.4-main.service`
  with a `postgresql.service` meta-target aggregating them; I synthesized the plain
  `postgresql.service` name since that's the literal, fixed string PROBE_SCRIPT's
  `DB_SERVER` check probes (`for s in mysql mariadb postgresql`). This is a reasonable
  synthesis, not sourced from a file in this repo.
- `units/supervisor.service` — SYNTHESIZED **best-effort reconstruction** of the
  standard Debian/Ubuntu `supervisor` package's systemd unit shape. No such file exists
  anywhere in `refs/isucon5-final/` — the repo only ships supervisor *program* configs
  (`supervisor.<lang>.conf`), never a systemd unit for the supervisord daemon itself.
  This file exists purely so a plausible "supervisor daemon" process is present in
  `active`, matching what a real Ubuntu box with `apt install supervisor` would expose.

## THE GAP — why `expected` records `APP_UNIT=` (empty), not a made-up unit name

There is **no systemd unit, anywhere, for the actual application** (any `isuxi.<lang>`
equivalent) in this repo — it's Supervisor-managed exclusively. The true, correct answer
for "which systemd unit is the app" is: **none exists; this can't be determined via
systemd at all.**

But `DENY_PAT` has no `supervisor*` entry, so PROBE_SCRIPT's app-candidate loop does NOT
filter out `supervisor.service`. Since it's the only active, non-denied candidate (nginx
is denied via `nginx*`, postgresql is denied via `postgres*`), it becomes `APP_UNIT` by
default — even though its score is deeply unflattering:
WorkingDirectory unset (+0), ExecStart=/usr/bin/supervisord not home-prefixed (+0),
no EnvironmentFile (+0), User unset (+0) = **score 0**, confidence=low.

So the actual PROBE_SCRIPT run on this fixture produces:
- `APP_UNIT=supervisor.service` (WRONG — this is the process manager, not the app)
- `APP_UNIT_CONFIDENCE=low` (at least self-flagged as uncertain, which is honest)

...while the fixture's `expected` file (the ground truth) correctly asserts
`APP_UNIT=` (empty), so **this fixture is a genuine, intentional FAIL** — do not "fix" it
by changing `expected` to `supervisor.service`. It's here to document a real blind spot:
**PROBE_SCRIPT has no notion of Supervisor (or any non-systemd process manager) as a
place apps might live**, and will mis-attribute the process manager's own unit as the
app when nothing else is systemd-visible. `DB_SERVER`/`WEB_SERVER`/`SRC_LANGS` all
resolve correctly and are not part of the gap.

## What's real (webapp dirs)

`home-isucon/webapp/*` mirrors the real, unfiltered `ls -1 webapp/` output:
`golang java node perl php python ruby scala sql static`.

---

## UPDATE 2026-09-28 — gap CLOSED, and this section supersedes the one above

The "intentional FAIL" verdict above has been reversed on purpose. Read this instead.

The argument for `APP_UNIT=` (empty) was *"no systemd unit is the app"*. True as a
statement about systemd — but wrong as ground truth for what isukit is asked to produce.
`APP_UNIT` is not a trivia answer; it is the handle `isukit deploy` and `isukit restart`
hand to `systemctl restart`. And `systemctl restart supervisor` **does** restart this
app. An empty `APP_UNIT` leaves the kit unable to restart anything on this box, which is
strictly worse on contest day than naming the manager.

So `supervisor.service` is kept, and the real defect — that nothing told the operator
this was the *manager* rather than the app — is fixed by disclosure instead:

- `PROC_MANAGER=supervisor` (vs `systemd` on every other year)
- `SUPERVISOR_PROGRAMS=ruby ` — from `supervisorctl status`, i.e. the granular handle
  (`supervisorctl restart ruby`) for when restarting the whole daemon is too blunt.

`supervisorctl-status.txt` is the fixture for that call, answered by `test/bin/supervisorctl`.
Its content is synthesized (one RUNNING `ruby` program) but the program *name* is real:
`provisioning/image/files/supervisor.ruby.conf` declares `[program:ruby]`, and ansible's
final deploy task is `supervisorctl: name=ruby state=restarted`.

`expected` now records all of this and the fixture PASSES.
