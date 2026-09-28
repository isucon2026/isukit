#!/usr/bin/env bash
# isukit prestage — run this DAYS before the contest, not on contest day.
#
# Verifies (and creates only what the team owns) everything that CAN be nailed
# down before the organizers publish the AMI: account identity, key pair, VPC/
# subnet, and a security group scoped to the operator's own IP. Never launches
# an instance — instance count/type/AMI are read off the day-of manual by a
# human and passed to launch.sh, not guessed here.
#
# Idempotent: re-running finds what already exists and leaves it alone.

set -euo pipefail

die()  { printf '\033[31m!! %s\033[0m\n' "$*" >&2; exit 1; }
say()  { printf '\033[36m:: %s\033[0m\n' "$*" >&2; }
warn() { printf '\033[33m~~ %s\033[0m\n' "$*" >&2; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
envfile="$here/prestage.env"

key_name="" key_file="" region="" vpc_id="" subnet_id="" sg_name="isukit-ssh"

while [ $# -gt 0 ]; do
  case "$1" in
    --key-name)  key_name="$2"; shift 2 ;;
    --key-file)  key_file="$2"; shift 2 ;;
    --region)    region="$2"; shift 2 ;;
    --vpc-id)    vpc_id="$2"; shift 2 ;;
    --subnet-id) subnet_id="$2"; shift 2 ;;
    --sg-name)   sg_name="$2"; shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done

[ -n "$key_name" ] || die "usage: prestage.sh --key-name <name> --key-file <path/to/save.pem> [--region r] [--vpc-id id] [--subnet-id id] [--sg-name name]"
[ -n "$key_file" ] || die "usage: prestage.sh --key-name <name> --key-file <path/to/save.pem> [--region r] [--vpc-id id] [--subnet-id id] [--sg-name name]"

command -v aws >/dev/null 2>&1 || die "aws CLI not found — install it before contest day"

# ---------------------------------------------------------------- identity
say "checking AWS identity..."
ident=$(aws sts get-caller-identity --output json) || die "aws sts get-caller-identity failed — check credentials"
account=$(printf '%s' "$ident" | grep -o '"Account": *"[0-9]*"' | grep -o '[0-9]*')
arn=$(printf '%s' "$ident" | grep -o '"Arn": *"[^"]*"' | cut -d'"' -f4)
[ -n "$region" ] || region=$(aws configure get region 2>/dev/null || true)
[ -n "$region" ] || die "no region set — pass --region or run 'aws configure set region <region>'"

echo "==============================================================" >&2
printf '\033[35m   AWS ACCOUNT: %s\n   IDENTITY:    %s\n   REGION:      %s\033[0m\n' "$account" "$arn" "$region" >&2
echo "   double check this is the CONTEST team account, not a personal one." >&2
echo "==============================================================" >&2

# ---------------------------------------------------------------- key pair
# AWS only returns private key material at creation time, so "verify" for an
# already-created pair just means the local .pem is present; if AWS has the
# key but the local file is gone, the key material is unrecoverable.
say "checking key pair '$key_name'..."
aws_has_key=0
aws ec2 describe-key-pairs --region "$region" --key-names "$key_name" >/dev/null 2>&1 && aws_has_key=1

if [ -f "$key_file" ]; then
  chmod 600 "$key_file"
  [ "$aws_has_key" -eq 1 ] || warn "local $key_file exists but AWS has no key pair named '$key_name' in $region — mismatch, verify by hand"
  say "key file present: $key_file (chmod 600)"
elif [ "$aws_has_key" -eq 1 ]; then
  die "AWS already has key pair '$key_name' but $key_file is missing locally — private key material can't be re-downloaded; use a different --key-name or restore the .pem from wherever it was saved"
else
  say "creating key pair '$key_name'..."
  mkdir -p "$(dirname "$key_file")"
  aws ec2 create-key-pair --region "$region" --key-name "$key_name" \
    --query 'KeyMaterial' --output text > "$key_file" || die "create-key-pair failed"
  chmod 600 "$key_file"
  say "saved $key_file (chmod 600)"
fi

# ---------------------------------------------------------------- vpc / subnet
if [ -z "$vpc_id" ]; then
  say "no --vpc-id given, looking for the default VPC..."
  vpc_id=$(aws ec2 describe-vpcs --region "$region" --filters Name=isDefault,Values=true \
    --query 'Vpcs[0].VpcId' --output text)
  [ -n "$vpc_id" ] && [ "$vpc_id" != "None" ] || die "no default VPC found and no --vpc-id given — pass one explicitly"
fi
aws ec2 describe-vpcs --region "$region" --vpc-ids "$vpc_id" >/dev/null 2>&1 || die "VPC $vpc_id not found in $region"
say "VPC: $vpc_id"

if [ -z "$subnet_id" ]; then
  say "no --subnet-id given, picking the first subnet in $vpc_id..."
  subnet_id=$(aws ec2 describe-subnets --region "$region" --filters "Name=vpc-id,Values=$vpc_id" \
    --query 'Subnets[0].SubnetId' --output text)
  [ -n "$subnet_id" ] && [ "$subnet_id" != "None" ] || die "no subnet found in $vpc_id and no --subnet-id given — pass one explicitly"
fi
aws ec2 describe-subnets --region "$region" --subnet-ids "$subnet_id" >/dev/null 2>&1 || die "subnet $subnet_id not found in $region"
say "subnet: $subnet_id"

# an instance launched into a subnet without this WILL have no public IP, and
# security groups (hence ssh access) can't be changed after launch — so this
# has to be caught now, not discovered at T+0.
pub_ip_on_launch=$(aws ec2 describe-subnets --region "$region" --subnet-ids "$subnet_id" \
  --query 'Subnets[0].MapPublicIpOnLaunch' --output text)
[ "$pub_ip_on_launch" = "True" ] || die "subnet $subnet_id has MapPublicIpOnLaunch=false — instances launched here get NO public IP and ssh will be impossible. fix with: aws ec2 modify-subnet-attribute --region $region --subnet-id $subnet_id --map-public-ip-on-launch (then re-run prestage.sh)"
say "subnet auto-assigns public IPs: yes"

# ---------------------------------------------------------------- security group
say "checking security group '$sg_name'..."
my_ip=$(curl -fsS --max-time 5 https://checkip.amazonaws.com | tr -d '[:space:]') \
  || die "couldn't determine this machine's public IP (checkip.amazonaws.com unreachable) — pass it in by hand if this keeps failing"
my_cidr="${my_ip}/32"

sg_id=$(aws ec2 describe-security-groups --region "$region" \
  --filters "Name=vpc-id,Values=$vpc_id" "Name=group-name,Values=$sg_name" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)

if [ -z "$sg_id" ] || [ "$sg_id" = "None" ]; then
  say "creating security group '$sg_name' in $vpc_id..."
  sg_id=$(aws ec2 create-security-group --region "$region" --vpc-id "$vpc_id" \
    --group-name "$sg_name" --description "isukit: ssh from operator IP only" \
    --query 'GroupId' --output text) || die "create-security-group failed"
fi
say "security group: $sg_id"

has_rule=$(aws ec2 describe-security-groups --region "$region" --group-ids "$sg_id" \
  --query "SecurityGroups[0].IpPermissions[?ToPort==\`22\`].IpRanges[?CidrIp=='${my_cidr}'].CidrIp" \
  --output text 2>/dev/null || true)

if [ -z "$has_rule" ]; then
  say "authorizing SSH (22) from $my_cidr..."
  aws ec2 authorize-security-group-ingress --region "$region" --group-id "$sg_id" \
    --protocol tcp --port 22 --cidr "$my_cidr" >/dev/null \
    || die "authorize-security-group-ingress failed"
else
  say "SSH from $my_cidr already authorized"
fi

warn "SG allows SSH only from $my_cidr, captured NOW. If your IP changes before contest day, re-run this script."
warn "the day-of manual may require opening OTHER ports (e.g. the app port, envcheck) — add those rules HERE, before launch."
warn "changing a security group AFTER instances are launched is prohibited by the rules — get every port right in this pass."

# ---------------------------------------------------------------- write env
cat > "$envfile" <<EOF
# generated by prestage.sh — sourced by launch.sh, do not hand-edit lightly
AWS_REGION=$region
KEY_NAME=$key_name
KEY_FILE=$key_file
VPC_ID=$vpc_id
SUBNET_ID=$subnet_id
SUBNET_PUBLIC_IP=true
SG_ID=$sg_id
EOF

say "wrote $envfile"
say "prestage complete. re-run any time before contest day to re-verify."
