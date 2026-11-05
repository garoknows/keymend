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
| With Learning on: the last finished word | Memory only | About 5 seconds, or until you click, switch apps or pause |
| With Learning on: learned words (see below) | One encrypted file in its sandbox container | Until you delete them, or 90 days unseen if never made active |
| Your settings: on/off, skip list, never-correct words | The app's own settings file in its sandbox | Until you change them |
| Today's number of fixes | Same settings file | Resets every day |

That's all. There are no logs, no history, no analytics and no crash reports. With Learning off, which is the default, no typed text is ever written to a file.

## Learning, if you turn it on

**Stored for each item, and nothing else:** the kind (correction, undo or known word), the typed word, the correction, a count, the number of days it was seen, the last day it was seen (no time), and its status.

**Never stored:** sentences, neighbouring words, the app, window, document or website, the time of day, or anything from Secure Input, an excluded app or a Careful Mode app.

The file is encrypted with AES-256-GCM, and the key is in your login Keychain. Exports are encrypted separately with a passphrase you choose. Learned words stay out of the Mac's shared Learn Spelling list.

**Limits:**

- Encryption protects a copied file, a backup or a stolen disk. It doesn't protect against malware running as you while your Mac is unlocked.
- Keymend can't tell which website you're on, so a bank's website is protected only in its password fields.
- A letters-only password typed into an ordinary field without Secure Input could be recorded. It would be encrypted, and you could see and delete it in the review list.
- The default exclusion list has password managers only. Add your banking apps yourself.

Clear Everything in Settings → Learning deletes the words, the file and the key.

## What it can't do

- **Connect to the internet.** Keymend runs in Apple's App Sandbox without the network permission. macOS blocks every connection attempt, including from a bug.
- **See password fields.** When a password field is active, macOS turns on Secure Input and stops all apps like Keymend from receiving keys. Keymend also checks for Secure Input and does nothing while it's on. Password managers are on the default skip list as well.
- **Read your screen, files or contacts.** It doesn't have those permissions. The only files it can open besides its own are ones you pick in a save or open dialog, to export or import learned words.

## The exception: terminal password prompts

A password prompt in a terminal (`sudo`, `ssh`) uses Secure Input only if the terminal turns it on. If it doesn't, Keymend receives those keys like any others. It holds the current word in memory, writes nothing down, and forgets the word when it ends. Keymend turns off the line right after a command, which lowers the chance of changing a passphrase but doesn't stop it seeing the keys.

Careful Mode is on by default only in Ghostty, which turns on Secure Input when it detects a password prompt. That detection is a best guess and doesn't work over SSH, so over SSH the keys can reach Keymend's memory. Other terminals stay skipped unless you change that, and skipped apps give Keymend nothing to hold.

## How to check

- **Read the code.** It's small. The parts that touch keys are in `Packages/KeymendCore/Sources/KeymendCore/` (`KeyboardBridge.swift`, `WordEngine.swift`).
- **Run the privacy checks.** `scripts/check-privacy.sh path/to/Keymend.app` confirms the sandbox is on, there is no network entitlement or network code, no logging, file writes only in the encrypted store, and no third-party libraries. CI runs it on every change.
- **Check the signature yourself.**

  ```sh
  codesign -d --entitlements - /Applications/Keymend.app
  ```

  The only entitlements listed are `com.apple.security.app-sandbox` and `com.apple.security.files.user-selected.read-write` (files you pick yourself).
- **Watch the network.** Little Snitch, LuLu or `nettop -p Keymend` will show no connections.
- **Look in its container.** Everything Keymend stores is in `~/Library/Containers/io.github.garoknows.keymend/`. Search it for something you typed. With Learning off you won't find it, and with Learning on the only word file is encrypted. The words you add to the Dictionary tab are in the settings file, in plain form.

## Permissions it asks for

1. **Input Monitoring**, to see keys.
2. **Post keyboard events** (listed under Accessibility), to type the fix.

Both can be turned off at any time in System Settings → Privacy & Security. Keymend then simply stops working.
