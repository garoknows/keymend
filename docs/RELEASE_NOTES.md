**Early preview.** Keymend is being tested day to day by its author. Expect rough edges.

Keymend fixes spelling as you type, in every Mac app, using Apple's own on-device spell checker. It never connects to the internet.

### In this release
- Fixes a word when it ends (space, or `, ; ! ?`), only when Apple's spell checker is confident.
- Press Delete right after a fix to undo it; that word is then left alone.
- Pause from the menu or with Control-Option-K.
- Skip list (terminals, code editors, password managers and apps that already autocorrect), editable in Settings.
- Never changes ALL CAPS, words with numbers, links, emails, paths, @mentions, #tags or `code`.
- Personal never-correct list, shared with the Mac's "Learn Spelling".
- Today's fix count (numbers only). Launch at login.
- Runs in the App Sandbox with no network permission.

### Install
1. Download `Keymend-0.1.0.dmg` below, open it and drag **Keymend** into Applications.
2. This preview is **not notarized** yet. The first time, open Keymend, then go to **System Settings → Privacy & Security** and click **Open Anyway**.
3. Follow the setup window to allow Input Monitoring and typing fixes.

Step-by-step guide with pictures: [docs/INSTALL.md](https://github.com/garoknows/keymend/blob/main/docs/INSTALL.md)
