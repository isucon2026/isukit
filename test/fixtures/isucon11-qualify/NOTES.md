# isucon11-qualify

Source: `refs/isucon11-qualify/provisioning/ansible/roles/contestant/`.

- 7 language variants ship as `isucondition.<lang>.service` (real units,
  copied verbatim from `roles/contestant/files/etc/systemd/system/`); only
  `isucondition.go.service` is actually enabled+started, via
  `systemctl enable --now isucondition.go.service` at the end of
  `generate-env_aws.sh` (a cloud-init per-instance script, not an ansible
  `systemd:` task) — so only `isucondition.go` is listed `active` here.
- Datastore is **MariaDB 10.3** (`mariadb.yml`), not MySQL — `mariadb.service`
  is synthesized (apt-installed, no unit file shipped). `DB_SERVER=mariadb`
  is correct: PROBE_SCRIPT's DB candidate list is `mysql mariadb postgresql`,
  and mariadb wins since mysql isn't active. The `mysql` CLI stub still
  answers (MariaDB ships a mysql-compatible client), so `MYSQL_OK=1` too.
- `jiaapi-mock.service` (real unit, verbatim) is enabled and active — it's
  caught by `DENY_PAT`'s `*mock*` glob, exercising that specific pattern.
- `isucon-env-checker.service` is synthesized `Type=oneshot` (the real unit
  is built from a `/tmp` source tree not present in `refs/`) — **worth
  flagging**: its real name is `isucon-env-checker`, which `DENY_PAT`'s
  `envcheck*`/`env-checker*` globs do NOT match by prefix (the name starts
  with `isucon-`, not `env-checker`). It's excluded from `APP_CANDIDATES`
  only because it's `Type=oneshot`, not because `DENY_PAT` caught it — a
  near-miss in the deny-list naming, not a bug (the oneshot skip covers it).
- `SRC_LANGS` fixture mirrors only the 7 language dirs under `webapp/`,
  matching the isucon13 reference pattern. The real `/home/isucon/webapp`
  also contains `frontend` (removed by ansible before contest), `sql`, and
  a couple of asset files not modeled here — same simplification the
  isucon13 fixture makes.
