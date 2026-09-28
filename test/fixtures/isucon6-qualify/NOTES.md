# isucon6-qualify fixture

Source: `refs/isucon6-qualify/provisioning/image/` (ansible + shipped unit files under
`files/`).

## What's real vs synthesized

- `units/isuda.{go,js,perl,php,python,ruby,scala}.service`,
  `units/isutar.{go,js,perl,php,python,ruby,scala}.service`, `units/isupam.service` —
  all 15 copied verbatim from `provisioning/image/files/*.service`.
- `units/nginx.service`, `units/mysql.service` — SYNTHESIZED (standard apt packages;
  the repo ships a custom `nginx.conf`/`nginx.php.conf`/`fastcgi_params` but no custom
  systemd unit for either nginx or mysql).
- `nginx/nginx.conf` — real, copied from `provisioning/image/files/nginx.conf`. Proxies
  `/` to 127.0.0.1:5000 (isuda) and `/stars` to 127.0.0.1:5001 (isutar). No
  `access_log` directive (not asserted here).
- `home-isucon/webapp/*` mirrors the real, unfiltered `ls -1 webapp/` output:
  `bin go js perl php public python ruby scala` — note `bin` and `public` are literal
  directory entries in `webapp/` in this repo, not language dirs; PROBE_SCRIPT's
  `SRC_LANGS` is unfiltered by design so they're included as-is.

## Default active app

`provisioning/image/ansible/04_deploy.yml`'s final block enables/starts, for BOTH
sub-apps, the **perl** variant: `isupam`, `isuda.perl`, `isutar.perl` — unlike
isucon5-qualify (ruby default), this year defaults to perl for both.

## Expected behavior (PASS, but with a near-miss worth flagging)

Scores (WorkingDirectory home-prefixed=+4, ExecStart path home-prefixed=+3,
EnvironmentFile present=+2, User=isucon=+2):

- `isuda.perl.service`: WorkingDirectory=/home/isucon/webapp/perl,
  ExecStart=/home/isucon/.local/perl/bin/carton, EnvironmentFile=/home/isucon/env.sh,
  User=isucon → 4+3+2+2 = **11**
- `isutar.perl.service`: identical shape (only the port and psgi file differ) → **11**
  — an EXACT tie with isuda.
- `isupam.service`: WorkingDirectory=/home/isucon/ (home-prefixed, +4),
  ExecStart=/home/isucon/bin/isupam (+3), no EnvironmentFile (+0), User=isucon (+2)
  → **9**

PROBE_SCRIPT's tie-break is strictly-greater-only, so on an exact tie the FIRST unit
encountered wins (alphabetical, since `$UNITS` is `sort -u`'d) — `isuda` < `isutar`,
so `isuda.perl.service` wins and becomes `APP_UNIT`, confidence=high (11>=6).

This happens to be the CORRECT answer — `isuda` genuinely is described as the "main
application" and `isutar` as the "sub application" per their `Description=` fields — but
it's worth flagging as a **fragility, not a real signal**: the scoring model cannot
structurally distinguish "main app" from "sub app" when both units are shaped
identically. The alphabetical tie-break getting it right here is closer to luck (isuda
sorts before isutar) than to the scoring heuristic actually detecting which one is
primary. A hypothetical isucon year where the secondary app's name sorted first would
silently pick the wrong one at the same high confidence. Not a FAIL in this fixture —
the pick is genuinely correct — but a good target for a future scoring improvement
(e.g. penalizing higher port numbers, or an actual-traffic signal from nginx upstream
config, which PROBE_SCRIPT does not currently cross-reference).
