# isucon7-qualify fixture

Source: `refs/isucon7-qualify/provisioning/allinone/` — standard ansible, same shape as
isucon13's reference fixture. `site.yml`'s role list includes only `golang` among the
per-language roles (nodejs/perl/php/python/ruby are all commented out in that file), so
`isubata.golang.service` is the sole real app unit — no sibling-language decoys to skip.

Home dir is nested one level deeper than isucon13 (`/home/isucon/isubata/webapp/...`
not `/home/isucon/webapp/...`), which exercises PROBE_SCRIPT's second SRC-dir glob
candidate (`/home/isucon/*/webapp`) instead of the first literal one — still discoverable.

`nginx.service`/`mysql.service` are synthesized minimal decoy units (no ansible-shipped
unit file ships for these apt-installed daemons, same as isucon13). `bench.service` is
real (`roles/bench/files/...`) and deliberately included in `active` to exercise
DENY_PAT's `*bench*` pattern (this role runs on the same allinone playbook/host in this
year, unlike isucon7-final where bench runs on a separate host — see that fixture's notes).
`nginx.php.conf` (an unlinked alternate PHP conf shipped in the same role) is excluded
from `nginx/` since the "Enable isubata config" task only ever links plain `nginx.conf`.

Everything here is expected to PASS.
