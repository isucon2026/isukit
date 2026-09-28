# isucon8-final fixture — KNOWN DISCOVERY GAP (WEB_SERVER / DB_SERVER)

Source: `refs/isucon8-final/` — this year ships NO ansible/provisioning directory.
Instead the repo's own `README.md` documents the exact contest-day (2018-10-20) home
dir layout AND the exact production systemd unit verbatim (quoted here for provenance,
reproduced byte-for-byte into `units/isucoin.service`): a single `isucoin.service` whose
`ExecStart`/`ExecStop` wrap `docker-compose -f docker-compose.yml -f
docker-compose.go.yml {up,down}`. `webapp/docker-compose.yml` defines `nginx`, `isucoin`
(the app), and `mysql` as three separate **docker-compose services/containers** — none
of which register as independent host-level systemd units. Only `isucoin.service` is
ever visible to `systemctl` on the real host.

**This is a genuine, honest FAIL, not a fixture bug.** PROBE_SCRIPT's WEB_SERVER/DB_SERVER
checks are both `systemctl is-active --quiet <name>` against a fixed candidate list —
correct for host-native daemons, but nginx and mysql here only exist *inside* containers
that docker-compose starts, so:
  - isukit's real computed output: `WEB_SERVER=` (empty), `DB_SERVER=` (empty)
  - true correct answer:            `WEB_SERVER=nginx`, `DB_SERVER=mysql`
`expected` is set to the TRUE values per the task's hard rule (never weaken `expected`
to force a pass), so `run-probe-tests.sh` will print a genuine `FAIL isucon8-final` on
these two keys. This is the intended, documented outcome — see the "Known discovery
gaps" writeup. `MYSQL_OK=0` for the same underlying reason (host `mysql` CLI cannot
reach a container-only, non-host-exposed MySQL), which is why no `mysql.tsv` exists here.

APP_UNIT itself is correctly discovered (WorkingDirectory under /home/isucon + User=isucon
+ the `compose`-in-ExecStart bonus score to 8, well above the high-confidence threshold),
and SRC_LANGS is correctly discovered too (naively sweeps in `mockservice`/`mysql`/
`nginx`/`public` alongside the three real language dirs present on contest day —
`webapp/sql` was `rm`'d before go-live per the README, so it's excluded here; this
fixture models the go-live filesystem, not the repo's raw source tree).

---

## UPDATE 2026-09-28 — no longer a FAIL

`PROBE_SCRIPT` now consults `docker ps` when the systemd sweep finds no web/DB tier, so
the TRUE values this file insisted on (`WEB_SERVER=nginx`, `DB_SERVER=mysql`) are now
what the probe actually computes — `expected` was right and did not have to move. See
`isucon6-final/NOTES.md` for the mechanism and the new `STACK_IN_DOCKER` key.

`docker-ps.txt` here is derived from the real `webapp/docker-compose.yml`
(`nginx:1.15.3-alpine`, a locally-built `isucoin`, `mysql:8`) under compose v1 container
naming. `MYSQL_OK=0` still holds and is still correct: the host `mysql` CLI genuinely
cannot reach a container-only MySQL, which is a real property of the box, not a blind spot.
