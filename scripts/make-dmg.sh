#!/bin/bash
# Packages Keymend.app into a .dmg with an Applications shortcut, using macOS's hdiutil.
# Usage: scripts/make-dmg.sh path/to/Keymend.app path/to/Keymend-0.1.0.dmg
set -euo pipefail
APP="$1"; OUT="$2"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/keymend-dmg.XXXXXX")"
ditto "$APP" "$STAGE/Keymend.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT"
hdiutil create -volname "Keymend" -srcfolder "$STAGE" -ov -format UDZO "$OUT"
rm -rf "$STAGE"
echo "Wrote $OUT"
