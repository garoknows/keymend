# Keymend and your privacy

Keymend sees every key you type. That is what lets it fix typos, and it is also exactly what a keylogger does. This page explains what Keymend sees, what it does with it, and how you can check.

## What Keymend sees

- The keys you press while a normal text field is active, one at a time.
- Mouse clicks (only that a click happened, not where), so it can forget the current word.
- Which app is in front, so it can stay off in apps on your skip list.

## What it keeps

| Kept | Where | For how long |
| --- | --- | --- |
| The word you are typing right now (at most about 40 characters) | Memory only | Until the word ends, you click, switch apps, or pause |
| Words you undid this session | Memory only | Until you quit Keymend |
| Your settings: on/off, skip list, never-correct words | The app's own settings file in its sandbox | Until you change them |
| Today's number of fixes | Same settings file | Resets every day |

That's all. There are no logs, no history, no files with typed text, no analytics and no crash reports.

## What it can't do

- **Connect to the internet.** Keymend runs in Apple's App Sandbox without the network permission. macOS blocks every connection attempt, including from a bug.
- **See passwords.** When a password field is active, macOS turns on Secure Input and stops all apps like Keymend from receiving keys. Keymend also checks for Secure Input and does nothing while it's on. Password managers are on the default skip list as well.
- **Read your screen, files or contacts.** It doesn't have those permissions and never asks for them.

## How to check

- **Read the code.** It's small. The parts that touch keys are in `Packages/KeymendCore/Sources/KeymendCore/` (`KeyboardBridge.swift`, `WordEngine.swift`).
- **Run the privacy checks.** `scripts/check-privacy.sh path/to/Keymend.app` confirms the sandbox is on, there is no network entitlement, no network or file-writing code, no logging, and no third-party libraries. CI runs it on every change.
- **Check the signature yourself.**

  ```sh
  codesign -d --entitlements - /Applications/Keymend.app
  ```

  The only entitlement listed is `com.apple.security.app-sandbox`.
- **Watch the network.** Little Snitch, LuLu or `nettop -p Keymend` will show no connections.
- **Look in its container.** Everything Keymend stores is in `~/Library/Containers/io.github.garoknows.keymend/`. Search it for something you typed; you won't find it.

## Permissions it asks for

1. **Input Monitoring**, to see keys.
2. **Post keyboard events** (listed under Accessibility), to type the fix.

Both can be turned off at any time in System Settings → Privacy & Security. Keymend then simply stops working.
