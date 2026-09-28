# isucon7-final fixture

Source: `refs/isucon7-final/files/` — this year ships NO ansible/provisioning directory
at all. Instead the repo's own `README.md` documents manual xbuild-based setup and
explicitly points at `files/*.service` "if using systemd" (「systemd を利用して起動する
場合は、files/ 配下にある各 service ファイルを参照してください」). These are real,
maintainer-authored unit files meant for manual `cp` to `/etc/systemd/system/`, not
ansible role output — a genuinely different provisioning convention from isucon13/
isucon7-qualify that a shallow `*ansible*`/`*provisio*` search misses entirely.

`files/` ships one `cco.<lang>.service` per language (go/nodejs/perl/php/python/ruby),
all structurally identical (WorkingDirectory=/home/isucon/webapp/<lang>,
EnvironmentFile=/home/isucon/env.sh, User=isucon) — no task/playbook indicates which
one actually ran on contest day, so **Go was picked as the fixture's ground-truth
active language** (an explicit judgment call, not evidenced by the source). This is
unlike isucon7-qualify/isucon8-qualify where the ansible task list itself picks the
language.

`files/portal.*.service` (portal host) and `files/bench.*.service` (separate bench-worker
host) are deliberately EXCLUDED from `active` — they run on different physical hosts in
the real contest architecture even though their unit files ship in the same repo.
`files/cco.php.nginx.conf` (a PHP-specific alternate conf) is excluded since Go is the
chosen language. `nginx.service`/`mysql.service` are synthesized decoys, same as
isucon13/isucon7-qualify.

Everything here is expected to PASS.
