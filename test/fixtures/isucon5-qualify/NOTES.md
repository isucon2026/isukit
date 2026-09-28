# isucon5-qualify fixture

Source: `refs/isucon5-qualify/` (GCP-based provisioning under `gcp/image/`).

## What's real vs synthesized

- `units/isuxi.{go,java,perl,php,python,ruby,scala}.service` — copied verbatim from
  `gcp/image/files/systemd.<lang>.service`, renamed to the deployed unit name
  `isuxi.<lang>.service` (the ansible deploy task installs each as
  `/etc/systemd/system/isuxi.<lang>.service`, see `04_deploy_application.yml`).
  None of the 7 unit files sets `User=` — real finding, not an omission on my part.
- `units/nginx.service`, `units/mysql.service` — SYNTHESIZED (standard distro package
  units). The repo installs nginx/mysql via apt with no custom systemd unit shipped.
- `nginx/nginx.conf` — real, copied from `gcp/image/files/nginx.conf`. It has no
  `access_log` directive, so `NGINX_ACCESS_LOG` would resolve empty (not asserted here).
- `home-isucon/webapp/*` — empty `.keep` markers mirroring the real, UNFILTERED
  `ls -1 webapp/` output: `go java perl php python ruby scala script sql static`
  (includes non-language dirs `script`, `sql`, `static`, matching PROBE_SCRIPT's
  literal, unfiltered `SRC_LANGS` behavior).

## Expected behavior (PASS)

`04_deploy_application.yml`'s final task is
`service: name=isuxi.ruby state=running enabled=true` — ruby is the deployed default,
so `isuxi.ruby.service` is the one listed `active`.

Score for `isuxi.ruby.service`: WorkingDirectory=/home/isucon/webapp/ruby (+4),
ExecStart path /home/isucon/.local/ruby/bin/bundle (+3), EnvironmentFile=/home/isucon/env.sh
(+2), User not set (+0) = **9**, confidence=high (>=6). No other app unit is active, so
this is a clean, unambiguous correct pick — no discovery gap here.
