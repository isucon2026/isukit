# isucon9-final

Source: `refs/isucon9-final/ansible/` + `refs/isucon9-final/webapp/docker-compose*.yml`.

## Real finding: DB_SERVER is legitimately empty (systemd-only blind spot)

The whole challenge stack is launched by ONE systemd unit
(`isutrain-{lang}.service`, from `ansible/roles/challenge/templates/
isutrain.service`) whose ExecStart is `docker-compose ... up`. Per
`webapp/docker-compose.yml`:
- `mysql` runs as a container (`image: mysql:8`) — there is NO
  `mysql-server` apt package anywhere in `ansible/roles/` (grepped, zero
  hits). Real host `systemctl is-active mysql` would be "unit not found".
  So `DB_SERVER=""` in `expected` is the CORRECT ground truth, not a
  weakened/forced pass — isukit's systemd-only DB_SERVER check is honestly
  blind to a docker-compose-embedded MySQL. No `mysql.tsv` in this fixture
  either (mysql stub returns MYSQL_OK=0), matching a host where mysql isn't
  reachable via the bare `mysql` CLI.
- **nginx is NOT only in docker** — `ansible/roles/challenge/tasks/main.yml`
  DOES `apt: name=nginx` on the HOST and templates a real TLS-terminating
  vhost (`nginx/default`) that reverse-proxies `/api` and `/initialize` to
  `127.0.0.1:8000` (the docker-compose-exposed app port); the docker-compose
  `nginx` service (image nginx:1.17, port 8080) is a SEPARATE internal
  reverse proxy inside the compose network, not the one isukit's systemd
  check would find. So `WEB_SERVER=nginx` correctly resolves via the real
  HOST nginx unit — this is not a gap, contrary to an initial assumption
  that nginx.service would also be docker-only. Corrected during research
  by reading `ansible/roles/challenge/tasks/main.yml` directly.
  `nginx/default.conf` here is that real templated vhost, renamed with a
  `.conf` extension (real deployed filename is extensionless `default`) so
  the `nginx -T` stub's `**/*.conf` glob picks it up — same
  filename-massage the isucon13 reference fixture doesn't need but is
  required here. `nginx/nginx.conf` (the http-block wrapper with
  `access_log`) is synthesized — no ansible-shipped main nginx.conf found,
  same precedent as isucon13.
- `isutrain-go.service` is the real templated unit
  (`ansible/roles/challenge/templates/isutrain.service` with `{{ item }}`
  rendered to `go` — only go gets `enabled: yes, state: started` in
  `ansible/roles/challenge/tasks/main.yml`; the other 4 languages
  (perl/php/python/ruby) only get their unit templated, not started).
  `{{ payment_api }}` is an ansible var with no fixed value in source;
  filled with a placeholder — irrelevant to scoring/probing.
- Score for isutrain-go: WorkingDirectory=+4, ExecStart path
  (`/usr/bin/docker-compose`, not under /home/isucon)=+0, EnvironmentFile
  (leading `-` stripped by the test stub)=+2, User unset in the template=+0,
  ExecStart contains "compose" AND WorkingDirectory under /home/isucon=+2
  bonus → 8, high confidence.
- SRC_DIR: `/home/isucon/isutrain/webapp` (matches the
  `/home/isucon/*/webapp` glob). `home-isucon/isutrain/webapp/<lang>/`
  models the 5 languages that actually have a `docker-compose.<lang>.yml`
  overlay (go, perl, php, python, ruby — no node/rust for this year), same
  language-dirs-only precedent as the other fixtures.
