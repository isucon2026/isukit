# isucon13

Source: `refs/isucon13/provisioning/ansible/`. Reference/template fixture —
built first, used as the model for the other years.

- 7 language variants of the same app ship as separate units
  (`isupipe-{go,node,perl,php,python,ruby,rust}.service`); only `go` is
  `enabled+restarted` in `roles/webapp/tasks/go.yaml`, the other 6 are
  `enabled: false, state: stopped`. Only `isupipe-go` is listed `active` here.
- Decoys included on purpose to exercise `DENY_PAT` and the oneshot skip:
  `envcheck.service` and `aws-env-isucon-subdomain-address.service` (both real,
  copied verbatim, both `Type=oneshot`/`RemainAfterExit=yes` so both are listed
  `active`); `pdns.service`, `nginx.service`, `mysql.service` are synthesized
  minimal stanzas (no ansible-shipped unit file for these — apt-installed).
- `nginx/isupipe.conf` is the real site conf (no explicit `access_log`
  directive in the source — `nginx/nginx.conf`'s http-block `access_log` is
  synthesized so `NGINX_ACCESS_LOG` isn't empty).
- `/home/isucon` paths are relocated to `$ISUKIT_FAKE_HOME` symmetrically by
  the runner (PROBE_SCRIPT text) and the `systemctl` stub (unit file values);
  see `test/README.md`.
