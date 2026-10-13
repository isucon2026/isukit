# isucon14

Source: `isucon/isucon14` `provisioning/ansible/roles/{webapp,envcheck,nginx}/files/`
(units and `isuride.conf` copied verbatim; `nginx.conf`, `mysql.service` and
`nginx.service` are the synthesized ones from the isucon13 fixture).

- 7 language variants ship as `isuride-{go,node,perl,php,python,ruby,rust}.service`;
  only `go` is enabled. `isuride-matcher.service` (curls
  `/api/internal/matching` every `$ISUCON_MATCHING_INTERVAL`, same
  `EnvironmentFile=/home/isucon/env.sh`, no `WorkingDirectory=`) is enabled
  next to it: the sibling probe must report it as `APP_SIBLINGS` so it lands in
  `EXTRA_UNITS` (#42). The disabled language variants share the prefix and the
  env file and must not.
- `isuride-payment_mock.service` is enabled by the ansible role but was neither
  enabled nor running on the 2026-10-12 rehearsal's contest image; it is left
  disabled here, as observed.
- `isuride-go.service` has `Requires=mysql.service` — what the split check
  flags on an app host without the db role (#29).
- `enabled` lists what `systemctl is-enabled` reports; `envcheck` is a oneshot
  and denied, so it is no sibling either.
