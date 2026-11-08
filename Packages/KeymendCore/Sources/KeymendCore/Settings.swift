import Foundation

/// Words the user never wants changed. Stored in the app's own UserDefaults (inside its
/// sandbox container). Ships empty.
public struct NeverCorrectList: Equatable, Sendable {
    public private(set) var words: [String]

    public init(words: [String] = []) {
        self.words = []
        for w in words { add(w) }
    }

    /// Adds a word. Returns false if it was empty, not a single word, or already there.
    @discardableResult
    public mutating func add(_ raw: String) -> Bool {
        let w = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !w.contains(where: { $0.isWhitespace }), w.count <= 64 else { return false }
        guard !contains(w) else { return false }
        words.append(w)
        words.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return true
    }

    public mutating func remove(_ word: String) {
        words.removeAll { $0.caseInsensitiveCompare(word) == .orderedSame }
    }

    public func contains(_ word: String) -> Bool {
        words.contains { $0.caseInsensitiveCompare(word) == .orderedSame }
    }
}

/// The Mac's shared "Learn Spelling" list, which every app's spell checker uses.
public protocol SystemSpellingList {
    func hasLearnedWord(_ word: String) -> Bool
    func learnWord(_ word: String)
    func unlearnWord(_ word: String)
}

extension AppleSpellChecker: SystemSpellingList {}

/// The never-correct words Keymend itself added to the Mac's "Learn Spelling" list. Only these
/// are taken off it again, so a word the user had taught the Mac before stays learned. Stored
/// next to the never-correct list, which already holds the same words.
public struct TaughtSpellings: Equatable, Sendable {
    public private(set) var words: [String]

    public init(words: [String] = []) {
        self.words = words
    }

    /// Adds `raw` to the Mac's list unless it's already there, and remembers if Keymend added it.
    public mutating func add(_ raw: String, to list: SystemSpellingList) {
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, !list.hasLearnedWord(word) else { return }
        list.learnWord(word)
        if !words.contains(word) { words.append(word) }
    }

    /// Takes `raw` off the Mac's list, only if Keymend put it there.
    public mutating func remove(_ raw: String, from list: SystemSpellingList) {
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let mine = words.filter { $0.caseInsensitiveCompare(word) == .orderedSame }
        for w in mine { list.unlearnWord(w) }
        words.removeAll { $0.caseInsensitiveCompare(word) == .orderedSame }
    }
}

/// Apps that use the Careful rules out of the box.
public enum DefaultCarefulList {
    public static let bundleIDs: [String] = ["com.mitchellh.ghostty"]
}

/// Apps where Keymend stays off. Defaults: terminals other than Ghostty, code editors and
/// apps that already autocorrect with Apple's own text system.
public enum DefaultSkipList {
    public static let bundleIDs: [String] = [
        // Terminals
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
        "org.tabby",
        // Code editors
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.apple.dt.Xcode",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "dev.zed.Zed",
        "com.sublimetext.4",
        // Apps that already autocorrect
        "com.microsoft.Word",
        "com.apple.Notes",
        "com.apple.mail",
        "com.apple.iWork.Pages",
        "com.apple.MobileSMS",
        "com.apple.Safari",
        "com.apple.TextEdit",
        // Password managers
        "com.1password.1password",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
    ]
}

/// Apps Keymend never learns from. The user can edit the list. No banking apps ship here: there
/// is no universal list, so the user adds their own.
public enum DefaultLearningExclusions {
    public static let bundleIDs: [String] = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
    ]
}

/// Today's number of fixes. Counts only; the words themselves are never stored.
public struct DailyFixCount: Codable, Equatable, Sendable {
    public var day: String
    public var count: Int

    public init(day: String = "", count: Int = 0) {
        self.day = day
        self.count = count
    }

    public static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The count for `date`, which is zero once the day has changed.
    public func count(on date: Date, calendar: Calendar = .current) -> Int {
        day == DailyFixCount.dayKey(for: date, calendar: calendar) ? count : 0
    }

    public mutating func increment(on date: Date, calendar: Calendar = .current) {
        let key = DailyFixCount.dayKey(for: date, calendar: calendar)
        if day != key { day = key; count = 0 }
        count += 1
    }

    public mutating func decrement(on date: Date, calendar: Calendar = .current) {
        let key = DailyFixCount.dayKey(for: date, calendar: calendar)
        if day == key, count > 0 { count -= 1 }
    }

    /// "Fixed 42 typos today."
    public static func summary(_ n: Int) -> String {
        switch n {
        case 0: return "No fixes yet today"
        case 1: return "Fixed 1 typo today"
        default: return "Fixed \(n) typos today"
        }
    }
}
