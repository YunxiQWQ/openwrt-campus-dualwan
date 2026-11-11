#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Always isolate curl's bound loopback interface, including on mirrored WSL.
set -eu
test_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
CDW_TEST_ROOT="$test_root" unshare --net -- sh -eu <<'ISOLATED_HTTP'
ip link set lo up
exec python3 "$CDW_TEST_ROOT/tests/http_integration.py"
ISOLATED_HTTP
