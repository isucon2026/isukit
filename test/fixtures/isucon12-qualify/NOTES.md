# isucon12-qualify

Source: `refs/isucon12-qualify/provisioning/mitamae/`.

- **Hybrid datastore — the flagship finding for this fixture.** The task
  brief's working hypothesis was "SQLite only, so `DB_SERVER` should come
  back empty and `SQLITE_FILES` is the only signal." That's **wrong**: real
  source (`webapp/go/isuports.go`, `go.mod`, `webapp/docker-compose-go.yml`)
  shows isuports runs a genuine host MySQL 8.0 (`mysql-server` apt package,
  `adminDB`, tenant registry, `github.com/go-sql-driver/mysql`) *and*
  per-tenant real SQLite files at `/home/isucon/webapp/tenant_db/<id>.db`
  (`github.com/mattn/go-sqlite3`) simultaneously. The app container reaches
  MySQL via `network_mode: host` + `127.0.0.1:3306`, so it's a real host
  service, not a container-internal DB. Correct expected behavior: `DB_SERVER=mysql`
  **and** `SQLITE_FILES` both fire correctly at the same time — isukit
  handles this hybrid case gracefully, it isn't a gap. `tenant_db/1.db` here
  is a **real** SQLite file built via the local `sqlite3` CLI from the
  actual contest schema (`webapp/sql/tenant/10_schema.sql`), not a stub.
- `isuports.service` and `blackauth.service` are real units, copied verbatim.
  `nginx.service`/`mysql.service`/`redis-server.service` are synthesized
  (apt-installed, no unit files shipped in refs). `blackauth` is denied via
  DENY_PAT's `blackauth*` glob, exercising that specific pattern.
- **`isucon-env-checker.service` is deliberately excluded from `active`
  here**, unlike isucon11-qualify. Its cookbook file exists in the repo
  (`cookbooks/envchecker/`), and its unit uses the same DENY_PAT-missing
  name (`isucon-env-checker*` matches neither `envcheck*` nor
  `env-checker*` — the recurring cross-year naming near-miss), but
  `provisioning/mitamae/roles/default.rb` — the actually-applied recipe —
  has `include_recipe '../cookbooks/envchecker/default.rb'` **commented
  out**. So this year it's genuinely never deployed/enabled at contest
  time, and listing it as active would be a fabrication. The near-miss
  glob pattern is still worth noting as a latent gap, just not exercised
  by this particular fixture.
- 8 language dirs under `webapp/` (go/java/node/perl/php/python/ruby/rust)
  — Java appears for the first time across all years researched. `SRC_LANGS`
  expected value also includes `tenant_db` — `ls -1` on the real
  `/home/isucon/webapp/` genuinely lists that directory alongside the
  language dirs (confirmed by `docker-compose-go.yml`'s volume mount), so
  this isn't a fixture artifact, it's what the real host directory listing
  would show; PROBE_SCRIPT's `SRC_LANGS` has no allowlist, it lists
  whatever's there.
- `mysql.tsv`'s `VERSION` (`8.0.31-0ubuntu0.22.04.1`) is a representative
  Ubuntu 22.04 jammy `mysql-server` build string, same approach as
  isucon11-final — refs only names the apt package (`mysql-server`), no
  exact contest-day build string. `DATABASES=isuports` is confirmed
  verbatim from `webapp/sql/admin/01_create_mysql_database.sql`'s
  `CREATE DATABASE IF NOT EXISTS \`isuports\``.
- `isuports.service` has no `EnvironmentFile=` at all (unlike
  isucon11-qualify/-final, which both had one) — `APP_ENVFILE`/`ENV_FILE`
  correctly come back empty here; genuine year-to-year difference, not
  an omission. Scoring: wd `/home/isucon/webapp` +4, envf +0, user=isucon
  +2, `docker compose` in ExecStart + workdir-under-home +2 = 8 ⇒ high
  confidence (execpath is just `docker`, no path-prefix bonus, since the
  stub takes ExecStart's first token literally with no PATH resolution).
