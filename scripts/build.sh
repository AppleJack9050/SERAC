#!/usr/bin/env bash
#
# Fetch upstream COLMAP at the pinned commit, apply the SERAC patches, build.
# Nothing in this repository contains COLMAP source; it is fetched here.
#
#   usage: scripts/build.sh [--baseline] [build-dir] [extra cmake flags...]
#
#     (default)     the measured SERAC build: upstream + 0000 + 0001..0004
#     --baseline    the paper's reference arm: upstream + 0000 only
#
# Patch 0000 (PatchMatch memory, Blackwell native SASS) is present in BOTH arms
# of the paper's A/B, so it is applied either way and cancels out of the
# comparison. Patches 0001..0004 are the SIFT matcher work the paper measures.
#
set -euo pipefail

COLMAP_REPO="${COLMAP_REPO:-https://github.com/colmap/colmap.git}"
COLMAP_COMMIT="${COLMAP_COMMIT:-e8c01c782571b1f08e4fd5b72ce13a2e01ae2aa5}"

BASELINE=0
if [ "${1:-}" = "--baseline" ]; then BASELINE=1; shift; fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${1:-$ROOT/build}"; [ $# -gt 0 ] && shift || true
SRC="$WORK/colmap"

mkdir -p "$WORK"

if [ ! -d "$SRC/.git" ]; then
    echo "==> cloning COLMAP into $SRC"
    git clone --filter=blob:none "$COLMAP_REPO" "$SRC"
fi

echo "==> checking out upstream baseline ${COLMAP_COMMIT:0:8}"
git -C "$SRC" fetch --all --tags --quiet
git -C "$SRC" checkout --force --quiet "$COLMAP_COMMIT"
git -C "$SRC" clean -fdq

if [ "$BASELINE" -eq 1 ]; then
    echo "==> applying baseline patch only (reference arm)"
    SERIES=("$ROOT"/patches/0000-*.patch)
else
    echo "==> applying full SERAC series"
    SERIES=("$ROOT"/patches/0*.patch)
fi

for p in "${SERIES[@]}"; do
    printf '    %s\n' "$(basename "$p")"
    git -C "$SRC" apply "$p"
done

echo "==> configuring"
cmake -S "$SRC" -B "$SRC/build" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCUDA_ENABLED=ON \
      -DCMAKE_CUDA_ARCHITECTURES=native \
      "$@"

echo "==> building"
cmake --build "$SRC/build" -j"$(nproc)"

echo
echo "build complete: $SRC/build"
[ "$BASELINE" -eq 1 ] && echo "(reference arm: SIFT matcher patches NOT applied)"
