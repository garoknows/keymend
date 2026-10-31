<p align="center"><img src="docs/images/icon.png" width="112" alt=""></p>

<h1 align="center">keymend</h1>

<p align="center">Spelling fixes as you type, in every Mac app.<br>
<a href="https://garoknows.github.io/keymend/">Website</a> · <a href="https://github.com/garoknows/keymend/releases">Download</a> · <a href="docs/PRIVACY.md">Privacy</a> · <a href="docs/INSTALL.md">Install guide</a></p>

Mac autocorrect only works in apps built with Apple's own text tools, like Notes, Mail and Messages. In Chrome, Arc, Dia, Slack, Obsidian, the Claude and ChatGPT desktop apps and other apps built on web technology, typos just get a red underline. No Mac setting changes that.

Keymend is a small menu bar app that fixes them as you type, in every app. It uses only Apple's built-in spell checker and never connects to the internet.

<p align="center"><img src="docs/images/menu.png" width="420" alt="The Keymend menu: Keymend is On, Fixed 42 typos today, Skip in Slack, Settings, Quit"></p>

## What it does

- **Fixes a word when it ends.** After you type a space or `, ; ! ?`, the finished word is checked. If Apple's spell checker has a confident correction, Keymend swaps it in. `teh ` becomes `the `.
- **Instant undo.** Press Delete right after a fix to get your word back. Keymend then leaves that word alone until you quit it.
- **Pause anytime.** The switch in the menu, or Control-Option-K from anywhere.
- **Skips apps.** Off by default in terminals, code editors, password managers and apps that already autocorrect (Ghostty, Terminal, iTerm, VS Code, Xcode, Cursor, Word, Notes, Mail, Pages, Messages, Safari and more). Add or remove apps in Settings, or with "Skip in [app]" in the menu.
- **Smart skips.** Never touches ALL CAPS, words with numbers, links, email addresses, file paths, @mentions, #tags, or anything inside `backticks`.
- **Your words.** A personal dictionary of words to never change. It starts empty and is shared with the Mac's own "Learn Spelling" list.
- **Today's count.** The menu shows how many typos it fixed today. It counts; it never keeps the words.

Return and Tab end a word without fixing it, on purpose: in chat apps Return sends the message immediately, and a fix typed after that would land in the empty box.

## Install

1. Download `Keymend-1.0.0.dmg` from [Releases](https://github.com/garoknows/keymend/releases), open it and drag **Keymend** into Applications.
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

No screen recording, files, contacts, location or network.

## Privacy, in plain English

To fix typing, an app has to see your keys. That makes Keymend technically a keylogger, so these rules matter. Each one is enforced by macOS or checked automatically on every change ([details](docs/PRIVACY.md)):

1. **No internet, enforced by Apple.** Keymend runs in the App Sandbox with no network permission. macOS blocks any connection, even from a future bug.
2. **Nothing typed is saved.** Only the word you're typing right now is held in memory, and it's cleared when the word ends, when you switch apps, or click. No logs, files, analytics or crash reports.
3. **Passwords are never seen.** Password fields turn on macOS Secure Input, which stops Keymend from receiving keys. Keymend also checks for it and does nothing while it's on.
4. **Only two permissions**, listed above.
5. **No third-party code.** Plain Swift and Apple frameworks. No analytics, no auto-updater.
6. **Open source.** Read it, or build it yourself.

`scripts/check-privacy.sh` checks the entitlements, the source and the built app for these rules. CI runs it on every push.

## How it works

Keymend listens to key presses with a listen-only event tap. When a word ends, it asks `NSSpellChecker` (the same on-device engine as Mac autocorrect) for a correction, giving up after 50 ms. If there is one, it presses Delete once per character of the word and the punctuation after it, then types the correction. If you've already pressed another key by then, it does nothing, so fast typing never loses or doubles characters.

If Keymend can't be sure where the cursor is (after a click, an arrow key, a shortcut or switching apps), it leaves the next word alone.

## Build and test

```sh
swift test --package-path Packages/KeymendCore   # word engine and keyboard harness tests
scripts/check-privacy.sh                         # privacy rules
brew install xcodegen && xcodegen generate       # Xcode project from project.yml
```

The word engine and keyboard bridge live in `Packages/KeymendCore` with no UI. The harness tests feed real `CGEvent`s through the bridge into a simulated text field and check exactly what text arrives, including typing at 400 words per minute.

## Known limits (v1.0)

- English-focused: it follows the Mac's current spell-checker language. More languages are planned for 1.1.
- Accented letters typed with dead keys (Option-E, then E) end tracking for that word.
- Input methods for Chinese, Japanese and Korean aren't supported.
- Coming in 1.1: your Mac's Text Replacements in every app, capitalize sentences, double-space period, Homebrew.

## License

MIT. See [LICENSE](LICENSE). Not affiliated with Apple.
