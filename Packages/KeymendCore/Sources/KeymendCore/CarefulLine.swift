/// What the spell checker thinks of a word.
public enum SpellVerdict: Equatable, Sendable {
    /// Spelled correctly, or a word the user told Keymend to leave alone.
    case correct
    /// Misspelled, with a confident correction.
    case fix(String)
    /// Misspelled, with no confident correction (or the checker ran out of time).
    case unknown
}

/// The rules for Careful mode: is this line plain-language typing, or could it be a command?
///
/// Keymend sees only keys, so it can't know what a terminal is running. A line therefore stays
/// off unless it proves it's prose. Everything here is one-way: anything Keymend can't follow,
/// or that looks like code, turns off the rest of the line.
///
/// Privacy: this keeps a few numbers and switches about the line, never the words.
public struct CarefulLine: Sendable {
    /// Correctly spelled words needed on a line before anything on it can be fixed.
    public static let proseWordsNeeded = 2

    /// True when the rest of the line must stay as typed. A line starts off until Keymend has
    /// seen it from its beginning, which means after a Return.
    private(set) public var isOff = true
    private var wordsSeen = 0
    private var proseWords = 0
    private var insideDoubleQuotes = false
    private var insideSingleQuotes = false
    /// The line looks like a command or opens multi-line input, so the next line is off too.
    /// It may be a password prompt, a heredoc or a continuation.
    private var nextLineOff = false
    /// Inside a ``` code block, which lasts across lines until it's closed.
    private(set) public var insideCodeBlock = false

    public init() {}

    /// Keymend lost track of the line (click, arrow, Tab, paste, shortcut, Escape).
    public mutating func stop() {
        isOff = true
    }

    /// Returns the fix for a word that just ended, or nil to leave it exactly as typed.
    public mutating func consider(_ raw: String, verdict: (String) -> SpellVerdict) -> String? {
        // These are tracked even on a line that's already off.
        if raw.contains("<<") { nextLineOff = true }
        if CarefulRules.countOf("```", in: raw) % 2 == 1 { insideCodeBlock.toggle() }
        guard !raw.isEmpty, !isOff, !insideCodeBlock else { return nil }

        let isFirst = wordsSeen == 0
        wordsSeen += 1
        if isFirst, CarefulRules.startsCommand(raw) {
            stopAsCommand()
            return nil
        }
        if updateQuotes(for: raw) {
            // Quoted words are never fixed. A line that opens with a quote isn't trusted as prose.
            if isFirst { stopAsCommand() }
            return nil
        }
        guard let word = CarefulRules.plainWord(raw) else {
            stop(isFirst: isFirst)
            return nil
        }
        switch verdict(word) {
        case .correct:
            if CarefulRules.countsAsProse(word) { proseWords += 1 }
            return nil
        case .fix(let suggestion):
            guard proseWords >= CarefulLine.proseWordsNeeded, word.count >= 3,
                  CarefulRules.isPlainSuggestion(suggestion) else {
                stop(isFirst: isFirst)
                return nil
            }
            return suggestion
        case .unknown:
            stop(isFirst: isFirst)
            return nil
        }
    }

    /// Return was pressed. `lastWord` is what was typed after the last space; it's checked but
    /// never fixed, because Return may already have run it.
    public mutating func endLine(lastWord: String, verdict: (String) -> SpellVerdict) {
        _ = consider(lastWord, verdict: verdict)
        if lastWord.hasSuffix("\\") { nextLineOff = true }
        isOff = nextLineOff
        nextLineOff = false
        wordsSeen = 0
        proseWords = 0
        insideDoubleQuotes = false
        insideSingleQuotes = false
    }

    private mutating func stop(isFirst: Bool) {
        if isFirst { stopAsCommand() } else { stop() }
    }

    private mutating func stopAsCommand() {
        isOff = true
        nextLineOff = true
    }

    /// Updates the quote state and returns true when this word is in or touches a quote.
    /// Apostrophes inside a word (don't) aren't quotes.
    private mutating func updateQuotes(for raw: String) -> Bool {
        let wasInside = insideDoubleQuotes || insideSingleQuotes
        var touched = false
        for ch in raw where CarefulRules.doubleQuotes.contains(ch) {
            insideDoubleQuotes.toggle()
            touched = true
        }
        if let first = raw.first, CarefulRules.singleQuotes.contains(first) {
            insideSingleQuotes.toggle()
            touched = true
        }
        let core = raw.dropLast(CarefulRules.sentencePunctuationCount(in: raw))
        if raw.count > 1, let last = core.last, CarefulRules.singleQuotes.contains(last), insideSingleQuotes {
            insideSingleQuotes = false
            touched = true
        }
        return wasInside || touched
    }
}

public enum CarefulRules {
    static let doubleQuotes: Set<Character> = ["\"", "\u{201C}", "\u{201D}"]
    static let singleQuotes: Set<Character> = ["'", "\u{2018}", "\u{2019}"]
    static let sentencePunctuation: Set<Character> = [".", ",", ";", "!", "?"]
    static let lineStartSymbols: Set<Character> = [
        "!", "$", ".", "/", "~", "#", "*", "@", "-", "=", "&", "|", "<", ">", "(", ")", "[", "]",
        "{", "}", "\\", "`", "%", "^", "+", ":", ";", ",", "?", "_",
    ]

    /// Tools and shell words that aren't everyday words, so capitals don't change what they are.
    static let tools: Set<String> = [
        "cd", "ls", "git", "gh", "brew", "npm", "npx", "yarn", "pnpm", "bun", "deno", "rm", "mv", "cp", "sudo", "su",
        "claude", "python", "python3", "pip", "pip3", "swift", "swiftc", "xcodebuild", "xcrun", "xcodegen", "cargo",
        "rustc", "node", "ruby", "gem", "rake", "docker", "kubectl", "helm", "terraform", "curl", "wget", "ssh", "scp",
        "sftp", "rsync", "tar", "gzip", "unzip", "grep", "rg", "fd", "sed", "awk", "chmod", "chown", "mkdir", "rmdir",
        "ps", "htop", "vim", "vi", "nvim", "nano", "emacs", "tmux", "zsh", "bash", "sh", "fish", "pwd", "whoami",
        "defaults", "launchctl", "codesign", "plutil", "gcloud", "aws", "az", "psql", "mysql", "sqlite3", "redis",
        "mongo", "ffmpeg", "jq", "yq", "gitleaks", "hdiutil", "diskutil", "dig", "ping", "nc", "lsof", "pkill", "killall",
        "php", "java", "javac", "gradle", "mvn", "dotnet", "perl", "lua", "ghc", "clang", "gcc", "cmake", "ninja",
    ]

    /// Commands and code keywords that are also everyday words. They count only in lowercase, so
    /// "Make sure this works" is still prose. A lowercase "make sure" line isn't fixed.
    static let wordCommands: Set<String> = [
        "make", "go", "open", "kill", "cat", "echo", "find", "touch", "top", "head", "tail", "more", "less", "man",
        "which", "export", "source", "clear", "exit", "history", "sort", "diff", "patch", "tee", "watch", "time",
        "date", "test", "read", "set", "type", "say", "zip", "alias", "unset", "wait", "jobs", "fg", "bg", "env",
        "for", "while", "if", "else", "do", "done", "fi", "then", "case", "def", "class", "import", "from", "return",
        "function", "let", "var", "const", "print", "select", "insert", "update", "delete", "drop", "create", "alter",
    ]

    /// True when a line's first word means the whole line is treated as a command.
    public static func startsCommand(_ raw: String) -> Bool {
        guard let first = raw.first else { return false }
        if lineStartSymbols.contains(first) || first.isNumber { return true }
        if raw.contains("/") || raw.contains("=") { return true }
        let word = String(raw.dropLast(sentencePunctuationCount(in: raw)))
        return tools.contains(word.lowercased()) || wordCommands.contains(word)
    }

    /// The word without its sentence punctuation, if it's made only of letters and in-word
    /// apostrophes and passes every rule. Nil for anything that looks like code: / \ . _ - = $ ~
    /// @ : # * backticks, digits, ALL CAPS, camelCase, flags, paths, URLs and emails.
    public static func plainWord(_ raw: String) -> String? {
        let word = String(raw.dropLast(sentencePunctuationCount(in: raw)))
        guard let first = word.first, first.isLetter, let last = word.last, last.isLetter else { return nil }
        guard word.allSatisfy({ $0.isLetter || SkipRules.apostrophes.contains($0) }) else { return nil }
        return SkipRules.skipReason(for: word) == nil ? word : nil
    }

    /// One-letter "words" are often answers to a prompt or keys in a program, so only the two
    /// real ones count as evidence of prose.
    static func countsAsProse(_ word: String) -> Bool {
        word.count >= 2 || word.lowercased() == "a" || word.lowercased() == "i"
    }

    static func isPlainSuggestion(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isLetter || $0 == " " || SkipRules.apostrophes.contains($0) }
    }

    static func sentencePunctuationCount(in raw: String) -> Int {
        var n = 0
        for ch in raw.reversed() {
            guard sentencePunctuation.contains(ch) else { break }
            n += 1
        }
        return n
    }

    static func countOf(_ needle: String, in text: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var n = 0
        var rest = Substring(text)
        while let r = rest.range(of: needle) {
            n += 1
            rest = rest[r.upperBound...]
        }
        return n
    }
}

/// How Keymend behaves in one app.
public enum AppMode: Equatable, Sendable {
    case on
    case careful
    case skip
}

/// Decides each app's mode. A terminal is never in plain On mode: if it's taken off the skip
/// list it gets the Careful rules, because a plain fix there could change a command.
public enum AppModePolicy {
    /// Terminal apps Keymend knows about.
    public static let terminals: Set<String> = [
        "com.mitchellh.ghostty",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
        "org.tabby",
    ]

    public static func mode(for bundleID: String, skipList: [String], carefulList: [String]) -> AppMode {
        if skipList.contains(bundleID) { return .skip }
        if carefulList.contains(bundleID) || terminals.contains(bundleID) { return .careful }
        return .on
    }
}
