# isucon12-final

Source: `refs/isucon12-final/provisioning/packer/ansible/roles/webapp/`.

- App is "isuconquest", 6 real language units (go/nodejs/perl/php/ruby/rust,
  copied verbatim). Only `isuconquest.go` is enabled, via a plain ansible
  `systemd:` task in `tasks/main.yml` — same one-language-enabled pattern as
  every other year checked so far.
- `ExecStart=/home/isucon/.x /home/isucon/webapp/go/isuconquest` — `.x` is
  a version-manager shim (`ansible` builds every language app through it,
  e.g. `/home/isucon/.x go build ...`). This is a genuinely different
  ExecStart shape from other years: `execpath` (the first ExecStart token)
  is `/home/isucon/.x` itself, which *is* under `/home/isucon`, so it earns
  the execpath +3 bonus directly — unlike isucon12-qualify's
  `docker compose ...` shape, which only earns points via the separate
  compose-substring bonus since `execpath` there is just `docker`. Score:
  wd +4, execpath +3, envf +2, user +2 = 11, high confidence.
- Real MySQL 8.0 (`mysql-server-8.0` apt package, explicit `service:
  name=mysql enabled=true state=started` ansible task — this year's role
  starts it explicitly, not just apt-postinst-implicit like isucon11/12-q).
  `DATABASES=isucon` confirmed verbatim from the role's
  `CREATE DATABASE IF NOT EXISTS isucon;` task. `mysql.service` is
  synthesized (no unit file shipped in refs, same as every year's stock
  `mysql-server` package). `VERSION` is a representative Ubuntu 22.04
  jammy build string, no exact one in refs.
- `EnvironmentFile=/home/isucon/env` (no `.sh` extension) — PROBE_SCRIPT's
  `ENV_FILE` probe checks `env.sh`, `env`, `.env` in that order, so the bare
  `env` filename here matches on the second candidate; fixture's
  `home-isucon/env` carries 5 representative `MYSQL_*` keys, not a full
  reproduction (refs doesn't ship the real env file's contents).
- nginx enables only `isuconquest.conf` (`isuconquest-php.conf` deployed,
  not symlinked); both real confs plus the real top-level `nginx.conf` are
  copied verbatim (unlike prior years, this fixture includes a real
  `nginx.conf`, not a synthesized `[Unit]`/`[Service]` stand-in, since the
  role ships one).
