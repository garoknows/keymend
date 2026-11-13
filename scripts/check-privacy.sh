#!/bin/bash
# Checks Keymend's privacy rules in the source and, if given, in a built app.
#   scripts/check-privacy.sh                      # source checks
#   scripts/check-privacy.sh path/to/Keymend.app  # source + built app checks
# Exit code 0 means every rule held.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-}"
FAIL=0
pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=1; }
SRC=("$ROOT/App/Sources" "$ROOT/Packages/KeymendCore/Sources")

echo "Entitlements (App/Keymend.entitlements)"
ENT="$ROOT/App/Keymend.entitlements"
[ "$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.app-sandbox" "$ENT" 2>/dev/null)" = "true" ] && pass "App Sandbox is on" || bad "App Sandbox is not on"
KEYS=$(plutil -convert json -o - "$ENT" | tr ',' '\n' | grep -o '"com\.apple\.[^"]*"' | tr -d '"' | sort | tr '\n' ' ')
[ "$KEYS" = "com.apple.security.app-sandbox com.apple.security.files.user-selected.read-write " ] && pass "Only the sandbox and user-picked files (no network, other files, camera, contacts)" || bad "Unexpected entitlements: $KEYS"

echo "Source code"
if grep -rn -E 'URLSession|NSURLConnection|URLRequest|Network\b|import Network|CFSocket|NWConnection|NWPathMonitor|WebSocket|socket\(' "${SRC[@]}" >/dev/null; then
  bad "Network code found:"; grep -rn -E 'URLSession|NSURLConnection|URLRequest|import Network|CFSocket|NWConnection|WebSocket|socket\(' "${SRC[@]}"
else pass "No network code"; fi
# The one allowed exception: LearningVault.swift writes the encrypted store and encrypted exports.
WRITES='\.write\(to|FileManager\.default\.create|FileHandle|fopen|NSKeyedArchiver'
if grep -rn -E "$WRITES|os_log|Logger\(|NSLog|print\(" "${SRC[@]}" | grep -v -E 'KeymendCore/LearningVault\.swift:[0-9]+:.*\.write\(to' >/dev/null; then
  bad "File writes or logging found outside LearningVault.swift:"; grep -rn -E "$WRITES|os_log|Logger\(|NSLog|print\(" "${SRC[@]}" | grep -v -E 'KeymendCore/LearningVault\.swift:[0-9]+:.*\.write\(to'
else pass "No logs, and file writes only in LearningVault.swift (settings go to UserDefaults)"; fi
VAULT="$ROOT/Packages/KeymendCore/Sources/KeymendCore/LearningVault.swift"
if [ "$(grep -c -E '\.write\(to' "$VAULT")" = "2" ] && [ "$(grep -c -E 'combined\.write\(to|exportData\(.*\.write\(to' "$VAULT")" = "2" ]; then
  pass "LearningVault writes only sealed (encrypted) data"
else bad "LearningVault writes something other than sealed data"; fi
if grep -rn 'learnWord\|unlearnWord' "$ROOT/App/Sources/LearningModel.swift" "$ROOT/App/Sources/LearningView.swift" "$ROOT"/Packages/KeymendCore/Sources/KeymendCore/Learning*.swift >/dev/null; then
  bad "Learned words reach the Mac's shared Learn Spelling list"
else pass "Learned words stay out of the Mac's shared Learn Spelling list"; fi
if grep -n -E '\.package\(' "$ROOT/Packages/KeymendCore/Package.swift" >/dev/null || grep -n -E '^\s+url:' "$ROOT/project.yml" >/dev/null; then
  bad "Third-party package dependency found"
else pass "No third-party packages"; fi
if grep -rn -i -E 'analytics|telemetry|crashlytics|sentry|sparkle' "${SRC[@]}" >/dev/null; then
  bad "Analytics or updater code found"
else pass "No analytics, crash reporters or auto-updater"; fi
# No tap may stop or change keys: an active tap froze a Mac in beta.2 when Accessibility was
# switched off. The pick keys are hot keys. Every event tap must be listen-only.
if grep -rn -E '\.defaultTap|kCGEventTapOptionDefault' "${SRC[@]}" >/dev/null || \
   [ "$(grep -rn -E 'tapCreate' "${SRC[@]}" | wc -l | tr -d ' ')" != "$(grep -rn -E 'options: *\.listenOnly' "${SRC[@]}" | wc -l | tr -d ' ')" ]; then
  bad "An event tap that can stop or change keys exists:"; grep -rn -E '\.defaultTap|kCGEventTapOptionDefault|tapCreate' "${SRC[@]}"
else pass "Every event tap is listen-only: nothing can stop or change a key"; fi
if grep -rn -E 'AXUIElement|AXIsProcessTrusted|kAXBoundsForRange|kAXFocused' "${SRC[@]}" >/dev/null; then
  bad "Accessibility API that reads other apps found"
else pass "No Accessibility API that reads other apps"; fi
if grep -rn -E 'kCGWindowName|CGWindowListCreateImage|SCScreenshot|ScreenCaptureKit' "${SRC[@]}" >/dev/null; then
  bad "Code that reads window titles or screen contents found"
else pass "No code that reads window titles or screen contents"; fi
ALLOWED='Keys\.(enabled|skipList|carefulList|neverCorrect|taughtSpellings|fixCount|setupShown|paused|excluded|suggestionsEnabled|pickModifier)'
if grep -rn -E 'defaults\.set\(' "${SRC[@]}" | grep -v -E "$ALLOWED" >/dev/null; then
  bad "UserDefaults stores something other than settings:"; grep -rn -E 'defaults\.set\(' "${SRC[@]}" | grep -v -E "$ALLOWED"
else pass "UserDefaults holds only settings and the fix count"; fi

if [ -n "$APP" ]; then
  echo "Built app ($APP)"
  E=$(codesign -d --entitlements :- "$APP" 2>/dev/null)
  echo "$E" | grep -q "com.apple.security.app-sandbox" && pass "Signed with the sandbox entitlement" || bad "Sandbox entitlement missing from signature"
  echo "$E" | grep -q -E "network\.(client|server)" && bad "Network entitlement in signature" || pass "No network entitlement in signature"
  SIG=$(codesign -dv "$APP" 2>&1); echo "$SIG" | grep -q "flags=.*runtime" && pass "Hardened runtime on" || bad "Hardened runtime off"
  BIN="$APP/Contents/MacOS/Keymend"
  LIBS=$(otool -L "$BIN" 2>/dev/null | grep -v -E ':$' | awk '{print $1}' | grep -v -E '^/System/Library/|^/usr/lib/' || true)
  [ -z "$LIBS" ] && pass "Links only Apple system libraries" || bad "Non-system libraries: $LIBS"
  SYMS=$(nm -u "$BIN" 2>/dev/null); echo "$SYMS" | grep -q -E 'URLSession|NSURLConnection|_connect$|_socket$' && bad "Network symbols referenced" || pass "No network symbols referenced"
fi

[ $FAIL = 0 ] && echo "All privacy checks passed." || echo "Privacy checks FAILED."
exit $FAIL
