#!/bin/bash
# isukit rules check (reboot survivability, R2) / isukit rules langs /
# IMPL_LANG drift — the on-host half of the regulation-compliance harness.
# shellcheck source=test/e2e/lib.sh
. /k/test/e2e/lib.sh
pkgs git
stubs; server

# a second reference-implementation unit left enabled alongside isu-go — R2's
# trap: both share one port, so the reboot test picks a winner at random
printf '[Service]\nExecStart=/home/isucon/webapp/ruby/isu\n' > /etc/systemd/system/isu-ruby.service

laptop_for /laptop

echo "rules check (two implementations enabled)"
"$I" rules check 2>&1 | plain > /tmp/check1; rc=${PIPESTATUS[0]}
sed 's/^/    | /' /tmp/check1
check "check fails while two impls are enabled"   [ "$rc" != 0 ]
check "reboot survivability section present"      grep -q '== reboot survivability' /tmp/check1
check "R2 two-enabled FIX reported"                grep -q '2 implementation units are enabled' /tmp/check1

echo "rules langs (still two enabled)"
"$I" rules langs 2>&1 | plain > /tmp/langs1
sed 's/^/    | /' /tmp/langs1
check "langs lists isu-go.service"                grep -q 'isu-go.service' /tmp/langs1
check "langs lists isu-ruby.service"               grep -q 'isu-ruby.service' /tmp/langs1
check "langs gives the switch command"             grep -q 'switch command: sudo systemctl disable --now' /tmp/langs1
check "langs quotes the parity guarantee"          grep -q 'その各々の性能が一致することは保証されない' /tmp/langs1
check "langs names this team's choice (go)"        grep -q "this team has already decided: Go" /tmp/langs1
check "langs refuses to rewrite with 2 enabled"    grep -q 'not rewriting IMPL_LANG' /tmp/langs1
check "IMPL_LANG not written with 2 enabled"       bash -c '! grep -q IMPL_LANG /laptop/isukit.conf 2>/dev/null'

echo "disable the extra implementation (fixing R2)"
systemctl disable --now isu-ruby.service
"$I" rules check 2>&1 | plain > /tmp/check2
sed 's/^/    | /' /tmp/check2
check "R2 FIX gone once only one impl is enabled"  bash -c '! grep -q "implementation units are enabled" /tmp/check2'

echo "rules langs (one enabled) writes IMPL_LANG"
"$I" rules langs 2>&1 | plain > /tmp/langs2
sed 's/^/    | /' /tmp/langs2
check "langs reports the auto-write"               grep -q "IMPL_LANG='go' written to isukit.conf" /tmp/langs2
check "isukit.conf now carries IMPL_LANG='go'"      grep -q "IMPL_LANG='go'" isukit.conf

echo "half-finished language switch: go disabled, ruby left enabled"
systemctl disable --now isu-go.service
sed -i '/^isu-ruby\.service$/d' /tmp/disabled-units
"$I" rules check 2>&1 | plain > /tmp/check3; rc=${PIPESTATUS[0]}
sed 's/^/    | /' /tmp/check3
check "check fails on IMPL_LANG drift"             [ "$rc" != 0 ]
check "drift message names go vs ruby"             grep -q "IMPL_LANG='go' but the enabled implementation is isu-ruby.service (ruby)" /tmp/check3

finish
