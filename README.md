<p align="center"><img src="docs/images/icon.png" width="112" alt=""></p>

<h1 align="center">keymend</h1>

<p align="center">Spelling fixes as you type, in every Mac app.<br>
<a href="https://garoknows.github.io/keymend/">Website</a> · <a href="https://github.com/garoknows/keymend/releases/tag/v1.1.1">Download</a> · <a href="docs/PRIVACY.md">Privacy</a> · <a href="docs/INSTALL.md">Install guide</a></p>

Mac autocorrect only works in apps built with Apple's own text tools, like Notes, Mail and Messages. In Chrome, Arc, Dia, Slack, Obsidian, the Claude and ChatGPT desktop apps and other apps built on web technology, typos just get a red underline. No Mac setting changes that.

Keymend is a small menu bar app that fixes them as you type, in every app. It uses only Apple's built-in spell checker and never connects to the internet.

<p align="center"><img src="docs/images/menu.png" width="420" alt="The Keymend menu: Keymend is On, Fixed 42 typos today, Skip in Slack, Settings, Quit"></p>

## What it does

- **Fixes a word when it ends.** After you type a space or `, ; ! ?`, the finished word is checked. If Apple's spell checker has a confident correction, Keymend swaps it in. `teh ` becomes `the `.
- **Instant undo.** Press Delete right after a fix to get your word back. Keymend then leaves that word alone until you quit it.
- **Pause anytime.** The switch in the menu, or Control-Option-K from anywhere.
- **Skips apps.** Off by default in most terminals, code editors, password managers and apps that already autocorrect (Terminal, iTerm, VS Code, Xcode, Cursor, Word, Notes, Mail, Pages, Messages, Safari and more). Add or remove apps in Settings, or with "Skip in [app]" in the menu.
- **Careful Mode for terminals.** On by default in Ghostty only. It fixes lines that look like plain language and leaves anything that looks like a command or code alone. It can't be perfect: read [Terminals and Careful Mode](#terminals-and-careful-mode).
- **Smart skips.** Never touches ALL CAPS, words with numbers, links, email addresses, file paths, @mentions, #tags, or anything inside `backticks`.
- **Your words.** A personal dictionary of words to never change. It starts empty and is shared with the Mac's own "Learn Spelling" list. Removing a word takes it off the Mac's list only if Keymend put it there.
- **Today's count.** The menu shows how many typos it fixed today. It only counts; the count doesn't keep the words.
- **Learning Dictionary (optional, off until you turn it on).** Learns single words you often fix or undo. You review everything in Settings → Learning. [What it stores](#learning-dictionary).

Return and Tab end a word without fixing it, on purpose: in chat apps Return sends the message immediately, and a fix typed after that would land in the empty box.

## Install

1. Download [`Keymend-1.1.1.dmg`](https://github.com/garoknows/keymend/releases/download/v1.1.1/Keymend-1.1.1.dmg) ([release page](https://github.com/garoknows/keymend/releases/tag/v1.1.1)), open it and drag **Keymend** into Applications.
2. Open Keymend. It's signed with a Developer ID and notarized by Apple, so it opens normally. ([Step-by-step guide](docs/INSTALL.md))
3. Keymend opens a setup window that shows exactly where to click for its two permissions.

<p align="center"><img src="docs/images/setup-window.png" width="560" alt="Keymend's setup window: step 1 Allow Input Monitoring, step 2 Allow Keymend to type fixes, each with a picture of System Settings marked with red boxes and numbers"></p>

Or build it yourself (needs Xcode):

```sh
git clone https://github.com/garoknows/keymend.git
cd keymend
scripts/install.sh
```

Apps you build yourself are signed ad hoc for your Mac only.

## Permissions

Keymend asks for exactly two, and nothing else:

| Permission | Where macOS lists it | Why |
| --- | --- | --- |
| Input Monitoring | Privacy & Security → Input Monitoring | To see the word you're typing |
| Post keyboard events | Privacy & Security → Accessibility | To type the corrected word |

No screen recording, contacts, location or network. Files are limited to what you pick yourself in a save or open dialog, to export or import learned words.

## Privacy, in plain English

To fix typing, an app has to see your keys. That makes Keymend technically a keylogger, so these rules matter. Each one is enforced by macOS or checked automatically on every change ([details](docs/PRIVACY.md)):

1. **No internet, enforced by Apple.** Keymend runs in the App Sandbox with no network permission. macOS blocks any connection, even from a future bug.
2. **Nothing you type is saved, unless you turn on Learning.** Only the word you're typing right now is held in memory, and it's cleared when the word ends, when you switch apps, or click. No logs, analytics or crash reports. With Learning on, single words and counts are kept, encrypted, on this Mac ([exactly what](#learning-dictionary)).
3. **Password fields stop Keymend seeing keys.** They turn on macOS Secure Input, which stops Keymend from receiving keys. Keymend also checks for it, does nothing while it's on, and checks once more right before it types any fix. **The exception is terminal password prompts.** They only use Secure Input if the terminal turns it on, so otherwise the keys reach Keymend's memory ([details](#passwords-in-terminals)).
4. **Only two permissions**, listed above.
5. **No third-party code.** Plain Swift and Apple frameworks. No analytics, no auto-updater.
6. **Open source.** Read it, or build it yourself.

`scripts/check-privacy.sh` checks the entitlements, the source and the built app for these rules. CI runs it on every push.

## Terminals and Careful Mode

Keymend only sees key presses. It can't read the screen or tell what's running in a terminal. So in Careful Mode a line stays off unless it looks like plain language, such as a message to a coding assistant.

**It leaves a line alone when:**

- Keymend hasn't seen it from its start. After you switch to the terminal, nothing is fixed until you press Return once.
- It starts with a known command (`cd`, `git`, `brew`, `sudo`, `python` and many more), or with `!`, `./`, `$` or a path.
- Its first word isn't a real word.
- It comes right after a command line, a trailing `\` or `<<`. The next line could be a password prompt or more of the same command.
- You pasted, clicked, pressed an arrow key, Tab, Escape or a Control or Command shortcut. The rest of that line stays off.
- It's inside a ` ``` ` code block.

**It stops at the first word that looks like code or that it doesn't recognize:** anything containing `/ \ . _ - = $ ~ @ : # *` or backticks (a full stop or comma at the end of a word is fine), flags, paths, links, emails, ALL CAPS, camelCase, digits, or a misspelled word with no confident fix.

**It never fixes:**

- Words in quotes.
- A misspelled word before two correctly spelled words have appeared on the line.
- The last word when you press Return. Keymend never presses Return, so a fix can't run a command by itself, but it can change one you then run.

To turn it off fast, use "Skip in [app]" in the menu, or Control-Option-K to pause everywhere.

### Known gaps

**Careful Mode can't promise that commands are never changed.** A command Keymend has never heard of, with plain words after it, looks exactly like a sentence. These can still change:

```
deploy the staging servr
install the latest packge
restart the main sevice
```

Other limits:

- Lines inside a multi-line command, after the first, and lines typed into a program's own prompt (a database shell, for example) can look like prose.
- Programs where keys are commands, like vim or less, may receive a Delete or a letter if what you type there looks like a sentence.
- Keys posted by text expanders and similar tools are detected only if they don't present themselves as a real keyboard.
- Fixes are limited on purpose. Expect fewer fixes than in other apps.

The tests in `CarefulModeTests.swift` type more than 100 made-up commands, paths, code lines and prose lines key by key, with a stand-in spell checker that wants to change every word it doesn't know. They include a known-gaps test that lists lines which still change, so the limit stays visible.

### Passwords in terminals

A terminal password prompt (`sudo`, `ssh`) doesn't have to use Secure Input. If it doesn't, the keys reach Keymend's memory like any others. Keymend writes nothing down, but it holds the current word in memory while you type it, and a passphrase with spaces could be "fixed", which would make the login fail.

That's why Careful Mode is on by default only in Ghostty, which turns on Secure Input when it detects a password prompt. Ghostty's detection is a best guess and doesn't work over SSH. Keep it on by adding this line to your Ghostty config (it's on by default):

```
macos-auto-secure-input = true
```

Terminal, iTerm and other terminals stay skipped unless you change that, and Keymend warns you first. Turning on Secure Keyboard Entry in a terminal protects its password prompts, and it also stops Keymend working in that terminal.

## Learning Dictionary

**Off until you turn it on,** in Settings → Learning.

| It notices | When | What happens |
| --- | --- | --- |
| A correction: you delete back and retype a flagged word, with at most 2 letters different | Within 5 seconds, 3 times on at least 2 different days | Proposed as a rule. **Nothing changes until you approve it** |
| An undo: you press Delete right after a fix | 2 times | That fix stops, automatically |
| A word the spell checker flags, has no confident fix for, and you don't go back to | 5 times on at least 3 different days | Treated as known, automatically |

Only words Apple's spell checker flags as misspelled are ever kept. If it doesn't answer within 50 ms, the word is skipped, not kept.

Anything that makes Keymend do less applies by itself. Anything that makes it type something new needs your approval. In Settings → Learning you can review, approve, edit, reject, delete, search, pause, clear everything, and export or import.

**Importing a file can't approve anything.** Imported corrections wait for your approval like ones learned here, unless you already approved the same rule. Anything in the file that Keymend couldn't have learned itself (not a plain word, for example) is left out, and Keymend tells you how many.

**Stored for each item, and nothing else:** the kind, the typed word, the correction, a count, the number of days it was seen, the last day it was seen (no time), and its status.

**Never stored:** sentences, neighbouring words, the app, window, document or website, the time of day, or anything from a password field or an excluded app.

**It doesn't learn from:**

- Anything that looks like code, a path, an email or a handle. You can add emails and handles by hand.
- Words in quotes or backticks.
- Terminals or other Careful Mode apps. What it learned isn't used there either.
- Anything typed while an input method (Chinese, Japanese, Korean and similar) is selected.
- Apps on the exclusion list. The default lists password managers only. **Add your banking apps yourself in Settings → Learning → Excluded Apps.**

**Where it lives:** one file in Keymend's sandbox container, encrypted with AES-256-GCM. The key is in your login Keychain. Words not approved or made active are forgotten after 90 days unseen. Learned words stay out of the Mac's shared Learn Spelling list. An export is a separate file encrypted with a passphrase you choose.

**What changes when it's on:**

- To catch a correction, Keymend keeps the last finished word in memory for about 5 seconds. With Learning off, it's cleared the moment the word ends.
- Keymend writes that one encrypted file.

**What it can't do:**

- Encryption protects the file if it's copied, or read from a backup or a stolen disk. It doesn't protect against malware running as you while your Mac is unlocked, and the list is in memory while Keymend runs.
- Keymend can't tell which website you're on, so a bank's website isn't excluded. Only its password fields are, through Secure Input.
- A letters-only password typed into an ordinary field that doesn't use Secure Input could be recorded, if you mistype and retype it or type it often enough. It would be encrypted and visible in your review list, where you can delete it.
- The list will include people's and clients' names, as single words. That's why it's encrypted and reviewable.

## How it works

Keymend listens to key presses with a listen-only event tap. When a word ends, it asks `NSSpellChecker` (the same on-device engine as Mac autocorrect) for a correction, giving up after 50 ms. If an earlier check is still running, it doesn't wait for it and leaves the word alone. If there is a correction, it presses Delete once per character of the word and the punctuation after it, then types the correction. If you've already pressed another key by then, it drops the fix. That covers most fast typing, but a key pressed in the instant the fix is being typed can still land in the middle of it, so a word can occasionally come out garbled. If you see that, please [open an issue](https://github.com/garoknows/keymend/issues).

If Keymend can't be sure where the cursor is (after a click, an arrow key, a shortcut or switching apps, or when a fix or undo had to be dropped), it leaves the next word alone.

If macOS stops Keymend's keyboard access (for example when Input Monitoring is turned off and on again), Keymend notices within 30 seconds and starts it again. Until then the menu says it isn't working and offers Try Again.

## Build and test

```sh
swift test --package-path Packages/KeymendCore   # word engine and keyboard harness tests
scripts/check-privacy.sh                         # privacy rules
brew install xcodegen && xcodegen generate       # Xcode project from project.yml
```

The word engine and keyboard bridge live in `Packages/KeymendCore` with no UI. The harness tests feed real `CGEvent`s through the bridge into a simulated text field and check exactly what text arrives, including typing at 400 words per minute. That field applies each fix as one unit, so these tests don't catch a key landing in the middle of a fix.

## Known limits

- English-focused: it follows the Mac's current spell-checker language. More languages are planned.
- Accented letters typed with dead keys (Option-E, then E) end tracking for that word.
- **Input methods pause Keymend.** While an input method for Chinese, Japanese, Korean, Vietnamese or a similar language is selected, Keymend pauses itself (no fixes, no learning) and the menu says so. It starts again by itself when you switch back to a regular keyboard layout. This includes the Japanese input method's alphanumeric mode: switch to ABC or U.S. to use Keymend.
- Planned: your Mac's Text Replacements in every app, capitalize sentences, double-space period, Homebrew.

## License

MIT. See [LICENSE](LICENSE). Not affiliated with Apple.
