# Getting a shell on the servers — contest day vs practice

isukit starts **once you can SSH to the app hosts**. How you get there is a different
procedure on contest day and in practice, and mixing them up is how a team spends the
first hour of the contest on the wrong thing.

## Contest day (ISUCON2026)

**The day's manual wins over everything here.** The regulation only says: each team
brings its own AWS account, launches EC2 from what the organisers specify after the
start, and "the concrete launch procedure is in the day's manual". It does not name the
instance type, count, region or tooling.

What ISUCON14 actually did under the same regulation wording — expect something like it,
do not assume it:

- The portal hands each team **its own CloudFormation template** (never share it). You
  create the stack in **ap-northeast-1**; it makes 3× c5.large, EBS, EIPs, a VPC, a
  security group, a Lambda and two IAM roles.
- You SSH as **`isucon`**, with the key you registered on **GitHub** — not `ubuntu`, not
  a `.pem`. Hence: `isukit go --new <team>/<repo> isucon@<ip>` (add `-i` only if that
  GitHub key is not your default ssh key).
- A **mandatory pre-contest "AWS environment check"** (create the stack, confirm SSH) had
  a deadline; missing it was disqualification. Watch for the 2026 announcement.
- Changing what the template created (instance type, security group, `envcheck`) is
  disqualification.

Account risks the regulation leaves to the team ("problems caused by resources or
settings already in the AWS account are not supported"):

- A company sandbox may forbid creating **IAM roles** (the stack fails), or may not allow
  granting the organisers' role read access to the account's other resources.
- Security tooling that auto-closes port 22 open to the world can **cut SSH mid-contest**.
- vCPU (3× c5.large = 6) and Elastic IP (3) quotas.
- Keep a spare team AWS account ready.

`launch/` (prestage / launch.sh) is **not** for this case unless the manual says only
"launch N of type T from AMI X" and leaves the how to you.

## Practice

The contest template is team-specific and portal-only, so practice uses a past problem's
AMI (matsuu/aws-isucon) launched with the kit's own scripts:

```
launch/prestage.sh --key-name isukit --key-file <pem> --region ap-northeast-1 --sg-name isukit-ssh
launch/launch.sh --ami <past-problem AMI> --type c5.large --count <n> --root-gb 30 --yes
isukit go --new <you>/<repo> ubuntu@<ip> -i <pem>
```

- SSH is `ubuntu@` + the `.pem`, then `sudo su - isucon` by hand when needed.
- `--root-gb 30`: practice AMIs ship 8–16GB, which the slow log fills.
- The bench usually runs on a box you may SSH (auto mode) — the opposite of contest day.

## The same either way (from the first SSH on)

`go --new` / `go` → roles (`host role`, commit `isukit.hosts`) → baseline on main →
the loop (lock, deploy, bench, show, attribute, merge or redeploy main, unlock) →
`final check` / `final apply` → `finalize`.
