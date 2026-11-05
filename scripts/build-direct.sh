#!/bin/bash
# Builds Keymend.app with swiftc directly, without Xcode's build system.
# The normal way is `scripts/install.sh` (Xcode). This script is for environments where
# xcodebuild can't run, and it produces the same sandboxed, signed app.
#
# Usage: scripts/build-direct.sh [version]
# Env:   KEYMEND_BUILD_DIR (default ~/Library/Caches/Keymend-build)
#        SIGN_IDENTITY     (default "-" = ad hoc; e.g. "Developer ID Application")
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-1.1.0}"
B="${KEYMEND_BUILD_DIR:-$HOME/Library/Caches/Keymend-build}/direct-app"
IDENTITY="${SIGN_IDENTITY:--}"
APP="$B/Keymend.app"
SDK="$(xcrun --show-sdk-path --sdk macosx 2>/dev/null)"
mkdir -p "$B"

for ARCH in arm64 x86_64; do
  O="$B/$ARCH"; mkdir -p "$O"
  PLUGINS="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"
  # Load macro plugins in-process (-plugin-path) rather than through swift-plugin-server.
  COMMON=(-swift-version 6 -O -whole-module-optimization -sdk "$SDK" -target "$ARCH-apple-macos14.0" -module-cache-path "$B/modcache" -plugin-path "$PLUGINS")
  swiftc "${COMMON[@]}" -parse-as-library -emit-library -static -emit-module -module-name KeymendCore \
    -emit-module-path "$O/KeymendCore.swiftmodule" "$ROOT"/Packages/KeymendCore/Sources/KeymendCore/*.swift -o "$O/libKeymendCore.a"
  swiftc "${COMMON[@]}" -parse-as-library -I "$O" -L "$O" -lKeymendCore -module-name Keymend \
    "$ROOT"/App/Sources/*.swift -o "$O/Keymend"
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$B/arm64/Keymend" "$B/x86_64/Keymend" -output "$APP/Contents/MacOS/Keymend"
cp "$ROOT/App/Info.plist" "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "${BUILD_NUMBER:-4}" "$APP/Contents/Info.plist"
[ -f "$ROOT/App/Resources/AppIcon.icns" ] && cp "$ROOT/App/Resources/AppIcon.icns" "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

TS="--timestamp=none"; [ "$IDENTITY" != "-" ] && TS="--timestamp"
codesign --force --options runtime $TS --entitlements "$ROOT/App/Keymend.entitlements" --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "Built $APP"
