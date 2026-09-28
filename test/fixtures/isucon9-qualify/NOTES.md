# isucon9-qualify

Source: `refs/isucon9-qualify/provisioning/` (ansible).

- Only `isucari.golang.service` is enabled+started
  (`roles/webapp.golang/tasks/*.yml`, `state: started, enabled: yes`); the
  other 5 language roles (`webapp.{nodejs,perl,php,python,ruby}`) only copy
  their unit file, no enable/start — matches the isucon13 pattern of "N
  language units shipped, 1 active".
- `nginx.service`/`mysql.service` are synthesized minimal stanzas (both
  apt-installed via `roles/nginx`/`roles/mysql`, no ansible-shipped custom
  unit file) — same synthesized units as the isucon13 reference fixture.
- `nginx/nginx.conf` and `nginx/isucari.conf` are the REAL provisioned files
  (`roles/webapp.nginx/files/etc/nginx/...`), copied verbatim — both already
  have a real `access_log` directive, no synthesis needed.
- `mysql.tsv` VERSION (5.7.26-0ubuntu0.16.04.1) is a representative
  placeholder, not extracted from source: provisioning apt-installs a bare
  `mysql-server` with no version pin. Doesn't affect PASS/FAIL — `expected`
  only checks APP_UNIT/CONFIDENCE/WEB_SERVER/DB_SERVER/SRC_LANGS.
- SRC_DIR resolves via the `/home/isucon/*/webapp` glob candidate to
  `/home/isucon/isucari/webapp` (confirmed by the `dev.deploy`/
  `webapp.deploy` ansible tasks that rsync `webapp/` there).
- `home-isucon/isucari/webapp/<lang>/` models only the 6 actually-deployed
  language dirs (go, nodejs, perl, php, python, ruby) that have a
  `webapp.<lang>` role, not literal `ls` output of the real repo's `webapp/`
  (which also has non-language entries) — same precedent as isucon13.
- Score for isucari.golang: WorkingDirectory=+4, ExecStart path
  `/home/isucon/isucari/webapp/go/isucari`=+3, EnvironmentFile=+2, User=isucon
  =+2 → 11, high confidence. No gap found for this year.
