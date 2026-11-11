#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Always create a NEW network namespace before any network mutation.
# Requires Linux root (or equivalent capabilities), ip-full, util-linux unshare.
set -eu
unshare --net -- sh -eu <<'ISOLATED_NETWORK'
ip link set lo up
ip link add mobile_test type dummy
ip link add campus_test type dummy
ip link set mobile_test up
ip link set campus_test up
ip addr add 192.0.2.2/24 dev mobile_test
ip addr add 198.51.100.2/24 dev campus_test
ip route add default via 198.51.100.1 dev campus_test
ip route add table 100 192.0.2.0/24 dev mobile_test
ip route add table 100 unreachable default metric 32760
ip route add table 100 default via 192.0.2.1 dev mobile_test metric 10
ip rule add priority 11000 fwmark 6666 lookup 100
ip rule add priority 11003 to 203.0.113.20/32 lookup 100
ip route get 203.0.113.20 mark 6666 | grep -q 'dev mobile_test'
ip route get 203.0.113.30 | grep -q 'dev campus_test'
ip route del table 100 default via 192.0.2.1 dev mobile_test metric 10
if ip route get 203.0.113.20 mark 6666 >/dev/null 2>&1; then
    echo 'FAIL: marked node connection found a fallback route' >&2
    exit 1
fi
if ip route get 203.0.113.20 >/dev/null 2>&1; then
    echo 'FAIL: fixed node endpoint found a fallback route' >&2
    exit 1
fi
ip route get 203.0.113.30 | grep -q 'dev campus_test'
echo 'PASS: isolated kernel policy; mobile removal blocks node, direct campus route remains'
ISOLATED_NETWORK
