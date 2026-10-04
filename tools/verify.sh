#!/bin/bash
# Checks the app's assertions about each attached storage device against independent
# sources, and proves the byte counters are not double counted. See tools/verify/.
#
#   tools/verify.sh                 # build (universal) and run here
#   SKIP_BUILD=1 BIN=/tmp/verify tools/verify.sh   # run a copied binary elsewhere
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="${BIN:-build/verify}"
if [ "${SKIP_BUILD:-0}" != "1" ]; then
    SOURCES=$(ls Sources/*.swift | grep -v 'Sources/main.swift')
    mkdir -p build; SLICES=()
    for arch in x86_64 arm64; do
        swiftc -O -target "${arch}-apple-macosx10.14.4" \
            -framework Cocoa -framework IOKit -framework SystemConfiguration \
            $SOURCES tools/verify/main.swift -o "build/verify-$arch"
        SLICES+=("build/verify-$arch")
    done
    lipo -create -output "$BIN" "${SLICES[@]}"; rm -f "${SLICES[@]}"
    echo "==> Built $BIN"
fi
exec "$BIN"
