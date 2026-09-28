# isucon10-qualify

Source: `refs/isucon10-qualify/provisioning/ansible/`.

- 8 language roles exist (`web-{deno,go,node,perl,php,python,ruby,rust}`,
  unit files `isuumo.{deno,go,nodejs,perl,php,python,ruby,rust}.service`).
  Per-language tasks only build+copy the unit file; the actual enable/start
  is centralized in `roles/web-prepare/tasks`, which explicitly restarts+
  enables only `isuumo.go.service` and reloads+enables `nginx`. Only go is
  `active` here.
- `web-bootstrap/tasks/main.yaml` installs `mysql-server-5.7` (pinned) and
  restarts mysql with `enabled: "yes"` — real version used in `mysql.tsv`.
- `nginx.service`/`mysql.service` are synthesized minimal stanzas (both
  apt-installed, no ansible-shipped custom unit) — same as isucon13/
  isucon9-qualify.
- `nginx/nginx.conf` and `nginx/isuumo.conf` are the REAL provisioned files
  (`web-bootstrap/files/{nginx.conf,isuumo.conf}`), copied verbatim.
  `nginx.conf`'s `access_log` directive is real, no synthesis needed.
  Note `isuumo.conf`'s `root` line says `/home/isucon/isucon10-qualify/webapp/public`
  (an apparent stale/leftover path in the real source) while every deploy task
  in the ansible roles uses `/home/isucon/isuumo/webapp/...` — kept verbatim
  since it's the real file and doesn't affect isukit's SRC_DIR/WEB_SERVER
  detection (those come from systemd unit introspection and filesystem
  existence checks, not from grepping nginx config).
- SRC_DIR resolves via the `/home/isucon/*/webapp` glob to
  `/home/isucon/isuumo/webapp` (confirmed by every `web-<lang>/tasks` chdir).
  Real top-level `webapp/` also has non-language entries (docker-compose,
  fixture, frontend, mysql, nginx, Makefile, README.md) — `home-isucon/`
  here models only the 8 actual language dirs, same precedent as isucon13.
- Score for isuumo.go: WorkingDirectory=+4, EnvironmentFile=+2, User=isucon=+2,
  ExecStart path under /home/isucon=+3 → 11, high confidence. No gap found
  for this year.
