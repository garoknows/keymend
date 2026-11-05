### Next release (not published yet)
- **Careful Mode for terminals, on by default in Ghostty only.** It fixes lines that look like plain language and leaves anything that looks like a command or code alone. It can't promise commands are never changed: see "Known gaps" in the README.
- **Terminal password prompts can reach Keymend's memory** in a terminal where Keymend is on, unless that terminal turns on Secure Input. Ghostty does when it detects a prompt, but not over SSH.
- Typed letters now use their real keys, so programs that read the physical key should get the right letter. Not yet tested in those programs.
- If you've changed your skip list before, Ghostty stays on it until you choose "Don't Skip in Ghostty".
- Permissions are checked every 30 seconds once granted, instead of every 2.
- **Learning Dictionary, off until you turn it on.** Learns single words you often fix or undo, encrypted on your Mac, and you review everything. It adds one file and one permission limited to files you pick. See the README for exactly what it stores.

Keymend fixes spelling as you type, in every Mac app, using Apple's own on-device spell checker. It never connects to the internet.

### What it does
- Fixes a word when it ends (space, or `, ; ! ?`), only when Apple's spell checker is confident.
- Press Delete right after a fix to undo it; that word is then left alone.
- Pause from the menu or with Control-Option-K.
- Skip list (terminals, code editors, password managers and apps that already autocorrect), editable in Settings.
- Never changes ALL CAPS, words with numbers, links, emails, paths, @mentions, #tags or `code`.
- Personal never-correct list, shared with the Mac's "Learn Spelling".
- Today's fix count (numbers only). Launch at login.
- Runs in the App Sandbox with no network permission.

### New in 1.0.2
- New app icon: a white bold K on a dark ink tile, matching the menu bar. It looks right in light mode, dark mode and the tinted and clear icon styles of current macOS.

### New in 1.0.1
- New app icon: a bold K, matching the menu bar icon.

### New in 1.0
- Menu bar icon is now a bold K.
- Signed with a Developer ID and notarized by Apple.

### Install
1. Download `Keymend-1.0.2.dmg` below, open it and drag **Keymend** into Applications.
2. Open Keymend. It's notarized, so it opens normally.
3. Follow the setup window to allow Input Monitoring and typing fixes.

Step-by-step guide with pictures: [docs/INSTALL.md](https://github.com/garoknows/keymend/blob/main/docs/INSTALL.md)
