#!/bin/bash
# launch/prestage.sh against a fake `aws` that keeps the security group's rules
# in files: which ingress rules a fresh run adds (22 and 443 from the operator
# and --allow-ip, all traffic from the group itself), that a re-run adds none,
# and that AWS's "already exists" answer is not a failure. prestage writes
# prestage.env next to itself, so each case runs a copy in a scratch dir.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERBOSE=0
for a in "$@"; do [ "$a" = "-v" ] && VERBOSE=1; done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/isukit-prestage.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
# the fake: sg rules live in $STATE/sg-<port> (CIDRs) and $STATE/sg-self;
# every authorize call is appended to $STATE/calls.
cat > "$WORK/bin/aws" <<'FAKE'
#!/bin/bash
S="$STATE"
args="$*"
case "$1 $2" in
  "sts get-caller-identity") printf '{"Account": "123456789012", "Arn": "arn:aws:iam::123456789012:user/t"}\n'; exit 0 ;;
  "configure get") echo ap-northeast-1; exit 0 ;;
esac
case "$2" in
  describe-key-pairs|describe-vpcs) exit 0 ;;
  describe-subnets)
    case "$args" in *MapPublicIpOnLaunch*) echo True ;; esac; exit 0 ;;
  create-security-group) : > "$S/sg-created"; echo sg-0abc; exit 0 ;;
  describe-security-groups)
    case "$args" in
      *group-name*) [ -f "$S/sg-created" ] && echo sg-0abc || echo None ;;
      *"IpProtocol=='-1'"*) [ -n "${HIDE_RULES:-}" ] || cat "$S/sg-self" 2>/dev/null ;;
      *'ToPort==`22`'*) [ -n "${HIDE_RULES:-}" ] || paste -sd '\t' "$S/sg-22" 2>/dev/null ;;
      *'ToPort==`443`'*) [ -n "${HIDE_RULES:-}" ] || paste -sd '\t' "$S/sg-443" 2>/dev/null ;;
    esac
    exit 0 ;;
  authorize-security-group-ingress)
    echo "$args" >> "$S/calls"
    if [[ "$args" == *--ip-permissions* ]]; then
      f="$S/sg-self"; v=sg-0abc
    else
      port=$(sed -E 's/.*--port ([0-9]+).*/\1/' <<< "$args"); f="$S/sg-$port"
      v=$(sed -E 's/.*--cidr ([^ ]+).*/\1/' <<< "$args")
    fi
    if grep -qx "$v" "$f" 2>/dev/null; then
      echo "An error occurred (InvalidPermission.Duplicate) when calling the AuthorizeSecurityGroupIngress operation: the specified rule already exists" >&2
      exit 254
    fi
    echo "$v" >> "$f"; exit 0 ;;
esac
echo "fake aws: unhandled: $args" >&2; exit 1
FAKE
printf '#!/bin/sh\necho 198.51.100.9\n' > "$WORK/bin/curl"
chmod +x "$WORK/bin/aws" "$WORK/bin/curl"

TOTAL=0; PASSED=0; FAILED=""; ERR=""; OUT=""
check() { [ "$@" ] || ERR="$ERR
    failed: [ $* ]"; }
case_() {
  TOTAL=$((TOTAL+1)); ERR=""
  ( "$2" ; printf '%s' "$ERR" > "$WORK/err" )
  ERR="$(cat "$WORK/err" 2>/dev/null)"
  if [ -z "$ERR" ]; then PASSED=$((PASSED+1)); echo "PASS  $1"
  else FAILED="$FAILED $1"; echo "FAIL  $1$ERR"; fi
  [ "$VERBOSE" = 1 ] && sed 's/^/      | /' "$WORK/out" 2>/dev/null
  return 0
}

fresh() { # new scratch launch/ dir + empty fake AWS
  D="$(mktemp -d "$WORK/case.XXXXXX")"
  mkdir -p "$D/launch" "$D/state"
  cp "$HERE/../launch/prestage.sh" "$D/launch/"
  : > "$D/key.pem"
  export STATE="$D/state"
}
prestage() {
  PATH="$WORK/bin:$PATH" bash "$D/launch/prestage.sh" --key-name k --key-file "$D/key.pem" \
    --region ap-northeast-1 --vpc-id vpc-1 --subnet-id subnet-1 "$@" > "$WORK/out" 2>&1
}

t_fresh_opens_22_443_and_the_group() {
  fresh
  prestage --allow-ip 203.0.113.7; check $? = 0
  check "$(sort "$STATE/sg-22" | tr '\n' ' ')" = "198.51.100.9/32 203.0.113.7/32 "
  check "$(sort "$STATE/sg-443" | tr '\n' ' ')" = "198.51.100.9/32 203.0.113.7/32 "
  check "$(cat "$STATE/sg-self")" = sg-0abc
  check -n "$(grep -F 'IpProtocol=-1,UserIdGroupPairs=[{GroupId=sg-0abc}]' "$STATE/calls")"
  check -n "$(grep -F 'SG_HTTPS_CIDRS="198.51.100.9/32 203.0.113.7/32"' "$D/launch/prestage.env")"
  check -n "$(grep -F 'all traffic between instances in sg-0abc: allowed' "$WORK/out")"
}

t_rerun_adds_nothing() {
  fresh
  prestage --allow-ip 203.0.113.7; check $? = 0
  : > "$STATE/calls"
  prestage --allow-ip 203.0.113.7; check $? = 0
  check ! -s "$STATE/calls"
}

# describe misses the rules (or they were added by hand in another shape) and
# AWS answers InvalidPermission.Duplicate: that is "already there", not a failure.
t_duplicate_is_not_a_failure() {
  fresh
  prestage; check $? = 0
  HIDE_RULES=1 prestage; check $? = 0
  check -n "$(grep -F 'all traffic within sg-0abc already authorized' "$WORK/out")"
  check -n "$(grep -F '443 from 198.51.100.9/32 already authorized' "$WORK/out")"
}

case_ fresh-opens-22-443-and-group  t_fresh_opens_22_443_and_the_group
case_ rerun-adds-nothing            t_rerun_adds_nothing
case_ duplicate-is-not-a-failure    t_duplicate_is_not_a_failure

echo "$TOTAL fixtures, $PASSED passed, $((TOTAL-PASSED)) failed"
[ -z "$FAILED" ]
