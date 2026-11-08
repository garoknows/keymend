Keymend fixes spelling as you type, in every Mac app, using Apple's own on-device spell checker. It never connects to the internet.

1.1.1 fixes everything found in an independent review of Keymend's code and release process in November 2026, and makes the 1.1 features (Careful Mode for terminals and the optional Learning Dictionary) the main download.

### Fixed in 1.1.1
- **Password fields that appear during a fix.** Keymend now checks one last time, right before it types, whether a password field has focus (macOS Secure Input). Before, a password dialog that popped up in the split second while a word was being checked could receive the fix.
- **Chinese, Japanese, Korean and other input methods.** Keymend now pauses itself while one is selected, so it never deletes text you're still composing and never learns from it. The menu says it's paused, and it starts again when you switch back to a regular keyboard layout.
- **Learning only keeps words the spell checker really flagged.** If the spell checker was slow to answer, a correctly spelled word (a name, or "salary") could be kept. Now a slow answer means the word is skipped. One slow check also can't hold up the next ones any more.
- **Importing a learned-words file can't approve anything.** Imported corrections now wait for your approval, the same as ones learned on this Mac. Anything that isn't a plain word is left out, and a damaged or hostile file can no longer freeze Keymend.
- **Keymend recovers when macOS stops its keyboard access** (for example after turning Input Monitoring off and on). Before, the menu said "On" while nothing worked until the Mac slept and woke. Now it restarts within 30 seconds, and the menu says when it isn't working.
- **Undo kept in step.** If you pressed Delete to undo a fix and another key landed first, Keymend could lose track of the word on screen. Now it leaves that word alone.
- **Never-correct words.** Removing a word from your list no longer removes it from the Mac's own Learn Spelling list if you had added it there yourself before.
- **Safer releases.** The build that signs Keymend now installs every tool before the signing certificate is unlocked, checks the exact tool it downloads, and keeps the publishing step separate from the signing secrets.

### What it does
- Fixes a word when it ends (space, or `, ; ! ?`), only when Apple's spell checker is confident.
- Press Delete right after a fix to undo it; that word is then left alone.
- Pause from the menu or with Control-Option-K.
- Skip list (terminals, code editors, password managers and apps that already autocorrect), editable in Settings.
- **Careful Mode for terminals**, on by default in Ghostty only. It fixes lines that look like plain language and leaves commands and code alone. It can't be perfect: see "Terminals and Careful Mode" in the README.
- **Learning Dictionary, off until you turn it on.** Learns single words you often fix or undo, encrypted on your Mac, and you review everything. See the README for exactly what it stores.
- Never changes ALL CAPS, words with numbers, links, emails, paths, @mentions, #tags or `code`.
- Personal never-correct list, shared with the Mac's "Learn Spelling".
- Today's fix count (numbers only). Launch at login.
- Runs in the App Sandbox with no network permission.

### Install
1. Download `Keymend-1.1.1.dmg` below, open it and drag **Keymend** into Applications.
2. Open Keymend. It's notarized by Apple, so it opens normally.
3. Follow the setup window to allow Input Monitoring and typing fixes.

Step-by-step guide with pictures: [docs/INSTALL.md](https://github.com/garoknows/keymend/blob/main/docs/INSTALL.md)
