#!/usr/bin/env bash
#
# Confirm the DP4A path is live in the shipped binary rather than merely
# present in source. The paper reports 1024 DP4A instructions, 512 in each of
# the two matcher kernels.
#
set -euo pipefail
BIN="${1:?usage: verify-dp4a.sh <path-to-colmap-binary-or-lib>}"
n=$(cuobjdump -sass "$BIN" | grep -c 'IDP4A\|DP4A' || true)
echo "DP4A instructions in $BIN: $n"
[ "$n" -gt 0 ] || { echo "FAIL: no DP4A found; the scalar fallback is compiled in"; exit 1; }
