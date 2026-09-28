# isucon11-final

Source: `refs/isucon11-final/provisioning/ansible/roles/contestant/`.

- 5 language variants ship as `isucholar.<lang>.service` (real units, copied
  verbatim from `roles/contestant/files/etc/systemd/system/`) — no perl or
  python this year, unlike isucon11-qualify's 7. Only `isucholar.go.service`
  is actually enabled, via a plain ansible `systemd:` task in `isucholar.yml`
  (`enabled: "yes"`, `daemon_reload: "yes"`) — no cloud-init per-instance
  script this time (confirmed: no `*per-instance*`/`*cloud-init*` files and
  no other `systemctl enable` hit anywhere in the repo besides one in
  `docs/manual.md`, which documents a *manual* switch to ruby, not the
  default state). So only `isucholar.go` is listed `active` here.
- Datastore is **real MySQL 8.0** this year (`mysql.yml` installs
  `mysql-server-8.0`, starts/enables unit name `mysql.service`) — unlike
  isucon11-qualify's MariaDB-under-a-`mysql.yml`-shaped-name trap, this one's
  filename is accurate. `mysql.service` is synthesized (apt-installed, no
  unit file shipped in refs); `DB_SERVER=mysql` is correct. `VERSION` in
  `mysql.tsv` is a representative Ubuntu 20.04 focal `mysql-server-8.0`
  build string (`8.0.27-0ubuntu0.20.04.1`) — refs contains no exact
  contest-day version string to pull verbatim, only the package name.
- nginx only enables `isucholar.conf` (proxies `/api` etc. to go's
  `127.0.0.1:7000`) via a `file: state=link` into `sites-enabled`;
  `isucholar-php.conf` is deployed but never linked. Both real confs are
  copied verbatim; `nginx.service` is synthesized.
- No mock/envchecker-style decoy unit exists in this year's contestant role
  (`roles/common/tasks/main.yml` is empty of service tasks) — `active` here
  is just the 3 real signals: app, web, db.
- `SRC_LANGS` fixture mirrors the 5 real language dirs under `webapp/`
  (go/nodejs/php/ruby/rust); the real tree also has non-language `data`,
  `frontend`, and `sql` dirs, excluded here per the same simplification the
  isucon13/isucon11-qualify fixtures use.
