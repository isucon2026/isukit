# isucon10-final

Source: `refs/isucon10-final/packer/files/itamae/` — itamae (Ruby), NOT
ansible, which is why an earlier `*provisio*`/`*ansible*`/`*deploy*`
maxdepth-3 search found nothing. Unit templates live under
`cookbooks/*/templates/etc/systemd/system/*.service`, enable/start logic
lives in `roles/*/default.rb` as itamae `service` resources.

## The Envoy question — no naming gap, WEB_SERVER=envoy IS correctly detected

The task flagged this year as "very likely" to hide a discovery gap, since
`refs/isucon10-final` is documented to use Envoy instead of nginx. Checked
carefully:
- `cookbooks/envoy/templates/etc/systemd/system/envoy.service` names the
  unit exactly `envoy.service` — this **is** in isukit's WEB_SERVER
  candidate list (`nginx h2o envoy caddy apache2 httpd`) verbatim. No
  naming mismatch.
- `roles/contestant/default.rb` (the correct role to model a real
  per-team contestant box — see "which role" below) ends with:
  ```ruby
  service "envoy.service" do
    #TODO:action [:enable, :start]
    action :enable
  end
  ```
  Only `:enable` is called at itamae-converge time (during AMI build via
  packer), with the itamae source's own unfinished `#TODO` comment as
  evidence this was known/incomplete at build time. This does NOT mean
  envoy is inactive on a real contest box: `:enable` sets
  `WantedBy=multi-user.target`, so systemd auto-starts the unit on the next
  boot — and a contest day is a fresh boot of the baked AMI. So on an
  actual running contestant server, `envoy` is active, and
  `WEB_SERVER=envoy` is the CORRECT expected value.
- **Conclusion: no WEB_SERVER gap for this year.** `envoy*` is also in
  `DENY_PAT`, so `envoy.service` is correctly excluded from APP_UNIT
  candidacy too (by design, not a bug) — same as isucon13's mysql/nginx.

## Real finding: alphabetical tie-break picks the API unit over the web unit

The app is xsuportal itself — participants extend both a web frontend
(`xsuportal-web-ruby.service`, puma) and an API/benchmark-trigger backend
(`xsuportal-api-ruby.service`, `bin/benchmark_server.rb`), same
WorkingDirectory (`/home/isucon/webapp/ruby`), same EnvironmentFile
(`/home/isucon/env`), same User (isucon). Both score identically:
WorkingDirectory=+4, ExecStart path (`/home/isucon/.x`, under
`/home/isucon`)=+3, EnvironmentFile=+2, User=isucon=+2 → **11 each, tied**.
isukit's scoring loop uses strict `-gt` (not `-ge`) over `UNITS_LOCAL`,
which is alphabetically sorted (`sort -u`) — so the first of the tied pair
in sort order wins. `xsuportal-api-ruby` sorts before `xsuportal-web-ruby`
("api" < "web"), so **`APP_UNIT=xsuportal-api-ruby.service`** is what
isukit reports, arbitrarily preferring the benchmark-trigger backend over
the actual user-facing web app. Not a wrong answer in a practical sense
(both units ARE the same application, `APP_UNIT_CONFIDENCE=high` either
way, and a human skimming the output would recognize `xsuportal-*` as one
app), but worth flagging: **a real tie in the scoring heuristic**, unlike
every other fixture in this batch where one unit was unambiguously best.

## Which role: `contestant`, not `full`

`roles/full/default.rb` sets `xsuportal: {enable: nil, disable_default:
true}` and includes both `contestant` and `benchmarker` roles together —
that's a combined demo/CI image, not what ships to a real team. The plain
`contestant` role (`default_enable = 'ruby'`, i.e. isucon10-final's
default contestant language is Ruby, not Go) is the correct model for "a
real contestant application server" and is what this fixture follows.
`isuxportal-supervisor*.service` units (the portal/benchmarker-side
process) are deliberately NOT included here — they belong to the
benchmarker box, not the contestant's app server being modeled.

## Other details

- `mysql.service` is a REAL systemd unit here (not synthesized-because-
  containerized, unlike isucon9-final): `cookbooks/mysql/default.rb`
  apt-installs `mysql-server-8.0` and explicitly
  `service "mysql.service" do action [:enable, :start] end`. Still modeled
  with the same synthesized minimal stanza content as other years (no
  ansible/itamae-shipped custom unit body to copy verbatim), but it IS a
  genuine host-level unit, correctly detected.
- No `nginx/` dir in this fixture — WEB_SERVER=envoy means the nginx-only
  branch of PROBE_SCRIPT (which reads `nginx -T`) never runs; correct to
  omit.
- SRC_DIR resolves directly via the first candidate `/home/isucon/webapp`
  (WorkingDirectory in both xsuportal units confirms `/home/isucon/webapp/
  ruby` exists, so the parent matches with no glob needed). Real
  `webapp/` also has `frontend`, `generate_vapid_key.sh`, `sql`, `tools`
  (confirmed via `ls`) — `home-isucon/webapp/<lang>/` here models only the
  4 actually-included languages (golang, nodejs, ruby, rust; perl/php are
  explicitly commented out in `cookbooks/xsuportal/default.rb`'s
  `include_cookbook` chain), same language-dirs-only precedent as every
  other fixture in this batch.
- `mysql.tsv` VERSION (8.0.21-0ubuntu0.20.04.4) is a representative
  placeholder for the pinned `mysql-server-8.0` apt package on the
  contest-era Ubuntu 20.04 image — doesn't affect PASS/FAIL.
