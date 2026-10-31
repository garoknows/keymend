#!/bin/bash
# Renders App/Resources/AppIcon.icns and the pictures in docs/images from the app's SwiftUI views.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
B="${KEYMEND_BUILD_DIR:-$HOME/Library/Caches/Keymend-build}/render"
mkdir -p "$B"
PLUGINS="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"
COMMON=(-swift-version 6 -module-cache-path "$B/modcache" -plugin-path "$PLUGINS" -target "$(uname -m)-apple-macos14.0")
swiftc "${COMMON[@]}" -parse-as-library -emit-library -static -emit-module -module-name KeymendCore \
  -emit-module-path "$B/KeymendCore.swiftmodule" "$ROOT"/Packages/KeymendCore/Sources/KeymendCore/*.swift -o "$B/libKeymendCore.a"
SOURCES=$(ls "$ROOT"/App/Sources/*.swift | grep -v KeymendApp.swift)
# shellcheck disable=SC2086
swiftc "${COMMON[@]}" -parse-as-library -I "$B" -L "$B" -lKeymendCore -module-name DocRenderer \
  $SOURCES "$ROOT/tools/DocRenderer/main.swift" -o "$B/DocRenderer"
rm -rf "$B/AppIcon.iconset"
"$B/DocRenderer" "$B/AppIcon.iconset" "$ROOT/docs/images" "$ROOT/site/icon.svg"
iconutil -c icns "$B/AppIcon.iconset" -o "$ROOT/App/Resources/AppIcon.icns" 2>/dev/null \
  || python3 "$ROOT/tools/make-icns.py" "$B/AppIcon.iconset" "$ROOT/App/Resources/AppIcon.icns"
echo "Wrote App/Resources/AppIcon.icns"
