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
KEYS=$(plutil -convert json -o - "$ENT" | tr ',' '\n' | grep -o '"com\.apple\.[^"]*"' | tr -d '"')
[ "$KEYS" = "com.apple.security.app-sandbox" ] && pass "No other entitlements (no network, files, camera, contacts)" || bad "Extra entitlements: $KEYS"

echo "Source code"
if grep -rn -E 'URLSession|NSURLConnection|URLRequest|Network\b|import Network|CFSocket|NWConnection|NWPathMonitor|WebSocket|socket\(' "${SRC[@]}" >/dev/null; then
  bad "Network code found:"; grep -rn -E 'URLSession|NSURLConnection|URLRequest|import Network|CFSocket|NWConnection|WebSocket|socket\(' "${SRC[@]}"
else pass "No network code"; fi
if grep -rn -E '\.write\(to|FileManager\.default\.create|FileHandle|fopen|NSKeyedArchiver|os_log|Logger\(|NSLog|print\(' "${SRC[@]}" >/dev/null; then
  bad "File writes or logging found:"; grep -rn -E '\.write\(to|FileManager\.default\.create|FileHandle|fopen|NSKeyedArchiver|os_log|Logger\(|NSLog|print\(' "${SRC[@]}"
else pass "No file writes or logs (settings go to UserDefaults only)"; fi
if grep -n -E '\.package\(' "$ROOT/Packages/KeymendCore/Package.swift" >/dev/null || grep -n -E '^\s+url:' "$ROOT/project.yml" >/dev/null; then
  bad "Third-party package dependency found"
else pass "No third-party packages"; fi
if grep -rn -i -E 'analytics|telemetry|crashlytics|sentry|sparkle' "${SRC[@]}" >/dev/null; then
  bad "Analytics or updater code found"
else pass "No analytics, crash reporters or auto-updater"; fi
if grep -rn -E 'UserDefaults.*set\(' "${SRC[@]}" | grep -v -E 'Keys\.(enabled|skipList|neverCorrect|fixCount|setupShown)' >/dev/null; then
  bad "UserDefaults stores something other than settings:"; grep -rn -E 'UserDefaults.*set\(' "${SRC[@]}" | grep -v -E 'Keys\.'
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
