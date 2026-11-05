#!/bin/bash
# Builds and runs the KeymendCore tests with swiftc directly (no SwiftPM or Xcode build system).
# Useful in restricted environments where those tools cannot write their temp files.
# Normal use: `swift test --package-path Packages/KeymendCore`.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
B="${KEYMEND_BUILD_DIR:-$HOME/Library/Caches/Keymend-build}/direct-tests"
mkdir -p "$B"
DEV="$(xcode-select -p)"
PLAT="$DEV/Platforms/MacOSX.platform/Developer"
TC="$DEV/Toolchains/XcodeDefault.xctoolchain"
COMMON=(-swift-version 6 -module-cache-path "$B/modcache" -target "$(uname -m)-apple-macos14.0" -F "$PLAT/Library/Frameworks" -I "$PLAT/usr/lib" -L "$PLAT/usr/lib" -plugin-path "$TC/usr/lib/swift/host/plugins/testing")
swiftc "${COMMON[@]}" -parse-as-library -enable-testing -emit-library -static -emit-module -module-name KeymendCore \
  -emit-module-path "$B/KeymendCore.swiftmodule" "$HERE"/Sources/KeymendCore/*.swift -o "$B/libKeymendCore.a"
cat > "$B/runner.swift" <<'SWIFT'
import Foundation
import Testing
@main struct Runner { static func main() async { exit(await Testing.__swiftPMEntryPoint()) } }
SWIFT
swiftc "${COMMON[@]}" -parse-as-library -I "$B" -L "$B" -lKeymendCore -module-name KeymendCoreTests \
  -Xlinker -rpath -Xlinker "$PLAT/Library/Frameworks" -Xlinker -rpath -Xlinker "$PLAT/usr/lib" \
  "$HERE"/Tests/KeymendCoreTests/*.swift "$B/runner.swift" -o "$B/keymend-core-tests"
KEYMEND_TEST_DIR="$B" "$B/keymend-core-tests" "$@"
