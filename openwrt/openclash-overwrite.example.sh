#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Optional manual addition to OpenClash's custom overwrite hook. Not auto-installed.
set -eu
config=${1:?OpenClash must supply its generated configuration path}
case "$config" in /etc/openclash/config/*) ;; *) exit 1;; esac
ruby /usr/libexec/campus-dualwan/bin/render-mihomo.rb \
    "$config" /etc/campus-dualwan/private/render.json "$config.candidate"
# --check/--run are deliberately not implemented here. Validate the whole candidate
# using your installed core's -t and SAFE_PATHS environment BEFORE replacing files.
# The hook only creates a candidate; see docs/INSTALL.md for the review procedure.
