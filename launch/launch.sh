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

ami="" type="" count="" prefix="isucon" yes=0 root_gb=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ami)         ami="$2"; shift 2 ;;
    --type)        type="$2"; shift 2 ;;
    --count)       count="$2"; shift 2 ;;
    --name-prefix) prefix="$2"; shift 2 ;;
    --root-gb)     root_gb="$2"; shift 2 ;;
    --yes)         yes=1; shift ;;
    *) die "unknown arg: $1 (usage: launch.sh --ami <id> --type <type> --count <n> [--name-prefix p] [--root-gb n] [--yes])" ;;
  esac
done

[ -n "$ami" ]   || die "missing --ami <ami-id> — the manual publishes this at contest start, don't guess"
[ -n "$type" ]  || die "missing --type <instance-type> — the manual specifies this, don't guess"
[ -n "$count" ] || die "missing --count <n> — the manual specifies how many instances, don't guess"
case "$count" in ''|*[!0-9]*|0) die "--count must be a positive integer, got: $count" ;; esac
case "$root_gb" in '') ;; *[!0-9]*|0) die "--root-gb must be a positive integer, got: $root_gb" ;; esac

: "${AWS_REGION:?$envfile missing AWS_REGION — re-run prestage.sh}"
: "${KEY_NAME:?$envfile missing KEY_NAME — re-run prestage.sh}"
: "${KEY_FILE:?$envfile missing KEY_FILE — re-run prestage.sh}"
: "${SUBNET_ID:?$envfile missing SUBNET_ID — re-run prestage.sh}"
: "${SG_ID:?$envfile missing SG_ID — re-run prestage.sh}"

block_device_args=()
root_summary="AMI default"
if [ -n "$root_gb" ]; then
  root_device=$(aws ec2 describe-images --region "$AWS_REGION" --image-ids "$ami" \
    --query 'Images[0].RootDeviceName' --output text) || die "describe-images failed (root device)"
  [ -n "$root_device" ] && [ "$root_device" != "None" ] || die "couldn't read root device name for $ami"
  ami_root_gb=$(aws ec2 describe-images --region "$AWS_REGION" --image-ids "$ami" \
    --query "Images[0].BlockDeviceMappings[?DeviceName==\`$root_device\`]|[0].Ebs.VolumeSize" --output text) \
    || die "describe-images failed (root size)"
  [ -n "$ami_root_gb" ] && [ "$ami_root_gb" != "None" ] || die "couldn't read root volume size for $ami"
  [ "$root_gb" -ge "$ami_root_gb" ] || die "--root-gb $root_gb is smaller than the AMI's own root ($ami_root_gb GB) — EBS can't shrink a volume"
  warn "--root-gb $root_gb deviates from the AMI's default root ($ami_root_gb GB) — practice only, not contest day unless the manual says so."
  block_device_args=(--block-device-mappings "[{\"DeviceName\":\"$root_device\",\"Ebs\":{\"VolumeSize\":$root_gb}}]")
  root_summary="${root_gb}GB (AMI default ${ami_root_gb}GB)"
fi

echo "==============================================================" >&2
printf '\033[35m   ABOUT TO LAUNCH %s x %s FROM %s IN %s\n   names: %s-1 .. %s-%s\n   subnet %s, sg %s, key %s\n   root volume: %s\033[0m\n' \
  "$count" "$type" "$ami" "$AWS_REGION" "$prefix" "$prefix" "$count" "$SUBNET_ID" "$SG_ID" "$KEY_NAME" "$root_summary" >&2
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
  "${block_device_args[@]+"${block_device_args[@]}"}" \
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
{
  echo "  # no team repo yet (T+0): ONE person builds it from ${prefix}-1"
  echo "  isukit go --new <team>/<repo> ubuntu@${first_ip} -i $KEY_FILE --invite <teammate>,<teammate>"
  echo "  # everyone else, once it exists:"
  echo "  isukit go <repo-url> ubuntu@${first_ip} -i $KEY_FILE"
  echo "  # every box starts as an identical copy; give each its roles (re-assign when you split):"
  echo "  isukit host role ubuntu@${first_ip} web,app,db  # ${prefix}-1"
} >&2
printf '%s\n' "$info" | awk -v n="${prefix}-1" '$1!=n' | while read -r name iid pub priv; do
  ip=$(pick_ip "$pub" "$priv")
  echo "  isukit host role ubuntu@${ip} app  # $name (private $priv)" >&2
done
echo "  isukit hosts" >&2
