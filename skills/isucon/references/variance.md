# What varies between ISUCONs

Every field in this file has changed at least once across isucon5 through isucon14 —
source dir naming, unit naming, env files, web server, DB, bench flags, instance count.
Nothing about ISUCON repo layout is stable across years. This is why isukit discovers
the running host (`isukit probe`, `isukit benchprobe`) instead of reading the repo, and
why an agent must never hardcode a path, unit name, or flag it has not observed on the
actual machine in front of it.

Source: `~/claude-workspace/isucon-variance-matrix.md` (18 repos, isucon5–14, compiled
2026-09-28). isucon15/isucon2026 do not exist publicly yet.

## The variance matrix

| Year | App source dir | systemd unit(s) | Env/config | Web server | DB | Bench target flag | Instances |
|---|---|---|---|---|---|---|---|
| isucon5-qualify | `/home/isucon/webapp/<lang>` | `systemd.<lang>.service` (no nodejs unit) | env vars `ISUCON5_DB_*` | nginx | MySQL 5.6 | Gradle `-Pargs="... 127.0.0.1"` (positional) | 1 |
| isucon5-final | `/home/isucon/webapp/<lang>` | supervisord `supervisor.<lang>.conf` (no systemd) | supervisor conf `user=isucon` | nginx | **PostgreSQL 9.4** | Gradle `-Pargs="... 127.0.0.1 -p 9292"` (positional) | 3 |
| isucon6-qualify | `/home/isucon/webapp/<lang>` (2 apps: isuda+isutar) | `isuda.<lang>.service`, `isutar.<lang>.service`, `isupam.service` | `provisioning/image/files/my.cnf` | nginx | MySQL | `-target` (default `http://localhost`) | 1 |
| isucon6-final | `/home/isucon/webapp` | **none** (pure Docker, contestant side) | none | **none** (TLS in-app) | MySQL (Docker) | `-urls=https://127.0.0.1:443 -timeout 30` | ? (not stated) |
| isucon7-qualify | `/home/isucon/isubata/webapp/<lang>` | `isubata.<lang>.service` | `env.sh` (`ISUBATA_DB_*`) | nginx | MySQL | `-remotes` (default `localhost:8080`) | 1 |
| isucon7-final | `/home/isucon/webapp/<lang>` | `cco.<lang>.service` | none (no `.cnf` at all) | nginx (+WebSocket) | MySQL | `-remotes` (default `localhost:5000`) | 1 |
| isucon8-qualify | `/home/isucon/torb/webapp/<lang>` | `torb.<lang>.service` | `/etc/my.cnf` via blockinfile | **H2O** | MariaDB | `-remotes` (default `localhost:8080`) | 3 |
| isucon8-final | container-internal | **none** (no systemd, no provisioning dir) | none | nginx + **OpenResty** blackbox | MySQL 8 (Docker) | `-appep` | **4** |
| isucon9-qualify | `/home/isucon/isucari/webapp/go/` | `isucari.<lang>.service` + `payment.service`, `shipment.service` | none | nginx | MySQL | `-target-url` / `-target-host` | up to 3 |
| isucon9-final | `/home/isucon/isutrain/webapp` | `isutrain-<lang>.service` (shells to docker-compose) | Docker named volume | nginx (host+container) | MySQL 8 (Docker) | `--target` (env `BENCH_TARGET_URL`) | 3 |
| isucon10-qualify | `/home/isucon/isuumo/webapp/<lang>` | `isuumo.<lang>.service` | `env.sh` (`MYSQL_*`) | nginx | MySQL 5.7 | `--target-url` (default `:1323`) | **1** (allinone) |
| isucon10-final | `/home/isucon/webapp/<lang>` | `xsuportal-{api,web}-<lang>.service` + `envoy.service` | itamae templates | **Envoy** | MySQL 8 | `-target` | 3 |
| isucon11-qualify | `/home/isucon/webapp/go` | `isucondition.<lang>.service` + `jiaapi-mock.service` | ansible-rendered | nginx (TLS) | **MariaDB 10.3** | `-target` (default `localhost:9292`) | 3 |
| isucon11-final | `/home/isucon/webapp/go` | `isucholar.<lang>.service` (no perl/python) | ansible-rendered | nginx (TLS) | MySQL 8 | `-target` (fallback `localhost:8080`) | 3 |
| isucon12-qualify | `/home/isucon/webapp` (compose root) | `isuports.service` (generic, wraps docker-compose) | mitamae-rendered | nginx | MySQL + per-tenant **SQLite** | `-target-url` (stdlib `flag`, single-dash) | 3 app + 1 bench |
| isucon12-final | `/home/isucon/webapp/go` | `isuconquest.<lang>.service` | `etc/mysql/conf.d/my.cnf` (empty) | nginx | MySQL 8.0 | `--target-host` (default `localhost:8080`) | ? (not stated) |
| isucon13 | `/home/isucon/webapp/<lang>` | `isupipe-<lang>.service` | ansible-rendered | nginx | MySQL + **PowerDNS** | `--target` (env `BENCH_TARGET_URL`) | 3 |
| isucon14 | `/home/isucon/webapp/<lang>` | `isuride-<lang>.service` + `-payment_mock`, `-matcher` | ansible-rendered | nginx | MySQL 8.0 | `--target` (default `:8080`) | 3 |

## Axes that varied, and what to do about each

### Source dir naming
`/home/isucon/webapp/<lang>`, `/home/isucon/<appname>/webapp/<lang>`, or bare
`/home/isucon/webapp`. The `/home/isucon/` root is the only constant.
Discover by: read the running unit's `WorkingDirectory=` via `systemctl show -p WorkingDirectory <unit>`, not a guess from a past year's path.

### Build tool / language toolchain
Local toolchain paths differ even within the same era (`/home/isucon/.local/<lang>` in
isucon6 vs `/home/isucon/local/<lang>` in isucon7). Language roster ranges from 5 to 8
languages per year; presence of Java/Scala/Deno/Rust is era-correlated, never guaranteed.
Discover by: `isukit probe` reads the live unit, not the repo's language list.

### systemd unit naming convention
Five incompatible shapes observed: hyphen (`isuride-go.service`), dot
(`isuconquest.go.service`), Description-only with separate filename (`isuumo.go` /
`isuumo.go.service`), 3-part component names (`xsuportal-api-golang`), one generic unit
wrapping docker-compose (`isuports.service`). Two years ship **zero** units at all
(isucon8-final, isucon6-final contestant side).
Discover by: `isukit probe` (scored heuristic over `systemctl list-units`), never a
naming-convention regex. If `APP_UNIT_CONFIDENCE` is not `high`, read `APP_CANDIDATES`
and resolve with `isukit unit <name>`.

### Unit file path in repo
Ranges from `provisioning/ansible/roles/webapp/files/*.service` to flat `files/*.service`
(no `provisioning/` dir, isucon7-final) to Jinja2/itamae templates rendered at deploy
time. Irrelevant on contest day anyway — the running host is ground truth, not the repo.
Discover by: `systemctl show -p FragmentPath <unit>` on the live box.

### Env file + env var naming
Sometimes a shell `env.sh` (`ISUBATA_DB_*`, `MYSQL_HOST/PORT/USER/DBNAME/PASS`), sometimes
ansible/mitamae/itamae-rendered config with no shell env file at all, sometimes nothing
(defaults implicit). No stable filename or variable prefix.
Discover by: `systemctl show -p Environment -p EnvironmentFiles <unit>`, or read the
running process's actual env via `/proc/<pid>/environ`.

### Web server
nginx is the majority but not universal: H2O (isucon8-qualify), Envoy
(isucon10-final, gRPC+TLS), OpenResty (isucon8-final's blackbox), no proxy at all /
TLS terminated in-app (isucon6-final contestant).
Discover by: check the listening process (`ss -ltnp`) and its config, don't assume nginx
config paths exist.

### Database
MySQL is the majority (versions unpinned through 8.0), but MariaDB (isucon8-qualify,
isucon11-qualify), PostgreSQL 9.4 (isucon5-final, the one true outlier), and per-tenant
SQLite alongside MySQL (isucon12-qualify) all appear. Config file path and whether a
config file even exists (several years ship none, package defaults apply silently) vary
per year.
Discover by: check the listening port / running process, not a `.cnf` grep — several
years have no `.cnf` file in the repo at all.

### Benchmarker invocation
No stable target-host flag name across any span of years: `--target`, `-target-url`,
`-target-addr`, `--target-host`, `-remotes`, `-appep`, `-urls`, or (isucon5 both years)
a positional IP buried inside a Gradle `-Pargs="..."` string — not a CLI flag at all.
Flag style itself varies (cobra/urfave-cli double-dash vs Go stdlib single-dash vs
Gradle). `/initialize` verb (POST vs GET, ~50/50), path (`/initialize` vs
`/api/initialize`), response field name (`language` vs `lang` vs no body at all), and
timeout (5s–60s, a 12x spread) are all independently unstable.
Discover by: `isukit benchprobe` (composes `BENCH_CMD`); verify/correct with
`isukit benchcmd '<command>'` — never hand-type a remembered flag from a past year.

### Instance count
1 (several allinone years), 3 (the modern-era majority), 4 (isucon8-final), or "up to 3,
variable" (isucon9-qualify). Several years leave it undocumented for contestants
entirely (isucon6-final, isucon12-final).
Discover by: enumerate hosts actually provisioned for this contest — don't assume 3.

### Containerisation
Ranges from zero Docker involvement to fully containerised with no host-level
provisioning tool at all (isucon8-final has no `provisioning/`, `ansible/`, or
`terraform/` directory whatsoever).
Discover by: `docker compose ps` / `docker ps` alongside the systemd probe — a unit that
just shells out to `docker compose up` still counts as the "app unit" for restart
purposes even though the process tree lives in containers.

### Provisioning style
Ansible (most years), mitamae (isucon12-qualify), itamae (isucon10-final),
Packer+Ansible combos, GCE-ansible numbered playbooks (isucon5), or none at all
(isucon8-final, isucon6-final contestant side).
Discover by: irrelevant at runtime — provisioning tooling only matters if you're
re-imaging a box, which isn't the isukit loop. Don't go looking for it.

## Outliers worth remembering

- **isucon5-final**: PostgreSQL 9.4, not MySQL — the only non-MySQL/MariaDB year. Also
  the only supervisord year (no systemd `.service` files exist at all).
- **isucon5-qualify / isucon5-final**: benchmarker is a Gradle project; the target IP is
  a positional argument inside a `-Pargs="..."` string, not a CLI flag.
- **isucon6-final**: contestant app has no `/initialize` endpoint at all (real-time SSE
  drawing game, structurally different reset model) and no init system — pure
  `docker-compose up`, "Docker installed, OS doesn't matter."
- **isucon8-final**: 4 instances (every other year with a stated count uses 1 or 3), no
  provisioning directory whatsoever, no systemd units at all, OpenResty as a second
  proxy layer alongside nginx.
- **isucon8-qualify**: H2O instead of nginx as the reverse proxy.
- **isucon10-final**: Envoy instead of nginx, gRPC+TLS routing — this year is a meta
  "portal" app, not a normal qualify-style problem.
- **isucon10-qualify**: single allinone VM despite being a "modern era" (2020) contest;
  widest language roster of any year (8 languages including Deno).
  isukit ambiguity trap: 8 simultaneous per-lang units on one box can outscore the real
  app unit in a naive heuristic — this is why `isukit probe` scores candidates and
  surfaces `APP_CANDIDATES` rather than picking the first match.
- **isucon12-qualify**: per-tenant SQLite files alongside the main MySQL DB; provisioning
  via mitamae, not Ansible; the only Java-inclusive modern-era year.
- **isucon13**: PowerDNS with a MySQL backend for DNS-based multi-tenancy — no other year
  uses DNS as part of the contest mechanic.
- Source notes several fields as genuinely unverifiable rather than guessable — e.g.
  isucon6-final's and isucon12-final's instance counts are undocumented for contestants;
  treat any `?`/`NOT FOUND` cell in the matrix above the same way: verify on the live
  box, don't infer from era.

## What this means for the agent

- Read `isukit probe`'s manifest before touching anything — it is the ground truth for
  this box, not any past year's writeup, including this file.
- If `APP_UNIT_CONFIDENCE` is not `high`, resolve it with `isukit unit <name>` (after
  reading `APP_CANDIDATES`) before running `isukit bench` or deploying anything.
- Never assume the bench invocation or target-host flag name — run `isukit benchprobe`
  and verify with `isukit benchcmd` rather than typing a remembered flag.
- Never copy a systemd unit name, file path, env var name, or config path from this file
  or from a past year's repo into commands run against this year's box.
- Verb, path, response schema, and timeout for `/initialize` are each independently
  unstable — probe or read the manual, don't assume POST, `/initialize`, or a `language`
  field.
- Don't assume nginx, MySQL, or 3 instances — check the listening process and enumerate
  hosts before writing anything that depends on server count or DB flavor.
