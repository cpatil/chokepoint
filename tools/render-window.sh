#!/bin/bash
# Draws the main window offscreen, optionally with real read traffic on the cards.
#
#   tools/render-window.sh [OUT_DIR] [VOLUME ...]
#   SAMPLE=12 tools/render-window.sh build/window /Volumes/sd-17 /Volumes/sd-8
#
# Built universal, so the binary can be copied to an Intel Mac and run over ssh -
# which is the point: a screenshot needs the window on the visible Space and the
# machine free for a moment, and this needs neither.
#
# TRAFFIC IS READ-ONLY. Each named volume gets a loop reading one file it already
# holds into /dev/null. Nothing is written to the media, and nothing on it changes.
# It does, however, move real bytes, so the monitor logs real sessions - the render
# leaves entries in the session log exactly as using the app would.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-build/window}"
shift || true
BIN="${BIN:-build/render-window}"
SAMPLE="${SAMPLE:-10}"
MIN_MACOS="10.14.4"

if [ "${SKIP_BUILD:-0}" != "1" ]; then
    SOURCES=$(ls Sources/*.swift | grep -v 'Sources/main.swift')
    mkdir -p build
    SLICES=()
    for arch in x86_64 arm64; do
        echo "==> Compiling $arch (min macOS $MIN_MACOS)"
        swiftc -O -target "${arch}-apple-macosx${MIN_MACOS}" \
            -framework Cocoa -framework IOKit -framework SystemConfiguration \
            $SOURCES tools/render-window/main.swift -o "build/render-window-$arch"
        SLICES+=("build/render-window-$arch")
    done
    lipo -create -output "$BIN" "${SLICES[@]}"
    rm -f "${SLICES[@]}"
    echo "==> Built $BIN"
fi

PIDS=()
cleanup() {
    for pid in ${PIDS+"${PIDS[@]}"}; do kill "$pid" 2>/dev/null || true; done
}
trap cleanup EXIT

for volume in "$@"; do
    # Many files, not one. Reading a single file in a loop touches the medium once
    # and is then served from the unified buffer cache forever after, so the device
    # counters sit at zero and the charts stay flat. Walking the whole volume puts
    # the working set past what the cache will hold and every pass goes back to the
    # card - which is the thing being shown.
    count=$(find "$volume" -type f -size +1M 2>/dev/null | head -40 | wc -l | tr -d ' ')
    if [ "$count" = "0" ]; then
        echo "==> $volume: nothing substantial to read, skipping"
        continue
    fi
    echo "==> Reading $volume ($count files)"
    ( while :; do
        find "$volume" -type f -size +1M -print0 2>/dev/null \
            | xargs -0 -n 4 cat 2>/dev/null > /dev/null || true
        sleep 0.2
      done ) &
    PIDS+=($!)
done

[ ${#PIDS[@]} -gt 0 ] && sleep 2 || true

echo "==> Rendering into $OUT (sampling ${SAMPLE}s per appearance)"
SAMPLE="$SAMPLE" WIDTH="${WIDTH:-1100}" HEIGHT="${HEIGHT:-820}" "$BIN" "$OUT"
