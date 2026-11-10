**Pre-release, a test build.** This beta is for trying word suggestions. They've been tested in simulation and need daily use on a real Mac before they're part of the main download. [Keymend 1.1.1](https://github.com/garoknows/keymend/releases/tag/v1.1.1) is the main download.

Keymend fixes spelling as you type, in every Mac app, using Apple's own on-device spell checker. It never connects to the internet.

### New in 1.2.0-beta.2
- **Built on 1.1.1,** so every fix from the November 2026 review is in this beta too. beta.1 was made before those fixes and doesn't have them.
- **Suggestions follow the same safety rules as fixes.** The bar never shows, and the pick keys always reach your app, while an input method (Chinese, Japanese, Korean and similar) is selected, while Keymend is paused, or in a skipped app. This holds even in the split second before the bar disappears.
- **A slow spell checker can't hold up suggestions.** Completions use the same 50 ms limit as fixes, and while an earlier check is still running the bar shows only the word as typed.

### Word suggestions, on by default in this build
- After two letters, a small bar shows your word in quotes and up to three completions from Apple's on-device spell checker.
- **Pick with Option+1, 2, 3 or 4, or a click.** A completion is typed with a space. The quoted word stays as typed and isn't autocorrected until you quit.
- **Keymend can block the pick keys from reaching your app, only while the bar is showing.** Every other key passes through unchanged. If Option plus a number types something you need, like # or @, choose other keys in Settings → General → Suggestions.
- **The bar sits at the bottom center of the front window, not at your cursor,** because reading the cursor's position would need more access than the App Sandbox allows. The sandbox and permissions are unchanged.
- The bar never shows in skipped apps, Careful Mode apps like Ghostty, password fields, or while an input method is selected.
- **Known risk:** one developer reports that turning off Accessibility while an active tap runs froze all input until a forced restart. Keymend stops its tap if either permission is lost, and clicking a switch in System Settings already hides the bar, but this hasn't been tried on a real Mac. See "Known issues" in the README on the `feature/suggestions-v2` branch.

### Fixed in 1.1.1 (also in this beta)
- **Password fields that appear during a fix.** Keymend checks one last time, right before it types, whether a password field has focus.
- **Chinese, Japanese, Korean and other input methods.** Keymend pauses itself while one is selected.
- **Learning only keeps words the spell checker really flagged.** A slow answer means the word is skipped.
- **Importing a learned-words file can't approve anything.** Imported corrections wait for your approval.
- **Keymend recovers when macOS stops its keyboard access,** within 30 seconds, and the menu says when it isn't working.
- **Undo kept in step** when another key lands before an undo is typed.
- **Never-correct words.** Removing a word only removes it from the Mac's Learn Spelling list if Keymend put it there.
- **Safer releases.** Tools are installed and checked before the signing certificate is unlocked, and publishing is kept apart from the signing secrets.

### What it does
- Fixes a word when it ends (space, or `, ; ! ?`), only when Apple's spell checker is confident.
- Press Delete right after a fix to undo it; that word is then left alone.
- Pause from the menu or with Control-Option-K.
- Skip list (terminals, code editors, password managers and apps that already autocorrect), editable in Settings.
- **Careful Mode for terminals**, on by default in Ghostty only. It fixes lines that look like plain language and leaves commands and code alone.
- **Learning Dictionary, off until you turn it on.** Learns single words you often fix or undo, encrypted on your Mac, and you review everything.
- Never changes ALL CAPS, words with numbers, links, emails, paths, @mentions, #tags or `code`.
- Personal never-correct list, shared with the Mac's "Learn Spelling".
- Today's fix count (numbers only). Launch at login.
- Runs in the App Sandbox with no network permission.

### Install
1. Download `Keymend-1.2.0-beta.2.dmg` below, open it and drag **Keymend** into Applications.
2. Open Keymend. It's notarized, so it opens normally.
3. Follow the setup window to allow Input Monitoring and typing fixes.

Step-by-step guide with pictures: [docs/INSTALL.md](https://github.com/garoknows/keymend/blob/main/docs/INSTALL.md)
