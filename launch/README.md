# launch — AWS instances for practice (and a plain-AMI contest fallback)

**Practice tooling first.** These scripts launch a past problem's AMI in your
own AWS account so you can rehearse everything from the first SSH on
(REHEARSAL.md). On contest day **the organizers' manual decides how servers
come up** — ISUCON14 used a team-specific CloudFormation template, the `isucon`
user and GitHub keys — **and that wins: skip these scripts entirely.** They
are for the contest only if the manual just says "launch N of instance type T
from AMI X" and leaves the how to you.

## Timeline

| When | Script | What |
|---|---|---|
| T-7d (any day before) | `prestage.sh` | verify AWS auth, key pair, VPC/subnet, security group (SSH from your IP, plus any `--allow-ip`) |
| T+0:00 | — | contest starts, read the manual, get AMI id / instance type / instance count |
| T+0:10 | `launch.sh --ami … --type … --count …` | launch exactly what the manual specifies |
| T+0:15 | `isukit go …` | printed by launch.sh — hand off to the main isukit loop |

## The rules this respects

- **Never launch instances the manual doesn't specify.** `launch.sh` takes
  `--ami`, `--type`, and `--count` as required flags with no defaults — it
  will not guess, and it will not create a "helper" or "bench" box of its
  own. A human reads the manual and types the three values in.
- **`--root-gb <N>` is optional and defaults to nothing.** Leave it off and
  `launch.sh` launches with the AMI's own root volume, byte for byte — the
  contest-day-safe path. Pass it to size the root larger than the AMI ships
  (common practice AMIs are 8GB, which `isukit logs on`'s slow query log can
  fill) for practice runs; don't use it on contest day unless the manual
  says so.
- **Instance type, security groups, and `envcheck` can't change after
  launch.** This is an ISUCON rule, not an AWS limit — nothing stops you from
  editing a security group after boot, but doing so is a disqualifiable move
  on contest day. Everything that can be gotten right in advance — key pair,
  VPC, subnet, security group rules — is verified (and only-if-missing
  created) by `prestage.sh`, days before the contest, so there's nothing left
  to decide under time pressure at T+0.
- **The key file `prestage.sh` writes (`--key-file`) is gitignored — never
  put it in the shared repo.** Distribute it to the team out of band.
- **`--allow-ip <cidr-or-ip>` (repeatable) authorizes teammates' SSH access.**
  `prestage.sh` always authorizes the operator's own auto-detected IP with no
  flags needed; pass `--allow-ip` once per teammate to add theirs too (a bare
  IP is normalized to `/32`, a `203.0.113.0/24`-style CIDR is passed through
  as-is). Since security group rules can't change after `launch.sh` runs,
  every teammate's IP has to be in the list **before** that point — re-run
  `prestage.sh` with `--allow-ip` any time before contest day to add one, and
  check the printed authorized-CIDR list against the roster.
- **The benchmarker server is never touched by this tooling.** These scripts
  launch app instances only; nothing here targets or reconfigures a bench
  host.

`user-data.sh` runs at first boot and is install-only — packages and `alp`,
nothing that touches the app, nginx logging, the mysql slow log, or
`envcheck`. Turning logging on/off is `isukit logs on|off`, run by the
operator once the app is actually being tuned.
