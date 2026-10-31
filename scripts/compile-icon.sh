#!/bin/bash
# Compiles the Icon Composer icon (App/Resources/AppIcon.icon) with Apple's actool into
# App/Resources/Generated: Assets.car (light, dark, tinted and clear variants for macOS 26+)
# and AppIcon.icns (Apple's flattened fallback for macOS 14 and 15).
# Needs Xcode 26 or later. Without it, the app keeps the hand-made App/Resources/AppIcon.icns.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/App/Resources/Generated"
rm -rf "$OUT"; mkdir -p "$OUT"
xcrun actool "$ROOT/App/Resources/AppIcon.icon" --compile "$OUT" \
  --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
  --include-all-app-icons --output-partial-info-plist "$OUT/partial-info.plist" \
  --output-format human-readable-text --notices --warnings --errors
[ -f "$OUT/Assets.car" ] || { echo "actool did not produce Assets.car"; exit 1; }
echo "== Generated files"; ls -la "$OUT"
echo "== Icon renditions in Assets.car (appearance, size)"
xcrun assetutil --info "$OUT/Assets.car" | grep -E '"(Appearance|Name|PixelWidth|RenditionName)"' | paste - - - - | sort -u | head -60 || true
echo "== Appearances present"
xcrun assetutil --info "$OUT/Assets.car" | grep '"Appearance"' | sort | uniq -c || true
