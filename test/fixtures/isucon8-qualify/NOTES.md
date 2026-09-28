# isucon8-qualify fixture

Source: `refs/isucon8-qualify/provisioning/` — standard ansible (`roles/*`), same general
shape as isucon7-qualify/isucon13, but this year's stack is **H2O + MariaDB**, not
nginx/MySQL (`install_h2o` and `install_mariadb` roles; no nginx role exists at all).
Both `h2o` and `mariadb` are already in PROBE_SCRIPT's fixed WEB_SERVER/DB_SERVER
candidate lists, so this is directly (and correctly) discoverable.

`site.yml` fans out to `webapp1.yml`/`webapp2.yml`/`webapp3.yml`. All three hosts run
`prepare_webapp` (which installs unit files for every language: go/nodejs/perl/php/
python/ruby), but only `webapp1.yml` additionally runs `start_perl_webapp` — the ONLY
`start_<lang>_webapp` role that exists in this year's role list. That role explicitly
`systemd: restart+enable`s mariadb, h2o, and `torb.perl` — so **Perl is the ground-truth
active language** for webapp1 (the host this fixture models), not Go. The other five
`torb.<lang>.service` units are real, ansible-deployed files (correctly present in
`units/`) but never started — same "siblings shipped, one active" pattern as isucon13,
just with a different language winning.

`ls -1` on the SRC dir sweeps in `env.sh` and `static` alongside the six real language
dirs (the repo's own `webapp/` has both) — `SRC_LANGS` faithfully reflects that naive
inclusion, same non-bug caveat as isucon8-final's `mockservice`/`nginx`/`mysql`/`public`
sweep-in.

Everything here is expected to PASS.
