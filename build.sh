#!/bin/bash
# Builds Chokepoint.app as a universal (x86_64 + arm64) bundle with no Xcode required.
# Deployment target is macOS 10.14.4 - the release where Swift's ABI-stable runtime
# arrived in the OS. The app links @rpath/libswiftCore.dylib and embeds no Swift
# libraries, so 10.14.0-10.14.3 would fail at dynamic loading.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Chokepoint"
BUNDLE_ID="local.chokepoint"
MIN_MACOS="10.14.4"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"

# The version is read off git rather than typed in, so a build and the commit it
# came from can never disagree. "v1.0" plus 59 commits becomes 1.0.59; the bundle
# version is the total commit count, which only ever rises; the commit and its date
# are kept under keys of our own so About can show where a build really came from.
# A tarball with no .git, or a checkout too shallow to see the tag, gets a fallback.
VERSION_SHORT="${CHOKEPOINT_VERSION:-}"
if [ -z "$VERSION_SHORT" ]; then
    if described=$(git describe --tags --long --match 'v[0-9]*' 2>/dev/null); then
        # v1.0-59-g3a4da7a -> 1.0.59
        VERSION_SHORT=$(echo "$described" | sed -E 's/^v([0-9][0-9.]*)-([0-9]+)-g[0-9a-f]+$/\1.\2/')
    else
        VERSION_SHORT="1.0"
    fi
fi
VERSION_BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 0)
VERSION_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then VERSION_COMMIT="$VERSION_COMMIT-dirty"; fi
VERSION_DATE=$(git log -1 --format=%cs 2>/dev/null || date +%F)
echo "==> Version $VERSION_SHORT ($VERSION_BUILD) from $VERSION_COMMIT, $VERSION_DATE"

rm -rf "$BUILD_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

SOURCES=(Sources/*.swift)
ARCHS=(x86_64 arm64)
SLICES=()

for arch in "${ARCHS[@]}"; do
    echo "==> Compiling $arch (min macOS $MIN_MACOS)"
    swiftc -O \
        -target "${arch}-apple-macosx${MIN_MACOS}" \
        -framework Cocoa -framework IOKit -framework SystemConfiguration \
        "${SOURCES[@]}" \
        -o "$BUILD_DIR/$APP_NAME-$arch"
    SLICES+=("$BUILD_DIR/$APP_NAME-$arch")
done

echo "==> Creating universal binary"
lipo -create -output "$APP_DIR/Contents/MacOS/$APP_NAME" "${SLICES[@]}"
rm -f "${SLICES[@]}"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>Chokepoint</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>$VERSION_BUILD</string>
    <key>CFBundleShortVersionString</key><string>$VERSION_SHORT</string>
    <key>ChokepointCommit</key><string>$VERSION_COMMIT</string>
    <key>ChokepointBuilt</key><string>$VERSION_DATE</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>Chokepoint</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>Chokepoint reads throughput counters for connected volumes, and can write a .metadata_never_index marker to a card when you ask it to stop Spotlight indexing that card.</string>
</dict>
</plist>
PLIST

# The icon is drawn from tools/make-icon.swift rather than checked in as pixels, so
# the repository holds no binaries and the artwork stays editable.
if [ ! -f "$BUILD_DIR/Chokepoint.icns" ]; then
    echo "==> Drawing icon"
    swift tools/make-icon.swift >/dev/null
    iconutil -c icns "$BUILD_DIR/Chokepoint.iconset" -o "$BUILD_DIR/Chokepoint.icns"
fi
cp "$BUILD_DIR/Chokepoint.icns" "$APP_DIR/Contents/Resources/Chokepoint.icns"

# The card watcher's script travels inside the app, so the copy the user installs is
# always the one that shipped with that build.
cp tools/card-watch.sh "$APP_DIR/Contents/Resources/card-watch.sh"

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || echo "    (ad-hoc signing skipped)"

echo "==> Built $APP_DIR"
lipo -info "$APP_DIR/Contents/MacOS/$APP_NAME"
