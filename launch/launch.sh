#!/usr/bin/env bash
# isukit launch — T+0, AFTER a human has read the day-of manual. Launches
# exactly what the manual says and nothing else: ami/type/count are required
# with no defaults, because guessing any of them risks an extra or wrong
# instance, which is a rules violation. Everything reusable (key, vpc, subnet,
# security group) was already verified by prestage.sh.

set -euo pipefail

die()  { printf '\033[31m!! %s\033[0m\n' "$*" >&2; exit 1; }
say()  { printf '\033[36m:: %s\033[0m\n' "$*" >&2; }
warn() { printf '\033[33m~~ %s\033[0m\n' "$*" >&2; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
envfile="$here/prestage.env"
[ -f "$envfile" ] || die "no $envfile — run launch/prestage.sh first"
# shellcheck source=/dev/null
. "$envfile"

ami="" type="" count="" prefix="isucon" yes=0
while [ $# -gt 0 ]; do
  case "$1" in
    --ami)         ami="$2"; shift 2 ;;
    --type)        type="$2"; shift 2 ;;
    --count)       count="$2"; shift 2 ;;
    --name-prefix) prefix="$2"; shift 2 ;;
    --yes)         yes=1; shift ;;
    *) die "unknown arg: $1 (usage: launch.sh --ami <id> --type <type> --count <n> [--name-prefix p] [--yes])" ;;
  esac
done

[ -n "$ami" ]   || die "missing --ami <ami-id> — the manual publishes this at contest start, don't guess"
[ -n "$type" ]  || die "missing --type <instance-type> — the manual specifies this, don't guess"
[ -n "$count" ] || die "missing --count <n> — the manual specifies how many instances, don't guess"
case "$count" in ''|*[!0-9]*|0) die "--count must be a positive integer, got: $count" ;; esac

: "${AWS_REGION:?$envfile missing AWS_REGION — re-run prestage.sh}"
: "${KEY_NAME:?$envfile missing KEY_NAME — re-run prestage.sh}"
: "${KEY_FILE:?$envfile missing KEY_FILE — re-run prestage.sh}"
: "${SUBNET_ID:?$envfile missing SUBNET_ID — re-run prestage.sh}"
: "${SG_ID:?$envfile missing SG_ID — re-run prestage.sh}"

echo "==============================================================" >&2
printf '\033[35m   ABOUT TO LAUNCH %s x %s FROM %s IN %s\n   names: %s-1 .. %s-%s\n   subnet %s, sg %s, key %s\033[0m\n' \
  "$count" "$type" "$ami" "$AWS_REGION" "$prefix" "$prefix" "$count" "$SUBNET_ID" "$SG_ID" "$KEY_NAME" >&2
echo "==============================================================" >&2
warn "launching MORE or OTHER instances than the manual specifies is a rules violation — recheck ami/type/count now."
warn "instance type and security groups can't be changed after launch — this is your last chance to get them right."

if [ "$yes" -ne 1 ]; then
  printf 'type "yes" to launch: ' >&2
  read -r confirm
  [ "$confirm" = "yes" ] || die "aborted"
fi

say "launching..."
ids=$(aws ec2 run-instances \
  --region "$AWS_REGION" \
  --image-id "$ami" \
  --instance-type "$type" \
  --count "$count" \
  --key-name "$KEY_NAME" \
  --subnet-id "$SUBNET_ID" \
  --security-group-ids "$SG_ID" \
  --user-data "file://$here/user-data.sh" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$prefix}]" \
  --query 'Instances[].InstanceId' --output text) || die "run-instances failed"

n=1
for id in $ids; do
  aws ec2 create-tags --region "$AWS_REGION" --resources "$id" --tags "Key=Name,Value=${prefix}-${n}" \
    || warn "failed to tag $id as ${prefix}-${n}"
  n=$((n + 1))
done

say "waiting for instances to reach running..."
# shellcheck disable=SC2086
aws ec2 wait instance-running --region "$AWS_REGION" --instance-ids $ids

# name comes along as a column so the table can't drift out of sync with the
# tags applied above, regardless of what order describe-instances returns rows in.
# shellcheck disable=SC2086,SC2016
info=$(aws ec2 describe-instances --region "$AWS_REGION" --instance-ids $ids \
  --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,InstanceId,PublicIpAddress,PrivateIpAddress]' \
  --output text)

echo >&2
printf '%-16s %-22s %-16s %-16s\n' "name" "instance-id" "public-ip" "private-ip" >&2
printf '%s\n' "$info" | while read -r name iid pub priv; do
  printf '%-16s %-22s %-16s %-16s\n' "$name" "$iid" "$pub" "$priv" >&2
done

if printf '%s\n' "$info" | awk '{print $3}' | grep -qx 'None'; then
  warn "one or more instances have NO PUBLIC IP (subnet's MapPublicIpOnLaunch is off) — using private IPs below; you'll need a bastion or VPN to reach them"
fi

pick_ip() { # pick_ip <public> <private> -- fall back to private when public is absent
  [ -n "$1" ] && [ "$1" != "None" ] && printf '%s' "$1" || printf '%s' "$2"
}

first_row=$(printf '%s\n' "$info" | awk -v n="${prefix}-1" '$1==n')
[ -n "$first_row" ] || die "couldn't find ${prefix}-1 in describe-instances output"
first_ip=$(pick_ip "$(printf '%s' "$first_row" | awk '{print $3}')" "$(printf '%s' "$first_row" | awk '{print $4}')")

echo >&2
say "ready-to-paste commands (adjust ssh user if the AMI isn't ubuntu):"
echo "  isukit go <repo-url> ubuntu@${first_ip} -i $KEY_FILE" >&2
printf '%s\n' "$info" | awk -v n="${prefix}-1" '$1!=n' | while read -r name iid pub priv; do
  ip=$(pick_ip "$pub" "$priv")
  echo "  isukit host add ubuntu@${ip}  # $name" >&2
done
